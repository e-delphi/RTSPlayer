unit VMS.Dvrip.Protocol;

// Protocolo Sofia / DVRIP (câmeras Xiongmai/XM), porta 34567/34568.
// Cada mensagem = header binário de 20 bytes + payload (JSON nos comandos,
// binário nos frames de mídia). Confirmado por captura Wireshark do login.
//
// Header (20 bytes):
//   0    : 0xFF (head)
//   1    : versão (0x00)
//   2-3  : reservado
//   4-7  : SessionID (LE)
//   8-11 : sequence   (LE)
//   12   : total de pacotes
//   13   : pacote atual
//   14-15: MsgID       (LE)
//   16-19: DataLen     (LE)  (tamanho do payload, inclui o \n final nos JSON)

interface

uses
  System.SysUtils,
  System.Classes,
  System.Hash,
  VMS.Net.Intf;

const
  DVRIP_HEAD = $FF;
  // MsgIDs. Login confirmado pela captura (0x03E8). A convenção do protocolo é
  // request = N e resposta = N+1; os fluxos de dados têm ID próprio.
  DVRIP_LOGIN               = 1000; // 0x03E8  (confirmado na captura)
  DVRIP_LOGIN_RSP           = 1001;
  DVRIP_KEEPALIVE           = 1006;
  DVRIP_KEEPALIVE_RSP       = 1007;
  DVRIP_SYSINFO             = 1020;
  DVRIP_SYSINFO_RSP         = 1021;
  DVRIP_CONFIG_GET          = 1042; // get de config por nome (ex.: "Simplify.Encode")
  DVRIP_CONFIG_GET_RSP      = 1043;
  // OPMonitor usa 2 MsgIDs distintos: Claim reserva no 1413, Start abre o fluxo
  // no 1410 (= 1413-3). Mandar o Claim no 1410 faz a câmera recusar com Ret=103.
  DVRIP_OPMONITOR_CLAIM     = 1413; // 0x0585  Action="Claim"
  DVRIP_OPMONITOR_CLAIM_RSP = 1414; // 0x0586
  DVRIP_OPMONITOR           = 1410; // 0x0582  Action="Start"
  DVRIP_OPMONITOR_RSP       = 1411; // 0x0583  resposta do Start (JSON com Ret)
  DVRIP_OPMONITOR_DATA      = 1412; // 0x0584  canal de dados de mídia

type
  TDvripHeader = record
    SessionID: Cardinal;
    Sequence: Cardinal;
    MsgID: Word;
    DataLen: Cardinal;
  end;

  // Para que serve o payload de uma mensagem recebida. O discriminador certo é
  // o MsgID do header: olhar o 1º byte do payload é heurística e erra em frame
  // de mídia que começa com 0x7B ('{').
  TDvripMsgKind = (mkUnknown, mkControl, mkMedia);

// Hash "Sofia" da senha: MD5(senha) -> 8 chars. Ex.: gera "nebTfKGj".
function SofiaHash(const Password: string): string;

// Envia um comando: header(20) + JSON + #10.
procedure DvripSendCmd(const Stream: ITcpStream; SessionID, Sequence: Cardinal;
                       MsgID: Word; const Json: string);

// Lê uma mensagem completa (header + payload cru). O chamador decide se o
// payload é JSON (resposta de comando) ou binário (frames de mídia).
function DvripRecv(const Stream: ITcpStream; out Hdr: TDvripHeader;
                   out Payload: TBytes; TimeoutMs: Cardinal): Boolean; overload;
// Mesma coisa, devolvendo em FailReason o motivo exato (com o hex do que
// chegou). Timeout e conexão fechada NÃO passam por aqui — o RecvExact levanta
// exceção nesses casos. Um False daqui é sempre desenquadramento.
function DvripRecv(const Stream: ITcpStream; out Hdr: TDvripHeader;
                   out Payload: TBytes; TimeoutMs: Cardinal;
                   out FailReason: string): Boolean; overload;

