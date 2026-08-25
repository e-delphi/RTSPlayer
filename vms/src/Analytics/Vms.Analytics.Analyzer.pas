unit Vms.Analytics.Analyzer;

// Onde quadro vira EVENTO.
//
// Recebe um quadro decodificado com hora, pergunta ao detector de movimento e,
// quando vale a pena, ao de objetos. Nao conhece nenhum dos dois por dentro:
// chegam prontos no construtor, o que e o que permite testa-lo com dubles e o
// que impede que ONNX ou FFmpeg vazem para cima daqui.
//
// ## Por que existe agregacao, e nao um evento por quadro
//
// A analise anda de 2 em 2 segundos. Uma pessoa atravessando o quintal aparece
// em oito quadros seguidos. Oito eventos de 'person' na linha do tempo nao
// descrevem melhor o que houve do que um evento de 16 segundos — descrevem
// pior, porque escondem que foi uma passagem so.
//
// Entao cada rotulo tem, no maximo, um evento ABERTO por vez. Avistamento novo
// do mesmo rotulo estende o evento aberto; passado MergeGapMs sem ver de novo,
// o evento fecha e vai para o disco. Score e caixa guardados sao os do quadro
// de PICO — a caixa da uniao seria o quintal inteiro depois de tres passagens.
//
// ## Por que a rede nao roda em todo quadro com movimento
//
// Movimento custa microssegundos; a rede custa centenas de milissegundos. Numa
// camera de rua com movimento continuo, rodar a rede em todo quadro faria a
// analise andar mais devagar do que a gravacao cresce — e ai ela nunca alcanca
// o presente. ObjectMinIntervalMs e o teto: entre duas passadas da rede o
// movimento continua sendo registrado normalmente.
//
// ## O teto de duracao
//
// Um evento nao pode crescer para sempre. Movimento continuo numa rua manteria
// 'movimento' aberto por horas; ao passar de MaxEventMs ele fecha e um novo
// comeca no mesmo instante, sem perder nada — o que era uma tarja unica vira
// uma sequencia, que e o que de fato aconteceu.
//
// ## O que NAO e evento
//
// Cena que muda inteira (luz, IR, camera movida) e descartada pelo detector de
// movimento e nem chega aqui como movimento — mas os eventos abertos sao
// fechados na hora, porque a cena de antes acabou.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  VMS.Domain.Logging,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

type
  // O que a composicao liga quando nao ha modelo (ou nao ha Windows). Responde
  // "nao tenho" a tudo, sem erro: a analise fica so com movimento e o resto do
  // servidor nao sabe da diferenca. Mesmo papel do TNullThumbSource, e mora
  // aqui pela mesma razao: e o orquestrador que precisa de um substituto.
  TNullObjectDetector = class(TInterfacedObject, IObjectDetector)
  public
    function Detect(const Img: TRgbImage; MinScore: Single;
                    out Hits: TObjectHits): Boolean;
    function Available: Boolean;
    function Describe: string;
  end;

  TFrameAnalyzer = class(TInterfacedObject, IFrameAnalyzer)
  strict private
  type
    // Um evento em construcao. Vira TVmsEvent quando fecha.
    TOpen = record
      Ev: TVmsEvent;
      LastSeenMs: Int64;
    end;
  strict private
    FCamera: string;
    FMotion: IMotionDetector;
    FObjects: IObjectDetector;
    FStore: IEventStore;
    FLogger: ILogger;
    FCfg: TAnalyticsConfig;
    FWanted: TDictionary<string, Boolean>;   // nil = aceita todos os rotulos
    FOpen: TDictionary<string, TOpen>;
    FLastObjectMs: Int64;
    FCount: Integer;                          // eventos fechados nesta rodada
    procedure Note(Ms: Int64; const Name: string; Kind: TEventKind;
                   Score: Single; Count: Integer; const Box: TEventBox);
    procedure CloseStale(Ms: Int64);
    procedure CloseAll(Persist: Boolean);
    function Accepts(const Name: string): Boolean;
  public
    constructor Create(const ACamera: string; const AMotion: IMotionDetector;
                       const AObjects: IObjectDetector; const AStore: IEventStore;
                       const ACfg: TAnalyticsConfig; const ALogger: ILogger);
    destructor Destroy; override;
    { IFrameAnalyzer }
    procedure Feed(Ms: Int64; const Img: TRgbImage);
    procedure Flush;
    procedure Rewind;
    // Quantos eventos ja foram fechados. So para o log de progresso.
    property ClosedCount: Integer read FCount;
  end;

