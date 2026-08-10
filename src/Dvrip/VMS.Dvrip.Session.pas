unit VMS.Dvrip.Session;

// Sessão DVRIP/Sofia (câmeras Xiongmai): conecta -> login (MD5 Sofia) ->
// OPMonitor Claim/Start -> recebe frames -> emite TSample no mesmo IMediaSink
// usado pelo RTSP. Reaproveita todo o decode/render (MediaCodec H264/H265).

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Net.Intf,
  VMS.Net.Tcp,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.MediaSink,
  VMS.Domain.Session,
  VMS.Dvrip.Protocol,
  VMS.Dvrip.Media;

type
  TDvripSession = class
  strict private
    FConfig: TCameraSessionConfig;
    FLogger: ILogger;
    FClock: IClock;
    FStopEvent: TEvent;
    FMediaSink: IMediaSink;
    FTcp: ITcpStream;
    FParser: TDvripMediaParser;
    FSessionID: Cardinal;
    FSeq: Cardinal;
    FAliveInterval: Integer;
    FLastKeepAliveMs: Int64;
    FVideoNotified: Boolean;
    FAudioNotified: Boolean;
    FPts: Int64;
    FAudioPts: Int64;
    FTag: string;
    FStreamType: string;
    FCombinMode: string;
    // estatísticas da janela de log (resetadas a cada LogStatsIfDue)
    FWinI, FWinP, FWinAud: Integer;
    FWinVidBytes, FWinAudBytes: Int64;
    FStatsTickMs: Int64;
    function ParseHostPort(out Host: string; out Port: Word): Boolean;
    function NextSeq: Cardinal;
    function MonitorJson(const Action, StreamType: string): string;
    function Login: Boolean;
    function QueryEncodeConfig: Boolean;
    procedure StartMonitor;
    procedure ReceiveLoop;
    procedure CheckKeepAlive;
    procedure LogStatsIfDue;
    function StopRequested: Boolean;
    procedure HandleVideo(const AnnexB: TBytes; Keyframe: Boolean; Codec: TVideoCodec);
    procedure HandleAudio(const Data: TBytes; Codec: TAudioCodec);
  public
    constructor Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger;
                       const AClock: IClock; const AStopEvent: TEvent;
                       const AMediaSink: IMediaSink);
    destructor Destroy; override;
    procedure Run;
    function CurrentOutputPath: string;
    // True se chegou a notificar mídia (stream funcionou de fato).
    function StreamedOk: Boolean;
    // Teste de conexão: connect + login + config, sem OPMonitor Start.
    function TestConnection(out Info: string): Boolean;
  end;

implementation

constructor TDvripSession.Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger;
  const AClock: IClock; const AStopEvent: TEvent; const AMediaSink: IMediaSink);
begin
  inherited Create;
  FConfig := AConfig;
  FLogger := ALogger;
  FClock := AClock;
  FStopEvent := AStopEvent;
  FMediaSink := AMediaSink;
  FTag := 'dvrip.' + FConfig.Name;
  FParser := TDvripMediaParser.Create;
  FParser.SetLogger(FLogger, FTag);
  FParser.SetOnVideo(
    procedure(const A: TBytes; Keyframe: Boolean; Codec: TVideoCodec)
    begin
      HandleVideo(A, Keyframe, Codec);
    end);
  FParser.SetOnAudio(
    procedure(const A: TBytes; Codec: TAudioCodec)
    begin
      HandleAudio(A, Codec);
    end);
end;

destructor TDvripSession.Destroy;
begin
  try
    if FTcp <> nil then FTcp.Disconnect;
  except
  end;
  FTcp := nil;
  FParser.Free;
  inherited;
end;

function TDvripSession.CurrentOutputPath: string;
begin
  Result := '';
end;

function TDvripSession.StreamedOk: Boolean;
begin
  Result := FVideoNotified or FAudioNotified;
end;

function TDvripSession.TestConnection(out Info: string): Boolean;
var
  Host: string;
  Port: Word;
