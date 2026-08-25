unit Vms.Analytics.Worker;

// A thread que percorre a gravacao de uma camera e alimenta o analisador.
//
// A analise anda pela GRAVACAO, nao pelo relogio. Ela vai do ponto onde parou
// da ultima vez ate um pouco atras do agora, no passo configurado, e so entao
// dorme esperando o arquivo crescer. Duas coisas caem de graca disso:
//
//   * Servidor que ficou desligado a noite toda recupera a noite toda quando
//     sobe, no ritmo que a CPU permitir. Nao ha janela perdida.
//   * Analisar nao interfere na gravacao nem na publicacao ao vivo: sao
//     caminhos separados que so se cruzam no arquivo, e este aqui so le.
//
// ## Como o quadro chega aqui
//
// Reusando as duas interfaces que as miniaturas ja tinham: IKeyframeSource acha
// o quadro comprimido do instante (busca binaria no indice + leitura de UM
// bloco, sem varredura) e IFrameGrabber o decodifica. Foi por elas ja existirem
// que este subsistema nao precisou saber o que e um `.vms` nem o que e H.264.
//
// ## A distancia do presente
//
// O arquivo mais recente esta sendo escrito neste instante, e o indice dele vai
// atras. LagMs mantem a analise um pouco para tras do agora; sem isso, ela
// passaria o tempo todo pedindo um quadro que ainda nao terminou de existir.
//
// ## Progresso
//
// Gravado a cada rajada, nao a cada quadro: o custo e uma escrita de arquivo, e
// perder trinta segundos de progresso numa queda so custa reanalisa-los. E
// gravado TAMBEM ao dormir, que e o caso comum de encerramento limpo.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.DateUtils,
  System.Math,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  Vms.Server.IndexCache,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

type
  TAnalyticsWorker = class(TThread)
  strict private
    FCamera: string;
    FKeyframes: IKeyframeSource;
    FGrabber: IFrameGrabber;
    FAnalyzer: IFrameAnalyzer;
    // Interface, e nao a classe: e o que permitiu trocar arquivo por banco sem
    // tocar em nada aqui dentro.
    FProgress: IAnalysisProgress;
    // Nome do modelo em vigor (so o arquivo, sem o caminho — mudar a pasta nao
    // pode invalidar o progresso). Vai junto do progresso para que trocar de
    // modelo faca a analise recomecar sozinha.
    FModel: string;
    FCache: TVmsIndexCache;
    FClock: IClock;
    FLogger: ILogger;
    FCfg: TAnalyticsConfig;
    FStop: TEvent;
    FAtMs: Int64;          // proximo instante a pedir
    FLastFrameMs: Int64;   // instante do ultimo quadro que de fato foi analisado
    FFrames: Int64;
    FFalhas: Int64;        // quadros que nao decodificaram
    FFalhasLote: Integer;
    FSalvoEmMs: Int64;     // progresso ja gravado
    function StartPoint: Int64;
    function FirstRecordedMs: Int64;
    function TargetMs: Int64;
    // Um quadro. False = nao havia gravacao dali para frente.
    function Step(out Avancou: Boolean): Boolean;
    procedure SaveProgress;
    procedure Log(const Msg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const ACamera: string; const AKeyframes: IKeyframeSource;
                       const AGrabber: IFrameGrabber; const AAnalyzer: IFrameAnalyzer;
                       const AProgress: IAnalysisProgress; ACache: TVmsIndexCache;
                       const ACfg: TAnalyticsConfig; const AClock: IClock;
                       const ALogger: ILogger; AStop: TEvent);
  end;

implementation

const
  // Tamanho maximo do quadro entregue aos detectores. 640 e o lado que os
  // modelos YOLO usam na entrada; mandar 1080p faria o preprocessador reduzir
  // de qualquer jeito, depois de o decodificador ter pago por cada pixel.
  FRAME_MAX_W = 640;
  FRAME_MAX_H = 640;
  // Quanto dorme quando a analise alcancou o presente.
  IDLE_MS = 5000;
  // De quantos em quantos quadros o progresso vai para o disco.
  PROGRESS_EVERY = 30;
  // Salto no tempo a partir do qual o detector de movimento perde a referencia:
  // buraco de gravacao, troca de arquivo depois de reconexao. Comparar os dois
  // lados de um buraco acusaria movimento em toda retomada.
  JUMP_MS = 15000;

