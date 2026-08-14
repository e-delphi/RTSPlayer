unit Tx.Server.Session;

interface

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  IdContext,
  IdGlobal,
  IdTCPConnection,
  IdUDPClient,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Rtsp.Messages,
  VMS.Rec.Format,
  VMS.Rec.Reader,
  Tx.Server.Types,
  Tx.Server.Sdp,
  Tx.Pkt.Intf,
  Tx.Pkt.RtpBuilder,
  Tx.Pkt.Factory;

type
  TTxSessionState = (sssInit, sssDescribed, sssSetupDone, sssPlaying, sssPaused, sssDone);

  TTxTrackBinding = record
    Active: Boolean;
    Codec: Integer;
    PayloadType: Byte;
    Timescale: Cardinal;
    Transport: TTxClientTransport;
    Packetizer: IPacketizer;
    UdpSock: TIdUDPClient;
    FirstPtsKnown: Boolean;
    FirstPts: Int64;
    // instante de parede correspondente a FirstPts; por trilha, para poder
    // re-ancorar uma sem bagunçar a outra
    AnchorWallMs: Int64;
  end;

  TTxSession = class;

  TTxPacerThread = class(TThread)
  strict private
    FSession: TTxSession;
  protected
    procedure Execute; override;
  public
    constructor Create(ASession: TTxSession);
  end;

  TTxSession = class
  strict private
    FContext: TIdContext;
    FLogger: ILogger;
    FClock: IClock;
    FRecordingsDir: string;
    FLoop: Boolean;
    FSessionId: string;
    FState: TTxSessionState;
    FWriteLock: TCriticalSection;
    FVmsFile: string;
    FReader: TVmsReader;
    FVideo: TTxTrackBinding;
    FAudio: TTxTrackBinding;
    FStopFlag: Boolean;
    FPacer: TTxPacerThread;
    FAnchorWallMs: Int64;
    FLiveMode: Boolean;
    FCameraName: string;
    procedure Log(Level: TLogLevel; const Msg: string);
    function GenerateSessionId: string;
    procedure SendResponse(Resp: TRtspResponse);
    procedure SendInterleaved(Channel: Byte; const RtpBytes: TBytes);
    procedure SendUdp(Sock: TIdUDPClient; const PeerHost: string; PeerPort: Word; const RtpBytes: TBytes);
    function ParseTransportRequest(const Header: string; out Tx: TTxClientTransport): Boolean;
    function ResolveFileFromUri(const Uri: string): string;
    procedure HandleOptions(Req: TRtspRequest);
    procedure HandleDescribe(Req: TRtspRequest);
    procedure HandleSetup(Req: TRtspRequest);
    procedure HandlePlay(Req: TRtspRequest);
    procedure HandlePause(Req: TRtspRequest);
    procedure HandleTeardown(Req: TRtspRequest);
    procedure HandleGetParameter(Req: TRtspRequest);
    function ParseRangeStartSec(const RangeHeader: string; out StartSec: Double): Boolean;
    procedure SendError(Req: TRtspRequest; Code: Integer);
    procedure OpenReader(const VmsPath: string);
    procedure WireUpPacketizer(var Track: TTxTrackBinding);
    procedure HandleRtpReadyVideo(const RtpBytes: TBytes);
    procedure HandleRtpReadyAudio(const RtpBytes: TBytes);
    procedure DispatchRtp(var Track: TTxTrackBinding; const RtpBytes: TBytes);
    procedure StopPacer;
  public
    constructor Create(AContext: TIdContext; const ALogger: ILogger; const AClock: IClock;
                       const ARecordingsDir: string; ALoop: Boolean);
    destructor Destroy; override;
    procedure HandleRequest(Req: TRtspRequest);
    procedure RunPacerOnce;
    procedure Cleanup;
    property State: TTxSessionState read FState;
    property StopFlag: Boolean read FStopFlag;
    property Reader: TVmsReader read FReader;
    property AnchorWallMs: Int64 read FAnchorWallMs;
    property Clock: IClock read FClock;
  end;