// Igual, mas se o fluxo estiver fora de sincronia procura o próximo início de
// mensagem plausível em vez de derrubar a conexão — mesma ideia do resync que
// o parser de mídia já faz uma camada abaixo.
// SkippedBytes = quantos bytes foram descartados até reencontrar o início
// (0 = leitura limpa). Se vier sempre o mesmo número, é tamanho mal calculado
// em algum tipo de mensagem, e aí o conserto é no comprimento, não aqui.
// ExpectedSession = SessionID desta sessão (0 antes do login = não confere).
// Sem ele, "começa com 0xFF e o tamanho cabe em 16 MB" aceita header falso
// dentro de vídeo comprimido — foi medido: um 0xFF 14 bytes ANTES de um header
// de verdade faz o DataLen ser lido em cima do próprio SessionID do header
// seguinte (0x00BF0000 = 12,4 MB), e a sessão morre ali.
function DvripRecvResync(const Stream: ITcpStream; out Hdr: TDvripHeader;
                         out Payload: TBytes; TimeoutMs: Cardinal;
                         ExpectedSession: Cardinal;
                         out SkippedBytes: Integer;
                         out FailReason: string): Boolean;

// Classifica a mensagem pelo MsgID do header. mkUnknown = ID fora da tabela;
// cabe ao chamador decidir (e avisar) — nada aqui adivinha pelo conteúdo.
function DvripClassifyMsg(MsgID: Word): TDvripMsgKind;

// True se o payload começa (ignorando espaços/quebras) com '{', ou seja, se
// parece um JSON de controle. Só para conferir a classificação por MsgID.
function DvripLooksLikeJson(const Payload: TBytes): Boolean;

// Extrai um valor string de um JSON simples ("chave":"valor" ou "chave":123).
function JsonGetStr(const Json, Key: string): string;
function JsonGetInt(const Json, Key: string; Default: Integer): Integer;
// Extrai o objeto { ... } que segue "Section" (respeitando chaves aninhadas).
function ExtractSection(const Json, Section: string): string;
// Bytes -> "aa bb cc ..." (para log de diagnóstico).
function BytesToHex(const B: TBytes; MaxCount: Integer): string;

implementation

const
  MAX_PAYLOAD = 16 * 1024 * 1024; // teto de sanidade (16 MB)
  // Prazo TOTAL para juntar o payload de UMA mensagem. Uma mensagem DVRIP é um
  // quadro; em qualquer bitrate real ela chega em muito menos que isto.
  MAX_PAYLOAD_MS = 5000;

// Lê Size bytes com prazo TOTAL, e não por chamada.
//
// Por que não usar RecvExact: o ReadTimeout do Indy só dispara quando o fluxo
// PARA de chegar. Com um DataLen falso e enorme — já aconteceu de um header de
// lixo pedir 11 MB — o socket continua entregando vídeo, então nada estoura e a
// thread fica presa lendo por MINUTOS (medido: 104 s a ~1 Mbps). Nesse tempo a
// gravação não avança, e quem está assistindo pelo servidor congela e cai por
// timeout. Com prazo total, um tamanho impossível falha em segundos e o
// chamador reancora no próximo header.
function RecvExactWithin(const Stream: ITcpStream; var Buf: TBytes; Size: Integer;
  TimeoutMs, TotalMs: Cardinal): Boolean;
var
  Chunk: TBytes;
  Got, Want, N: Integer;
  Deadline: UInt64;
begin
  if Size <= 0 then Exit(True);
  if Length(Buf) < Size then SetLength(Buf, Size);
  SetLength(Chunk, 64 * 1024);
  Deadline := UInt64(TThread.GetTickCount64) + TotalMs;
  Got := 0;
  while Got < Size do
  begin
    if UInt64(TThread.GetTickCount64) > Deadline then Exit(False);
    Want := Size - Got;
    if Want > Length(Chunk) then Want := Length(Chunk);
    N := Stream.Recv(Chunk, Want, TimeoutMs);
    if N <= 0 then Exit(False);
    Move(Chunk[0], Buf[Got], N);
    Inc(Got, N);
  end;
  Result := True;
end;

