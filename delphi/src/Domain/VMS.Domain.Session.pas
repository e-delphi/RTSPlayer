unit VMS.Domain.Session;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.DateUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.MediaSink,
  VMS.Net.Intf,
  VMS.Net.Tcp,
  VMS.Net.Udp,
  VMS.Rtsp.Url,
  VMS.Rtsp.Auth,
  VMS.Rtsp.Client,
  VMS.Rtsp.WireReader,
  VMS.Rtsp.Messages,
  VMS.Rtsp.Transport,
  VMS.Sdp.Types,
  VMS.Sdp.Parser,
  VMS.Rtp.Packet,
  VMS.Rtp.Demux,
  VMS.Depk.Intf,
  VMS.Depk.Base,
  VMS.Depk.H264,
  VMS.Depk.PCM,
  VMS.Rec.Format,
  VMS.Rec.Block,
  VMS.Rec.Paths,
  VMS.Rec.Writer,
  VMS.Net.Tailscale;

type
  // Avisa de onde a mídia está vindo, assim que o SDP responde. Existe porque
  // quem sabe disso é a sessão, e quem precisa mostrar é a tela — sem um canal,
  // o app exibiria gravação antiga com a pílula verde de "ao vivo".
  TSourceKnownEvent = procedure(IsLive: Boolean; MediaStartMs: Int64) of object;

  TCameraSessionConfig = record
    Name: string;
    Url: string;
    User: string;
    Password: string;
    Transports: TArray<TTransportKind>;
    RecordAudio: Boolean;
    FilenamePattern: string;
    StorageDir: string;
    NoRtpTimeoutMs: Cardinal;
    TransportFallbackTimeoutMs: Cardinal;
    KeepAliveMethod: TRtspKeepAliveMethod;
    MaxBlockSamples: Integer;
    MaxBlockDurationMs: Integer;
    MaxBlockSizeBytes: Integer;
    // De quanto em quanto tempo a gravação roda de arquivo. 0 = nunca roda,
    // e aí um arquivo cobre a sessão inteira.
    RotateMs: Integer;
    ConnectTimeoutMs: Cardinal;
    RtspTimeoutMs: Cardinal;
    RecordEnabled: Boolean;
    // 0 = reconecta pra sempre; N > 0 = desiste após N falhas seguidas
    MaxReconnectAttempts: Integer;
    // Câmera dentro da tailnet: espera o túnel antes de cada tentativa de
    // conexão (inclusive nas reconexões, que é quando a VPN costuma ter caído).
    UsesTailscale: Boolean;
    // Caminhos alternativos até a mesma câmera, em ordem de prioridade. Quem
    // escolhe é o supervisor, antes de CADA tentativa (ver VMS.Net.Probe); os
    // campos Url/User/Password/Transports acima são os do endpoint escolhido.
    // Lista vazia = câmera com um caminho só, que são os campos acima.
    Endpoints: TCameraEndpoints;
  end;

  TDepacketizerFactoryFn = reference to function(VideoCodec: TVideoCodec; AudioCodec: TAudioCodec;
                                                Kind: TTrackKind): IDepacketizer;

  TCameraSession = class
  strict private
    FConfig: TCameraSessionConfig;
    FLogger: ILogger;
    FClock: IClock;
    FDepkFactory: TDepacketizerFactoryFn;
    FStopEvent: TEvent;
    FTcp: ITcpStream;
    FUdp: IUdpReceiver;
    FAudioUdp: IUdpReceiver;
    FReader: TRtspWireReader;
    FAuth: TRtspAuthHandler;
    FRtsp: TRtspClient;
    FSdp: TSdpSession;
    FVideoTrack: TSdpMedia;
    FAudioTrack: TSdpMedia;
    FVideoInfo: TSdpCodecInfo;
    FAudioInfo: TSdpCodecInfo;
    FVideoDepk: IDepacketizer;
    FAudioDepk: IDepacketizer;
    FDemux: TRtpDemux;
    FBlockBuilder: TBlockBuilder;
    FWriter: IRecordingWriter;
    // O header do arquivo em gravação, guardado para a rotação poder reabrir
    // outro igual sem voltar ao SDP.
    FRecHeader: TVmsHeader;
    FOnSourceKnown: TSourceKnownEvent;
    FFileStartedMs: Int64;   // monotônico, de quando o arquivo corrente abriu
    FMediaSink: IMediaSink;
    FFormatNotified: Boolean;  // o sink já soube do formato desta sessão
    FUsedTransport: TTransportKind;
    FVideoTransport: TRtspTransportSpec;
    FAudioTransport: TRtspTransportSpec;
    FFirstRtpReceived: Boolean;
    FLastRtpMonoMs: Int64;
    FLastKeepAliveMs: Int64;
    FStreamStartMs: Int64;
    FOutputPath: string;
    // estatísticas RTP (diagnóstico de perda/throughput)
    FStatsLastMs: Int64;
    FVidPkts, FVidLost, FVidBytes: Int64;
    FAudPkts, FAudLost: Int64;
    FVidLastSeq, FAudLastSeq: Integer;
    FVidHasSeq, FAudHasSeq: Boolean;
    function BuildOutputPath: string;
    procedure OpenConnections;
    procedure CloseConnections;
    function HandshakeRtsp: Boolean;
    function TrySetupTransport(Kind: TTransportKind): Boolean;
    function ValidateFirstRtp(TimeoutMs: Cardinal): Boolean;
    procedure CleanupTransportAttempt;
    procedure SetupDepacketizers;
    procedure NoteSdpSource;
    procedure WriteHeaderFromSdp;
    function RotateDue(const Block: TVmsBlock): Boolean;
    procedure RotateWriter;
    procedure HandleSample(const Sample: TSample);
    procedure AccountRtp(IsVideo: Boolean; const Packet: TRtpPacket);
    procedure LogStatsIfDue;
    function WantAudio: Boolean;
    procedure NotifySinkFormat;
    procedure HandleVideoRtp(const Packet: TRtpPacket);
    procedure HandleAudioRtp(const Packet: TRtpPacket);
    procedure StreamLoop;
    procedure StreamLoopInterleaved;
    procedure StreamLoopUdp;
    procedure CheckKeepAlive;
    function StopRequested: Boolean;
    procedure DrainWriter(CleanShutdown: Boolean);
  public
    constructor Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger;
                       const AClock: IClock; const ADepkFactory: TDepacketizerFactoryFn;
                       const AStopEvent: TEvent; const AMediaSink: IMediaSink = nil);
    destructor Destroy; override;
    procedure Run;
    function CurrentOutputPath: string;
    property OnSourceKnown: TSourceKnownEvent read FOnSourceKnown write FOnSourceKnown;
    // True se a conexão chegou a receber RTP (stream funcionou de fato).
    function StreamedOk: Boolean;
    // Handshake de teste (OPTIONS+DESCRIBE+SETUP, sem PLAY). Não renderiza.
    function TestConnection(out Info: string): Boolean;
  end;

