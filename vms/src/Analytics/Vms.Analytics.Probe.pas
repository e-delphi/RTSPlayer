unit Vms.Analytics.Probe;

// O ENSAIO: reprocessa um trecho real de gravacao com os parametros que se
// quiser, e nao grava nada.
//
// Existe porque sintonizar o detector de movimento estava sendo as cegas. O que
// o banco guarda e so o PICO dos eventos que passaram do limiar; dos quadros
// que nao viraram evento nao sobra nada. Olhando so o banco, "nada se moveu" e
// "o limiar comeu" sao indistinguiveis — e ai mexer no numero e esperar horas
// nao converge nunca.
//
// Aqui o score de CADA quadro analisado volta, com os parametros passados na
// hora. Varrer limiares sobre a mesma filmagem passa a custar segundos.
//
// ## O que ele NAO faz
//
// Nao escreve evento, nao mexe no progresso, nao usa o detector do worker. O
// detector nasce e morre dentro da chamada, com os parametros do pedido — dois
// ensaios seguidos com limiares diferentes nao se contaminam.
//
// ## Reuso
//
// As mesmas interfaces do worker: IFrameWalkSource percorre a gravacao no ritmo
// pedido, e IKeyframeSource/IFrameGrabber sao a saida quando nao ha como
// percorrer. O ensaio nao sabe o que e um `.vms` nem o que e H.264 -- igual a
// todo o resto da analise.
//
// ## Dois caminhos, e por que
//
// O percurso decodifica a sequencia inteira e entrega quadro no ritmo pedido --
// e o unico jeito de olhar entre keyframes. O caminho de keyframe decodifica um
// quadro por GOP: e barato, mas a cadencia dele nao e uma escolha, e o GOP da
// camera. Numa camera de GOP 4 s ele responde "de 4 em 4 s" por mais fino que
// seja o passo, e movimento mais curto que isso nao tem quadro em que ser
// visto.
//
// O percurso e o caminho normal. O keyframe fica de reserva, para quando nao ha
// decodificador de sequencia nesta maquina.

interface

uses
  System.SysUtils,
  System.Math,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

type
  TMotionProbe = class(TInterfacedObject, IMotionProbe)
  strict private
    FKeyframes: IKeyframeSource;
    FGrabber: IFrameGrabber;
    FWalk: IFrameWalkSource;
    FLogger: ILogger;
    // Por que o ultimo percurso parou. Ver o cabecalho do IFrameWalk.
    FMotivoFim: string;
    function RodarPercurso(const Camera: string; FromMs, ToMs, StepMs: Int64;
                           const Motion: IMotionDetector;
                           MaxSamples: Integer): TMotionSamples;
    function RodarKeyframes(const Camera: string; FromMs, ToMs, StepMs: Int64;
                            const Motion: IMotionDetector;
                            MaxSamples: Integer): TMotionSamples;
  public
    constructor Create(const AKeyframes: IKeyframeSource;
                       const AGrabber: IFrameGrabber;
                       const AWalk: IFrameWalkSource; const ALogger: ILogger);
    { IMotionProbe }
    function Run(const Camera: string; FromMs, ToMs, StepMs: Int64;
                 Threshold, SceneThreshold, GridScale: Single;
                 CellDelta, MaxSamples: Integer): TMotionSamples;
    function MotivoDoFim: string;
    function Available: Boolean;
  end;

implementation

uses
  Vms.Analytics.Motion;

const
  // O mesmo tamanho que o worker usa. Tem de ser o mesmo: o score depende da
  // resolucao com que o quadro chega a grade, entao ensaiar num tamanho e
  // rodar noutro daria numeros que nao se comparam.
  // Um so: a reducao mantem a proporcao, entao o teto e do LADO maior. Eram
  // dois nomes para o mesmo 640, e depois da escala um deles ficaria sobrando.
  FRAME_MAX_W = 640;
  // Tetos de seguranca. Um ensaio e uma requisicao HTTP esperando: janela larga
  // demais com passo curto demais viraria minutos de decodificacao dentro dela.
  MAX_SAMPLES_HARD = 4000;
  MAX_WINDOW_MS = Int64(6) * 3600 * 1000;
  MIN_STEP_MS = 250;

constructor TMotionProbe.Create(const AKeyframes: IKeyframeSource;
  const AGrabber: IFrameGrabber; const AWalk: IFrameWalkSource;
  const ALogger: ILogger);
begin
  inherited Create;
  FKeyframes := AKeyframes;
  FGrabber := AGrabber;
  FWalk := AWalk;
  FLogger := ALogger;
end;

function TMotionProbe.Available: Boolean;
begin
  Result := (FKeyframes <> nil) and (FGrabber <> nil) and FGrabber.Available;
end;

function TMotionProbe.Run(const Camera: string; FromMs, ToMs, StepMs: Int64;
  Threshold, SceneThreshold, GridScale: Single;
  CellDelta, MaxSamples: Integer): TMotionSamples;
var
  Motion: IMotionDetector;