begin
  Result := False;
  Info := '';
  FSeq := 0;
  FCombinMode := 'NONE';
  try
    if not ParseHostPort(Host, Port) then
    begin
      Info := 'URL DVRIP inválida';
      Exit;
    end;
    FTcp := TIndyTcpStream.Create;
    try
      FTcp.Connect(Host, Port, FConfig.ConnectTimeoutMs);
      if not Login then
      begin
        Info := 'login falhou (usuário/senha?)';
        Exit;
      end;
      QueryEncodeConfig; // loga o Simplify.Encode
      Info := Format('OK: login DVRIP (SessionID=0x%x, alive=%ds)', [FSessionID, FAliveInterval]);
      Result := True;
    finally
      try if FTcp <> nil then FTcp.Disconnect; except end;
      FTcp := nil;
    end;
  except
    on E: Exception do
      Info := E.Message;
  end;
end;

function TDvripSession.StopRequested: Boolean;
begin
  Result := (FStopEvent <> nil) and (FStopEvent.WaitFor(0) = wrSignaled);
end;

function TDvripSession.NextSeq: Cardinal;
begin
  Inc(FSeq);
  Result := FSeq;
end;

function TDvripSession.ParseHostPort(out Host: string; out Port: Word): Boolean;
var
  S: string;
  P: Integer;
begin
  S := Trim(FConfig.Url);
  P := Pos('://', S);
  if P > 0 then Delete(S, 1, P + 2);
  P := Pos('/', S);
  if P > 0 then Delete(S, P, MaxInt);
  P := LastDelimiter('@', S);
  if P > 0 then Delete(S, 1, P);
  P := Pos(':', S);
  if P > 0 then
  begin
    Host := Copy(S, 1, P - 1);
    Port := Word(StrToIntDef(Copy(S, P + 1, MaxInt), 34567));
  end
  else
  begin
    Host := S;
    Port := 34567;
  end;
  Result := Host <> '';
end;

function TDvripSession.Login: Boolean;
var
  Json, Resp, Sid: string;
  Hdr: TDvripHeader;
  Payload: TBytes;
  Attempt: Integer;
begin
  Result := False;
  Json := '{ "CommunicateKey" : "", "EncryptType" : "MD5", "LoginType" : "DVRIP-Web", ' +
          '"PassWord" : "' + SofiaHash(FConfig.Password) + '", "UserName" : "' + FConfig.User + '" }';
  DvripSendCmd(FTcp, 0, 0, DVRIP_LOGIN, Json);
  // Lê até achar a mensagem com SessionID (algumas câmeras mandam um
  // "LoginEncryptionType" antes da resposta real do login).
  for Attempt := 1 to 4 do
  begin
    if not DvripRecv(FTcp, Hdr, Payload, FConfig.RtspTimeoutMs) then Exit;
    Resp := TEncoding.UTF8.GetString(Payload);
    FLogger.Debug(FTag, 'login resp: ' + Resp);
    Sid := JsonGetStr(Resp, 'SessionID');
    if Sid = '' then Continue; // mensagem pré-login; lê a próxima
    if JsonGetInt(Resp, 'Ret', 0) <> 100 then Exit;
    if Sid.StartsWith('0x') then
      FSessionID := Cardinal(StrToInt64Def('$' + Copy(Sid, 3, MaxInt), 0))
    else
      FSessionID := Cardinal(StrToInt64Def(Sid, 0));
    FAliveInterval := JsonGetInt(Resp, 'AliveInterval', 30);
    if FAliveInterval <= 0 then FAliveInterval := 30;
    Exit(True);
  end;
end;

// Consulta a config de encode ("Simplify.Encode"): loga o JSON cru e o resumo
// Main/Extra. Retorna True se o SUBSTREAM (Extra) tiver vídeo habilitado. Em
// caso de falha/ambiguidade retorna False (o padrão é o Main). A decisão final
// do stream é feita no Run.
function TDvripSession.QueryEncodeConfig: Boolean;
var
  Hdr: TDvripHeader;
  Payload: TBytes;
  Resp, Main, Extra: string;