implementation

const
  KEEPALIVE_INTERVAL_RATIO = 0.5;
  STREAM_LOOP_POLL_MS = 200;
  CONNECT_DEFAULT_TIMEOUT = 5000;
  RTSP_DEFAULT_TIMEOUT = 10000;
  UDP_DRAIN_MAX = 256; // pacotes drenados por iteração (limita rajada de keyframe)
  // quanto se espera por um keyframe depois de vencido o prazo de rotação
  ROTATE_KEYFRAME_GRACE_MS = 60000;

function FormatFilename(const Pattern, Name: string; CreationUtc: TDateTime): string;
  function Pad(I, W: Integer): string;
  begin
    Result := IntToStr(I);
    while Length(Result) < W do Result := '0' + Result;
  end;
var
  S, Local: string;
  Y, M, D, H, Mn, Sec, Ms: Word;
  DT: TDateTime;
begin
  if Pattern = '' then
    S := '{name}_{yyyy-MM-dd_HH-mm-ss}.vms'
  else
    S := Pattern;
  DT := TTimeZone.Local.ToLocalTime(CreationUtc);
  DecodeDate(DT, Y, M, D);
  DecodeTime(DT, H, Mn, Sec, Ms);
  S := StringReplace(S, '{name}', Name, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '{yyyy}', Pad(Y, 4), [rfReplaceAll]);
  S := StringReplace(S, '{MM}', Pad(M, 2), [rfReplaceAll]);
  S := StringReplace(S, '{dd}', Pad(D, 2), [rfReplaceAll]);
  S := StringReplace(S, '{HH}', Pad(H, 2), [rfReplaceAll]);
  S := StringReplace(S, '{mm}', Pad(Mn, 2), [rfReplaceAll]);
  S := StringReplace(S, '{ss}', Pad(Sec, 2), [rfReplaceAll]);
  Local := StringReplace(FormatDateTime('yyyy-mm-dd_hh-nn-ss', DT), ':', '-', [rfReplaceAll]);
  S := StringReplace(S, '{yyyy-MM-dd_HH-mm-ss}', Local, [rfReplaceAll]);
  Result := S;
end;

{ TCameraSession }

constructor TCameraSession.Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger;
  const AClock: IClock; const ADepkFactory: TDepacketizerFactoryFn; const AStopEvent: TEvent;
  const AMediaSink: IMediaSink);
begin
  inherited Create;
  FConfig := AConfig;
  FLogger := ALogger;
  FClock := AClock;
  FDepkFactory := ADepkFactory;
  FStopEvent := AStopEvent;
  FMediaSink := AMediaSink;
  if FConfig.ConnectTimeoutMs = 0 then FConfig.ConnectTimeoutMs := CONNECT_DEFAULT_TIMEOUT;
  if FConfig.RtspTimeoutMs = 0 then FConfig.RtspTimeoutMs := RTSP_DEFAULT_TIMEOUT;
  if FConfig.NoRtpTimeoutMs = 0 then FConfig.NoRtpTimeoutMs := 10000;
  if FConfig.TransportFallbackTimeoutMs = 0 then FConfig.TransportFallbackTimeoutMs := 5000;
  if Length(FConfig.Transports) = 0 then
  begin
    SetLength(FConfig.Transports, 2);
    FConfig.Transports[0] := txTcp;
    FConfig.Transports[1] := txUdp;
  end;
end;

destructor TCameraSession.Destroy;
begin
  CloseConnections;
  inherited;
end;

function TCameraSession.StopRequested: Boolean;
begin
  Result := (FStopEvent <> nil) and (FStopEvent.WaitFor(0) = wrSignaled);
end;

function TCameraSession.CurrentOutputPath: string;
begin
  Result := FOutputPath;
end;

function TCameraSession.StreamedOk: Boolean;
begin
  Result := FFirstRtpReceived;
end;

function TCameraSession.TestConnection(out Info: string): Boolean;
var
  Resp: TRtspResponse;
  Sdp: string;
