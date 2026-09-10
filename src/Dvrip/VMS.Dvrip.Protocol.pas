unit VMS.Dvrip.Protocol;

// Protocolo Sofia / DVRIP (câmeras Xiongmai/XM), porta 34567/34568.
// Cada mensagem = header binário de 20 bytes + payload (JSON nos comandos,
// binário nos frames de mídia). Confirmado por captura Wireshark do login.
//
// Header (20 bytes):
//   0    : 0xFF (head)
//   1    : versão (0x01 nas mensagens que a câmera manda)
//   2    : reservado (0x00)
//   3    : flags — NÃO é reservado. Medido na câmera XM: 0x00 nas mensagens de
//          vídeo e 0x80 nas de áudio. Tratar como "tem que ser zero" descarta
//          todo o áudio.
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
  // PTZ. Confirmado por captura do iCSee movendo a câmera (ver DvripPtzJson):
  // no pacote, os bytes logo antes do DataLen são 78 05, e o DataLen bate com
  // o tamanho do JSON -- 328 no comando e 325 na parada, que é exatamente a
  // diferença entre escrever "65535" e escrever "-1".
  // O aviso de evento que a camera manda sozinha, com numero de sessao
  // proprio. Nao pedimos nada disso; ele chega no meio do video.
  DVRIP_ALARM_INFO          = 1504; // 0x05e0
  DVRIP_PTZ                 = 1400; // 0x0578
  DVRIP_PTZ_RSP             = 1401; // 0x0579

  // Os comandos de direção. O NOME aqui é o da imagem, o que o usuário vê; o
  // VALOR é como a câmera chama o mesmo movimento.
  //
  // No horizontal os dois são opostos, e isso foi MEDIDO em duas câmeras
  // diferentes: mandando 'DirectionRight' a imagem anda para a esquerda nas
  // duas. O nome da câmera parece ser do ponto de vista de quem olha PARA ela,
  // que é o espelho do que se vê na tela.
  //
  // A troca fica aqui, e não em quem chama, por dois motivos. Quem lê o resto
  // do código pensa no que o usuário vê, que é o único ponto de vista que
  // importa numa tela. E se um dia aparecer câmera que não inverte, o conserto
  // é neste bloco e não espalhado.
  //
  // O vertical não inverte: cima é cima. Se algum dia aparecer câmera montada
  // de cabeça para baixo, ela inverte os dois, e aí o ajuste é por câmera.
  DVRIP_PTZ_CIMA        = 'DirectionUp';
  DVRIP_PTZ_BAIXO       = 'DirectionDown';
  DVRIP_PTZ_ESQUERDA    = 'DirectionRight';
  DVRIP_PTZ_DIREITA     = 'DirectionLeft';
  DVRIP_PTZ_CIMA_ESQ    = 'DirectionRightUp';
  DVRIP_PTZ_CIMA_DIR    = 'DirectionLeftUp';
  DVRIP_PTZ_BAIXO_ESQ   = 'DirectionRightDown';
  DVRIP_PTZ_BAIXO_DIR   = 'DirectionLeftDown';
  // O resto da lista, conferida contra a implementação de referência do
  // protocolo (python-dvr, do projeto OpenIPC), que traz os dezenove nomes.
  //
  // Os quatro primeiros abaixo eu tinha DEDUZIDO da família de nomes, e a
  // lista confirmou os quatro palavra por palavra. Os cinco últimos vieram
  // dela.
  //
  // Zoom e foco andam enquanto se segura, como as direções: a mesma mensagem
  // com Preset 65535 para começar e -1 para parar. Ronda e preset são de um
  // disparo só.
  DVRIP_PTZ_ZOOM_MAIS   = 'ZoomTile';
  DVRIP_PTZ_ZOOM_MENOS  = 'ZoomWide';
  DVRIP_PTZ_PRESET_IR   = 'GotoPreset';
  DVRIP_PTZ_PRESET_POR  = 'SetPreset';
  DVRIP_PTZ_PRESET_LIMPA = 'ClearPreset';
  DVRIP_PTZ_FOCO_PERTO  = 'FocusNear';
  DVRIP_PTZ_FOCO_LONGE  = 'FocusFar';
  DVRIP_PTZ_IRIS_FECHA  = 'IrisSmall';
  DVRIP_PTZ_IRIS_ABRE   = 'IrisLarge';
  DVRIP_PTZ_RONDA_INI   = 'StartTour';
  DVRIP_PTZ_RONDA_FIM   = 'StopTour';