begin
  Result := False;
  DvripSendCmd(FTcp, FSessionID, NextSeq, DVRIP_CONFIG_GET,
    Format('{ "Name" : "Simplify.Encode", "SessionID" : "0x%x" }', [FSessionID]));
  if not DvripRecv(FTcp, Hdr, Payload, 3000) then
  begin
    FLogger.Warn(FTag, 'Simplify.Encode: sem resposta (MsgID pode diferir)');
    Exit;
  end;
  Resp := TEncoding.UTF8.GetString(Payload);
  FLogger.Info(FTag, 'Encode config: ' + Resp);

  Main := ExtractSection(Resp, 'MainFormat');
  Extra := ExtractSection(Resp, 'ExtraFormat');
  if Main <> '' then
    FLogger.Info(FTag, Format('  Main : enable=%s compression=%s res=%s',
      [JsonGetStr(Main, 'VideoEnable'), JsonGetStr(Main, 'Compression'),
       JsonGetStr(Main, 'Resolution')]));
  if Extra <> '' then
    FLogger.Info(FTag, Format('  Extra: enable=%s compression=%s res=%s',
      [JsonGetStr(Extra, 'VideoEnable'), JsonGetStr(Extra, 'Compression'),
       JsonGetStr(Extra, 'Resolution')]));

  Result := (Extra <> '') and SameText(JsonGetStr(Extra, 'VideoEnable'), 'true');
end;

function TDvripSession.MonitorJson(const Action, StreamType: string): string;
begin
  Result := Format('{ "Name" : "OPMonitor", "OPMonitor" : { "Action" : "%s", ' +
    '"Parameter" : { "Channel" : 0, "CombinMode" : "%s", "StreamType" : "%s", ' +
    '"TransMode" : "TCP" } }, "SessionID" : "0x%x" }',
    [Action, FCombinMode, StreamType, FSessionID]);
end;

procedure TDvripSession.StartMonitor;
var
  Hdr: TDvripHeader;
  Payload: TBytes;
  Ret: Integer;
begin
  // Claim (reserva o stream) no MsgID 1413 e lê a resposta.
  DvripSendCmd(FTcp, FSessionID, NextSeq, DVRIP_OPMONITOR_CLAIM, MonitorJson('Claim', FStreamType));
  if DvripRecv(FTcp, Hdr, Payload, FConfig.RtspTimeoutMs) then
  begin
    Ret := JsonGetInt(TEncoding.UTF8.GetString(Payload), 'Ret', -1);
    FLogger.Info(FTag, Format('OPMonitor Claim (%s) Ret=%d', [FStreamType, Ret]));
    if Ret <> 100 then
      FLogger.Warn(FTag, 'Claim recusado (Ret=' + IntToStr(Ret) +
        '); a câmera pode não aceitar esse StreamType');
  end;
  // Start (abre o fluxo) no MsgID 1410. A resposta e a mídia são tratadas no loop.
  DvripSendCmd(FTcp, FSessionID, NextSeq, DVRIP_OPMONITOR, MonitorJson('Start', FStreamType));
end;

procedure TDvripSession.CheckKeepAlive;
var
  ElapsedS: Int64;
begin
  ElapsedS := (FClock.MonotonicMs - FLastKeepAliveMs) div 1000;
  if ElapsedS < (FAliveInterval div 2) then Exit;
  DvripSendCmd(FTcp, FSessionID, NextSeq, DVRIP_KEEPALIVE,
    Format('{ "Name" : "KeepAlive", "SessionID" : "0x%x" }', [FSessionID]));
  FLastKeepAliveMs := FClock.MonotonicMs;
end;

procedure TDvripSession.ReceiveLoop;
var
  Hdr: TDvripHeader;
  Payload: TBytes;
begin
  FLastKeepAliveMs := FClock.MonotonicMs;
  while not StopRequested do
  begin
    if not DvripRecv(FTcp, Hdr, Payload, 4000) then
      raise EVmsIoError.Create('DVRIP recv timeout/erro');
    if Length(Payload) >= 4 then
    begin
      if Payload[0] = Ord('{') then
        FLogger.Debug(FTag, 'ctrl: ' + TEncoding.UTF8.GetString(Payload))
      else
        FParser.Feed(Payload, Length(Payload)); // mídia
    end;
    LogStatsIfDue;
    CheckKeepAlive;
  end;
end;

