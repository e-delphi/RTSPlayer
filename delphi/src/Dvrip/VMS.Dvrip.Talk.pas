unit VMS.Dvrip.Talk;

// Fala: áudio que vai PARA a câmera tocar no alto-falante (OPTalk do DVRIP).
//
// Fluxo, na mesma porta 34567 e numa conexão só dela:
//   login -> Claim (1434, espera Ret=100) -> Start (1430)
//   -> um frame a cada 40 ms no 1432: 8 bytes de sub-header + 320 de A-law
//   -> Stop (1430) e desconecta
//
// Os números e o formato do frame são os do go2rtc (pkg/dvrip), que já fala com
// estas câmeras; não há documentação oficial do protocolo.
//
// Duas threads:
//   ritmo  -- tira da fila um quadro a cada 40 ms e manda. A página entrega o
//             áudio aos pedaços, na hora que o HTTP deixa; mandar do jeito que
//             chega entupiria o buffer da câmera, que toca em tempo real.
//   leitor -- depois do Start a câmera abre um canal duplex e manda o microfone
//             dela por aqui. Ninguém quer esse áudio, mas ele TEM de ser lido:
//             com o buffer TCP cheio a câmera para de mandar, e o que se viu no
//             go2rtc foi a conexão travar.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Net.Intf,
  VMS.Net.Tcp,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Ptz,
  VMS.Dvrip.Protocol;

type
  TDvripTalk = class(TInterfacedObject, IFalaSession)
  strict private
    FHost: string;
    FPort: Word;
    FUser: string;
    FPassword: string;
    FTimeoutMs: Cardinal;
    FLogger: ILogger;
    FTag: string;
    FTcp: ITcpStream;
    FSessionID: Cardinal;
    FAliveInterval: Integer;
    FSeq: Cardinal;
    // Seq e socket: o ritmo manda áudio e keepalive, e o Fechar pode mandar o
    // Stop de outra thread.
    FEnvio: TCriticalSection;
    // A fila de A-law entre o Enviar (thread do HTTP) e o ritmo.
    FFilaLock: TCriticalSection;
    FFila: TBytes;
    FEnchendo: Boolean;
    FUltimoEnviarMs: UInt64;
    FParar: TEvent;
    FViva: Boolean;
    FFechou: Integer;
    FRitmo: TThread;
    FLeitor: TThread;
    // Para o log do fim da conversa: é ele que diz se houve buraco ou atraso.
    FQuadros: Integer;
    FFaltas: Integer;
    FDescartados: Int64;
    FRecebidos: Int64;
    function NextSeq: Cardinal;
    procedure Mandar(MsgID: Word; const Payload: TBytes);
    procedure MandarJson(MsgID: Word; const Json: string);
    function LerClaim(out Motivo: string): Boolean;
    procedure LacoRitmo;
    procedure LacoLeitor;
  public
    constructor Create(const AHost: string; APort: Word;
                       const AUser, APassword: string; ATimeoutMs: Cardinal;
                       const ALogger: ILogger; const ATag: string);
    destructor Destroy; override;
    // Conecta, loga, Claim e Start. False = não deu, e Motivo diz o porquê.
    function Abrir(out Motivo: string): Boolean;
    { IFalaSession }
    function Enviar(const Pcm: TBytes): Boolean;
    procedure Fechar;
    function Viva: Boolean;
  end;

// G.711 A-law de uma amostra linear de 16 bits (o linear2alaw clássico da Sun).
function LinearParaALaw(Amostra: Integer): Byte;
// PCM 16 bits little-endian -> A-law, um byte por amostra. Byte ímpar no fim
// (amostra pela metade) é ignorado.
function PcmParaALaw(const Pcm: TBytes): TBytes;

implementation

const
  PERIODO_MS = 40;  // DVRIP_OPTALK_QUADRO bytes a 8 kHz
  // Quanto juntar antes de começar a tocar, e de novo depois de a fila secar.
  // O áudio chega em POSTs de ~160 ms, e o HTTP não é pontual: sem essa folga
  // cada atraso de um POST vira um buraco na fala.
  PREENCHER = DVRIP_OPTALK_QUADRO * 8;  // 320 ms
  // Teto da fila. Acima disso a fala estaria ficando para trás do que a pessoa
  // diz; o mais velho sai, porque atraso é pior que um corte.
  FILA_MAX = DVRIP_OPTALK_QUADRO * 38;  // ~1,5 s
  // Sem Enviar por este tempo e com a fila vazia, a conversa se encerra: a
  // página pode ter fechado sem mandar o `fechar`, e a câmera não pode ficar
  // com o alto-falante preso.
  OCIOSA_MS = 3000;
  // Se o ritmo se atrasar mais que isto (máquina parada, depurador), recomeça
  // a contar do agora em vez de mandar uma rajada para recuperar.
  ATRASO_MAX_MS = 200;