function SofiaHash(const Password: string): string;
const
  ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
var
  H: THashMD5;
  PwBytes, Digest: TBytes;
  I, N: Integer;
begin
  PwBytes := TEncoding.UTF8.GetBytes(Password);
  H := THashMD5.Create;
  H.Update(PwBytes);
  Digest := H.HashAsBytes; // 16 bytes
  Result := '';
  if Length(Digest) < 16 then Exit;
  for I := 0 to 7 do
  begin
    N := (Digest[2 * I] + Digest[2 * I + 1]) mod 62;
    Result := Result + ALPHABET[N + 1]; // string 1-based
  end;
end;

procedure PutLE32(var B: TBytes; Offset: Integer; V: Cardinal); inline;
begin
  B[Offset]     := Byte(V);
  B[Offset + 1] := Byte(V shr 8);
  B[Offset + 2] := Byte(V shr 16);
  B[Offset + 3] := Byte(V shr 24);
end;

function GetLE32(const B: TBytes; Offset: Integer): Cardinal; inline;
begin
  Result := Cardinal(B[Offset]) or (Cardinal(B[Offset + 1]) shl 8) or
            (Cardinal(B[Offset + 2]) shl 16) or (Cardinal(B[Offset + 3]) shl 24);
end;

procedure DvripSendCmd(const Stream: ITcpStream; SessionID, Sequence: Cardinal;
  MsgID: Word; const Json: string);
var
  Payload, Buf: TBytes;
  N: Integer;