implementation

uses
  IdSocketHandle,
  IdException;

const
  // Espera máxima por sample antes de considerar que o PTS deu um salto.
  PACE_MAX_WAIT_MS = 1000;
  // Atraso máximo tolerado antes de re-ancorar em vez de tentar recuperar.
  PACE_MAX_LAG_MS = 2000;

{ TTxPacerThread }

constructor TTxPacerThread.Create(ASession: TTxSession);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSession := ASession;
end;

procedure TTxPacerThread.Execute;
begin
  try
    while (not Terminated) and (not FSession.StopFlag) do
    begin
      if FSession.State <> sssPlaying then
      begin
        Sleep(50);
        Continue;
      end;
      FSession.RunPacerOnce;
    end;
  except
    on E: Exception do
      ;
  end;
end;

{ TTxSession }

constructor TTxSession.Create(AContext: TIdContext; const ALogger: ILogger; const AClock: IClock;
                              const ARecordingsDir: string; ALoop: Boolean);
begin
  inherited Create;
  FContext := AContext;
  FLogger := ALogger;
  FClock := AClock;
  FRecordingsDir := ARecordingsDir;
  FLoop := ALoop;
  FState := sssInit;
  FWriteLock := TCriticalSection.Create;
  FSessionId := GenerateSessionId;
end;

destructor TTxSession.Destroy;
begin
  Cleanup;
  FWriteLock.Free;
  inherited;
end;

procedure TTxSession.Cleanup;
begin
  FStopFlag := True;
  StopPacer;
  if FVideo.UdpSock <> nil then
  begin
    try FVideo.UdpSock.Active := False; except end;
    FreeAndNil(FVideo.UdpSock);
  end;
  if FAudio.UdpSock <> nil then
  begin
    try FAudio.UdpSock.Active := False; except end;
    FreeAndNil(FAudio.UdpSock);
  end;
  FVideo.Packetizer := nil;
  FAudio.Packetizer := nil;
  if FReader <> nil then
    FreeAndNil(FReader);
end;

procedure TTxSession.StopPacer;
begin
  if FPacer <> nil then
  begin
    FPacer.Terminate;
    FPacer.WaitFor;
    FreeAndNil(FPacer);
  end;
end;

procedure TTxSession.Log(Level: TLogLevel; const Msg: string);
begin
  if FLogger = nil then Exit;
  // com o nome da câmera na tag, o que acontece com quem está assistindo cai no
  // log daquela câmera. Antes do DESCRIBE ainda não se sabe qual é.
  if FCameraName <> '' then
    FLogger.Log(Level, 'tx.session.' + FCameraName, Msg)
  else
    FLogger.Log(Level, 'tx.session', Msg);
end;

function TTxSession.GenerateSessionId: string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to 8 do
    Result := Result + IntToHex(Random(256), 2);
end;

procedure TTxSession.SendResponse(Resp: TRtspResponse);
var
  Bytes: TBytes;
  Idb: TIdBytes;
begin
  Bytes := Resp.Serialize;
  if Length(Bytes) = 0 then Exit;
  SetLength(Idb, Length(Bytes));
  Move(Bytes[0], Idb[0], Length(Bytes));
  FWriteLock.Enter;
  try
    try
      FContext.Connection.IOHandler.Write(Idb);
    except
      on E: Exception do
      begin
        FStopFlag := True;
        Log(llWarn, 'Write response failed: ' + E.Message);
      end;
    end;
  finally
    FWriteLock.Leave;
  end;
end;

procedure TTxSession.SendInterleaved(Channel: Byte; const RtpBytes: TBytes);
var
  Frame: TBytes;
  Idb: TIdBytes;
begin
  Frame := BuildInterleavedFrame(Channel, RtpBytes);
  SetLength(Idb, Length(Frame));
  Move(Frame[0], Idb[0], Length(Frame));
  FWriteLock.Enter;
  try
    try
      FContext.Connection.IOHandler.Write(Idb);
    except
      on E: Exception do
      begin
        FStopFlag := True;
      end;
    end;
  finally
    FWriteLock.Leave;
  end;
