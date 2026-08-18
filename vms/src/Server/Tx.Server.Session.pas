unit Tx.Server.Session;

// Uma sessão RTSP por cliente conectado. Duas fontes possíveis:
//
//   memória — /live/<camera> quando o hub tem a câmera publicando. O sample sai
//             para o cliente no instante em que chega da câmera; é o caminho de
//             baixa latência, e não toca no disco.
//   arquivo — playback de um .vms e o plano B do ao vivo (câmera que ainda não
//             conectou nesta execução). Aqui a mídia é ritmada pelo PTS, porque
//             o arquivo entrega um bloco fechado de cada vez.
//
// A mesma conexão também atende HTTP (a API de gravações, ver Vms.Server.Api):
// quem chega com `HTTP/1.1` na linha do pedido cai no HandleHttpRequest. A
// resposta sai pelo mesmo lock de escrita do RTP interleaved — se saísse por
// fora, um quadro no meio da resposta corromperia as duas coisas.

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
  Vms.Server.LiveHub,
  Vms.Server.Api,
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
    FHub: TLiveHub;
    FApi: TApiRouter;
    FSessionId: string;
    FState: TTxSessionState;
    FWriteLock: TCriticalSection;
    // Buffers de envio, reaproveitados entre pacotes. Um TIdBytes local com
    // SetLength por pacote — que era como estava — dava uma alocação por quadro
    // RTP POR CLIENTE, mais outra do frame interleaved montado à parte.
    // FTxIdb só é tocado dentro do FWriteLock; FUdpIdb só pela thread do pacer.
    FTxIdb: TIdBytes;
    FUdpIdb: TIdBytes;
    FVmsFile: string;
    FReader: TVmsReader;
    // Formatos que o SDP desta sessão descreve. Vêm do header do arquivo ou dos
    // formatos correntes do hub; o SETUP responde a partir daqui, para não
    // depender de qual das duas fontes está em uso.
    FHeader: TVmsHeader;
    FLive: TLiveStream;   // nil = fonte é o arquivo
    FCursor: TLiveCursor;
    FVideo: TTxTrackBinding;
    FAudio: TTxTrackBinding;
    FStopFlag: Boolean;
    FPacer: TTxPacerThread;
    FAnchorWallMs: Int64;
    FLiveMode: Boolean;
    FCameraName: string;
    FLastBlockMs: Int64; // último bloco lido; detecta arquivo que parou de crescer
    FRejectedLivePath: string; // arquivo novo recusado (codec diferente): não repete
    function SwitchToNewerLiveFile: Boolean;
    procedure Log(Level: TLogLevel; const Msg: string);
    function GenerateSessionId: string;
    procedure SendResponse(Resp: TRtspResponse);
    procedure SendHttpBytes(const Head, Body: TBytes);
    procedure SendApiResponse(Req: TRtspRequest; const Resp: TApiResponse);
    procedure SendInterleaved(Channel: Byte; const RtpBytes: TBytes);
    procedure SendUdp(Sock: TIdUDPClient; const PeerHost: string; PeerPort: Word; const RtpBytes: TBytes);
    function ParseTransportRequest(const Header: string; out Tx: TTxClientTransport): Boolean;
    function ParseRoute(const Uri: string): string;
    function ResolveVmsFile(const PathPart: string): string;
    function LiveHeaderMatchesSdp(const H: TVmsHeader): Boolean;
    procedure PreferInbandParameterSets;
    procedure RunFilePacerOnce;
    procedure RunLivePacerOnce(AStream: TLiveStream);
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
                       const ARecordingsDir: string; ALoop: Boolean; AHub: TLiveHub = nil;
                       AApi: TApiRouter = nil);
    destructor Destroy; override;
    procedure HandleRequest(Req: TRtspRequest);
    // Pedido HTTP na mesma porta (a API de gravações). Separado do
    // HandleRequest de propósito: nada aqui toca no estado da sessão RTSP.
    procedure HandleHttpRequest(Req: TRtspRequest);
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
  // Quanto o leitor ao vivo espera por um bloco novo antes de devolver o
  // controle ao pacer (não é erro: ele só tenta de novo).
  LIVE_READ_WAIT_MS = 2000;
  // Espera do pacer por sample novo na memória. Só define de quanto em quanto
  // tempo a thread reavalia StopFlag/estado: o sample em si acorda a espera na
  // hora em que a câmera o entrega.
  LIVE_FETCH_WAIT_MS = 200;

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
                              const ARecordingsDir: string; ALoop: Boolean; AHub: TLiveHub;
                              AApi: TApiRouter);
