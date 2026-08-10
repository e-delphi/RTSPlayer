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
  // MsgIDs. Login confirmado pela captura (0x03E8). Os de OPMonitor/keepalive
  // são os padrões do protocolo — confirmar no hex do OPMonitor se necessário.
  DVRIP_LOGIN            = 1000; // 0x03E8  (confirmado na captura)
  DVRIP_KEEPALIVE        = 1006;
  DVRIP_SYSINFO          = 1020;
  DVRIP_CONFIG_GET       = 1042; // get de config por nome (ex.: "Simplify.Encode")
  // OPMonitor usa 2 MsgIDs distintos: Claim reserva no 1413, Start abre o fluxo
  // no 1410 (= 1413-3). Mandar o Claim no 1410 faz a câmera recusar com Ret=103.
  DVRIP_OPMONITOR_CLAIM  = 1413; // 0x0585  Action="Claim"
  DVRIP_OPMONITOR        = 1410; // 0x0582  Action="Start" + canal de dados de mídia

type
  TDvripHeader = record
    SessionID: Cardinal;
    Sequence: Cardinal;
    MsgID: Word;
    DataLen: Cardinal;
  end;

// Hash "Sofia" da senha: MD5(senha) -> 8 chars. Ex.: gera "nebTfKGj".
function SofiaHash(const Password: string): string;

// Envia um comando: header(20) + JSON + #10.
procedure DvripSendCmd(const Stream: ITcpStream; SessionID, Sequence: Cardinal;
                       MsgID: Word; const Json: string);

// Lê uma mensagem completa (header + payload cru). O chamador decide se o
// payload é JSON (resposta de comando) ou binário (frames de mídia).
function DvripRecv(const Stream: ITcpStream; out Hdr: TDvripHeader;
                   out Payload: TBytes; TimeoutMs: Cardinal): Boolean;

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
  HBuf: TBytes;
begin
  Result := False;
  SetLength(Payload, 0);
  SetLength(HBuf, 20);
  if not Stream.RecvExact(HBuf, 20, TimeoutMs) then Exit;
  if HBuf[0] <> DVRIP_HEAD then Exit;
  Hdr.SessionID := GetLE32(HBuf, 4);
  Hdr.Sequence := GetLE32(HBuf, 8);
  Hdr.MsgID := Word(HBuf[14]) or (Word(HBuf[15]) shl 8);
  Hdr.DataLen := GetLE32(HBuf, 16);
  if Hdr.DataLen > MAX_PAYLOAD then Exit;
  if Hdr.DataLen > 0 then
  begin
    SetLength(Payload, Hdr.DataLen);
    if not Stream.RecvExact(Payload, Integer(Hdr.DataLen), TimeoutMs) then Exit;
  end;
  Result := True;
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