// Extrai o csd-0 (VPS/SPS/PPS em Annex-B) de dentro de um keyframe DVRIP, que
// vem in-band. O Android novo (MediaCodec estrito) precisa do csd-0 na
// configuração; sem ele, erra ao decodificar e se libera ("Released state").
// Copia só os NALs de parâmetro (para antes do 1º slice VCL), cada um com um
// start code de 4 bytes.
function ExtractInbandCsd(const Data: TBytes; Codec: TVideoCodec): TBytes;
var
  N, I, NalStart, NalEnd, NalType, ScLen, J: Integer;
  IsH265, IsVcl, IsParam: Boolean;

  procedure AppendNal(SrcStart, SrcEnd: Integer);
  var
    Len, Base: Integer;
  begin
    Len := SrcEnd - SrcStart;
    if Len <= 0 then Exit;
    Base := Length(Result);
    SetLength(Result, Base + 4 + Len);
    Result[Base] := 0; Result[Base + 1] := 0; Result[Base + 2] := 0; Result[Base + 3] := 1;
    Move(Data[SrcStart], Result[Base + 4], Len);
  end;

begin
  Result := nil;
  N := Length(Data);
  IsH265 := Codec = vcH265;
  I := 0;
  while I + 3 < N do
  begin
    if (Data[I] = 0) and (Data[I + 1] = 0) and (Data[I + 2] = 1) then
      ScLen := 3
    else if (Data[I] = 0) and (Data[I + 1] = 0) and (Data[I + 2] = 0) and (Data[I + 3] = 1) then
      ScLen := 4
    else
    begin
      Inc(I);
      Continue;
    end;
    NalStart := I + ScLen;
    if NalStart >= N then Break;
    if IsH265 then
      NalType := (Data[NalStart] shr 1) and $3F
    else
      NalType := Data[NalStart] and $1F;
    // fim do NAL = próximo start code (00 00 01)
    NalEnd := N;
    J := NalStart + 1;
    while J + 2 < N do
    begin
      if (Data[J] = 0) and (Data[J + 1] = 0) and (Data[J + 2] = 1) then
      begin
        NalEnd := J;
        Break;
      end;
      Inc(J);
    end;
    IsVcl := (IsH265 and (NalType <= 31)) or
             ((not IsH265) and (NalType >= 1) and (NalType <= 5));
    if IsVcl then Break; // chegou no slice; os parâmetros já passaram
    IsParam := (IsH265 and ((NalType = 32) or (NalType = 33) or (NalType = 34))) or
               ((not IsH265) and ((NalType = 7) or (NalType = 8)));
    if IsParam then
      AppendNal(NalStart, NalEnd);
    I := NalEnd;
  end;
end;

procedure TDvripSession.HandleVideo(const AnnexB: TBytes; Keyframe: Boolean; Codec: TVideoCodec);
var
  S: TSample;
  Csd: TBytes;
begin
  if not FVideoNotified then
  begin
    // Espera o 1º keyframe: dele extraímos o SPS/PPS in-band pra dar como csd-0
    // ao decoder (necessário no Android novo). P-frames antes disso são inúteis.
    if not Keyframe then Exit;
    FVideoNotified := True;
    Csd := ExtractInbandCsd(AnnexB, Codec);
    if FMediaSink <> nil then
      FMediaSink.OnVideoFormat(Codec, 0, 0, Csd); // Csd vazio -> decoder usa SPS in-band
    FLogger.Info(FTag, 'Video: ' + VideoCodecToStr(Codec) + ' (stream ' + FStreamType +
      ') csd=' + IntToStr(Length(Csd)) + ' bytes');
  end;
  if Keyframe then Inc(FWinI) else Inc(FWinP);
  Inc(FWinVidBytes, Length(AnnexB));
  S.Kind := tkVideo;
  S.TrackId := 0;
  S.Pts := FPts;
  Inc(FPts, 3600); // ~40ms @ 90kHz (só p/ ordem; display não depende disso)
  if Keyframe then S.Flags := [sfKeyframe] else S.Flags := [];
  S.Data := AnnexB;
  if FMediaSink <> nil then
    FMediaSink.OnSample(S);
end;

procedure TDvripSession.HandleAudio(const Data: TBytes; Codec: TAudioCodec);
var
  S: TSample;