type
  // As duas formas de OPPTZControl que existem na implementacao de referencia.
  //
  // fPasso  Pattern "SetBegin" e o campo POINT presente. E a da captura do
  //         iCSee e a que a Isis obedece.
  // fStart  Pattern "Start" e SEM o POINT. A referencia usa esta para preset,
  //         e ela nunca foi tentada nas cameras daqui.
  //
  // Existem as duas porque camera que ignora uma pode obedecer a outra, e
  // descobrir qual e trabalho de tentativa.
  TDvripPtzForma = (fPasso, fStart);

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
// RejectInfo = motivo e hex do header recusado na posição corrente ('' se a
// leitura foi limpa). Mensagem recusada é descartada inteira, então este campo é
// a única pista de que isso aconteceu.
function DvripRecvResync(const Stream: ITcpStream; out Hdr: TDvripHeader;
                         out Payload: TBytes; TimeoutMs: Cardinal;
                         ExpectedSession: Cardinal;
                         out SkippedBytes: Integer;
                         out RejectInfo: string;
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

// O JSON do comando de PTZ, no formato exato que a câmera espera.
//
// Reproduzido de uma captura do iCSee movendo a câmera, e conferido pelo
// TAMANHO: o DataLen do pacote dela é 328 no comando e 325 na parada, e este
// texto dá os mesmos 328 e 325 contando o \n final. O espaçamento e a ordem dos
// campos são os da captura de propósito -- não porque a câmera exija, mas
// porque qualquer diferença aqui tiraria a comparação de pé.
//
// Andar e parar são a MESMA mensagem, com o mesmo Command e o mesmo Step. Muda
// um campo só: Preset vale 65535 para começar e -1 para parar. Quem manda o
// comando é responsável por mandar a parada -- sem ela a câmera gira até o fim
// do curso.
//
// Passo vai de 1 a 8 na prática; a captura usou 5.
function DvripPtzJson(const Comando: string; Passo, Canal: Integer;
                      Iniciar: Boolean; const SessionHex: string): string;

// "Vá para o preset N", na mesma mensagem dos comandos de direção.
//
// O número entra onde nos comandos de direção entra o 65535: é o único campo
// que muda. Preset abaixo de 0 não existe e vira 0.
function DvripPresetJson(Preset, Canal: Integer; const SessionHex: string;
                         const Comando: string = DVRIP_PTZ_PRESET_IR): string;

// A direcao pedida, no nome que a camera DVRIP usa. Vazio = direcao invalida.
//
// Quem chama fala em pan/tilt/zoom porque e o vocabulario da ONVIF, que e
// continuo. O DVRIP e discreto: oito direcoes com nome. A conversao mora aqui,
// e nao em cada rota, porque tanto o servidor quanto o app mandam PTZ -- e uma
// segunda copia seria uma segunda chance de divergir.
function ComandoDvripDe(Pan, Tilt, Zoom: Double): string;

// O passo do DVRIP, de 1 a 8, a partir da velocidade normalizada.
function PassoDvripDe(Pan, Tilt, Zoom: Double): Integer;

implementation

const
  // Teto de sanidade para UMA mensagem. Uma mensagem DVRIP carrega um quadro:
  // medido, o I-frame de 1080p desta câmera dá ~34 KB e o de H265 da outra
  // ~116 KB. 4 MB deixa folga de 30x e ainda recusa a família de tamanhos falsos
  // que derrubava a sessão (0,8 a 13 MB).
  MAX_PAYLOAD = 4 * 1024 * 1024;
  // Prazo TOTAL para juntar o payload de UMA mensagem. Uma mensagem DVRIP é um
  // quadro; em qualquer bitrate real ela chega em muito menos que isto.
  MAX_PAYLOAD_MS = 5000;
  // Prazo para engolir o resto de um payload que nao completou. Maior que o de
  // montar a mensagem de proposito: aqui nao ha nada a ganhar desistindo -- sair
  // no meio custa o enquadramento do fluxo inteiro.
  DRENO_MS = 10000;

// Lê Size bytes com prazo TOTAL, e não por chamada.
//
// Por que não usar RecvExact: o ReadTimeout do Indy só dispara quando o fluxo
// PARA de chegar. Com um DataLen falso e enorme — já aconteceu de um header de
// lixo pedir 11 MB — o socket continua entregando vídeo, então nada estoura e a
// thread fica presa lendo por MINUTOS (medido: 104 s a ~1 Mbps). Nesse tempo a
// gravação não avança, e quem está assistindo pelo servidor congela e cai por
// timeout. Com prazo total, um tamanho impossível falha em segundos e o
// chamador reancora no próximo header.
//
// Lidos devolve quantos bytes chegaram ANTES de falhar. E o que permite ao
// chamador consumir o resto e nao deixar o fluxo no meio de uma mensagem --
// ver DescartarBytes logo abaixo.
function RecvExactWithin(const Stream: ITcpStream; var Buf: TBytes; Size: Integer;
  TimeoutMs, TotalMs: Cardinal; out Lidos: Integer): Boolean;
var
  Chunk: TBytes;
  Got, Want, N: Integer;
  Deadline: UInt64;
begin
  Lidos := 0;
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
    Lidos := Got;
  end;
  Result := True;
end;

// Consome e joga fora Quantos bytes, para o fluxo voltar ao inicio da proxima
// mensagem.
//
// Existe porque desistir de um payload no meio deixava o resto dele no socket,
// e a leitura seguinte tomava bytes de video por cabecalho. Aqui nao ha
// adivinhacao: o DataLen ja disse quanto falta. Chegar atrasado ainda e melhor
// que perder o enquadramento, e quem chamou ja desistiu do conteudo -- por isso
// o prazo proprio, e nao o que acabou de estourar.
function DescartarBytes(const Stream: ITcpStream; Quantos: Integer;
  TimeoutMs, TotalMs: Cardinal): Boolean;
var
  Chunk: TBytes;
  Falta, Want, N: Integer;
  Deadline: UInt64;
begin
  if Quantos <= 0 then Exit(True);
  SetLength(Chunk, 64 * 1024);
  Deadline := UInt64(TThread.GetTickCount64) + TotalMs;
  Falta := Quantos;
  while Falta > 0 do
  begin
    if UInt64(TThread.GetTickCount64) > Deadline then Exit(False);
    Want := Falta;
    if Want > Length(Chunk) then Want := Length(Chunk);
    N := Stream.Recv(Chunk, Want, TimeoutMs);
    if N <= 0 then Exit(False);
    Dec(Falta, N);
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
  Lidos: Integer;
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
    if not RecvExactWithin(Stream, Payload, Integer(Hdr.DataLen), TimeoutMs,
                           MAX_PAYLOAD_MS, Lidos) then
    begin
      // Quem chama esta versao segue em frente depois do erro (a consulta de
      // config, o Claim do monitor), entao o resto do payload TEM que sair do
      // socket -- senao a proxima leitura comeca no meio dele.
      if DescartarBytes(Stream, Integer(Hdr.DataLen) - Lidos, TimeoutMs, DRENO_MS) then
        FailReason := Format('payload incompleto (%u bytes) MsgID=%d; resto descartado',
          [Hdr.DataLen, Hdr.MsgID])
      else
        FailReason := Format('payload incompleto (%u bytes) MsgID=%d; fluxo desenquadrado',
          [Hdr.DataLen, Hdr.MsgID]);
      Exit;
    end;
  end;
  Result := True;
end;

// Motivo pelo qual um candidato a header foi recusado; '' = aceito.
//
// Só o 0xFF não serve para reconhecer header: dentro de vídeo comprimido ele
// aparece toda hora. Só somar o teto de tamanho também não basta — os falsos
// positivos medidos caíam a poucos bytes de um header VERDADEIRO, e o DataLen
// acabava lido em cima dos campos dele (reservado, SessionID), dando valores
// enormes mas dentro do teto: 0x00BF0000 = 12,4 MB, que é o SessionID 0xBF
// deslocado.
//
// Cada regra aqui tem um custo se estiver errada: recusar header verdadeiro
// descarta a mensagem inteira em silêncio. Já aconteceu — exigir o byte 3 em
// zero descartou TODO o áudio da câmera XM, que manda 0x80 ali (ver o mapa do
// header no topo da unit). O header recusado era legítimo: SessionID certo,
// MsgID de mídia, DataLen=328 (frame G711 de 320 B + 8 de header).
//
// Quem faz o trabalho de filtrar header falso é o SessionID: são 32 bits que só
// esta sessão conhece, e o vídeo comprimido não os imita por acaso. O byte 2 e o
// teto de DataLen entram como reforço barato.
function HeaderReject(const HBuf: TBytes; ExpectedSession: Cardinal): string;
var
  Session: Cardinal;
begin
  Result := '';
  if Length(HBuf) < 20 then Exit('curto');
  if HBuf[0] <> DVRIP_HEAD then Exit('sem 0xFF');
  if HBuf[2] <> 0 then
    Exit(Format('reservado=%.2x', [HBuf[2]]));
  if ExpectedSession <> 0 then
  begin
    Session := GetLE32(HBuf, 4);
    // Sessao diferente passa quando o MsgID e um dos que conhecemos.
    //
    // A camera manda AlarmInfo (1504) com numero de sessao proprio, e recusar
    // custava caro: o leitor perdia o sincronismo e varria o fluxo atras do
    // proximo cabecalho, jogando fora mais de cem bytes de video a cada
    // comando de PTZ. Medido nas duas cameras.
    //
    // MsgID conhecido e prova tao forte quanto o SessionID: video comprimido
    // nao imita por acaso a marca 0xFF 0x01, o reservado em zero E um numero
    // da nossa tabela, tudo nas posicoes certas.
    if (Session <> ExpectedSession) and (Session <> 0) and
       (DvripClassifyMsg(Word(HBuf[14]) or (Word(HBuf[15]) shl 8)) = mkUnknown) then
      Exit(Format('sessao=%x (esperada %x)', [Session, ExpectedSession]));
  end;
  if GetLE32(HBuf, 16) > MAX_PAYLOAD then
    Exit(Format('DataLen=%u', [GetLE32(HBuf, 16)]));
end;

function HeaderPlausible(const HBuf: TBytes; out MsgID: Word; out DataLen: Cardinal;
  ExpectedSession: Cardinal): Boolean;
begin
  MsgID := 0;
  DataLen := 0;
  Result := HeaderReject(HBuf, ExpectedSession) = '';
  if not Result then Exit;
  MsgID := Word(HBuf[14]) or (Word(HBuf[15]) shl 8);
  DataLen := GetLE32(HBuf, 16);
end;

function DvripRecvResync(const Stream: ITcpStream; out Hdr: TDvripHeader;
  out Payload: TBytes; TimeoutMs: Cardinal; ExpectedSession: Cardinal;
  out SkippedBytes: Integer; out RejectInfo: string;
  out FailReason: string): Boolean;
const
  MAX_RESYNC_SCAN = 4 * 1024 * 1024; // desiste em vez de varrer para sempre
var
  HBuf, OneByte: TBytes;
  MsgID: Word;
  DataLen: Cardinal;
  Lidos: Integer;
begin
  Result := False;
  SkippedBytes := 0;
  RejectInfo := '';
  FailReason := '';
  SetLength(Payload, 0);
  SetLength(HBuf, 20);
  SetLength(OneByte, 1);

  if not Stream.RecvExact(HBuf, 20, TimeoutMs) then
  begin
    FailReason := 'header incompleto';
    Exit;
  end;

  // O motivo da PRIMEIRA recusa é o que interessa: é o header que estava na
  // posição em que devia haver um. Mensagem recusada é mensagem descartada, e
  // sem isso no log não se distingue "lixo" de "mensagem legítima que a regra
  // não reconhece" — foi assim que o áudio sumiu sem deixar rastro.
  if Length(HBuf) >= 20 then
  begin
    RejectInfo := HeaderReject(HBuf, ExpectedSession);
    if RejectInfo <> '' then
      RejectInfo := RejectInfo + ' [' + BytesToHex(HBuf, 20) + ']';
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
    if not RecvExactWithin(Stream, Payload, Integer(DataLen), TimeoutMs,
                           MAX_PAYLOAD_MS, Lidos) then
    begin
      // Pelo mesmo motivo da outra versao. Aqui o laco de recepcao derruba a
      // sessao logo em seguida, mas nao e este codigo que garante isso.
      if DescartarBytes(Stream, Integer(DataLen) - Lidos, TimeoutMs, DRENO_MS) then
        FailReason := Format('payload incompleto (%u bytes) MsgID=%d; resto descartado',
          [DataLen, MsgID])
      else
        FailReason := Format('payload incompleto (%u bytes) MsgID=%d; fluxo desenquadrado',
          [DataLen, MsgID]);
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
    DVRIP_OPMONITOR_RSP,
    // A resposta do PTZ. Estava faltando, e o efeito era ela cair em
    // mkUnknown: a camera respondia ao comando de movimento e o log dizia
    // "MsgID desconhecido" em vez do JSON. Justamente a resposta que se quer
    // ler quando a camera aceita o comando e nao se mexe.
    DVRIP_PTZ, DVRIP_PTZ_RSP,
    DVRIP_ALARM_INFO:
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

// O corpo comum das duas mensagens de OPPTZControl. O que as separa é o par
// (Command, Preset), e é por isso que ele entra por parâmetro em vez de haver
// duas cópias deste texto -- que é comprido e foi conferido byte a byte contra
// uma captura.
function OpPtzJson(const Comando: string; Passo, Canal, Preset: Integer;
  const SessionHex: string; Forma: TDvripPtzForma): string;
var
  Ponto, Padrao: string;
begin
  if Passo < 1 then Passo := 1
  else if Passo > 8 then Passo := 8;
  // A unica diferenca entre as duas formas: o campo POINT existir, e o valor
  // do Pattern. O resto e igual, na mesma ordem.
  if Forma = fPasso then
  begin
    Ponto := '"POINT" : { "bottom" : 0, "left" : 0, "right" : 0, "top" : 0 }, ';
    Padrao := 'SetBegin';
  end
  else
  begin
    Ponto := '';
    Padrao := 'Start';
  end;
  Result :=
    '{ "Name" : "OPPTZControl", "OPPTZControl" : { "Command" : "' + Comando +
    '", "Parameter" : { "AUX" : { "Number" : 0, "Status" : "On" }, ' +
    '"Channel" : ' + IntToStr(Canal) + ', "MenuOpts" : "Enter", ' + Ponto +
    '"Pattern" : "' + Padrao + '", "Preset" : ' + IntToStr(Preset) +
    ', "Step" : ' + IntToStr(Passo) + ', "Tour" : 0 } }, ' +
    '"SessionID" : "' + SessionHex + '" }';
end;

function DvripPtzJson(const Comando: string; Passo, Canal: Integer;
  Iniciar: Boolean; const SessionHex: string): string;
var
  Preset: Integer;
begin
  // 65535 anda, -1 para. Ver o cabeçalho da declaração.
  if Iniciar then Preset := 65535 else Preset := -1;
  // fPasso: é a forma que a referência usa para mover, e a da captura.
  Result := OpPtzJson(Comando, Passo, Canal, Preset, SessionHex, fPasso);
end;

function DvripPresetJson(Preset, Canal: Integer; const SessionHex: string;
  const Comando: string): string;
begin
  if Preset < 0 then Preset := 0;
  // fStart: é a forma que a implementação de referência usa para preset, e a
  // nossa estava mandando o número na forma de mover.
  //
  // Passo 5, o mesmo da captura: para ir a um preset ele não governa nada, mas
  // a mensagem tem o campo e mandá-lo fora da faixa seria pedir problema.
  Result := OpPtzJson(Comando, 5, Canal, Preset, SessionHex, fStart);
end;

function ComandoDvripDe(Pan, Tilt, Zoom: Double): string;
const
  MORTO = 0.15;   // abaixo disto o eixo nao conta: dedo torto nao vira diagonal
begin
  Result := '';
  if Abs(Zoom) > MORTO then
  begin
    if Zoom > 0 then Exit(DVRIP_PTZ_ZOOM_MAIS);
    Exit(DVRIP_PTZ_ZOOM_MENOS);
  end;
  if (Tilt > MORTO) and (Pan < -MORTO) then Exit(DVRIP_PTZ_CIMA_ESQ);
  if (Tilt > MORTO) and (Pan > MORTO) then Exit(DVRIP_PTZ_CIMA_DIR);
  if (Tilt < -MORTO) and (Pan < -MORTO) then Exit(DVRIP_PTZ_BAIXO_ESQ);
  if (Tilt < -MORTO) and (Pan > MORTO) then Exit(DVRIP_PTZ_BAIXO_DIR);
  if Tilt > MORTO then Exit(DVRIP_PTZ_CIMA);
  if Tilt < -MORTO then Exit(DVRIP_PTZ_BAIXO);
  if Pan < -MORTO then Exit(DVRIP_PTZ_ESQUERDA);
  if Pan > MORTO then Exit(DVRIP_PTZ_DIREITA);
end;

function PassoDvripDe(Pan, Tilt, Zoom: Double): Integer;
var
  V: Double;
begin
  V := Abs(Pan);
  if Abs(Tilt) > V then V := Abs(Tilt);
  if Abs(Zoom) > V then V := Abs(Zoom);
  Result := Round(V * 8);
  if Result < 1 then Result := 1;
end;

end.