implementation

{ TNullObjectDetector }

function TNullObjectDetector.Detect(const Img: TRgbImage; MinScore: Single;
  out Hits: TObjectHits): Boolean;
begin
  Hits := nil;
  Result := False;
end;

function TNullObjectDetector.Available: Boolean;
begin
  Result := False;
end;

function TNullObjectDetector.Describe: string;
begin
  Result := 'sem deteccao de objetos';
end;

{ TFrameAnalyzer }

constructor TFrameAnalyzer.Create(const ACamera: string;
  const AMotion: IMotionDetector; const AObjects: IObjectDetector;
  const AStore: IEventStore; const ACfg: TAnalyticsConfig; const ALogger: ILogger);
var
  I: Integer;
begin
  inherited Create;
  FCamera := ACamera;
  FMotion := AMotion;
  FObjects := AObjects;
  FStore := AStore;
  FCfg := ACfg;
  FLogger := ALogger;
  FOpen := TDictionary<string, TOpen>.Create;
  // Lista de rotulos vazia na config = todos interessam. Um dicionario vazio
  // significaria o contrario (nenhum), por isso a distincao e nil x criado.
  if Length(ACfg.Classes) > 0 then
  begin
    FWanted := TDictionary<string, Boolean>.Create;
    for I := 0 to High(ACfg.Classes) do
      FWanted.AddOrSetValue(LowerCase(Trim(ACfg.Classes[I])), True);
  end;
end;

destructor TFrameAnalyzer.Destroy;
begin
  // Sem persistir: quem quer gravar o que sobrou chama Flush antes. Gravar no
  // destrutor esconderia um erro de uso e ainda escreveria durante o
  // encerramento do processo.
  FOpen.Free;
  FWanted.Free;
  inherited;
end;

function TFrameAnalyzer.Accepts(const Name: string): Boolean;
begin
  Result := (FWanted = nil) or FWanted.ContainsKey(LowerCase(Name));
end;

// Um avistamento. Abre o evento daquele rotulo, ou estende o que ja estava
// aberto, guardando o pico.
procedure TFrameAnalyzer.Note(Ms: Int64; const Name: string; Kind: TEventKind;
  Score: Single; Count: Integer; const Box: TEventBox);
var
  Aberto: TOpen;
begin
  if FOpen.TryGetValue(Name, Aberto) then
  begin
    // Estourou o teto: fecha o que estava aberto e deixa o caminho de baixo
    // abrir outro comecando agora. Nada se perde — o que era uma tarja unica
    // vira uma sequencia, que e o que de fato aconteceu.
    if (FCfg.MaxEventMs > 0) and
       ((Ms - Aberto.Ev.StartMs) >= FCfg.MaxEventMs) then
    begin
      if FStore <> nil then
        FStore.Append(FCamera, Aberto.Ev);
      Inc(FCount);
      FOpen.Remove(Name);
    end
    else
    begin
      Aberto.Ev.EndMs := Ms;
      Aberto.LastSeenMs := Ms;
      // Pico, nao media nem uniao: e o quadro de pico que descreve melhor o
      // que aconteceu, e e nele que a miniatura do evento vai cair.
      if Score > Aberto.Ev.Score then
      begin
        Aberto.Ev.Score := Score;
        Aberto.Ev.Box := Box;
      end;
      if Count > Aberto.Ev.Count then Aberto.Ev.Count := Count;
      FOpen.AddOrSetValue(Name, Aberto);
      Exit;
    end;
  end;

  Aberto.Ev.StartMs := Ms;
  Aberto.Ev.EndMs := Ms;
  Aberto.Ev.Kind := Kind;
  Aberto.Ev.Name := Name;
  Aberto.Ev.Score := Score;
  Aberto.Ev.Count := Count;
  Aberto.Ev.Box := Box;
  Aberto.LastSeenMs := Ms;
  FOpen.AddOrSetValue(Name, Aberto);
end;