end;

procedure TTxSession.SendUdp(Sock: TIdUDPClient; const PeerHost: string; PeerPort: Word; const RtpBytes: TBytes);
var
  Idb: TIdBytes;
begin
  if (Sock = nil) or (Length(RtpBytes) = 0) then Exit;
  SetLength(Idb, Length(RtpBytes));
  Move(RtpBytes[0], Idb[0], Length(RtpBytes));
  try
    Sock.SendBuffer(PeerHost, PeerPort, Idb);
  except
    on E: Exception do ;
  end;
end;

procedure TTxSession.SendError(Req: TRtspRequest; Code: Integer);
var
  Resp: TRtspResponse;
begin
  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := Code;
    Resp.StatusText := StatusTextForCode(Code);
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
end;

procedure TTxSession.HandleOptions(Req: TRtspRequest);
var
  Resp: TRtspResponse;
begin
  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    Resp.Headers.Add('Public', 'OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER');
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
end;

function TTxSession.ResolveFileFromUri(const Uri: string): string;
var
  P, SchemeEnd, PathStart: Integer;
  PathPart, BaseName: string;
begin
  Result := '';
  FLiveMode := False;
  FCameraName := '';
  SchemeEnd := Pos('://', Uri);
  if SchemeEnd > 0 then
  begin
    PathStart := PosEx('/', Uri, SchemeEnd + 3);
    if PathStart > 0 then
      PathPart := Copy(Uri, PathStart, MaxInt)
    else
      PathPart := '/';
  end
  else
    PathPart := Uri;
  while (Length(PathPart) > 0) and (PathPart[1] = '/') do
    Delete(PathPart, 1, 1);
  P := Pos('/trackID=', PathPart);
  if P > 0 then PathPart := Copy(PathPart, 1, P - 1);
  P := Pos('?', PathPart);
  if P > 0 then PathPart := Copy(PathPart, 1, P - 1);

  if StartsText('live/', PathPart) then
  begin
    FLiveMode := True;
    FCameraName := Copy(PathPart, Length('live/') + 1, MaxInt);
    if FCameraName = '' then Exit;
    Result := FindMostRecentVmsForCamera(FRecordingsDir, FCameraName);
    if Result = '' then
      Log(llWarn, 'No .vms found for camera: ' + FCameraName);
    Exit;
  end;

  BaseName := PathPart;
  if BaseName = '' then Exit;
  if not SameText(ExtractFileExt(BaseName), '.vms') then
    BaseName := BaseName + '.vms';
  Result := TPath.Combine(FRecordingsDir, BaseName);
end;

procedure TTxSession.OpenReader(const VmsPath: string);
begin
  if FReader <> nil then FreeAndNil(FReader);
  FReader := TVmsReader.Create(VmsPath);
  if not FReader.ReadHeader then
  begin
    FreeAndNil(FReader);
    raise Exception.Create('Invalid .vms file');
  end;
  FVmsFile := VmsPath;
  if FLiveMode then
  begin
    FReader.EnableLiveMode(60000);
    // Sem isto o cliente entra no PRIMEIRO bloco do arquivo — que pode ter
    // horas de gravação — e ainda no meio de um GOP, ficando com a tela preta
    // até o próximo keyframe. Começar no keyframe mais recente resolve as duas
    // coisas: entra ao vivo e já com ponto de entrada para o decodificador.
    if FReader.SeekToLastKeyframe then
      Log(llInfo, 'live: comecando no keyframe mais recente')
    else
      Log(llWarn, 'live: nenhum keyframe no arquivo; comecando do inicio');
  end
  else
    FReader.BuildIndex;
end;

procedure TTxSession.HandleDescribe(Req: TRtspRequest);
var
  Resp: TRtspResponse;
  VmsPath: string;
  Sdp: string;
  Body: TBytes;
