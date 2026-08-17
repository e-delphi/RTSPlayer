unit Tx.Server.Listener;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  IdContext,
  IdCustomTCPServer,
  IdTCPServer,
  IdSocketHandle,
  IdGlobal,
  IdException,
  IdExceptionCore,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  System.StrUtils,
  VMS.Rtsp.Messages,
  Vms.Server.LiveHub,
  Vms.Server.Api,
  Tx.Server.Session;

type
  TTxServerListener = class
  strict private
    FServer: TIdTCPServer;
    FLogger: ILogger;
    FClock: IClock;
    FPort: Word;
    FBindAddress: string;
    FRecordingsDir: string;
    FLoop: Boolean;
    FHub: TLiveHub;
    FApi: TApiRouter;
    procedure HandleConnect(AContext: TIdContext);
    procedure HandleDisconnect(AContext: TIdContext);
    procedure HandleExecute(AContext: TIdContext);
    function ReadRequest(AContext: TIdContext; out Req: TRtspRequest): Boolean;
  public
    // ABindAddress vazio = escuta em todas as interfaces.
    // AHub nil = /live/<camera> sai do arquivo, sem o caminho de memória.
    // AApi nil = a porta só fala RTSP.
    constructor Create(APort: Word; const ABindAddress, ARecordingsDir: string; ALoop: Boolean;
                       const ALogger: ILogger; const AClock: IClock; AHub: TLiveHub = nil;
                       AApi: TApiRouter = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

type
  TSessionHolder = class
  public
    Session: TTxSession;
    destructor Destroy; override;
  end;

destructor TSessionHolder.Destroy;
begin
  Session.Free;
  inherited;
end;

{ TTxServerListener }

constructor TTxServerListener.Create(APort: Word; const ABindAddress, ARecordingsDir: string;
                                     ALoop: Boolean;
                                     const ALogger: ILogger; const AClock: IClock;
                                     AHub: TLiveHub; AApi: TApiRouter);
begin
  inherited Create;
  FPort := APort;
  FBindAddress := Trim(ABindAddress);
  FRecordingsDir := ARecordingsDir;
  FLoop := ALoop;
  FHub := AHub;
  FApi := AApi;
  FLogger := ALogger;
  FClock := AClock;
  FServer := TIdTCPServer.Create(nil);
  FServer.DefaultPort := APort;
  FServer.OnConnect := HandleConnect;
  FServer.OnDisconnect := HandleDisconnect;
  FServer.OnExecute := HandleExecute;
end;

destructor TTxServerListener.Destroy;
begin
  Stop;
  FServer.Free;
  inherited;
end;

procedure TTxServerListener.Start;
var
  Binding: TIdSocketHandle;
  Shown: string;
begin
  // Sem Bindings o Indy escuta em 0.0.0.0 (a LAN inteira enxerga). Com o IP do
  // Tailscale aqui, só quem está no tailnet alcança o servidor.
  if FBindAddress <> '' then
  begin
    FServer.Bindings.Clear;
    Binding := FServer.Bindings.Add;
    Binding.IP := FBindAddress;
    Binding.Port := FPort;
  end;
  FServer.Active := True;
  if FBindAddress = '' then Shown := '0.0.0.0' else Shown := FBindAddress;
  FLogger.Info('tx.listener', Format('RTSP server listening on %s:%d, dir=%s, loop=%s',
    [Shown, FPort, FRecordingsDir, BoolToStr(FLoop, True)]));
end;

procedure TTxServerListener.Stop;
begin
  try
    if FServer.Active then FServer.Active := False;
  except
  end;
end;

procedure TTxServerListener.HandleConnect(AContext: TIdContext);
var
  Holder: TSessionHolder;
begin
  Holder := TSessionHolder.Create;
  Holder.Session := TTxSession.Create(AContext, FLogger, FClock, FRecordingsDir, FLoop,
                                      FHub, FApi);
  AContext.Data := Holder;
  AContext.Connection.IOHandler.ReadTimeout := 500;
  FLogger.Info('tx.listener', 'Client connected: ' + AContext.Binding.PeerIP);
end;

procedure TTxServerListener.HandleDisconnect(AContext: TIdContext);
var
  Holder: TSessionHolder;
begin
  Holder := AContext.Data as TSessionHolder;
  if Holder <> nil then
  begin
    if Holder.Session <> nil then
      Holder.Session.Cleanup;
    FLogger.Info('tx.listener', 'Client disconnected: ' + AContext.Binding.PeerIP);
  end;
end;

function TTxServerListener.ReadRequest(AContext: TIdContext; out Req: TRtspRequest): Boolean;
var
  Sb: TStringBuilder;
  Line: string;
  ContentLen: Integer;
  HeaderText: string;
  Buf: TIdBytes;
  BodyBytes: TBytes;
begin
  Req := nil;
  HeaderText := '';
  Sb := TStringBuilder.Create;
  try
    try
      Line := AContext.Connection.IOHandler.ReadLn(#10, IndyTextEncoding_UTF8);
    except
      on E: EIdReadTimeout do Exit(False);
      on E: Exception do Exit(False);
    end;
    Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    if Trim(Line) = '' then Exit(False);
    Sb.Append(Line).Append(#13#10);

    while True do
    begin
      try
        AContext.Connection.IOHandler.ReadTimeout := 5000;
        Line := AContext.Connection.IOHandler.ReadLn(#10, IndyTextEncoding_UTF8);
      except
        on E: Exception do Exit(False);
      end;
      Line := StringReplace(Line, #13, '', [rfReplaceAll]);
      Sb.Append(Line).Append(#13#10);
      if Trim(Line) = '' then Break;
    end;
    Sb.Append(#13#10);
    HeaderText := Sb.ToString;
  finally
    Sb.Free;
  end;

  Req := TRtspRequest.Create;
  try
    if not ParseRtspRequest(HeaderText, Req) then
    begin
      Req.Free;
      Req := nil;
      Exit(False);
    end;
    ContentLen := ParseContentLength(Req.Headers);
    if ContentLen > 0 then
    begin
      SetLength(Buf, ContentLen);
      try
        AContext.Connection.IOHandler.ReadBytes(Buf, ContentLen, False);
      except
        on E: Exception do
        begin
          Req.Free;
          Req := nil;
          Exit(False);
        end;
      end;
      SetLength(BodyBytes, ContentLen);
      if ContentLen > 0 then
        Move(Buf[0], BodyBytes[0], ContentLen);
      Req.Body := BodyBytes;
    end;
    Result := True;
  except
    Req.Free;
    Req := nil;
    raise;
  end;
end;

procedure TTxServerListener.HandleExecute(AContext: TIdContext);
var
  Holder: TSessionHolder;
  Req: TRtspRequest;
begin
  Holder := AContext.Data as TSessionHolder;
  if Holder = nil then Exit;
  if Holder.Session.StopFlag then
  begin
    try AContext.Connection.Disconnect; except end;
    Exit;
  end;
  try
    AContext.Connection.IOHandler.ReadTimeout := 500;
    if not ReadRequest(AContext, Req) then
    begin
      Sleep(10);
      Exit;
    end;
  except
    on E: Exception do
    begin
      Holder.Session.Cleanup;
      try AContext.Connection.Disconnect; except end;
      Exit;
    end;
  end;
  try
    FLogger.Debug('tx.listener', Format('< %s %s %s', [Req.Method, Req.Uri, Req.Version]));
    // Quem decide é a VERSÃO, não o método: OPTIONS existe nos dois protocolos,
    // e é o `HTTP/1.1` da linha do pedido que diz com quem se está falando.
    if StartsText('HTTP/', Req.Version) then
      Holder.Session.HandleHttpRequest(Req)
    else
      Holder.Session.HandleRequest(Req);
  finally
    Req.Free;
  end;
end;

end.
