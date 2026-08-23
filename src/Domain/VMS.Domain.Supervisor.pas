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
    // O que o servidor respondeu no SDP. SourceIsLive False = a câmera está
    // fora do ar e o que chega é gravação; MediaStartMs diz de quando.
    SourceIsLive: Boolean;
    MediaStartMs: Int64;
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
    // Roda na thread do supervisor: é ela que chama Session.Run, e é de lá que a
    // sessão avisa. Por isso escrever em FMetrics aqui não corre com ninguém.
    procedure SourceKnown(IsLive: Boolean; MediaStartMs: Int64);
    procedure SleepResponsive(Ms: Cardinal);
    // Config desta tentativa: igual à da câmera, com o endpoint que respondeu.
    function ConfigForAttempt: TCameraSessionConfig;
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
  VMS.Net.Probe,
  VMS.Dvrip.Session;

// A escolha é por TENTATIVA, não por sessão: sair de casa derruba o endereço
// local, e é a reconexão seguinte que tem de achar o caminho de fora sozinha.
// Ninguém respondendo, vai no primeiro assim mesmo — errar o palpite é melhor
// que não tentar, e o erro real aparece no log da conexão.
function TCameraSupervisor.ConfigForAttempt: TCameraSessionConfig;
var
  Idx, I: Integer;
begin
  Result := FConfig;
  if Length(FConfig.Endpoints) = 0 then Exit;
  if not SelectEndpoint(FConfig.Endpoints, FLogger, 'supervisor.' + FConfig.Name,
                        PROBE_TIMEOUT_MS, Idx) then
  begin
    // Ninguém respondeu. Se algum caminho é da tailnet, é ELE que se tenta: o
    // túnel pode estar caído, e é a sessão dele que sabe pedir para subir (ver
    // UsesTailscale). Senão, o primeiro da lista.
    Idx := 0;
    for I := 0 to High(FConfig.Endpoints) do
      if FConfig.Endpoints[I].UsesTailscale then
      begin
        Idx := I;
        Break;
      end;
    FLogger.Warn('supervisor.' + FConfig.Name,
      Format('nenhum dos %d caminhos respondeu; tentando "%s" assim mesmo',
        [Length(FConfig.Endpoints), FConfig.Endpoints[Idx].Name]));
  end;
  Result.Url := FConfig.Endpoints[Idx].Url;
  Result.User := FConfig.Endpoints[Idx].User;
  Result.Password := FConfig.Endpoints[Idx].Password;
  if Length(FConfig.Endpoints[Idx].Transports) > 0 then
    Result.Transports := FConfig.Endpoints[Idx].Transports;
  Result.UsesTailscale := FConfig.Endpoints[Idx].UsesTailscale;
end;

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
  // Até o SDP dizer o contrário, o que se espera é a câmera ao vivo.
  FMetrics.SourceIsLive := True;
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

procedure TCameraSupervisor.SourceKnown(IsLive: Boolean; MediaStartMs: Int64);
begin
  FMetrics.SourceIsLive := IsLive;
  FMetrics.MediaStartMs := MediaStartMs;
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
  Attempt: TCameraSessionConfig;
begin
  while FStopEvent.WaitFor(0) <> wrSignaled do
  begin
    SetState(svConnecting);
    WasStreaming := False;
    Session := nil;
    Dvrip := nil;
    Attempt := ConfigForAttempt;
    UseDvrip := SameText(Copy(Trim(Attempt.Url), 1, 5), 'dvrip');
    try
      try
        if UseDvrip then
        begin
          Dvrip := TDvripSession.Create(Attempt, FLogger, FClock, FStopEvent, FMediaSink);
          SetState(svStreaming);
          Dvrip.Run;
        end
        else
        begin
          Session := TCameraSession.Create(Attempt, FLogger, FClock, FDepkFactory, FStopEvent, FMediaSink);
          Session.OnSourceKnown := SourceKnown;
          // Tentativa nova: até o SDP responder, volta a valer a expectativa de
          // ao vivo. Sem isto, uma reconexão bem-sucedida herdaria o "é
          // gravação" da tentativa anterior.
          FMetrics.SourceIsLive := True;
          FMetrics.MediaStartMs := 0;
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