type
  // Uma thread que roda um procedimento e não se libera sozinha: o Fechar
  // precisa esperar por ela.
  TLaco = class(TThread)
  strict private
    FProc: TProc;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProc: TProc);
  end;

constructor TLaco.Create(const AProc: TProc);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProc := AProc;
end;

procedure TLaco.Execute;
begin
  FProc();
end;

function LinearParaALaw(Amostra: Integer): Byte;
const
  FIM_SEG: array[0..7] of Integer = ($1F, $3F, $7F, $FF, $1FF, $3FF, $7FF, $FFF);
var
  Pcm, Mascara, Seg: Integer;
  A: Integer;
begin
  // O original faz `pcm >> 3` com deslocamento aritmético e, se negativo,
  // `-pcm - 1`. As duas contas juntas dão (-amostra - 1) >> 3, que é o que se
  // escreve aqui sem depender de shr com sinal.
  if Amostra >= 0 then
  begin
    Pcm := Amostra shr 3;
    Mascara := $D5;
  end
  else
  begin
    Pcm := (-Amostra - 1) shr 3;
    Mascara := $55;
  end;
  Seg := 0;
  while (Seg < 8) and (Pcm > FIM_SEG[Seg]) do
    Inc(Seg);
  if Seg >= 8 then
    Exit(Byte($7F xor Mascara));
  A := Seg shl 4;
  if Seg < 2 then
    A := A or ((Pcm shr 1) and $0F)
  else
    A := A or ((Pcm shr Seg) and $0F);
  Result := Byte(A xor Mascara);
end;

function PcmParaALaw(const Pcm: TBytes): TBytes;
var
  I, N: Integer;
begin
  N := Length(Pcm) div 2;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := LinearParaALaw(SmallInt(Word(Pcm[2 * I]) or (Word(Pcm[2 * I + 1]) shl 8)));
end;

{ TDvripTalk }

constructor TDvripTalk.Create(const AHost: string; APort: Word;
  const AUser, APassword: string; ATimeoutMs: Cardinal;
  const ALogger: ILogger; const ATag: string);
begin
  inherited Create;
  FHost := AHost;
  FPort := APort;
  FUser := AUser;
  FPassword := APassword;
  FTimeoutMs := ATimeoutMs;
  if FTimeoutMs = 0 then FTimeoutMs := 5000;
  FLogger := ALogger;
  FTag := ATag;
  FEnvio := TCriticalSection.Create;
  FFilaLock := TCriticalSection.Create;
  FParar := TEvent.Create(nil, True, False, '');
end;

destructor TDvripTalk.Destroy;
begin
  Fechar;
  FRitmo.Free;
  FLeitor.Free;
  FParar.Free;
  FFilaLock.Free;
  FEnvio.Free;
  inherited;
end;

function TDvripTalk.NextSeq: Cardinal;
begin
  Inc(FSeq);
  Result := FSeq;
end;

procedure TDvripTalk.Mandar(MsgID: Word; const Payload: TBytes);
begin
  FEnvio.Enter;
  try
    DvripSendBin(FTcp, FSessionID, NextSeq, MsgID, Payload);
  finally
    FEnvio.Leave;
  end;
end;