begin
  inherited Create;
  FContext := AContext;
  FLogger := ALogger;
  FClock := AClock;
  FRecordingsDir := ARecordingsDir;
  FLoop := ALoop;
  FHub := AHub;
  FApi := AApi;
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
  FLive := nil;   // o stream é do hub; a sessão só apontava para ele
  FCursor.Valid := False;
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

// Cabeçalho e corpo numa tomada só do lock. Em duas, um quadro RTP de um PLAY
// em andamento nesta mesma conexão poderia entrar no meio da resposta HTTP.
procedure TTxSession.SendHttpBytes(const Head, Body: TBytes);
var
  IdbHead, IdbBody: TIdBytes;
begin
  SetLength(IdbHead, Length(Head));
  if Length(Head) > 0 then
    Move(Head[0], IdbHead[0], Length(Head));
  SetLength(IdbBody, Length(Body));
  if Length(Body) > 0 then
    Move(Body[0], IdbBody[0], Length(Body));
  FWriteLock.Enter;
  try
    try
      FContext.Connection.IOHandler.Write(IdbHead);
      if Length(IdbBody) > 0 then
        FContext.Connection.IOHandler.Write(IdbBody);
    except
      on E: Exception do
      begin
        FStopFlag := True;
        Log(llWarn, 'falha ao escrever resposta HTTP: ' + E.Message);
      end;
    end;
  finally
    FWriteLock.Leave;
  end;
end;

procedure TTxSession.SendApiResponse(Req: TRtspRequest; const Resp: TApiResponse);
var
  Sb: TStringBuilder;
  I: Integer;
  KeepAlive: Boolean;
  Body: TBytes;