// Fecha o que nao foi visto dentro da janela de fusao.
procedure TFrameAnalyzer.CloseStale(Ms: Int64);
var
  Par: TPair<string, TOpen>;
  Vencidos: TArray<string>;
  Vencido: TOpen;
  I, N: Integer;
begin
  if FOpen.Count = 0 then Exit;
  SetLength(Vencidos, FOpen.Count);
  N := 0;
  for Par in FOpen do
    if (Ms - Par.Value.LastSeenMs) > FCfg.MergeGapMs then
    begin
      Vencidos[N] := Par.Key;
      Inc(N);
    end;
  // A remocao e depois da varredura: mexer no dicionario durante o for-in
  // invalida o enumerador.
  for I := 0 to N - 1 do
  begin
    if not FOpen.TryGetValue(Vencidos[I], Vencido) then Continue;
    if FStore <> nil then
      FStore.Append(FCamera, Vencido.Ev);
    Inc(FCount);
    FOpen.Remove(Vencidos[I]);
  end;
end;

procedure TFrameAnalyzer.CloseAll(Persist: Boolean);
var
  Par: TPair<string, TOpen>;
begin
  if Persist and (FStore <> nil) then
    for Par in FOpen do
    begin
      FStore.Append(FCamera, Par.Value.Ev);
      Inc(FCount);
    end;
  FOpen.Clear;
end;

procedure TFrameAnalyzer.Flush;
begin
  CloseAll(True);
end;

procedure TFrameAnalyzer.Rewind;
begin
  // Descarta sem gravar: o que estava aberto pertence ao trecho que se
  // abandonou, e gravar daria um evento com fim inventado.
  CloseAll(False);
  FLastObjectMs := 0;
  if FMotion <> nil then FMotion.Reset;
end;

procedure TFrameAnalyzer.Feed(Ms: Int64; const Img: TRgbImage);
var
  Mov: TMotionResult;
  Hits: TObjectHits;
  I, J, Quantos: Integer;
  Melhor: Single;
  Caixa: TEventBox;
  Nome: string;
  Vistos: TDictionary<string, Boolean>;
begin
  if (FMotion = nil) or (not Img.IsValid) then Exit;

  Mov := FMotion.Feed(Ms, Img);

  if Mov.SceneChanged then
  begin
    // A cena de antes acabou. O que estava aberto pertence a ela e ja tem fim:
    // e o ultimo quadro em que ainda era aquela cena.
    Flush;
    Exit;
  end;

  CloseStale(Ms);

  if not Mov.Moved then Exit;

  Note(Ms, MOTION_NAME, ekMotion, Mov.Score, 1, Mov.Box);

  // A rede so entra com movimento na tela e respeitando o intervalo minimo.
  if (FObjects = nil) or (not FObjects.Available) then Exit;
  if (FLastObjectMs > 0) and (Abs(Ms - FLastObjectMs) < FCfg.ObjectMinIntervalMs) then Exit;
  FLastObjectMs := Ms;

  if not FObjects.Detect(Img, FCfg.ObjectThreshold, Hits) then Exit;
  if Length(Hits) = 0 then Exit;

  // Um avistamento por ROTULO por quadro, com o melhor score e a contagem.
  // Tres pessoas no quadro sao um evento 'person' com Count 3, e nao tres
  // eventos que a linha do tempo desenharia empilhados no mesmo lugar.
  Vistos := TDictionary<string, Boolean>.Create;
  try
    for I := 0 to High(Hits) do
    begin
      Nome := Hits[I].Name;
      if Nome = '' then Continue;
      if not Accepts(Nome) then Continue;
      if Vistos.ContainsKey(Nome) then Continue;
      Vistos.AddOrSetValue(Nome, True);

      Melhor := Hits[I].Score;
      Caixa := Hits[I].Box;
      Quantos := 1;
      for J := I + 1 to High(Hits) do
        if Hits[J].Name = Nome then
        begin
          Inc(Quantos);
          if Hits[J].Score > Melhor then
          begin
            Melhor := Hits[J].Score;
            Caixa := Hits[J].Box;
          end;
        end;

      Note(Ms, Nome, ekObject, Melhor, Quantos, Caixa);
    end;
  finally
    Vistos.Free;
  end;
end;

end.