begin
  Result := False;
  Info := '';
  try
    OpenConnections;

    Resp := FRtsp.DoOptions;
    try
      if (Resp.StatusCode <> 200) and (Resp.StatusCode <> 401) then
      begin
        Info := Format('OPTIONS %d %s', [Resp.StatusCode, Resp.StatusText]);
        Exit;
      end;
    finally
      Resp.Free;
    end;

    Resp := FRtsp.DoDescribe;
    try
      if Resp.StatusCode = 401 then
      begin
        Info := 'autenticação falhou (usuário/senha?)';
        Exit;
      end;
      if Resp.StatusCode <> 200 then
      begin
        Info := Format('DESCRIBE %d %s', [Resp.StatusCode, Resp.StatusText]);
        Exit;
      end;
      Sdp := TEncoding.UTF8.GetString(Resp.Body);
    finally
      Resp.Free;
    end;

    FSdp := ParseSdp(Sdp);
    NoteSdpSource;
    FVideoTrack := FSdp.FindFirst(smkVideo);
    FAudioTrack := FSdp.FindFirst(smkAudio);
    if (FVideoTrack = nil) and (FAudioTrack = nil) then
    begin
      Info := 'SDP sem trilha de vídeo/áudio';
      Exit;
    end;
    FillChar(FVideoInfo, SizeOf(FVideoInfo), 0);
    FillChar(FAudioInfo, SizeOf(FAudioInfo), 0);
    if FVideoTrack <> nil then ExtractCodecFromMedia(FVideoTrack, FVideoInfo);
    if FAudioTrack <> nil then ExtractCodecFromMedia(FAudioTrack, FAudioInfo);

    // SETUP do 1o transporte configurado (valida o transporte, sem PLAY)
    if Length(FConfig.Transports) > 0 then
      if not TrySetupTransport(FConfig.Transports[0]) then
      begin
        Info := Format('SETUP falhou (%s)', [TransportKindToStr(FConfig.Transports[0])]);
        Exit;
      end;

    Info := 'OK';
    if FVideoTrack <> nil then
      Info := Info + ' | vídeo ' + VideoCodecToStr(FVideoInfo.VideoCodec);
    if FAudioTrack <> nil then
      Info := Info + ' | áudio ' + AudioCodecToStr(FAudioInfo.AudioCodec);
    if Length(FConfig.Transports) > 0 then
      Info := Info + ' | ' + TransportKindToStr(FConfig.Transports[0]);
    Result := True;
  except
    on E: Exception do
      Info := E.Message;
  end;
  CloseConnections;
end;

function TCameraSession.BuildOutputPath: string;
var
  Filename, Dir: string;
  CreationUtc: TDateTime;
begin
  CreationUtc := TTimeZone.Local.ToUniversalTime(Now);
  Filename := FormatFilename(FConfig.FilenamePattern, FConfig.Name, CreationUtc);
  // Cada câmera na sua pasta (ver VMS.Rec.Paths).
  Dir := EnsureCameraDir(FConfig.StorageDir, FConfig.Name);
  Result := IncludeTrailingPathDelimiter(Dir) + Filename;
end;

procedure TCameraSession.OpenConnections;
var
  Parsed: TRtspUrl;
begin
  if not ParseRtspUrl(FConfig.Url, Parsed) then
    raise EVmsConfigError.CreateFmt('Invalid RTSP URL: %s', [FConfig.Url]);

  // Antes de qualquer socket: se a câmera vive na tailnet, não há rota até ela
  // sem VPN, e o erro de conexão não diria isso. Roda em toda tentativa, não só
  // na primeira — a reconexão é justamente quando o túnel caiu.
  if FConfig.UsesTailscale then
    EnsureTailnetUp(Parsed.Host, Parsed.Port, FLogger, FStopEvent)
  else if LooksLikeTailnetHost(Parsed.Host) then
    FLogger.Warn('session.' + FConfig.Name,
      Format('%s parece ser endereco de tailnet, mas a opcao Tailscale desta camera' +
             ' esta desligada', [Parsed.Host]));

  FTcp := TIndyTcpStream.Create;
  try
    FTcp.Connect(Parsed.Host, Parsed.Port, FConfig.ConnectTimeoutMs);
  except
    FTcp := nil;
    raise;
  end;
  FReader := TRtspWireReader.Create(FTcp);
  FAuth := TRtspAuthHandler.Create(FConfig.User, FConfig.Password);
  FRtsp := TRtspClient.Create(FTcp, FReader, FAuth, FLogger, Parsed);
end;

procedure TCameraSession.CloseConnections;
begin
  try
    if FBlockBuilder <> nil then
    begin
      FBlockBuilder.Free;
      FBlockBuilder := nil;
    end;
  except
  end;

  try
    FWriter := nil;
  except
  end;

  FVideoDepk := nil;
  FAudioDepk := nil;

  if FDemux <> nil then
  begin
    FDemux.Free;
    FDemux := nil;
  end;

  if FRtsp <> nil then
  begin
    FRtsp.Free;
    FRtsp := nil;
  end;

  if FAuth <> nil then
  begin
    FAuth.Free;
    FAuth := nil;
  end;

  if FReader <> nil then
  begin
    FReader.Free;
    FReader := nil;
  end;

  if FSdp <> nil then
  begin
    FSdp.Free;
    FSdp := nil;
  end;

  try
    if FTcp <> nil then
      FTcp.Disconnect;
  except
  end;
  FTcp := nil;

  try
    if FUdp <> nil then
      FUdp.Close;
  except
  end;
  FUdp := nil;

  try
    if FAudioUdp <> nil then
      FAudioUdp.Close;
  except
  end;
  FAudioUdp := nil;

  FVideoTrack := nil;
  FAudioTrack := nil;
end;

function TCameraSession.TrySetupTransport(Kind: TTransportKind): Boolean;
var
  Req, Negotiated: TRtspTransportSpec;
  Resp: TRtspResponse;
  VideoControl, AudioControl: string;