begin
  if not FAudioNotified then
  begin
    FAudioNotified := True;
    if FMediaSink <> nil then
      FMediaSink.OnAudioFormat(Codec, 8000, 1, nil);
    FLogger.Info(FTag, 'Audio: ' + AudioCodecToStr(Codec));
  end;
  Inc(FWinAud);
  Inc(FWinAudBytes, Length(Data));
  S.Kind := tkAudio;
  S.TrackId := 1;
  S.Pts := FAudioPts;
  Inc(FAudioPts, 320); // ~40ms @ 8kHz
  S.Flags := [];
  S.Data := Data;
  if FMediaSink <> nil then
    FMediaSink.OnSample(S);
end;

// Estatísticas a cada 5s: mostra que a mídia continua fluindo (I/P/áudio + kbps).
procedure TDvripSession.LogStatsIfDue;
var
  NowMs: Int64;
  ElapsedMs: Int64;
  Kbps: Integer;
begin
  NowMs := FClock.MonotonicMs;
  if FStatsTickMs = 0 then
  begin
    FStatsTickMs := NowMs;
    Exit;
  end;
  ElapsedMs := NowMs - FStatsTickMs;
  if ElapsedMs < 5000 then Exit;
  if (FWinI or FWinP or FWinAud) <> 0 then
  begin
    Kbps := Integer((FWinVidBytes * 8) div (ElapsedMs)); // bytes*8/ms = kbps
    FLogger.Info(FTag, Format('stats %ds: vid I=%d P=%d (%d kbps) | audio=%d frames',
      [ElapsedMs div 1000, FWinI, FWinP, Kbps, FWinAud]));
  end
  else
    FLogger.Warn(FTag, Format('stats %ds: SEM mídia nessa janela', [ElapsedMs div 1000]));
  FWinI := 0; FWinP := 0; FWinAud := 0;
  FWinVidBytes := 0; FWinAudBytes := 0;
  FStatsTickMs := NowMs;
end;

procedure TDvripSession.Run;
var
  Host: string;
  Port: Word;
  ForceSub, HasExtra: Boolean;
begin
  FSeq := 0;
  FVideoNotified := False;
  FAudioNotified := False;
  FPts := 0;
  FAudioPts := 0;
  FWinI := 0; FWinP := 0; FWinAud := 0;
  FWinVidBytes := 0; FWinAudBytes := 0;
  FStatsTickMs := 0;
  FParser.Reset;
  if not ParseHostPort(Host, Port) then
    raise EVmsConfigError.Create('URL DVRIP inválida: ' + FConfig.Url);

  FTcp := TIndyTcpStream.Create;
  try
    FTcp.Connect(Host, Port, FConfig.ConnectTimeoutMs);
    FLogger.Info(FTag, Format('conectado %s:%d', [Host, Port]));
    if not Login then
      raise EVmsAuthError.Create('Login DVRIP falhou (usuário/senha?)');
    FLogger.Info(FTag, Format('login OK (SessionID=0x%x, alive=%ds)', [FSessionID, FAliveInterval]));

    // Seleção do stream. Padrão = Main (principal, ex.: 1080p). URL com /sub ou
    // /extra força o substream (Extra1), desde que ele tenha vídeo (senão Main).
    ForceSub := (Pos('/sub', LowerCase(FConfig.Url)) > 0) or
                (Pos('/extra', LowerCase(FConfig.Url)) > 0);
    HasExtra := QueryEncodeConfig; // loga o config cru; True se o substream tem vídeo
    if ForceSub and HasExtra then
    begin
      FStreamType := 'Extra1';
      FCombinMode := 'NONE';
    end
    else
    begin
      FStreamType := 'Main';
      FCombinMode := 'CONNECT_ALL';
    end;
    FLogger.Info(FTag, Format('StreamType=%s CombinMode=%s', [FStreamType, FCombinMode]));

    StartMonitor;
    ReceiveLoop;
  finally
    try
      if FTcp <> nil then FTcp.Disconnect;
    except
    end;
    FTcp := nil;
    if FMediaSink <> nil then
      FMediaSink.OnStreamStopped;
  end;
end;

end.