begin
  VmsPath := ResolveFileFromUri(Req.Uri);
  if (VmsPath = '') or (not FileExists(VmsPath)) then
  begin
    Log(llWarn, 'DESCRIBE file not found: ' + VmsPath);
    SendError(Req, 404);
    Exit;
  end;
  try
    OpenReader(VmsPath);
  except
    on E: Exception do
    begin
      Log(llError, 'OpenReader failed: ' + E.Message);
      SendError(Req, 500);
      Exit;
    end;
  end;
  Sdp := BuildSdpForHeader(FReader.Header, ExtractFileName(VmsPath));
  Body := TEncoding.UTF8.GetBytes(Sdp);
  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    Resp.Headers.Add('Content-Type', 'application/sdp');
    Resp.Headers.Add('Content-Base', Req.Uri + '/');
    Resp.Headers.Add('Content-Length', IntToStr(Length(Body)));
    Resp.Body := Body;
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
  FState := sssDescribed;
end;

function TTxSession.ParseTransportRequest(const Header: string; out Tx: TTxClientTransport): Boolean;
var
  Tokens: TArray<string>;
  I: Integer;
  Token, K, V: string;
  P: Integer;
  Parts: TArray<string>;
begin
  FillChar(Tx, SizeOf(Tx), 0);
  Result := False;
  Tokens := Header.Split([';']);
  for I := 0 to High(Tokens) do
  begin
    Token := Trim(Tokens[I]);
    if SameText(Token, 'RTP/AVP/TCP') then
    begin
      Tx.Kind := txTcp;
      Result := True;
      Continue;
    end;
    if SameText(Token, 'RTP/AVP') or SameText(Token, 'RTP/AVP/UDP') then
    begin
      Tx.Kind := txUdp;
      Result := True;
      Continue;
    end;
    P := Pos('=', Token);
    if P < 1 then Continue;
    K := Copy(Token, 1, P - 1);
    V := Copy(Token, P + 1, MaxInt);
    if SameText(K, 'interleaved') then
    begin
      Parts := V.Split(['-']);
      if Length(Parts) >= 1 then Tx.InterleavedRtp := Byte(StrToIntDef(Parts[0], 0));
      if Length(Parts) >= 2 then Tx.InterleavedRtcp := Byte(StrToIntDef(Parts[1], Tx.InterleavedRtp + 1))
      else Tx.InterleavedRtcp := Tx.InterleavedRtp + 1;
      Tx.Kind := txTcp;
    end
    else if SameText(K, 'client_port') then
    begin
      Parts := V.Split(['-']);
      if Length(Parts) >= 1 then Tx.ClientRtpPort := Word(StrToIntDef(Parts[0], 0));
      if Length(Parts) >= 2 then Tx.ClientRtcpPort := Word(StrToIntDef(Parts[1], Tx.ClientRtpPort + 1))
      else Tx.ClientRtcpPort := Tx.ClientRtpPort + 1;
    end;
  end;
end;

procedure TTxSession.WireUpPacketizer(var Track: TTxTrackBinding);
begin
  if Track.Packetizer = nil then Exit;
  Track.Packetizer.SetPayloadType(Track.PayloadType);
  Track.Packetizer.SetSsrc(Cardinal(Random($7FFFFFFF)));
end;

procedure TTxSession.HandleSetup(Req: TRtspRequest);
var
  Resp: TRtspResponse;
  TxHeader, TransportResponse: string;
  Tx: TTxClientTransport;
  IsAudio: Boolean;
  UriLow: string;