begin
  FUsedTransport := Kind;
  FillChar(Req, SizeOf(Req), 0);

  if Kind = txTcp then
  begin
    Req.Kind := txTcp;
    Req.InterleavedRtp := 0;
    Req.InterleavedRtcp := 1;
  end
  else
  begin
    Req.Kind := txUdp;
    FUdp := TIndyUdpPair.Create;
    try
      Req.ClientRtpPort := 0;
      Req.ClientRtcpPort := 0;
      FUdp.BindPair('0.0.0.0', Req.ClientRtpPort, Req.ClientRtcpPort);
      FLogger.Debug('session.' + FConfig.Name,
        Format('UDP video bind porta %d/%d', [Req.ClientRtpPort, Req.ClientRtcpPort]));
    except
      on E: Exception do
      begin
        FLogger.Warn('session.' + FConfig.Name, 'UDP bind failed: ' + E.Message);
        FUdp := nil;
        Exit(False);
      end;
    end;
  end;

  VideoControl := '';
  if FVideoTrack <> nil then
    VideoControl := BuildAbsoluteControl(FRtsp.ContentBase, FVideoTrack.Control);
  if VideoControl = '' then VideoControl := FConfig.Url;

  try
    Resp := FRtsp.DoSetup(VideoControl, Req, Negotiated);
  except
    on E: Exception do
    begin
      FLogger.Warn('session.' + FConfig.Name,
        Format('SETUP video (%s) failed: %s', [TransportKindToStr(Kind), E.Message]));
      Exit(False);
    end;
  end;
  try
    if Resp.StatusCode <> 200 then
    begin
      FLogger.Warn('session.' + FConfig.Name,
        Format('SETUP video (%s) returned %d %s', [TransportKindToStr(Kind), Resp.StatusCode, Resp.StatusText]));
      Exit(False);
    end;
    FVideoTransport := Negotiated;
  finally
    Resp.Free;
  end;

  if WantAudio and (FAudioTrack <> nil) then
  begin
    if Kind = txTcp then
    begin
      Req.InterleavedRtp := 2;
      Req.InterleavedRtcp := 3;
    end
    else
    begin
      if FAudioUdp <> nil then
      begin
        FAudioUdp.Close;
        FAudioUdp := nil;
      end;
      FAudioUdp := TIndyUdpPair.Create;
      try
        Req.ClientRtpPort := 0;
        Req.ClientRtcpPort := 0;
        FAudioUdp.BindPair('0.0.0.0', Req.ClientRtpPort, Req.ClientRtcpPort);
        FLogger.Debug('session.' + FConfig.Name,
          Format('UDP audio bind porta %d/%d', [Req.ClientRtpPort, Req.ClientRtcpPort]));
      except
        on E: Exception do
        begin
          FLogger.Warn('session.' + FConfig.Name,
            'Audio UDP bind failed (skipping audio): ' + E.Message);
          FAudioUdp := nil;
          FAudioTrack := nil;
          Result := True;
          Exit;
        end;
      end;
    end;
    AudioControl := BuildAbsoluteControl(FRtsp.ContentBase, FAudioTrack.Control);
    if AudioControl = '' then AudioControl := FConfig.Url;
    try
      Resp := FRtsp.DoSetup(AudioControl, Req, Negotiated);
    except
      on E: Exception do
      begin
        FLogger.Warn('session.' + FConfig.Name,
          Format('SETUP audio failed (ignoring audio): %s', [E.Message]));
        FAudioTrack := nil;
        Result := True;
        Exit;
      end;
    end;
    try
      if Resp.StatusCode <> 200 then
      begin
        FLogger.Warn('session.' + FConfig.Name,
          Format('SETUP audio returned %d %s (ignoring audio)', [Resp.StatusCode, Resp.StatusText]));
        FAudioTrack := nil;
        Result := True;
        Exit;
      end;
      FAudioTransport := Negotiated;
    finally
      Resp.Free;
    end;
  end;
  Result := True;
end;

function TCameraSession.HandshakeRtsp: Boolean;
var
  Resp: TRtspResponse;
  Sdp: string;
  I: Integer;
  Tx: TTransportKind;
  SetupOk: Boolean;
begin
  Result := False;

  Resp := FRtsp.DoOptions;
  try
    if (Resp.StatusCode <> 200) and (Resp.StatusCode <> 401) then
    begin
      FLogger.Warn('session.' + FConfig.Name,
        Format('OPTIONS returned %d %s', [Resp.StatusCode, Resp.StatusText]));
      Exit;
    end;
  finally
    Resp.Free;
  end;

  Resp := FRtsp.DoDescribe;
  try
    if Resp.StatusCode <> 200 then
    begin
      FLogger.Warn('session.' + FConfig.Name,
        Format('DESCRIBE returned %d %s', [Resp.StatusCode, Resp.StatusText]));
      Exit;
    end;
    Sdp := TEncoding.UTF8.GetString(Resp.Body);
  finally
    Resp.Free;
  end;

  FSdp := ParseSdp(Sdp);
  NoteSdpSource;
  FVideoTrack := FSdp.FindFirst(smkVideo);
  FAudioTrack := FSdp.FindFirst(smkAudio);

  if (FVideoTrack = nil) and (FAudioTrack = nil) then
  begin
    FLogger.Warn('session.' + FConfig.Name, 'SDP has neither video nor audio track');
    Exit;
  end;

  FillChar(FVideoInfo, SizeOf(FVideoInfo), 0);
  FillChar(FAudioInfo, SizeOf(FAudioInfo), 0);
  if FVideoTrack <> nil then
    ExtractCodecFromMedia(FVideoTrack, FVideoInfo);
  if FAudioTrack <> nil then
    ExtractCodecFromMedia(FAudioTrack, FAudioInfo);

  for I := 0 to High(FConfig.Transports) do
  begin
    Tx := FConfig.Transports[I];
    FLogger.Info('session.' + FConfig.Name,
      Format('Trying transport: %s', [TransportKindToStr(Tx)]));

    if not TrySetupTransport(Tx) then
    begin
      CleanupTransportAttempt;
      Continue;
    end;

    SetupOk := False;
    try
      Resp := FRtsp.DoPlay;
      try
        if Resp.StatusCode = 200 then
          SetupOk := True
        else
          FLogger.Warn('session.' + FConfig.Name,
            Format('PLAY (%s) returned %d %s',
              [TransportKindToStr(Tx), Resp.StatusCode, Resp.StatusText]));
      finally
        Resp.Free;
      end;
    except
      on E: Exception do
      begin
        if FUsedTransport = txUdp then
        begin
          FLogger.Info('session.' + FConfig.Name,
            'PLAY response read failed in UDP mode (will validate via RTP arrival): ' + E.Message);
          SetupOk := True;
        end
        else
          FLogger.Warn('session.' + FConfig.Name,
            Format('PLAY (%s) failed: %s', [TransportKindToStr(Tx), E.Message]));
      end;
    end;

    if not SetupOk then
    begin
      try FRtsp.DoTeardown except end;
      CleanupTransportAttempt;
      Continue;
    end;

    SetupDepacketizers;
    // Formato ANTES do primeiro RTP: o ValidateFirstRtp despacha o pacote que
    // recebe, e se ele completar um sample o sink receberia mídia sem saber
    // configurar o decodificador. Hoje os três sinks (renderer, gravação, hub)
    // descartam nesse caso, mas depender disso é depender de todo sink futuro
    // ser tolerante.
    NotifySinkFormat;
    FStreamStartMs := FClock.MonotonicMs;
    FFirstRtpReceived := False;
    if ValidateFirstRtp(FConfig.TransportFallbackTimeoutMs) then
    begin
      FLogger.Info('session.' + FConfig.Name,
        Format('First RTP received on %s', [TransportKindToStr(Tx)]));
      Result := True;
      Exit;
    end;

    FLogger.Warn('session.' + FConfig.Name,
      Format('No RTP within %d ms on %s, trying next transport',
        [FConfig.TransportFallbackTimeoutMs, TransportKindToStr(Tx)]));
    try FRtsp.DoTeardown except end;
    CleanupTransportAttempt;
  end;

  FLogger.Error('session.' + FConfig.Name, 'No transport produced RTP');
