unit VMS.Domain.Supervisor;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.Reconnect,
  VMS.Domain.MediaSink,
  VMS.Domain.Session;

type
  TSupervisorState = (svIdle, svConnecting, svStreaming, svDraining, svBackoff, svStopping);

  TSupervisorMetrics = record
    State: TSupervisorState;
    LastConnectedAtMs: Int64;
    LastDisconnectedAtMs: Int64;
    TotalReconnects: Cardinal;
    CurrentFile: string;
  end;

  TCameraSupervisor = class(TThread)
  strict private
    FConfig: TCameraSessionConfig;
    FLogger: ILogger;
    FClock: IClock;
    FDepkFactory: TDepacketizerFactoryFn;
    FPolicy: IReconnectPolicy;
    FMediaSink: IMediaSink;
    FStopEvent: TEvent;
    FState: TSupervisorState;
    FMetrics: TSupervisorMetrics;
    FCurrentSession: TCameraSession;
    procedure SetState(NewState: TSupervisorState);
    procedure SleepResponsive(Ms: Cardinal);
  protected
    procedure Execute; override;
  public
    constructor Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger;
                       const AClock: IClock; const ADepkFactory: TDepacketizerFactoryFn;
                       const APolicy: IReconnectPolicy; const AMediaSink: IMediaSink = nil);
    destructor Destroy; override;
    procedure Stop;
    function State: TSupervisorState;
    function Metrics: TSupervisorMetrics;
  end;

implementation

uses
  VMS.Dvrip.Session;

function StateToStr(S: TSupervisorState): string;
begin
  case S of
    svIdle:       Result := 'IDLE';
    svConnecting: Result := 'CONNECT';
    svStreaming:  Result := 'STREAM';
    svDraining:   Result := 'DRAIN';
    svBackoff:    Result := 'BACKOFF';
    svStopping:   Result := 'STOPPING';
  else
    Result := '?';
  end;
end;

{ TCameraSupervisor }

constructor TCameraSupervisor.Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger;
  const AClock: IClock; const ADepkFactory: TDepacketizerFactoryFn;
  const APolicy: IReconnectPolicy; const AMediaSink: IMediaSink);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConfig := AConfig;
  FLogger := ALogger;
  FClock := AClock;
  FDepkFactory := ADepkFactory;
  FPolicy := APolicy;
  FMediaSink := AMediaSink;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FState := svIdle;
  FillChar(FMetrics, SizeOf(FMetrics), 0);
  FMetrics.State := svIdle;
end;

destructor TCameraSupervisor.Destroy;
begin
  Stop;
  WaitFor;
  FStopEvent.Free;
  inherited;
end;

procedure TCameraSupervisor.Stop;
begin
  if FStopEvent <> nil then
    FStopEvent.SetEvent;
end;

procedure TCameraSupervisor.SetState(NewState: TSupervisorState);
begin
  if FState = NewState then Exit;
  FLogger.Info('supervisor.' + FConfig.Name,
    Format('%s -> %s', [StateToStr(FState), StateToStr(NewState)]));
  FState := NewState;
  FMetrics.State := NewState;
end;

function TCameraSupervisor.State: TSupervisorState;
begin
  Result := FState;
end;

function TCameraSupervisor.Metrics: TSupervisorMetrics;
begin
  Result := FMetrics;
end;

procedure TCameraSupervisor.SleepResponsive(Ms: Cardinal);
var
  WaitRes: TWaitResult;
begin
  if Ms = 0 then Exit;
  WaitRes := FStopEvent.WaitFor(Ms);
  if WaitRes = wrSignaled then ;
end;

procedure TCameraSupervisor.Execute;
var
  Session: TCameraSession;
  Dvrip: TDvripSession;
  Delay: Cardinal;
  WasStreaming: Boolean;
  UseDvrip: Boolean;
  StreamedOk: Boolean;
begin
  while FStopEvent.WaitFor(0) <> wrSignaled do
  begin
    SetState(svConnecting);
    WasStreaming := False;
    Session := nil;
    Dvrip := nil;
    UseDvrip := SameText(Copy(Trim(FConfig.Url), 1, 5), 'dvrip');
    try
      try
        if UseDvrip then
        begin
          Dvrip := TDvripSession.Create(FConfig, FLogger, FClock, FStopEvent, FMediaSink);
          SetState(svStreaming);
          Dvrip.Run;
        end
        else
        begin
          Session := TCameraSession.Create(FConfig, FLogger, FClock, FDepkFactory, FStopEvent, FMediaSink);
          FCurrentSession := Session;
          SetState(svStreaming);
          Session.Run;
        end;
        WasStreaming := True;
        FMetrics.LastConnectedAtMs := FClock.NowUtcMs;
        FPolicy.NotifySuccess;
      except
        on E: Exception do
        begin
          FLogger.Warn('supervisor.' + FConfig.Name, 'Cycle ended: ' + E.Message);
          if Session <> nil then
            FMetrics.CurrentFile := Session.CurrentOutputPath;
          // Se a conexão chegou a receber mídia, a queda é transiente -> reseta o
          // contador (segue reconectando). Se nunca produziu RTP, é falha real -> conta.
          StreamedOk := ((Session <> nil) and Session.StreamedOk) or
                        ((Dvrip <> nil) and Dvrip.StreamedOk);
          if StreamedOk then
            FPolicy.NotifySuccess
          else
            FPolicy.NotifyFailure;
          WasStreaming := False;
        end;
      end;
    finally
      SetState(svDraining);
      FMetrics.LastDisconnectedAtMs := FClock.NowUtcMs;
      if WasStreaming then
        Inc(FMetrics.TotalReconnects);
      FCurrentSession := nil;
      if Session <> nil then Session.Free;
      if Dvrip <> nil then Dvrip.Free;
    end;

    if FStopEvent.WaitFor(0) = wrSignaled then Break;

    // Limite de tentativas por câmera (0 = reconecta pra sempre). O contador só
    // conta falhas em que a câmera NUNCA entregou RTP (config/rede); quedas no
    // meio de um stream que funcionava resetam o contador (acima).
    if (FConfig.MaxReconnectAttempts > 0) and
       (FPolicy.Attempts >= Cardinal(FConfig.MaxReconnectAttempts)) then
    begin
      FLogger.Warn('supervisor.' + FConfig.Name,
        Format('desistindo após %d tentativa(s) sem sucesso (limite da câmera)', [FPolicy.Attempts]));
      Break;
    end;

    SetState(svBackoff);
    Delay := FPolicy.NextDelayMs;
    FLogger.Info('supervisor.' + FConfig.Name,
      Format('Backoff %d ms (attempts=%d)', [Delay, FPolicy.Attempts]));
    SleepResponsive(Delay);
  end;
  SetState(svStopping);
end;

end.