begin
  if FReader = nil then
  begin
    SendError(Req, 455);
    Exit;
  end;
  UriLow := LowerCase(Req.Uri);
  IsAudio := (Pos('trackid=1', UriLow) > 0) or (Pos('/track2', UriLow) > 0);

  TxHeader := Req.Headers.Get('Transport');
  if not ParseTransportRequest(TxHeader, Tx) then
  begin
    SendError(Req, 461);
    Exit;
  end;

  if Tx.Kind = txUdp then
  begin
    if IsAudio then
    begin
      if FAudio.UdpSock <> nil then FreeAndNil(FAudio.UdpSock);
      FAudio.UdpSock := TIdUDPClient.Create(nil);
      FAudio.UdpSock.BufferSize := 65535;
    end
    else
    begin
      if FVideo.UdpSock <> nil then FreeAndNil(FVideo.UdpSock);
      FVideo.UdpSock := TIdUDPClient.Create(nil);
      FVideo.UdpSock.BufferSize := 65535;
    end;
  end;

  if IsAudio then
  begin
    if not FReader.Header.AudioPresent then
    begin
      SendError(Req, 404);
      Exit;
    end;
    FAudio.Transport := Tx;
    FAudio.Active := True;
    FAudio.Codec := Integer(FReader.Header.Audio.Codec);
    FAudio.Timescale := FReader.Header.Audio.Timescale;
    case FReader.Header.Audio.Codec of
      acG711U: FAudio.PayloadType := 0;
      acG711A: FAudio.PayloadType := 8;
    else
      FAudio.PayloadType := TX_TRACK_AUDIO_PT;
    end;
    FAudio.Packetizer := CreateAudioPacketizer(FReader.Header.Audio.Codec);
    if FAudio.Packetizer <> nil then
    begin
      WireUpPacketizer(FAudio);
      FAudio.Packetizer.SetOnRtpReady(HandleRtpReadyAudio);
    end;
  end
  else
  begin
    if not FReader.Header.VideoPresent then
    begin
      SendError(Req, 404);
      Exit;
    end;
    FVideo.Transport := Tx;
    FVideo.Active := True;
    FVideo.Codec := Integer(FReader.Header.Video.Codec);
    FVideo.Timescale := FReader.Header.Video.Timescale;
    if FReader.Header.Video.Codec = vcMJPEG then
      FVideo.PayloadType := 26
    else
      FVideo.PayloadType := TX_TRACK_VIDEO_PT;
    FVideo.Packetizer := CreateVideoPacketizer(FReader.Header.Video.Codec);
    if FVideo.Packetizer <> nil then
    begin
      WireUpPacketizer(FVideo);
      FVideo.Packetizer.SetOnRtpReady(HandleRtpReadyVideo);
    end;
  end;

  if Tx.Kind = txTcp then
    TransportResponse := Format('RTP/AVP/TCP;unicast;interleaved=%d-%d',
      [Tx.InterleavedRtp, Tx.InterleavedRtcp])
  else
    TransportResponse := Format('RTP/AVP;unicast;client_port=%d-%d;server_port=0-0',
      [Tx.ClientRtpPort, Tx.ClientRtcpPort]);

  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    Resp.Headers.Add('Session', FSessionId + ';timeout=60');
    Resp.Headers.Add('Transport', TransportResponse);
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
  FState := sssSetupDone;
end;

function TTxSession.ParseRangeStartSec(const RangeHeader: string; out StartSec: Double): Boolean;
var
  S, NptPart, StartStr: string;
  P: Integer;
  Saved: Char;
  FS: TFormatSettings;
begin
  Result := False;
  StartSec := 0;
  S := Trim(RangeHeader);
  if S = '' then Exit;
  P := Pos('npt=', LowerCase(S));
  if P < 1 then Exit;
  NptPart := Copy(S, P + 4, MaxInt);
  P := Pos('-', NptPart);
  if P < 1 then
    StartStr := NptPart
  else
    StartStr := Copy(NptPart, 1, P - 1);
  StartStr := Trim(StartStr);
  if (StartStr = '') or SameText(StartStr, 'now') then Exit;
  FS := FormatSettings;
  FS.DecimalSeparator := '.';
  Saved := FormatSettings.DecimalSeparator;
  if Saved = ',' then StartStr := StringReplace(StartStr, '.', ',', [rfReplaceAll]);
  Result := TryStrToFloat(StartStr, StartSec, FS);
end;

procedure TTxSession.HandlePlay(Req: TRtspRequest);
var
  Resp: TRtspResponse;
  RtpInfo, RangeHeader: string;
  StartSec: Double;
  TargetUnixMs: Int64;