end;

function TCameraSession.ValidateFirstRtp(TimeoutMs: Cardinal): Boolean;
var
  Pkt: TUdpPacket;
  Event: TWireEvent;
  Deadline, NowTick: Int64;
begin
  Result := False;
  NowTick := FClock.MonotonicMs;
  Deadline := NowTick + Int64(TimeoutMs);
  while NowTick < Deadline do
  begin
    if StopRequested then Exit;
    if FUsedTransport = txUdp then
    begin
      if (FUdp <> nil) and FUdp.ReceiveRtp(Pkt, 100) then
      begin
        FDemux.DispatchUdp(tkVideo, Pkt.Data);
        FFirstRtpReceived := True;
        FLastRtpMonoMs := FClock.MonotonicMs;
        Exit(True);
      end;
      if (FAudioUdp <> nil) and FAudioUdp.ReceiveRtp(Pkt, 1) then
      begin
        FDemux.DispatchUdp(tkAudio, Pkt.Data);
        FFirstRtpReceived := True;
        FLastRtpMonoMs := FClock.MonotonicMs;
        Exit(True);
      end;
    end
    else
    begin
      try
        if FReader.TryReadNext(100, Event) then
        begin
          if Event.Kind = wekInterleaved then
          begin
            FDemux.DispatchInterleaved(Event.Frame.Channel, Event.Frame.Data);
            FFirstRtpReceived := True;
            FLastRtpMonoMs := FClock.MonotonicMs;
            Exit(True);
          end;
          if (Event.Kind = wekRtspMessage) and (Event.Response <> nil) then
            Event.Response.Free;
        end;
      except
        on E: EVmsIoError do Exit(False);
      end;
    end;
    NowTick := FClock.MonotonicMs;
  end;
end;

procedure TCameraSession.CleanupTransportAttempt;
begin
  if FDemux <> nil then
  begin
    FDemux.Free;
    FDemux := nil;
  end;
  FVideoDepk := nil;
  FAudioDepk := nil;
  if FUdp <> nil then
  begin
    try FUdp.Close; except end;
    FUdp := nil;
  end;
  if FAudioUdp <> nil then
  begin
    try FAudioUdp.Close; except end;
    FAudioUdp := nil;
  end;
end;

procedure TCameraSession.SetupDepacketizers;
begin
  // Idempotente: solta o demux anterior antes de trocar. Sem isto, chamar duas
  // vezes vazava um TRtpDemux por conexão — e o de antes ficava sem dono, com
  // as rotas apontando para depacketizadores já descartados.
  if FDemux <> nil then
    FreeAndNil(FDemux);
  FDemux := TRtpDemux.Create;
  FVideoDepk := nil;
  FAudioDepk := nil;

  if FVideoTrack <> nil then
  begin
    FVideoDepk := FDepkFactory(FVideoInfo.VideoCodec, acNone, tkVideo);
    if FVideoDepk <> nil then
    begin
      FVideoDepk.SetTrackId(0);
      FVideoDepk.SetOnSample(HandleSample);
      if FUsedTransport = txTcp then
        FDemux.RegisterRoute(tkVideo, Byte(FVideoTrack.PayloadType),
                             FVideoTransport.InterleavedRtp, HandleVideoRtp)
      else
        FDemux.RegisterRoute(tkVideo, Byte(FVideoTrack.PayloadType), -1, HandleVideoRtp);
    end;
  end;

  if (FAudioTrack <> nil) and WantAudio then
  begin
    FAudioDepk := FDepkFactory(vcNone, FAudioInfo.AudioCodec, tkAudio);
    if FAudioDepk <> nil then
    begin
      FAudioDepk.SetTrackId(1);
      FAudioDepk.SetOnSample(HandleSample);
      if FUsedTransport = txTcp then
        FDemux.RegisterRoute(tkAudio, Byte(FAudioTrack.PayloadType),
                             FAudioTransport.InterleavedRtp, HandleAudioRtp)
      else
        FDemux.RegisterRoute(tkAudio, Byte(FAudioTrack.PayloadType), -1, HandleAudioRtp);
    end;
  end;
end;

// Chamada logo depois de o SDP ser lido, nos dois caminhos de handshake.
procedure TCameraSession.NoteSdpSource;
begin
  if FSdp = nil then Exit;
  if not FSdp.SourceIsLive then
    FLogger.Warn('session.' + FConfig.Name,
      'o servidor esta entregando GRAVACAO, nao a camera ao vivo');
  if Assigned(FOnSourceKnown) then
    FOnSourceKnown(FSdp.SourceIsLive, FSdp.MediaStartMs);
end;