begin
  KeepAlive := not SameText(Trim(Req.Headers.Get('Connection')), 'close');
  // HEAD responde igual, mas sem corpo — e com o Content-Length do corpo que
  // teria, que é o que faz o HEAD servir para alguma coisa.
  if SameText(Req.Method, 'HEAD') then
    Body := nil
  else
    Body := Resp.Body;

  Sb := TStringBuilder.Create;
  try
    Sb.AppendFormat('HTTP/1.1 %d %s'#13#10, [Resp.Status, StatusTextForCode(Resp.Status)]);
    Sb.AppendFormat('Content-Type: %s'#13#10, [Resp.ContentType]);
    Sb.AppendFormat('Content-Length: %d'#13#10, [Length(Resp.Body)]);
    // Gravação muda o tempo todo (o arquivo do dia cresce): resposta guardada
    // em cache seria resposta errada.
    Sb.Append('Cache-Control: no-store'#13#10);
    for I := 0 to High(Resp.Extra) do
      Sb.Append(Resp.Extra[I]).Append(#13#10);
    if KeepAlive then
      Sb.Append('Connection: keep-alive'#13#10)
    else
      Sb.Append('Connection: close'#13#10);
    Sb.Append(#13#10);
    SendHttpBytes(TEncoding.UTF8.GetBytes(Sb.ToString), Body);
  finally
    Sb.Free;
  end;

  if not KeepAlive then
    FStopFlag := True;
end;

procedure TTxSession.HandleHttpRequest(Req: TRtspRequest);
var
  Resp: TApiResponse;
begin
  if FApi = nil then
  begin
    Resp := TApiResponse.Error(404, 'api indisponivel');
    SendApiResponse(Req, Resp);
    Exit;
  end;
  Resp := FApi.Handle(Req.Method, Req.Uri);
  SendApiResponse(Req, Resp);
end;

procedure TTxSession.SendInterleaved(Channel: Byte; const RtpBytes: TBytes);
var
  Len, Total: Integer;
begin
  Len := Length(RtpBytes);
  if Len > $FFFF then Exit;   // não cabe no tamanho de 16 bits do enquadramento
  Total := 4 + Len;
  FWriteLock.Enter;
  try
    // Montado direto no buffer da sessão, dentro do lock: some o TBytes
    // intermediário do BuildInterleavedFrame e a cópia para o TIdBytes. O Write
    // leva o tamanho explícito, então o buffer pode ser maior que o pacote.
    if Length(FTxIdb) < Total then
      SetLength(FTxIdb, Total);
    FTxIdb[0] := $24;
    FTxIdb[1] := Channel;
    FTxIdb[2] := Byte((Len shr 8) and $FF);
    FTxIdb[3] := Byte(Len and $FF);
    if Len > 0 then
      Move(RtpBytes[0], FTxIdb[4], Len);
    try
      FContext.Connection.IOHandler.Write(FTxIdb, Total);
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
begin
  if (Sock = nil) or (Length(RtpBytes) = 0) then Exit;
  // Aqui o array TEM que ter o tamanho exato: o SendBuffer do Indy manda
  // Length(ABuffer) bytes, não aceita tamanho separado. Então o truque de
  // capacidade não serve — o que dá para fazer é reaproveitar o mesmo campo, e
  // o SetLength só custa quando o tamanho muda de um pacote para o outro.
  if Length(FUdpIdb) <> Length(RtpBytes) then
    SetLength(FUdpIdb, Length(RtpBytes));
  Move(RtpBytes[0], FUdpIdb[0], Length(RtpBytes));
  try
    Sock.SendBuffer(PeerHost, PeerPort, FUdpIdb);
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

// Lê a rota pedida e devolve o caminho limpo (sem esquema, sem trackID, sem
// query). Só isso: achar o arquivo é outro passo, porque a rota ao vivo pode
// nem precisar de arquivo.
function TTxSession.ParseRoute(const Uri: string): string;
var
  P, SchemeEnd, PathStart: Integer;
  PathPart: string;
begin
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
  end;
  Result := PathPart;
end;

function TTxSession.ResolveVmsFile(const PathPart: string): string;
var
  BaseName: string;
begin
  Result := '';
  if FLiveMode then
  begin
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
  FReader.Logger := FLogger;   // bloco corrompido vira aviso no log da câmera
  if not FReader.ReadHeader then
  begin
    FreeAndNil(FReader);
    raise Exception.Create('Invalid .vms file');
  end;
  FVmsFile := VmsPath;
  if FLiveMode then
  begin
    // Espera curta de propósito: quando o arquivo para de crescer, o pacer
    // precisa voltar para decidir o que fazer (ver SwitchToNewerLiveFile). Com
    // os 60 s de antes ele ficava um minuto preso aqui dentro — muito além dos
    // 10 s em que o cliente desiste. Voltar sem bloco pronto não custa nada: o
    // leitor não perde a posição e o pacer só tenta de novo.
    FReader.EnableLiveMode(LIVE_READ_WAIT_MS);
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
  Route, VmsPath, SdpName: string;
  Sdp: string;
  Body: TBytes;
  Stream: TLiveStream;
begin
  Route := ParseRoute(Req.Uri);
  FLive := nil;

  // Memória primeiro: se a câmera está publicando agora, é dela que sai a
  // mídia, e o arquivo nem é aberto. Sem formatos ainda (câmera desligada,
  // servidor recém-subido) cai no arquivo, que é o histórico dela.
  if FLiveMode and (FHub <> nil) and (FCameraName <> '') then
  begin
    Stream := FHub.Find(FCameraName);
    if (Stream <> nil) and Stream.TryGetHeader(FHeader) then
      FLive := Stream;
  end;

  if FLive = nil then
  begin
    VmsPath := ResolveVmsFile(Route);
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
    FHeader := FReader.Header;
    SdpName := ExtractFileName(VmsPath);
    if FLiveMode then
      Log(llInfo, 'ao vivo pelo arquivo (camera sem publicacao na memoria)');
  end
  else
  begin
    SdpName := FCameraName;
    Log(llInfo, 'ao vivo pela memoria');
  end;

  // Antes de montar o SDP: o extradata que veio do header pode não descrever o
  // que a câmera realmente transmite. Ver PreferInbandParameterSets.
  PreferInbandParameterSets;
  Sdp := BuildSdpForHeader(FHeader, SdpName);
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
  if FState = sssInit then   // sem DESCRIBE não há formato para descrever
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

  // UDP é recusado de propósito, com o código que o cliente entende (461
  // Unsupported Transport): ele cai para TCP interleaved na hora. Aceitar era
  // pior — o servidor respondia `server_port=0-0`, não mandava RTCP SR e o
  // caminho nunca foi exercitado, então o cliente descobria o problema no meio
  // do stream. E pelo túnel do Tailscale tem que ser TCP de qualquer forma: o
  // WireGuard usa MTU 1280 e RTP em UDP de ~1400 bytes é descartado.
  if Tx.Kind = txUdp then
  begin
    Log(llInfo, 'SETUP em UDP recusado (461); o cliente deve tentar TCP interleaved');
    SendError(Req, 461);
    Exit;
  end;

  if IsAudio then
  begin
    if not FHeader.AudioPresent then
    begin
      SendError(Req, 404);
      Exit;
    end;
    FAudio.Transport := Tx;
    FAudio.Active := True;
    FAudio.Codec := Integer(FHeader.Audio.Codec);
    FAudio.Timescale := FHeader.Audio.Timescale;
    case FHeader.Audio.Codec of
      acG711U: FAudio.PayloadType := 0;
      acG711A: FAudio.PayloadType := 8;
    else
      FAudio.PayloadType := TX_TRACK_AUDIO_PT;
    end;
    FAudio.Packetizer := CreateAudioPacketizer(FHeader.Audio.Codec);
    if FAudio.Packetizer <> nil then
    begin
      WireUpPacketizer(FAudio);
      FAudio.Packetizer.SetOnRtpReady(HandleRtpReadyAudio);
    end;
  end
  else
  begin
    if not FHeader.VideoPresent then
    begin
      SendError(Req, 404);
      Exit;
    end;
    FVideo.Transport := Tx;
    FVideo.Active := True;
    FVideo.Codec := Integer(FHeader.Video.Codec);
    FVideo.Timescale := FHeader.Video.Timescale;
    if FHeader.Video.Codec = vcMJPEG then
      FVideo.PayloadType := 26
    else
      FVideo.PayloadType := TX_TRACK_VIDEO_PT;
    FVideo.Packetizer := CreateVideoPacketizer(FHeader.Video.Codec);
    if FVideo.Packetizer <> nil then
    begin
      WireUpPacketizer(FVideo);
      FVideo.Packetizer.SetOnRtpReady(HandleRtpReadyVideo);
    end;
  end;

  // Só chega aqui em TCP: o UDP foi recusado com 461 acima.
  TransportResponse := Format('RTP/AVP/TCP;unicast;interleaved=%d-%d',
    [Tx.InterleavedRtp, Tx.InterleavedRtcp]);

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
  if ((FReader = nil) and (FLive = nil)) or
     ((FState <> sssSetupDone) and (FState <> sssPaused)) then
  begin
    SendError(Req, 455);
    Exit;
  end;

  // Assina agora, e de novo a cada PLAY: depois de um PAUSE o cliente quer
  // voltar ao vivo, não retomar de onde parou.
  if FLive <> nil then
    if not FLive.Subscribe(FCursor) then
      Log(llWarn, 'camera parou de publicar; aguardando ela voltar');

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
  FLastBlockMs := FAnchorWallMs;
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
    // Inerte enquanto o SETUP recusa UDP (461). Fica aqui porque é a metade
    // pronta do caminho: se o UDP voltar, falta abrir a porta de saída e
    // responder o server_port de verdade — não isto.
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

// O gravador começa um arquivo NOVO toda vez que a sessão com a câmera cai e
// reconecta. Quem estava assistindo ficava preso no arquivo velho, que nunca
// mais cresce: imagem congelada até o cliente desistir por timeout e reconectar
// — foi o que apareceu no log da isis. Se o arquivo parou de crescer e já há um
// mais recente para esta câmera, segue nele, do keyframe mais recente.
//
// Só troca se os codecs baterem: o cliente já recebeu o SDP do arquivo antigo, e
// mandar outro codec no meio seria pior que congelar. Se mudou, deixa o cliente
// cair e reconectar, que aí ele pega um SDP novo.
function TTxSession.SwitchToNewerLiveFile: Boolean;
const
  LIVE_STALL_MS = 5000; // > período de um bloco, para não trocar por jitter
var
  Path: string;
  Probe: TVmsReader;
begin
  Result := False;
  if (not FLiveMode) or (FCameraName = '') then Exit;
  if (FClock.MonotonicMs - FLastBlockMs) < LIVE_STALL_MS then Exit;
  Path := FindMostRecentVmsForCamera(FRecordingsDir, FCameraName);
  if (Path = '') or SameText(Path, FVmsFile) then Exit;
  // Já recusado antes: não reabre nem repete o aviso a cada tentativa.
  if SameText(Path, FRejectedLivePath) then Exit;

  try
    Probe := TVmsReader.Create(Path);
  except
    Exit; // ainda sendo criado; tenta de novo na próxima
  end;
  try
    if not Probe.ReadHeader then Exit;
    if FVideo.Active and (Integer(Probe.Header.Video.Codec) <> FVideo.Codec) then
    begin
      FRejectedLivePath := Path;
      Log(llWarn, 'arquivo novo tem outro codec de video; nao vou trocar no meio da sessao');
      Exit;
    end;
    if FAudio.Active and (Integer(Probe.Header.Audio.Codec) <> FAudio.Codec) then
    begin
      FRejectedLivePath := Path;
      Log(llWarn, 'arquivo novo tem outro codec de audio; nao vou trocar no meio da sessao');
      Exit;
    end;
  finally
    Probe.Free;
  end;

  try
    OpenReader(Path); // reabre em modo live e já posiciona no keyframe
  except
    on E: Exception do
    begin
      Log(llWarn, 'falha ao trocar de arquivo ao vivo: ' + E.Message);
      Exit;
    end;
  end;
  FVideo.FirstPtsKnown := False;
  FAudio.FirstPtsKnown := False;
  FAnchorWallMs := FClock.MonotonicMs;
  FLastBlockMs := FClock.MonotonicMs;
  Log(llInfo, 'gravacao trocou de arquivo; seguindo em ' + ExtractFileName(Path));
  Result := True;
end;

procedure TTxSession.RunPacerOnce;
var
  Stream: TLiveStream;
begin
  // Uma leitura só do campo: quem escolhe a fonte é a thread da conexão (no
  // DESCRIBE), e ela pode zerar FLive entre o teste e o uso.
  Stream := FLive;
  if Stream <> nil then
    RunLivePacerOnce(Stream)
  else
    RunFilePacerOnce;
end;

// O SDP entregue ao cliente descreve os formatos de FHeader. Depois de a câmera
// reconectar, isto diz se o que ela voltou a publicar ainda cabe naquele SDP.
// Trilha de áudio que aparece depois não invalida nada para quem só pediu vídeo.
// Troca o extradata do header pelos parameter sets que o STREAM traz, quando ele
// os traz. O extradata do `.vms` veio do SDP da câmera, e há câmera cujo SDP
// mente: a ayla anuncia Baseline/CAVLC e transmite Main/CABAC, com o mesmo
// sps_id. O nosso player já ignora o SDP quando vê parameter sets in-band, mas
// VLC, ffplay e o csd-0 do MediaCodec configuram o decodificador pelo que o SDP
// disser — e configuram errado.
//
// Não achando nada in-band (câmera que só manda parameter set no SDP), fica o
// que estava: melhor um extradata duvidoso que nenhum.
procedure TTxSession.PreferInbandParameterSets;
const
  MAX_SAMPLES = 24;   // ~2 s de vídeo: se não vier nos primeiros, não vem
var
  Samples: TArray<TBytes>;
  Probe: TVmsReader;
  Block: TVmsBlock;
  PS, Found: TBytes;
  I, Count, Idx: Integer;
  Codec: TVideoCodec;
begin
  if not FHeader.VideoPresent then Exit;
  Codec := FHeader.Video.Codec;
  if (Codec <> vcH264) and (Codec <> vcH265) then Exit;

  Samples := nil;
  if FLive <> nil then
    Samples := FLive.RecentVideoSamples(MAX_SAMPLES)
  else if FVmsFile <> '' then
  begin
    // Leitor próprio, de vida curta: o FReader já está posicionado para tocar, e
    // mexer nele aqui bagunçaria o começo da reprodução.
    try
      Probe := TVmsReader.Create(FVmsFile);
    except
      Exit;
    end;
    try
      if not Probe.ReadHeader then Exit;
      if not Probe.SeekToLastKeyframe then
        if not Probe.SeekToStart then Exit;
      Count := 0;
      SetLength(Samples, MAX_SAMPLES);
      while (Count < MAX_SAMPLES) and Probe.ReadNextBlock(Block) do
        for I := 0 to High(Block.Samples) do
        begin
          if Block.Samples[I].TrackId <> 0 then Continue;
          if Count >= MAX_SAMPLES then Break;
          SetLength(Samples[Count], Block.Samples[I].PayloadSize);
          if Block.Samples[I].PayloadSize > 0 then
            Move(Block.Payload[Block.Samples[I].PayloadOffset], Samples[Count][0],
                 Block.Samples[I].PayloadSize);
          Inc(Count);
        end;
      SetLength(Samples, Count);
    finally
      Probe.Free;
    end;
  end;

  Found := nil;
  for Idx := 0 to High(Samples) do
  begin
    PS := ParameterSetsOf(Samples[Idx], Codec);
    if Length(PS) = 0 then Continue;
    // ACUMULA entre samples: quando a câmera manda cada NAL sozinha, o SPS vem
    // num sample e o PPS no seguinte — substituir um pelo outro nunca fecharia
    // o conjunto. Para assim que dá para configurar um decodificador.
    Found := Found + PS;
    if ParameterSetsComplete(Found, Codec) then Break;
  end;

  if (Length(Found) > 0) and ParameterSetsComplete(Found, Codec) then
  begin
    Log(llInfo, Format('SDP: parameter sets do stream (%d bytes) no lugar dos do header (%d)',
      [Length(Found), Length(FHeader.Video.Extradata)]));
    FHeader.Video.Extradata := Found;
  end;
end;

function TTxSession.LiveHeaderMatchesSdp(const H: TVmsHeader): Boolean;
begin
  Result := False;
  if FVideo.Active then
  begin
    if not H.VideoPresent then Exit;
    if Integer(H.Video.Codec) <> FVideo.Codec then Exit;
    // resolução nova quer parameter set novo, e o cliente já configurou o
    // decodificador com o csd do SDP antigo
    if (H.Video.Width <> FHeader.Video.Width) or (H.Video.Height <> FHeader.Video.Height) then
      Exit;
  end;
  if FAudio.Active then
  begin
    if not H.AudioPresent then Exit;
    if Integer(H.Audio.Codec) <> FAudio.Codec then Exit;
    if H.Audio.Timescale <> FAudio.Timescale then Exit;
  end;
  Result := True;
end;

// Ao vivo pela memória: sem espera pelo PTS. O sample já chega no ritmo da
// câmera, então segurar aqui só somaria latência — que é justamente o que este
// caminho existe para tirar.
procedure TTxSession.RunLivePacerOnce(AStream: TLiveStream);
var
  Items: TArray<TLiveSampleRec>;
  Res: TLiveFetch;
  I: Integer;
  Track: ^TTxTrackBinding;
  NewHeader: TVmsHeader;
begin
  if not FCursor.Valid then
  begin
    if not AStream.Subscribe(FCursor) then
    begin
      Sleep(50);
      Exit;
    end;
  end;

  Res := AStream.Fetch(FCursor, LIVE_FETCH_WAIT_MS, Items);
  case Res of
    lfNone:
      Exit;
    lfFormatChanged:
      begin
        if AStream.TryGetHeader(NewHeader) and LiveHeaderMatchesSdp(NewHeader) then
        begin
          AStream.Subscribe(FCursor);
          Log(llInfo, 'camera reanunciou o formato; seguindo ao vivo');
        end
        else
        begin
          // Mandar outro codec no meio seria pior que cair: o cliente reconecta
          // e faz DESCRIBE de novo. Mesma regra do SwitchToNewerLiveFile.
          Log(llWarn, 'formato da camera mudou; encerrando para o cliente refazer o DESCRIBE');
          FStopFlag := True;
        end;
        Exit;
      end;
    lfResync:
      // Duas causas possíveis: cliente que não consome no ritmo da câmera, ou
      // câmera que caiu e voltou (o buffer é esvaziado na queda).
      Log(llWarn, 'reposicionado no keyframe mais recente (cliente atrasado ou camera reconectou)');
  end;

  for I := 0 to High(Items) do
  begin
    if FStopFlag then Exit;
    if Items[I].TrackId = 0 then
      Track := @FVideo
    else if Items[I].TrackId = 1 then
      Track := @FAudio
    else
      Continue;
    if (not Track.Active) or (Track.Packetizer = nil) then Continue;
    Track.Packetizer.PushSample(Items[I].Pts, Items[I].Data, Items[I].Keyframe);
  end;
end;

procedure TTxSession.RunFilePacerOnce;
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
      if not SwitchToNewerLiveFile then
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
  FLastBlockMs := FClock.MonotonicMs;
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
      // Âncora A/V do bloco: quando ela existe, a distância real
      // entre o começo do áudio e o do vídeo é preservada em vez de zerada.
      // Vale para o caso em que o áudio dita o ritmo (stream sem vídeo); com
      // vídeo presente ele sai na posição em que foi gravado, e o que carrega a
      // relação até o cliente é o PTS dentro do RTP.
      if (Sample.TrackId = 1) and (Block.AudioAnchorMs > 0) and (Block.VideoAnchorMs > 0) then
        Track.AnchorWallMs := FAnchorWallMs + (Block.AudioAnchorMs - Block.VideoAnchorMs);
    end;
    // Ritmo pelo PTS TAMBÉM ao vivo. Antes o modo live saía sem espera nenhuma,
    // e como o arquivo só cresce quando o gravador FECHA um bloco (2 s), o
    // cliente recebia 2 s de mídia numa rajada e ficava mais 2 s sem nada: a
    // imagem andava aos saltos. O arquivo estar sempre alguns segundos atrás do
    // vivo não muda com isto — o que muda é a mídia sair na mesma cadência em
    // que foi gravada.
    //
    // Quem dita o ritmo é o VÍDEO. O áudio sai na posição em que foi gravado —
    // ele está intercalado no bloco, entre os quadros — sem espera própria. Uma
    // trilha de áudio irregular (a câmera dvrip manda em rajadas, e em vários
    // trechos nada) tem a linha de tempo bem mais longa que o bloco, e se
    // dormisse no relógio dela seguraria o vídeo que vem depois: engasgo no
    // vídeo por causa do áudio. Sem trilha de vídeo, quem dita é o áudio.
    if (Sample.TrackId = 0) or (not FVideo.Active) then
    begin
      if Track.Timescale > 0 then
        RelativeMs := ((Pts - Track.FirstPts) * 1000) div Int64(Track.Timescale)
      else
        RelativeMs := 0;
      NowMs := FClock.MonotonicMs;
      Deadline := Track.AnchorWallMs + RelativeMs;
      WaitMs := Deadline - NowMs;
      // Fora destes limites não é atraso normal e sim descontinuidade de PTS
      // (wrap do timestamp RTP, troca de arquivo) ou uma fila que cresceu
      // demais. Re-ancora: segue no ritmo certo a partir daqui, sem despejar
      // tudo de uma vez nem dormir um tempo absurdo.
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
    end;

    SetLength(SampleData, Sample.PayloadSize);
    if Sample.PayloadSize > 0 then
      Move(Block.Payload[Sample.PayloadOffset], SampleData[0], Sample.PayloadSize);
    IsKeyframe := (Sample.FlagsByte and $01) <> 0;
    Track.Packetizer.PushSample(Pts, SampleData, IsKeyframe);
  end;
end;

end.