// A hora local de um instante, so para o log dizer algo que alguem consiga ler.
// Nao vem do Vms.Server.Api de proposito: o worker nao deve depender da camada
// HTTP so para formatar uma data.
function HoraLocal(Ms: Int64): TDateTime;
begin
  Result := TTimeZone.Local.ToLocalTime(UnixToDateTime(Ms div 1000, True));
end;

constructor TAnalyticsWorker.Create(const ACamera: string;
  const AKeyframes: IKeyframeSource; const AGrabber: IFrameGrabber;
  const AAnalyzer: IFrameAnalyzer; const AProgress: IAnalysisProgress;
  ACache: TVmsIndexCache; const ACfg: TAnalyticsConfig; const AClock: IClock;
  const ALogger: ILogger; AStop: TEvent);
begin
  // Campos primeiro, `inherited Create(False)` por ultimo, e SEM chamar Start:
  // quem inicia e o TThread.AfterConstruction (ver TApiThumbProvider.TFetcher,
  // mesma armadilha, mesmo motivo).
  FCamera := ACamera;
  FKeyframes := AKeyframes;
  FGrabber := AGrabber;
  FAnalyzer := AAnalyzer;
  FProgress := AProgress;
  FCache := ACache;
  FCfg := ACfg;
  FModel := ExtractFileName(ACfg.ModelPath);
  FClock := AClock;
  FLogger := ALogger;
  FStop := AStop;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TAnalyticsWorker.Log(const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Info('analytics.' + FCamera, Msg);
end;

// O comeco da gravacao mais antiga que a camera tem. Vem do cache, que ja sabe
// disso sem montar indice nenhum.
function TAnalyticsWorker.FirstRecordedMs: Int64;
var
  Files: TVmsFileInfoArray;
  I: Integer;
begin
  Result := 0;
  Files := FCache.ListFiles(FCamera);
  for I := 0 to High(Files) do
    if (Files[I].StartMs > 0) and ((Result = 0) or (Files[I].StartMs < Result)) then
      Result := Files[I].StartMs;
end;

function TAnalyticsWorker.StartPoint: Int64;
var
  Salvo, Primeiro, Limite: Int64;
begin
  Salvo := FProgress.ReadProgress(FCamera, FModel);
  Primeiro := FirstRecordedMs;
  if Primeiro = 0 then
    Primeiro := FClock.NowUtcMs;

  // Ja rodou antes: continua de onde parou, mas nunca antes da gravacao mais
  // antiga que ainda existe — a retencao pode ter apagado o que havia entre um
  // e outro, e insistir naquele intervalo seria varrer o vazio para sempre.
  if Salvo > 0 then
    Exit(Max(Salvo, Primeiro));

  if FCfg.BackfillMs <= 0 then
    Exit(Primeiro);   // 0 = analisa tudo o que houver

  Limite := FClock.NowUtcMs - FCfg.BackfillMs;
  Result := Max(Primeiro, Limite);
end;

function TAnalyticsWorker.TargetMs: Int64;
begin
  Result := FClock.NowUtcMs - FCfg.LagMs;
end;

procedure TAnalyticsWorker.SaveProgress;
begin
  if FAtMs <= FSalvoEmMs then Exit;
  FProgress.WriteProgress(FCamera, FAtMs, FFrames, FFalhas, FModel);
  FSalvoEmMs := FAtMs;
end;

function TAnalyticsWorker.Step(out Avancou: Boolean): Boolean;
var
  AU, Extra: TBytes;
  Codec: TVideoCodec;
  ActualMs: Int64;
  Img: TRgbImage;
begin
  Avancou := False;
  Result := FKeyframes.Grab(FCamera, FAtMs, AU, Extra, Codec, ActualMs);
  if not Result then Exit;
  if Length(AU) = 0 then
  begin
    // Bloco sem keyframe utilizavel: nao ha o que analisar, mas ha o que
    // avancar — senao o laco fica pedindo o mesmo instante para sempre.
    FAtMs := FAtMs + FCfg.StepMs;
    Avancou := True;
    Exit(True);
  end;

  // O keyframe em vigor num instante e o ANTERIOR mais proximo, entao pedir
  // 12:00:03 pode devolver o quadro de 12:00:00 — o mesmo que ja foi analisado
  // no passo anterior. Analisa-lo de novo daria movimento zero (quadro igual a
  // si mesmo) e ainda gastaria uma decodificacao.
  if (FLastFrameMs > 0) and (ActualMs <= FLastFrameMs) then
  begin
    FAtMs := Max(FAtMs + FCfg.StepMs, FLastFrameMs + 1);
    Avancou := True;
    Exit(True);
  end;

  // Saltou: buraco de gravacao, ou o proprio Grab pulou para o arquivo
  // seguinte. A referencia de movimento nao vale mais do outro lado do buraco.
  if (FLastFrameMs > 0) and ((ActualMs - FLastFrameMs) > JUMP_MS) then
  begin
    FAnalyzer.Flush;    // o que estava aberto termina no ultimo quadro visto
    FAnalyzer.Rewind;
  end;

  if FGrabber.Decode(AU, Extra, Codec, FRAME_MAX_W, FRAME_MAX_H, Img) and
     Img.IsValid then
  begin
    FAnalyzer.Feed(ActualMs, Img);
    Inc(FFrames);
  end
  else
  begin
    // Nao e excecao: keyframe truncado por perda de pacote no UDP, ou
    // parameter set do header que nao descreve o que a camera transmitiu. O
    // passo segue; o que nao pode e o quadro entrar na analise como se
    // estivesse bom. Contado, e nao logado um a um: sao milhares por vez.
    Inc(FFalhas);
    Inc(FFalhasLote);
  end;

  FLastFrameMs := ActualMs;
  FAtMs := Max(FAtMs + FCfg.StepMs, ActualMs + 1);
  Avancou := True;
end;

procedure TAnalyticsWorker.Execute;
var
  Avancou, Achou: Boolean;
  NoLote: Integer;
  Alvo: Int64;
begin
  NameThreadForDebugging('analytics.' + FCamera);
  try
    FAtMs := StartPoint;
    FSalvoEmMs := FAtMs;
    Log(Format('comecando em %s (%s)',
      [FormatDateTime('dd/mm hh:nn:ss', HoraLocal(FAtMs)), FCfg.Describe]));

    while (not Terminated) and (FStop.WaitFor(0) <> wrSignaled) do
    begin
      Alvo := TargetMs;
      NoLote := 0;

      Achou := False;
      while (not Terminated) and (FStop.WaitFor(0) <> wrSignaled) and (FAtMs <= Alvo) do
      begin
        try
          Achou := Step(Avancou);
        except
          on E: Exception do
          begin
            // Um arquivo corrompido nao pode parar a analise da camera inteira:
            // registra, pula o passo e segue.
            if FLogger <> nil then
              FLogger.Warn('analytics.' + FCamera,
                Format('falhou em %d: %s', [FAtMs, E.Message]));
            FAtMs := FAtMs + FCfg.StepMs;
            Achou := True;
            Avancou := True;
          end;
        end;

        if not Achou then
        begin
          // Nao ha gravacao daqui para frente (ainda). Fecha o que estiver
          // aberto e vai dormir: insistir nao faria a gravacao aparecer.
          FAnalyzer.Flush;
          FAtMs := Max(FAtMs, Alvo);
          Break;
        end;
        if not Avancou then Break;   // nao deve acontecer; nao trava o laco

        Inc(NoLote);
        if (NoLote mod PROGRESS_EVERY) = 0 then
          SaveProgress;
      end;

      // Alcancou o presente: fecha o que estava aberto para os eventos
      // aparecerem na linha do tempo agora, e nao daqui a meia hora quando algo
      // finalmente fechar por conta.
      FAnalyzer.Flush;
      SaveProgress;
      if NoLote > 0 then
        if FFalhasLote > 0 then
          Log(Format('%d quadros analisados (%d nao decodificaram); ate %s',
            [NoLote, FFalhasLote,
             FormatDateTime('dd/mm hh:nn:ss', HoraLocal(FAtMs))]))
        else
          Log(Format('%d quadros analisados; ate %s', [NoLote,
            FormatDateTime('dd/mm hh:nn:ss', HoraLocal(FAtMs))]));
      FFalhasLote := 0;

      if FStop.WaitFor(IDLE_MS) = wrSignaled then Break;
    end;

    FAnalyzer.Flush;
    SaveProgress;
    Log(Format('parou; %d quadros analisados nesta subida, %d descartados ' +
      'por nao decodificarem', [FFrames, FFalhas]));
  except
    on E: Exception do
      if FLogger <> nil then
        FLogger.Error('analytics.' + FCamera, 'thread morreu: ' + E.Message);
  end;
end;

end.