procedure TCameraSession.WriteHeaderFromSdp;
var
  Header: TVmsHeader;
begin
  if not FConfig.RecordEnabled then Exit;
  FillChar(Header, SizeOf(Header), 0);
  Header.Version := VMS_FORMAT_VERSION;
  Header.CreationUnixMs := FClock.NowUtcMs;
  Header.SourceUri := FConfig.Url;

  if (FVideoTrack <> nil) and (FVideoInfo.VideoCodec <> vcNone) then
  begin
    Header.VideoPresent := True;
    Header.Video.Codec := FVideoInfo.VideoCodec;
    Header.Video.Timescale := FVideoInfo.Timescale;
    Header.Video.Width := FVideoInfo.Width;
    Header.Video.Height := FVideoInfo.Height;
    Header.Video.Extradata := FVideoInfo.Extradata;
  end;
  if FConfig.RecordAudio and (FAudioTrack <> nil) and (FAudioInfo.AudioCodec <> acNone) then
  begin
    Header.AudioPresent := True;
    Header.Audio.Codec := FAudioInfo.AudioCodec;
    Header.Audio.Timescale := FAudioInfo.Timescale;
    Header.Audio.SampleRate := FAudioInfo.SampleRate;
    Header.Audio.Channels := FAudioInfo.Channels;
    Header.Audio.BitsPerSample := 16;
    Header.Audio.Extradata := FAudioInfo.Extradata;
  end;

  FRecHeader := Header;
  FOutputPath := UniqueRecordingPath(BuildOutputPath);
  FWriter := TFileRecordingWriter.Create(FOutputPath);
  FWriter.WriteHeader(Header);
  FFileStartedMs := FClock.MonotonicMs;

  FBlockBuilder := TBlockBuilder.Create(FConfig.MaxBlockSamples,
                                        FConfig.MaxBlockDurationMs,
                                        FConfig.MaxBlockSizeBytes);
  // Com as escalas, a âncora de cada bloco passa a ser derivada do pts em vez
  // de saltar para o relógio de chegada a cada bloco. Ver VMS.Rec.Block.
  FBlockBuilder.SetTimescales(Header.Video.Timescale, Header.Audio.Timescale);
  FBlockBuilder.SetOnBlockClosed(
    procedure(const Block: TVmsBlock)
    begin
      if FWriter = nil then Exit;
      // Roda de arquivo antes de gravar este bloco, para ele já entrar no
      // arquivo novo — que assim começa por um keyframe.
      if RotateDue(Block) then
        RotateWriter;
      if FWriter = nil then Exit;
      try
        FWriter.WriteBlock(Block);
      except
        on E: Exception do
          raise EVmsIoError.Create('WriteBlock failed: ' + E.Message);
      end;
    end);
  FLogger.Info('session.' + FConfig.Name, 'Recording to ' + FOutputPath);
end;

// Passou o tempo de rodar de arquivo. Depois do prazo, espera o próximo bloco
// com keyframe, para o arquivo novo começar por um ponto de entrada do
// decodificador; câmera sem keyframe nenhum não segura a rotação além da
// tolerância.
function TCameraSession.RotateDue(const Block: TVmsBlock): Boolean;
var
  Age: Int64;
begin
  Result := False;
  if FConfig.RotateMs <= 0 then Exit;
  Age := FClock.MonotonicMs - FFileStartedMs;
  if Age < FConfig.RotateMs then Exit;
  Result := SamplesHaveKeyframe(Block.Samples) or
            (Age >= FConfig.RotateMs + ROTATE_KEYFRAME_GRACE_MS);
end;

// Fecha o arquivo corrente e segue no seguinte, sem tocar no TBlockBuilder — ele
// é quem está chamando isto, e liberá-lo aqui derrubaria a sessão.
procedure TCameraSession.RotateWriter;
begin
  try
    if FWriter <> nil then
      FWriter.Close(True);
  except
    on E: Exception do
      FLogger.Warn('session.' + FConfig.Name, 'Rotate close failed: ' + E.Message);
  end;
  FWriter := nil;
  // Instante de criação novo: é dele que o servidor tira o começo da faixa deste
  // arquivo (ver Vms.Server.IndexCache).
  FRecHeader.CreationUnixMs := FClock.NowUtcMs;
  FOutputPath := UniqueRecordingPath(BuildOutputPath);
  try
    FWriter := TFileRecordingWriter.Create(FOutputPath);
    FWriter.WriteHeader(FRecHeader);
    FFileStartedMs := FClock.MonotonicMs;
    FLogger.Info('session.' + FConfig.Name, 'Rotating; recording to ' + FOutputPath);
  except
    on E: Exception do
    begin
      // Mesmo tratamento de uma falha de WriteBlock: derruba a sessão para o
      // supervisor reconectar e recomeçar um arquivo. Seguir com FWriter nil
      // gravaria em lugar nenhum, calado, até alguém reparar.
      FWriter := nil;
      raise EVmsIoError.Create('Rotate open failed: ' + E.Message);
    end;
  end;
end;

procedure TCameraSession.HandleSample(const Sample: TSample);
begin
  if FMediaSink <> nil then
    FMediaSink.OnSample(Sample);
  if FBlockBuilder <> nil then
    FBlockBuilder.AddSample(Sample, FClock.NowUtcMs, FClock.MonotonicMs);
end;

function TCameraSession.WantAudio: Boolean;
begin
  Result := FConfig.RecordAudio or (FMediaSink <> nil);
end;

