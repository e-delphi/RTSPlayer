unit Vms.Analytics.Intf;

// As fronteiras da analise de imagem.
//
// Detectar um evento numa gravacao e uma cadeia de coisas que nao tem nada a ver
// umas com as outras: achar o quadro (sabe de `.vms`), decodifica-lo (sabe de
// FFmpeg), ver se mexeu (aritmetica), ver o que e (uma rede neural) e guardar o
// que se concluiu (bytes em disco). As duas primeiras JA existem, atras de
// IKeyframeSource e IFrameGrabber, e sao reusadas inteiras — foi por elas
// existirem que este subsistema coube em sete units.
//
// O que estas fronteiras compram, em ordem de importancia:
//
//   1. A rota /api/events depende de IEventSource e mais nada. Sem isso,
//      `Vms.Server.Api` passaria a arrastar onnxruntime atras de si.
//   2. Sem o modelo (ou sem a DLL) no disco, a composicao liga um detector de
//      objetos nulo e o servidor sobe igual, gerando so eventos de movimento.
//      A ausencia de um recurso nao pode virar excecao no meio da analise.
//   3. Trocar YOLO por outra coisa — ou por um servico remoto — e escrever
//      outra classe. O analisador nao sabe o que ha do outro lado.
//   4. O analisador e testavel sem modelo, sem FFmpeg e sem disco: sao dubles
//      implementando interfaces de um metodo.

interface

uses
  System.SysUtils,
  Vms.Thumb.Intf,          // TRgbImage: o quadro decodificado ja tem dono
  Vms.Analytics.Types;

type
  // O que o detector de movimento conclui de um quadro.
  TMotionResult = record
    Moved: Boolean;        // passou do limiar?
    Score: Single;         // fracao do quadro que mudou, 0..1
    SceneChanged: Boolean; // mudou tudo: luz, IR, camera movida. Nao e evento.
    Box: TEventBox;        // a regiao que mudou, normalizada
  end;

  // Um objeto que a rede reconheceu.
  TObjectHit = record
    Name: string;          // minusculas, como vem do modelo
    Score: Single;
    Box: TEventBox;
  end;
  TObjectHits = TArray<TObjectHit>;

  // Mexeu?
  //
  // Tem estado (compara com o que veio antes), entao e UM POR CAMERA e nao pode
  // ser compartilhado entre threads. Quem cria e a composicao, um por worker.
  IMotionDetector = interface
    ['{A7F3C1D8-2B64-4E90-8C57-1D0A9E3B5F26}']
    // Ms serve para o detector perceber salto no tempo: dois quadros separados
    // por meia hora nao sao comparaveis, e comparar mesmo assim acusaria
    // movimento em todo comeco de trecho gravado.
    function Feed(Ms: Int64; const Img: TRgbImage): TMotionResult;
    // Esquece a referencia. Chamado ao pular para outro ponto da gravacao.
    procedure Reset;
  end;

  // O que e?
  IObjectDetector = interface
    ['{5E8B0A31-7C42-4D6F-93A1-6B2C8F0D4E17}']
    // False = nao deu (modelo ausente, quadro invalido, erro na inferencia).
    // Nunca excecao: uma falha aqui nao pode parar a analise da gravacao.
    function Detect(const Img: TRgbImage; MinScore: Single;
                    out Hits: TObjectHits): Boolean;
    function Available: Boolean;
    // Para o log da subida dizer o que foi carregado.
    function Describe: string;
  end;

  // Onde os eventos ficam.
  IEventStore = interface
    ['{3C9D4E70-18A5-4B2E-A6F3-0E7B5C1D9A48}']
    // Append-only. O evento ja vem fechado (com inicio e fim).
    procedure Append(const Camera: string; const Ev: TVmsEvent);
  end;

  // O que a API enxerga. Uma pergunta so: o que aconteceu neste intervalo.
  IEventSource = interface
    ['{8D2A6F51-4E93-4C08-B7D5-2A1F6E0C3B94}']
    // Devolve em ordem crescente de StartMs. Um evento que COMECA antes de
    // FromMs mas termina depois entra: quem pede uma janela quer o que estava
    // acontecendo nela, nao so o que comecou dentro dela.
    // NameFilter vazio = todos. Kind negativo = os dois tipos.
    function Query(const Camera: string; FromMs, ToMs: Int64;
                   const NameFilter: string; KindFilter: Integer;
                   MinScore: Single; Limit: Integer): TVmsEventArray;
    function Available: Boolean;
  end;

  // Ate onde a analise ja chegou em cada camera.
  //
  // Fronteira propria, e nao um metodo do IEventStore, porque sao perguntas
  // diferentes: o store guarda o QUE aconteceu, isto guarda ATE ONDE se olhou.
  // Separadas, o worker deixa de depender da classe concreta do store — que era
  // a unica coisa impedindo trocar arquivo por banco sem tocar nele.
  IAnalysisProgress = interface
    ['{4E1A7B93-6C25-4F08-BD37-9A5C0E2F81D4}']
    // 0 = nunca rodou. Model e o modelo configurado AGORA: se o progresso
    // gravado veio de outro, ele nao vale e a resposta e 0 — trocar o .onnx
    // sem reanalisar deixava horas vistas pelo modelo velho passando por
    // analisadas, e ninguem percebia.
    function ReadProgress(const Camera, Model: string): Int64;
    procedure WriteProgress(const Camera: string; AnalyzedToMs, Frames,
                            Failures: Int64; const Model: string);
  end;

  // Uma amostra do ENSAIO: o que o detector concluiu de UM quadro, com os
  // parametros que o pedido mandou. Ver Vms.Analytics.Probe.
  TMotionSample = record
    Ms: Int64;
    Score: Single;          // fracao da grade que mudou
    Moved: Boolean;         // passou do limiar
    SceneChanged: Boolean;  // tratado como cena nova (nao vira evento)
    Box: TEventBox;
  end;
  TMotionSamples = TArray<TMotionSample>;

  // Reprocessa um trecho de gravacao SEM GRAVAR NADA, com parametros dados na
  // hora. Existe porque o banco so guarda o pico dos eventos que passaram do
  // limiar: dos quadros que nao viraram evento nao sobra nada, e ai nao da para
  // distinguir "nada se moveu" de "o limiar comeu".
  IMotionProbe = interface
    ['{6D0F3A21-8B54-4C97-A1E6-2F7B9C4D0538}']
    function Run(const Camera: string; FromMs, ToMs, StepMs: Int64;
                 Threshold, SceneThreshold: Single;
                 MaxSamples: Integer): TMotionSamples;
    function Available: Boolean;
  end;

  // Um quadro decodificado, com hora. O que o worker entrega ao analisador.
  IFrameAnalyzer = interface
    ['{0B4E7C29-6A13-4F85-9D2C-7E3A1B5F8C60}']
    procedure Feed(Ms: Int64; const Img: TRgbImage);
    // Fecha o que estiver aberto. Chamado ao pular no tempo e ao encerrar: sem
    // isto, o ultimo evento de cada rodada nunca chegaria ao disco.
    procedure Flush;
    // Descarta o que estiver aberto sem gravar, e esquece a referencia de
    // movimento. E o que se faz ao saltar para outro ponto da gravacao.
    procedure Rewind;
  end;

implementation

end.