begin
  if (FReader = nil) or ((FState <> sssSetupDone) and (FState <> sssPaused)) then
  begin
    SendError(Req, 455);
    Exit;
  end;

  RangeHeader := Req.Headers.Get('Range');
  if (not FLiveMode) and (RangeHeader <> '') and ParseRangeStartSec(RangeHeader, StartSec) then
  begin
    if Length(FReader.Index) > 0 then
    begin
      TargetUnixMs := FReader.Index[0].StartUnixMs + Int64(Trunc(StartSec * 1000));
      FReader.SeekToTime(TargetUnixMs);
      FVideo.FirstPtsKnown := False;
      FAudio.FirstPtsKnown := False;
    end;
  end;

  FAnchorWallMs := FClock.MonotonicMs;
  RtpInfo := '';
  if FVideo.Active then
    RtpInfo := Format('url=%strackID=0;seq=0;rtptime=0', [Req.Uri]);
  if FAudio.Active then
  begin
    if RtpInfo <> '' then RtpInfo := RtpInfo + ',';
    RtpInfo := RtpInfo + Format('url=%strackID=1;seq=0;rtptime=0', [Req.Uri]);
  end;

  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    Resp.Headers.Add('Session', FSessionId);
    if RtpInfo <> '' then
      Resp.Headers.Add('RTP-Info', RtpInfo);
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
  FState := sssPlaying;
  if FPacer = nil then
  begin
    FPacer := TTxPacerThread.Create(Self);
    FPacer.Start;
  end;
end;

procedure TTxSession.HandlePause(Req: TRtspRequest);
var
  Resp: TRtspResponse;
begin
  if FState = sssPlaying then
    FState := sssPaused;
  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    Resp.Headers.Add('Session', FSessionId);
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
end;

procedure TTxSession.HandleTeardown(Req: TRtspRequest);
var
  Resp: TRtspResponse;
begin
  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    Resp.Headers.Add('Session', FSessionId);
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
  FStopFlag := True;
  FState := sssDone;
end;

procedure TTxSession.HandleGetParameter(Req: TRtspRequest);
var
  Resp: TRtspResponse;
begin
  Resp := TRtspResponse.Create;
  try
    Resp.StatusCode := 200;
    Resp.StatusText := 'OK';
    Resp.Headers.Add('CSeq', Req.Headers.Get('CSeq'));
    if FSessionId <> '' then
      Resp.Headers.Add('Session', FSessionId);
    SendResponse(Resp);
  finally
    Resp.Free;
  end;
end;

procedure TTxSession.HandleRequest(Req: TRtspRequest);
begin
  if SameText(Req.Method, 'OPTIONS')       then HandleOptions(Req)
  else if SameText(Req.Method, 'DESCRIBE') then HandleDescribe(Req)
  else if SameText(Req.Method, 'SETUP')    then HandleSetup(Req)
  else if SameText(Req.Method, 'PLAY')     then HandlePlay(Req)
  else if SameText(Req.Method, 'PAUSE')    then HandlePause(Req)
  else if SameText(Req.Method, 'TEARDOWN') then HandleTeardown(Req)
  else if SameText(Req.Method, 'GET_PARAMETER') then HandleGetParameter(Req)
  else SendError(Req, 501);
end;

procedure TTxSession.DispatchRtp(var Track: TTxTrackBinding; const RtpBytes: TBytes);
var
  PeerHost: string;
begin
  if Track.Transport.Kind = txTcp then
    SendInterleaved(Track.Transport.InterleavedRtp, RtpBytes)
  else
  begin
    try
      PeerHost := FContext.Binding.PeerIP;
    except
      PeerHost := '';
    end;
    if PeerHost = '' then Exit;
    SendUdp(Track.UdpSock, PeerHost, Track.Transport.ClientRtpPort, RtpBytes);
  end;
end;