procedure TCameraSession.NotifySinkFormat;
begin
  if FMediaSink = nil then Exit;
  // Idempotente: a busca de transporte pode passar por aqui uma vez por
  // tentativa, e reanunciar o mesmo formato faria o renderer reconfigurar o
  // decodificador à toa.
  if FFormatNotified then Exit;
  FFormatNotified := True;
  if (FVideoTrack <> nil) and (FVideoInfo.VideoCodec <> vcNone) then
  begin
    FLogger.Info('session.' + FConfig.Name,
      Format('Video: %s %dx%d extradata=%d bytes',
        [VideoCodecToStr(FVideoInfo.VideoCodec), FVideoInfo.Width,
         FVideoInfo.Height, Length(FVideoInfo.Extradata)]));
    FMediaSink.OnVideoFormat(FVideoInfo.VideoCodec, FVideoInfo.Width,
                             FVideoInfo.Height, FVideoInfo.Extradata);
  end
  else
    FLogger.Warn('session.' + FConfig.Name,
      'Sem track de video reconhecida no SDP (somente audio sera exibido)');

  if WantAudio and (FAudioTrack <> nil) and (FAudioInfo.AudioCodec <> acNone) then
  begin
    FLogger.Info('session.' + FConfig.Name,
      Format('Audio: %s %dHz %dch', [AudioCodecToStr(FAudioInfo.AudioCodec),
        FAudioInfo.SampleRate, FAudioInfo.Channels]));
    FMediaSink.OnAudioFormat(FAudioInfo.AudioCodec, FAudioInfo.SampleRate,
                             FAudioInfo.Channels, FAudioInfo.Extradata);
  end;
end;

procedure TCameraSession.AccountRtp(IsVideo: Boolean; const Packet: TRtpPacket);
var
  Delta: Integer;
begin
  if IsVideo then
  begin
    Inc(FVidPkts);
    Inc(FVidBytes, Length(Packet.Payload));
    if FVidHasSeq then
    begin
      Delta := (Integer(Packet.SequenceNumber) - FVidLastSeq) and $FFFF;
      if (Delta > 1) and (Delta < 32768) then
        Inc(FVidLost, Delta - 1); // pacotes pulados = perda
    end;
    FVidLastSeq := Packet.SequenceNumber;
    FVidHasSeq := True;
  end
  else
  begin
    Inc(FAudPkts);
    if FAudHasSeq then
    begin
      Delta := (Integer(Packet.SequenceNumber) - FAudLastSeq) and $FFFF;
      if (Delta > 1) and (Delta < 32768) then
        Inc(FAudLost, Delta - 1);
    end;
    FAudLastSeq := Packet.SequenceNumber;
    FAudHasSeq := True;
  end;
end;

procedure TCameraSession.LogStatsIfDue;
var
  NowMs, Elapsed: Int64;
  Secs, LossPct, Kbps: Double;
begin
  NowMs := FClock.MonotonicMs;
  if FStatsLastMs = 0 then
  begin
    FStatsLastMs := NowMs;
    Exit;
  end;
  Elapsed := NowMs - FStatsLastMs;
  if Elapsed < 5000 then Exit;
  Secs := Elapsed / 1000.0;
  if (FVidPkts + FVidLost) > 0 then
    LossPct := (FVidLost * 100.0) / (FVidPkts + FVidLost)
  else
    LossPct := 0;
  Kbps := (FVidBytes * 8.0 / 1000.0) / Secs;
  FLogger.Info('session.' + FConfig.Name,
    Format('RTP video=%d pkts perda=%d (%.1f%%) %.0fkbps | audio=%d pkts perda=%d',
      [FVidPkts, FVidLost, LossPct, Kbps, FAudPkts, FAudLost]));
  FVidPkts := 0; FVidLost := 0; FVidBytes := 0;
  FAudPkts := 0; FAudLost := 0;
  FStatsLastMs := NowMs;
end;

procedure TCameraSession.HandleVideoRtp(const Packet: TRtpPacket);
begin
  FFirstRtpReceived := True;
  FLastRtpMonoMs := FClock.MonotonicMs;
  AccountRtp(True, Packet);
  if FVideoDepk <> nil then
    FVideoDepk.Feed(Packet);
end;

procedure TCameraSession.HandleAudioRtp(const Packet: TRtpPacket);
begin
  FFirstRtpReceived := True;
  FLastRtpMonoMs := FClock.MonotonicMs;
  AccountRtp(False, Packet);
  if FAudioDepk <> nil then
    FAudioDepk.Feed(Packet);
end;

procedure TCameraSession.CheckKeepAlive;
var
  Elapsed, Interval: Int64;
  Resp: TRtspResponse;
  TcpAlive: Boolean;
begin
  if FRtsp.SessionTimeoutSec <= 0 then Exit;
  Interval := Round(FRtsp.SessionTimeoutSec * 1000 * KEEPALIVE_INTERVAL_RATIO);
  if Interval < 5000 then Interval := 5000;
  Elapsed := FClock.MonotonicMs - FLastKeepAliveMs;
  if Elapsed < Interval then Exit;

  // TCP interleaved: se a mídia está chegando, ela PRÓPRIA mantém a sessão viva.
  // Pula o GET_PARAMETER — a leitura da resposta dele compete com a mídia e,
  // num stream lento, cruza um frame grande e dá timeout, derrubando a conexão
  // à toa. Só faz o keepalive de verdade se a mídia tiver parado.
  if (FUsedTransport = txTcp) and
     ((FClock.MonotonicMs - FLastRtpMonoMs) < Interval) then
  begin
    FLastKeepAliveMs := FClock.MonotonicMs;
    Exit;
  end;

  TcpAlive := (FTcp <> nil) and FTcp.Connected;
  if (FUsedTransport = txUdp) and (not TcpAlive) then
  begin
    FLastKeepAliveMs := FClock.MonotonicMs;
    Exit;
  end;

  try
    Resp := FRtsp.DoKeepAlive(FConfig.KeepAliveMethod);
    try
      if Resp.StatusCode >= 400 then
        FLogger.Warn('session.' + FConfig.Name,
          Format('Keepalive returned %d %s', [Resp.StatusCode, Resp.StatusText]));
    finally
      Resp.Free;
    end;
  except
    on E: Exception do
    begin
      if FUsedTransport = txUdp then
      begin
        FLogger.Info('session.' + FConfig.Name,
          'Keepalive failed in UDP mode (ignoring, RTP-only): ' + E.Message);
        FLastKeepAliveMs := FClock.MonotonicMs;
        Exit;
      end;
      raise EVmsIoError.Create('Keepalive failed: ' + E.Message);
    end;
  end;
  FLastKeepAliveMs := FClock.MonotonicMs;