begin
  Payload := TEncoding.UTF8.GetBytes(Json + #10);
  N := Length(Payload);
  SetLength(Buf, 20 + N);
  FillChar(Buf[0], 20, 0);
  Buf[0] := DVRIP_HEAD;
  // Buf[1] versão = 0; 2-3 reservado = 0
  PutLE32(Buf, 4, SessionID);
  PutLE32(Buf, 8, Sequence);
  // 12 total / 13 atual = 0
  Buf[14] := Byte(MsgID);
  Buf[15] := Byte(MsgID shr 8);
  PutLE32(Buf, 16, Cardinal(N));
  if N > 0 then
    Move(Payload[0], Buf[20], N);
  Stream.Send(Buf);
end;

function DvripRecv(const Stream: ITcpStream; out Hdr: TDvripHeader;
  out Payload: TBytes; TimeoutMs: Cardinal): Boolean;
var
  Ignored: string;
begin
  Result := DvripRecv(Stream, Hdr, Payload, TimeoutMs, Ignored);
end;

function DvripRecv(const Stream: ITcpStream; out Hdr: TDvripHeader;
  out Payload: TBytes; TimeoutMs: Cardinal; out FailReason: string): Boolean;
var
  HBuf: TBytes;
begin
  Result := False;
  FailReason := '';
  SetLength(Payload, 0);
  SetLength(HBuf, 20);
  if not Stream.RecvExact(HBuf, 20, TimeoutMs) then
  begin
    FailReason := 'header incompleto';
    Exit;
  end;
  if HBuf[0] <> DVRIP_HEAD then
  begin
    // O fluxo saiu de sincronia: o que deveria ser começo de mensagem não é.
    // O hex mostra onde paramos dentro do que veio antes.
    FailReason := Format('fora de sincronia: esperava 0x%.2x, veio 0x%.2x [%s]',
      [DVRIP_HEAD, HBuf[0], BytesToHex(HBuf, 20)]);
    Exit;
  end;
  Hdr.SessionID := GetLE32(HBuf, 4);
  Hdr.Sequence := GetLE32(HBuf, 8);
  Hdr.MsgID := Word(HBuf[14]) or (Word(HBuf[15]) shl 8);
  Hdr.DataLen := GetLE32(HBuf, 16);
  if Hdr.DataLen > MAX_PAYLOAD then
  begin
    FailReason := Format('DataLen invalido (%u) MsgID=%d [%s]',
      [Hdr.DataLen, Hdr.MsgID, BytesToHex(HBuf, 20)]);
    Exit;
  end;
  if Hdr.DataLen > 0 then
  begin
    SetLength(Payload, Hdr.DataLen);
    if not RecvExactWithin(Stream, Payload, Integer(Hdr.DataLen), TimeoutMs, MAX_PAYLOAD_MS) then
    begin
      FailReason := Format('payload incompleto (%u bytes) MsgID=%d',
        [Hdr.DataLen, Hdr.MsgID]);
      Exit;
    end;
  end;
  Result := True;
end;

// Um header só é aceito se TODOS os campos fixos baterem. Só o 0xFF não serve:
// dentro de vídeo comprimido ele aparece toda hora. E só somar o teto de
// tamanho também não bastou — na prática os falsos positivos caíam a poucos
// bytes de um header verdadeiro, e o DataLen acabava lido em cima dos campos
// dele (SessionID, reservado), dando valores enormes mas "válidos".
//
// Os dois campos que um trecho de vídeo não imita por acaso:
//   - bytes 2-3 reservados, sempre 00 00
//   - SessionID, um valor de 32 bits que só esta sessão conhece
function HeaderPlausible(const HBuf: TBytes; out MsgID: Word; out DataLen: Cardinal;
  ExpectedSession: Cardinal): Boolean;
begin
  Result := False;
  if Length(HBuf) < 20 then Exit;
  if HBuf[0] <> DVRIP_HEAD then Exit;
  if (HBuf[2] <> 0) or (HBuf[3] <> 0) then Exit;
  if (ExpectedSession <> 0) and (GetLE32(HBuf, 4) <> ExpectedSession) then Exit;
  MsgID := Word(HBuf[14]) or (Word(HBuf[15]) shl 8);
  DataLen := GetLE32(HBuf, 16);
  Result := DataLen <= MAX_PAYLOAD;
end;

function DvripRecvResync(const Stream: ITcpStream; out Hdr: TDvripHeader;
  out Payload: TBytes; TimeoutMs: Cardinal; ExpectedSession: Cardinal;
  out SkippedBytes: Integer; out FailReason: string): Boolean;
const
  MAX_RESYNC_SCAN = 4 * 1024 * 1024; // desiste em vez de varrer para sempre
var
  HBuf, OneByte: TBytes;
  MsgID: Word;
  DataLen: Cardinal;
begin
  Result := False;
  SkippedBytes := 0;
  FailReason := '';
  SetLength(Payload, 0);
  SetLength(HBuf, 20);
  SetLength(OneByte, 1);

  if not Stream.RecvExact(HBuf, 20, TimeoutMs) then
  begin
    FailReason := 'header incompleto';
    Exit;
  end;

  // desliza a janela de 20 bytes até ela parecer um header de verdade
  while not HeaderPlausible(HBuf, MsgID, DataLen, ExpectedSession) do
  begin
    if SkippedBytes >= MAX_RESYNC_SCAN then
    begin
      FailReason := Format('sem sincronia apos %d bytes [%s]',
        [SkippedBytes, BytesToHex(HBuf, 20)]);
      Exit;
    end;
    Move(HBuf[1], HBuf[0], 19);
    if not Stream.RecvExact(OneByte, 1, TimeoutMs) then
    begin
      FailReason := Format('fluxo acabou apos pular %d bytes', [SkippedBytes]);
      Exit;
    end;
    HBuf[19] := OneByte[0];
    Inc(SkippedBytes);
  end;

  Hdr.SessionID := GetLE32(HBuf, 4);
  Hdr.Sequence := GetLE32(HBuf, 8);
  Hdr.MsgID := MsgID;
  Hdr.DataLen := DataLen;
  if DataLen > 0 then
  begin
    SetLength(Payload, DataLen);
    if not RecvExactWithin(Stream, Payload, Integer(DataLen), TimeoutMs, MAX_PAYLOAD_MS) then
    begin
      FailReason := Format('payload incompleto (%u bytes) MsgID=%d', [DataLen, MsgID]);
      Exit;
    end;
  end;
  Result := True;
end;

function DvripClassifyMsg(MsgID: Word): TDvripMsgKind;
begin
  case MsgID of
    // Único ID de mídia que conhecemos: o canal de dados do OPMonitor.
    DVRIP_OPMONITOR_DATA:
      Result := mkMedia;
    // Comandos e suas respostas: payload é sempre JSON. Inclui os IDs de
    // request porque algumas câmeras respondem no mesmo ID em que perguntamos.
    DVRIP_LOGIN, DVRIP_LOGIN_RSP,
    DVRIP_KEEPALIVE, DVRIP_KEEPALIVE_RSP,
    DVRIP_SYSINFO, DVRIP_SYSINFO_RSP,
    DVRIP_CONFIG_GET, DVRIP_CONFIG_GET_RSP,
    DVRIP_OPMONITOR_CLAIM, DVRIP_OPMONITOR_CLAIM_RSP,
    DVRIP_OPMONITOR_RSP:
      Result := mkControl;
    // DVRIP_OPMONITOR (1410) fica de fora de propósito: é o ID em que mandamos
    // o Start, e não sabemos se esta câmera responde nele ou se manda mídia por
    // ele. Cai em mkUnknown para o chamador logar o que realmente chegou.
  else
    Result := mkUnknown;
  end;
end;

function DvripLooksLikeJson(const Payload: TBytes): Boolean;
var
  I: Integer;
begin
  I := 0;
  while (I < Length(Payload)) and
        ((Payload[I] = 32) or (Payload[I] = 9) or (Payload[I] = 10) or (Payload[I] = 13)) do
    Inc(I);
  Result := (I < Length(Payload)) and (Payload[I] = Ord('{'));
end;

function JsonGetStr(const Json, Key: string): string;
var
  P, Q, R: Integer;
begin
  Result := '';
  P := Pos('"' + Key + '"', Json);
  if P < 1 then Exit;
  P := P + Length(Key) + 2;
  // pula ':' e espaços
  while (P <= Length(Json)) and (Json[P] <> ':') do Inc(P);
  Inc(P);
  while (P <= Length(Json)) and (Json[P] = ' ') do Inc(P);
  if (P <= Length(Json)) and (Json[P] = '"') then
  begin
    Inc(P);
    Q := P;
    while (Q <= Length(Json)) and (Json[Q] <> '"') do Inc(Q);
    Result := Copy(Json, P, Q - P);
  end
  else
  begin
    R := P;
    while (R <= Length(Json)) and (Json[R] <> ',') and (Json[R] <> '}') do Inc(R);
    Result := Trim(Copy(Json, P, R - P));
  end;
end;

function JsonGetInt(const Json, Key: string; Default: Integer): Integer;
var
  S: string;
begin
  S := JsonGetStr(Json, Key);
  if S = '' then Exit(Default);
  Result := StrToIntDef(S, Default);
end;

function ExtractSection(const Json, Section: string): string;
var
  P, I, Depth: Integer;
begin
  Result := '';
  P := Pos('"' + Section + '"', Json);
  if P < 1 then Exit;
  I := P;
  while (I <= Length(Json)) and (Json[I] <> '{') do Inc(I);
  if I > Length(Json) then Exit;
  P := I;
  Depth := 0;
  while I <= Length(Json) do
  begin
    if Json[I] = '{' then Inc(Depth)
    else if Json[I] = '}' then
    begin
      Dec(Depth);
      if Depth = 0 then Break;
    end;
    Inc(I);
  end;
  Result := Copy(Json, P, I - P + 1);
end;

function BytesToHex(const B: TBytes; MaxCount: Integer): string;
const
  HEX = '0123456789abcdef';
var
  I, N: Integer;
begin
  N := Length(B);
  if (MaxCount > 0) and (MaxCount < N) then N := MaxCount;
  SetLength(Result, N * 3);
  for I := 0 to N - 1 do
  begin
    Result[I * 3 + 1] := HEX[(B[I] shr 4) + 1];
    Result[I * 3 + 2] := HEX[(B[I] and $F) + 1];
    Result[I * 3 + 3] := ' ';
  end;
end;

end.