procedure TDvripTalk.MandarJson(MsgID: Word; const Json: string);
begin
  Mandar(MsgID, TEncoding.UTF8.GetBytes(Json + #10));
end;

// A resposta do Claim. Pode vir depois de outra mensagem -- a câmera manda
// AlarmInfo por conta própria --, então lê algumas até achar a do OPTalk.
function TDvripTalk.LerClaim(out Motivo: string): Boolean;
var
  Hdr: TDvripHeader;
  Payload: TBytes;
  Resp, Falha: string;
  I, Ret: Integer;
begin
  Result := False;
  Motivo := 'a camera nao respondeu ao OPTalk Claim';
  try
    for I := 1 to 6 do
    begin
      if not DvripRecv(FTcp, Hdr, Payload, 3000, Falha) then
      begin
        Motivo := 'resposta do OPTalk Claim ilegivel: ' + Falha;
        Exit;
      end;
      Resp := TEncoding.UTF8.GetString(Payload);
      if (Hdr.MsgID <> DVRIP_OPTALK_CLAIM_RSP) and (Hdr.MsgID <> DVRIP_OPTALK_CLAIM) and
         (Pos('OPTalk', Resp) = 0) then
      begin
        FLogger.Debug(FTag, Format('antes do Claim, MsgID=%d: %s', [Hdr.MsgID, Resp]));
        Continue;
      end;
      Ret := JsonGetInt(Resp, 'Ret', -1);
      FLogger.Info(FTag, Format('OPTalk Claim Ret=%d', [Ret]));
      if Ret = 100 then Exit(True);
      // Camera sem alto-falante, ou com outra conversa aberta (o app dela, por
      // exemplo): nos dois casos a recusa vem aqui.
      Motivo := Format('a camera recusou a fala (OPTalk Claim Ret=%d)', [Ret]);
      Exit;
    end;
  except
    on EVmsTimeoutError do ; // fica o Motivo de "nao respondeu"
  end;
end;

function TDvripTalk.Abrir(out Motivo: string): Boolean;
var
  Resp: string;
begin
  Result := False;
  Motivo := '';
  try
    FTcp := TIndyTcpStream.Create;
    FTcp.Connect(FHost, FPort, FTimeoutMs);
    if not DvripLogin(FTcp, FUser, FPassword, FTimeoutMs, FSessionID,
                      FAliveInterval, Resp) then
    begin
      Motivo := 'login DVRIP da fala falhou';
      FLogger.Debug(FTag, 'login resp: ' + Resp);
    end
    else
    begin
      MandarJson(DVRIP_OPTALK_CLAIM, DvripTalkJson('Claim', FSessionID));
      if LerClaim(Motivo) then
      begin
        // A resposta do Start não é esperada aqui: o go2rtc também não espera,
        // e ela chega pelo leitor, que a põe no log.
        MandarJson(DVRIP_OPTALK, DvripTalkJson('Start', FSessionID));
        FViva := True;
        FEnchendo := True;
        FUltimoEnviarMs := TThread.GetTickCount64;
        FRitmo := TLaco.Create(LacoRitmo);
        FLeitor := TLaco.Create(LacoLeitor);
        FRitmo.Start;
        FLeitor.Start;
        FLogger.Info(FTag, Format('fala aberta em %s:%d (SessionID=0x%x)',
                                  [FHost, FPort, FSessionID]));
        Result := True;
      end;
    end;
  except
    on E: Exception do
      Motivo := 'fala: ' + E.Message;
  end;
  if not Result then
  begin
    FLogger.Warn(FTag, Motivo);
    // Sem as threads, ninguém mais usa o socket: fecha aqui mesmo.
    try if FTcp <> nil then FTcp.Disconnect; except end;
    // O Fechar do destrutor não tem o que fazer com uma fala que nem abriu.
    FFechou := 1;
  end;
end;

function TDvripTalk.Enviar(const Pcm: TBytes): Boolean;
var
  ALaw: TBytes;
  N, Sobra: Integer;
begin
  Result := FViva;
  if not Result then Exit;
  ALaw := PcmParaALaw(Pcm);
  N := Length(ALaw);
  if N = 0 then Exit;
  FFilaLock.Enter;
  try
    SetLength(FFila, Length(FFila) + N);
    Move(ALaw[0], FFila[Length(FFila) - N], N);
    Sobra := Length(FFila) - FILA_MAX;
    if Sobra > 0 then
    begin
      FFila := Copy(FFila, Sobra, MaxInt);
      Inc(FDescartados, Sobra);
    end;
    FUltimoEnviarMs := TThread.GetTickCount64;
  finally
    FFilaLock.Leave;
  end;
end;

procedure TDvripTalk.LacoRitmo;
var
  Proximo, Agora, UltimoKeepAlive: UInt64;
  Quadro: TBytes;
  Ocioso: Boolean;
begin
  Proximo := TThread.GetTickCount64;
  UltimoKeepAlive := Proximo;
  try
    while True do
    begin
      // Relógio absoluto: cada quadro tem hora marcada, e a imprecisão do
      // WaitFor (15 ms no Windows) se compensa no seguinte em vez de somar.
      Agora := TThread.GetTickCount64;
      if Proximo > Agora then
      begin
        if FParar.WaitFor(Cardinal(Proximo - Agora)) = wrSignaled then Break;
      end
      else if FParar.WaitFor(0) = wrSignaled then
        Break;
      Inc(Proximo, PERIODO_MS);
      Agora := TThread.GetTickCount64;
      if Agora > Proximo + ATRASO_MAX_MS then
        Proximo := Agora;

      Quadro := nil;
      FFilaLock.Enter;
      try
        if FEnchendo and (Length(FFila) >= PREENCHER) then
          FEnchendo := False;
        if not FEnchendo then
        begin
          if Length(FFila) >= DVRIP_OPTALK_QUADRO then
          begin
            Quadro := Copy(FFila, 0, DVRIP_OPTALK_QUADRO);
            FFila := Copy(FFila, DVRIP_OPTALK_QUADRO, MaxInt);
          end
          else
          begin
            // A fila secou: ou a pessoa parou de falar, ou o POST atrasou. Nos
            // dois casos junta de novo antes de voltar a tocar.
            FEnchendo := True;
            Inc(FFaltas);
          end;
        end;
        // Com sinal: o Enviar pode ter carimbado a hora DEPOIS do Agora lido
        // acima, e em UInt64 essa diferença negativa viraria "ocioso há
        // séculos".
        Ocioso := (Length(FFila) = 0) and
                  (Int64(Agora) - Int64(FUltimoEnviarMs) > OCIOSA_MS);
      finally
        FFilaLock.Leave;
      end;

      if Quadro <> nil then
      begin
        Mandar(DVRIP_OPTALK_DATA, DvripTalkFrame(Quadro));
        Inc(FQuadros);
      end;

      if (Agora - UltimoKeepAlive) div 1000 >= UInt64(FAliveInterval div 2) then
      begin
        MandarJson(DVRIP_KEEPALIVE,
          Format('{ "Name" : "KeepAlive", "SessionID" : "0x%x" }', [FSessionID]));
        UltimoKeepAlive := Agora;
      end;

      if Ocioso then
      begin
        FLogger.Info(FTag, 'fala sem audio ha mais de 3 s; encerrando');
        Break;
      end;
    end;
  except
    on E: Exception do
      if FParar.WaitFor(0) <> wrSignaled then
        FLogger.Warn(FTag, 'fala: ' + E.Message);
  end;

  // O encerramento é todo daqui, e não do Fechar: assim é um só, venha o fim
  // da página, do silêncio ou da conexão.
  FViva := False;
  FParar.SetEvent;
  try
    // "Stop" não foi visto em captura nem em outra implementação -- o go2rtc
    // só desconecta. Mandar custa uma linha e, se a câmera entender, solta o
    // alto-falante na hora em vez de esperar ela notar o socket fechado.
    MandarJson(DVRIP_OPTALK, DvripTalkJson('Stop', FSessionID));
  except
  end;
  try FTcp.Disconnect; except end;
  FLogger.Info(FTag, Format('fala encerrada: %d quadros (%d ms), %d buracos, ' +
    '%d bytes descartados, %d bytes recebidos da camera',
    [FQuadros, FQuadros * PERIODO_MS, FFaltas, FDescartados, FRecebidos]));
end;

procedure TDvripTalk.LacoLeitor;
var
  Hdr: TDvripHeader;
  Payload: TBytes;
  Skipped: Integer;
  RejectInfo, FailReason: string;
begin
  while FParar.WaitFor(0) <> wrSignaled do
  begin
    try
      if DvripRecvResync(FTcp, Hdr, Payload, 500, FSessionID, Skipped,
                         RejectInfo, FailReason) then
      begin
        if DvripClassifyMsg(Hdr.MsgID) = mkMedia then
          Inc(FRecebidos, Length(Payload))
        else if DvripLooksLikeJson(Payload) then
          FLogger.Info(FTag, Format('fala MsgID=%d: %s',
            [Hdr.MsgID, Trim(TEncoding.UTF8.GetString(Payload))]))
        else
          Inc(FRecebidos, Length(Payload));
      end
      else if FailReason <> '' then
        raise EVmsIoError.Create(FailReason);
    except
      // Tempo esgotado sem nada chegar é normal: a câmera pode nem mandar o
      // microfone dela.
      on EVmsTimeoutError do ;
      on E: Exception do
      begin
        if FParar.WaitFor(0) <> wrSignaled then
          FLogger.Warn(FTag, 'fala, leitura: ' + E.Message);
        FViva := False;
        FParar.SetEvent;
        Break;
      end;
    end;
  end;
end;

procedure TDvripTalk.Fechar;
begin
  if TInterlocked.Exchange(FFechou, 1) = 1 then Exit;
  FParar.SetEvent;
  // O ritmo faz o encerramento (Stop + desconectar); o leitor sai quando o
  // socket fecha ou no próximo meio segundo.
  if FRitmo <> nil then FRitmo.WaitFor;
  if FLeitor <> nil then FLeitor.WaitFor;
  FViva := False;
end;

function TDvripTalk.Viva: Boolean;
begin
  Result := FViva;
end;

end.