procedure TTxSession.HandleRtpReadyVideo(const RtpBytes: TBytes);
begin
  DispatchRtp(FVideo, RtpBytes);
end;

procedure TTxSession.HandleRtpReadyAudio(const RtpBytes: TBytes);
begin
  DispatchRtp(FAudio, RtpBytes);
end;

procedure TTxSession.RunPacerOnce;
var
  Block: TVmsBlock;
  I: Integer;
  Sample: TVmsSampleEntry;
  Track: ^TTxTrackBinding;
  RelativeMs: Int64;
  Deadline: Int64;
  NowMs: Int64;
  WaitMs: Int64;
  SampleData: TBytes;
  IsKeyframe: Boolean;
  Pts: Int64;
begin
  if FReader = nil then
  begin
    Sleep(50);
    Exit;
  end;
  if not FReader.ReadNextBlock(Block) then
  begin
    if FLiveMode then
    begin
      Sleep(50);
      Exit;
    end;
    if FLoop then
    begin
      FReader.Free;
      FReader := TVmsReader.Create(FVmsFile);
      FReader.ReadHeader;
      FVideo.FirstPtsKnown := False;
      FAudio.FirstPtsKnown := False;
      FAnchorWallMs := FClock.MonotonicMs;
      Exit;
    end
    else
    begin
      FStopFlag := True;
      Exit;
    end;
  end;
  for I := 0 to High(Block.Samples) do
  begin
    if FStopFlag then Exit;
    Sample := Block.Samples[I];
    if Sample.TrackId = 0 then
    begin
      Track := @FVideo;
      if not Track.Active then Continue;
    end
    else if Sample.TrackId = 1 then
    begin
      Track := @FAudio;
      if not Track.Active then Continue;
    end
    else
      Continue;

    if Track.Packetizer = nil then Continue;

    Pts := Sample.Pts;
    if not Track.FirstPtsKnown then
    begin
      Track.FirstPts := Pts;
      Track.FirstPtsKnown := True;
      Track.AnchorWallMs := FAnchorWallMs;
    end;
    // Ritmo pelo PTS TAMBÉM ao vivo. Antes o modo live saía sem espera nenhuma,
    // e como o arquivo só cresce quando o gravador FECHA um bloco (2 s), o
    // cliente recebia 2 s de mídia numa rajada e ficava mais 2 s sem nada: a
    // imagem andava aos saltos. O arquivo estar sempre alguns segundos atrás do
    // vivo não muda com isto — o que muda é a mídia sair na mesma cadência em
    // que foi gravada.
    if Track.Timescale > 0 then
      RelativeMs := ((Pts - Track.FirstPts) * 1000) div Int64(Track.Timescale)
    else
      RelativeMs := 0;
    NowMs := FClock.MonotonicMs;
    Deadline := Track.AnchorWallMs + RelativeMs;
    WaitMs := Deadline - NowMs;
    // Fora destes limites não é atraso normal e sim descontinuidade de PTS
    // (wrap do timestamp RTP, troca de arquivo) ou uma fila que cresceu demais.
    // Re-ancora: segue no ritmo certo a partir daqui, sem despejar tudo de uma
    // vez nem dormir um tempo absurdo.
    if (WaitMs > PACE_MAX_WAIT_MS) or (WaitMs < -PACE_MAX_LAG_MS) then
    begin
      Track.FirstPts := Pts;
      Track.AnchorWallMs := NowMs;
      WaitMs := 0;
    end;
    // Atrasado (WaitMs < 0) sai na hora: é assim que recupera o atraso de uma
    // rajada curta sem precisar re-ancorar.
    if WaitMs > 0 then
      Sleep(Cardinal(WaitMs));

    SetLength(SampleData, Sample.PayloadSize);
    if Sample.PayloadSize > 0 then
      Move(Block.Payload[Sample.PayloadOffset], SampleData[0], Sample.PayloadSize);
    IsKeyframe := (Sample.FlagsByte and $01) <> 0;
    Track.Packetizer.PushSample(Pts, SampleData, IsKeyframe);
  end;
end;

end.