begin
  Result := nil;
  FMotivoFim := '';
  if not Available then Exit;
  if (Camera = '') or (ToMs <= FromMs) then Exit;

  if StepMs < MIN_STEP_MS then StepMs := MIN_STEP_MS;
  if (ToMs - FromMs) > MAX_WINDOW_MS then ToMs := FromMs + MAX_WINDOW_MS;
  if (MaxSamples <= 0) or (MaxSamples > MAX_SAMPLES_HARD) then
    MaxSamples := MAX_SAMPLES_HARD;

  // Detector novo, com os parametros do pedido. O MaxGapMs segue a mesma regra
  // do worker (quatro passos): e o que decide quando dois quadros deixam de ser
  // comparaveis, e mudar isso aqui faria o ensaio mentir sobre a producao.
  Motion := TFrameDiffMotionDetector.Create(Threshold, SceneThreshold,
             StepMs * 4, GridScale, CellDelta);

  if (FWalk <> nil) and FWalk.Available then
    Result := RodarPercurso(Camera, FromMs, ToMs, StepMs, Motion, MaxSamples);
  // Vazio pode ser "nao ha gravacao aqui", e ai o keyframe tambem nao acha
  // nada; tentar de novo custa uma busca no indice e nada mais.
  if Length(Result) = 0 then
    Result := RodarKeyframes(Camera, FromMs, ToMs, StepMs, Motion, MaxSamples);
end;

// O caminho normal: decodifica a sequencia e olha no ritmo pedido.
function TMotionProbe.MotivoDoFim: string;
begin
  Result := FMotivoFim;
end;

function TMotionProbe.RodarPercurso(const Camera: string;
  FromMs, ToMs, StepMs: Int64; const Motion: IMotionDetector;
  MaxSamples: Integer): TMotionSamples;
var
  Passeio: IFrameWalk;
  Img: TRgbImage;
  Ms: Int64;
  Res: TMotionResult;
  N: Integer;
begin
  Result := nil;
  Passeio := FWalk.Walk(Camera, FromMs, ToMs, StepMs, FRAME_MAX_W, FRAME_MAX_W);
  if Passeio = nil then
  begin
    FMotivoFim := 'sem por onde percorrer';
    Exit;
  end;

  SetLength(Result, MaxSamples);
  N := 0;
  while (N < MaxSamples) and Passeio.Next(Img, Ms) do
  begin
    if not Img.IsValid then Continue;
    Res := Motion.Feed(Ms, Img);
    Result[N].Ms := Ms;
    Result[N].Score := Res.Score;
    Result[N].Moved := Res.Moved;
    Result[N].SceneChanged := Res.SceneChanged;
    Result[N].Box := Res.Box;
    Inc(N);
  end;
  SetLength(Result, N);
  if N >= MaxSamples then
    FMotivoFim := 'teto de amostras'
  else
    FMotivoFim := Passeio.MotivoDoFim;
end;

// A reserva: um quadro por GOP. A cadencia aqui nao e o passo pedido, e o da
// camera -- ver o cabecalho desta unit.
function TMotionProbe.RodarKeyframes(const Camera: string;
  FromMs, ToMs, StepMs: Int64; const Motion: IMotionDetector;
  MaxSamples: Integer): TMotionSamples;
var
  AU, Extra: TBytes;
  Codec: TVideoCodec;
  Img: TRgbImage;
  At, ActualMs, UltimoMs: Int64;
  Res: TMotionResult;
  N: Integer;
begin
  Result := nil;
  if (FKeyframes = nil) or (FGrabber = nil) then Exit;
  SetLength(Result, MaxSamples);
  N := 0;
  UltimoMs := 0;
  At := FromMs;
  while (At <= ToMs) and (N < MaxSamples) do
  begin
    if not FKeyframes.Grab(Camera, At, AU, Extra, Codec, ActualMs) then Break;
    if Length(AU) = 0 then
    begin
      At := At + StepMs;
      Continue;
    end;
    // O keyframe em vigor num instante e o anterior mais proximo: pedir de
    // 2 em 2 s pode devolver o mesmo quadro duas vezes, e analisa-lo de novo
    // daria movimento zero (quadro igual a si mesmo).
    if (UltimoMs > 0) and (ActualMs <= UltimoMs) then
    begin
      At := Max(At + StepMs, UltimoMs + 1);
      Continue;
    end;
    if ActualMs > ToMs then Break;

    if FGrabber.Decode(AU, Extra, Codec, FRAME_MAX_W, FRAME_MAX_W, Img) and
       Img.IsValid then
    begin
      Res := Motion.Feed(ActualMs, Img);
      Result[N].Ms := ActualMs;
      Result[N].Score := Res.Score;
      Result[N].Moved := Res.Moved;
      Result[N].SceneChanged := Res.SceneChanged;
      Result[N].Box := Res.Box;
      Inc(N);
    end;

    UltimoMs := ActualMs;
    At := Max(At + StepMs, ActualMs + 1);
  end;
  SetLength(Result, N);
end;

end.