end;

procedure TCameraSession.StreamLoopInterleaved;
var
  Event: TWireEvent;
  GotEvent: Boolean;
begin
  while not StopRequested do
  begin
    GotEvent := FReader.TryReadNext(STREAM_LOOP_POLL_MS, Event);
    if GotEvent then
    begin
      case Event.Kind of
        wekInterleaved:
          FDemux.DispatchInterleaved(Event.Frame.Channel, Event.Frame.Data);
        wekRtspMessage:
          if Event.Response <> nil then
            Event.Response.Free;
      end;
    end;
    if (FClock.MonotonicMs - FLastRtpMonoMs) > FConfig.NoRtpTimeoutMs then
      raise EVmsTimeoutError.Create('No RTP received in noRtpTimeoutMs');
    CheckKeepAlive;
    LogStatsIfDue;
  end;
end;

procedure TCameraSession.StreamLoopUdp;
var
  Pkt: TUdpPacket;
  Got: Boolean;
  Event: TWireEvent;
  Drained: Integer;
begin
  while not StopRequested do
  begin
    Got := False;
    if (FUdp <> nil) and FUdp.ReceiveRtp(Pkt, STREAM_LOOP_POLL_MS div 4) then
    begin
      Got := True;
      FDemux.DispatchUdp(tkVideo, Pkt.Data);
      // Drena o resto da rajada já na fila (timeout 0 = não-bloqueante).
      Drained := 0;
      while (Drained < UDP_DRAIN_MAX) and (FUdp.ReceiveRtp(Pkt, 0)) do
      begin
        FDemux.DispatchUdp(tkVideo, Pkt.Data);
        Inc(Drained);
      end;
    end;
    if (FAudioUdp <> nil) and FAudioUdp.ReceiveRtp(Pkt, 1) then
    begin
      Got := True;
      FDemux.DispatchUdp(tkAudio, Pkt.Data);
      Drained := 0;
      while (Drained < UDP_DRAIN_MAX) and (FAudioUdp.ReceiveRtp(Pkt, 0)) do
      begin
        FDemux.DispatchUdp(tkAudio, Pkt.Data);
        Inc(Drained);
      end;
    end;
    if (FUdp <> nil) and FUdp.ReceiveRtcp(Pkt, 1) then
    begin
      // RTCP video discarded
    end;
    if (FAudioUdp <> nil) and FAudioUdp.ReceiveRtcp(Pkt, 1) then
    begin
      // RTCP audio discarded
    end;
    if (FTcp <> nil) and FTcp.Connected then
    begin
      try
        if FReader.TryReadNext(1, Event) then
        begin
          if Event.Kind = wekRtspMessage then
          begin
            if Event.Response <> nil then
              Event.Response.Free;
          end;
        end;
      except
        on E: EVmsIoError do
        begin
          try FTcp.Disconnect; except end;
          FLogger.Info('session.' + FConfig.Name,
            'TCP control channel closed (UDP RTP continues): ' + E.Message);
        end;
      end;
    end;
    if not Got then
      TThread.Sleep(5);
    if (FClock.MonotonicMs - FLastRtpMonoMs) > FConfig.NoRtpTimeoutMs then
      raise EVmsTimeoutError.Create('No RTP received in noRtpTimeoutMs');
    CheckKeepAlive;
    LogStatsIfDue;
  end;
end;

procedure TCameraSession.StreamLoop;
begin
  if FUsedTransport = txTcp then
    StreamLoopInterleaved
  else
    StreamLoopUdp;
end;

procedure TCameraSession.DrainWriter(CleanShutdown: Boolean);
begin
  try
    if FBlockBuilder <> nil then
      FBlockBuilder.ForceFlush(FClock.NowUtcMs, FClock.MonotonicMs);
  except
    on E: Exception do
      FLogger.Warn('session.' + FConfig.Name, 'Flush failed: ' + E.Message);
  end;
  try
    if FWriter <> nil then
      FWriter.Close(CleanShutdown);
  except
    on E: Exception do
      FLogger.Warn('session.' + FConfig.Name, 'Writer close failed: ' + E.Message);
  end;
end;

procedure TCameraSession.Run;
var
  CleanStop: Boolean;
  Resp: TRtspResponse;
begin
  CleanStop := False;
  FFirstRtpReceived := False;
  FLastRtpMonoMs := FClock.MonotonicMs;
  FLastKeepAliveMs := FClock.MonotonicMs;
  try
    OpenConnections;
    if not HandshakeRtsp then
      raise EVmsProtocolError.Create('Handshake failed');
    // Os depacketizadores já foram montados dentro do HandshakeRtsp, antes do
    // ValidateFirstRtp — que precisa deles para reconhecer o 1º RTP. Refazê-los
    // aqui só jogava fora o estado do pacote que acabou de chegar (se era o
    // início de um FU-A, o quadro se perdia) e vazava o demux anterior.
    WriteHeaderFromSdp;
    NotifySinkFormat;
    FStreamStartMs := FClock.MonotonicMs;
    FLastRtpMonoMs := FClock.MonotonicMs;
    FLastKeepAliveMs := FClock.MonotonicMs;
    try
      StreamLoop;
      CleanStop := True;
    except
      on E: Exception do
      begin
        FLogger.Warn('session.' + FConfig.Name, 'Stream loop: ' + E.Message);
        raise;
      end;
    end;
  finally
    if CleanStop then
    begin
      try
        Resp := FRtsp.DoTeardown;
        try
        finally
          Resp.Free;
        end;
      except
      end;
    end;
    DrainWriter(CleanStop);
    CloseConnections;
    if FMediaSink <> nil then
      FMediaSink.OnStreamStopped;
  end;
end;

end.
