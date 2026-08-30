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
// As mesmas duas interfaces do worker: IKeyframeSource acha o quadro comprimido
// do instante e IFrameGrabber o decodifica. O ensaio nao sabe o que e um `.vms`
// nem o que e H.264 — igual a todo o resto da analise.

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
    FLogger: ILogger;
  public
    constructor Create(const AKeyframes: IKeyframeSource;
                       const AGrabber: IFrameGrabber; const ALogger: ILogger);
    { IMotionProbe }
    function Run(const Camera: string; FromMs, ToMs, StepMs: Int64;
                 Threshold, SceneThreshold: Single;
                 MaxSamples: Integer): TMotionSamples;
    function Available: Boolean;
  end;

implementation

uses
  Vms.Analytics.Motion;

const
  // O mesmo tamanho que o worker usa. Tem de ser o mesmo: o score depende da
  // resolucao com que o quadro chega a grade, entao ensaiar num tamanho e
  // rodar noutro daria numeros que nao se comparam.
  FRAME_MAX_W = 640;
  FRAME_MAX_H = 640;
  // Tetos de seguranca. Um ensaio e uma requisicao HTTP esperando: janela larga
  // demais com passo curto demais viraria minutos de decodificacao dentro dela.
  MAX_SAMPLES_HARD = 4000;
  MAX_WINDOW_MS = Int64(6) * 3600 * 1000;
  MIN_STEP_MS = 250;

constructor TMotionProbe.Create(const AKeyframes: IKeyframeSource;
  const AGrabber: IFrameGrabber; const ALogger: ILogger);
begin
  inherited Create;
  FKeyframes := AKeyframes;
  FGrabber := AGrabber;
  FLogger := ALogger;
end;

function TMotionProbe.Available: Boolean;
begin
  Result := (FKeyframes <> nil) and (FGrabber <> nil) and FGrabber.Available;
end;

function TMotionProbe.Run(const Camera: string; FromMs, ToMs, StepMs: Int64;
  Threshold, SceneThreshold: Single; MaxSamples: Integer): TMotionSamples;
var
  Motion: IMotionDetector;
  AU, Extra: TBytes;
  Codec: TVideoCodec;
  Img: TRgbImage;
  At, ActualMs, UltimoMs: Int64;
  Res: TMotionResult;
  N: Integer;
begin
  Result := nil;
  if not Available then Exit;
  if (Camera = '') or (ToMs <= FromMs) then Exit;

  if StepMs < MIN_STEP_MS then StepMs := MIN_STEP_MS;
  if (ToMs - FromMs) > MAX_WINDOW_MS then ToMs := FromMs + MAX_WINDOW_MS;
  if (MaxSamples <= 0) or (MaxSamples > MAX_SAMPLES_HARD) then
    MaxSamples := MAX_SAMPLES_HARD;

  // Detector novo, com os parametros do pedido. O MaxGapMs segue a mesma regra
  // do worker (quatro passos): e o que decide quando dois quadros deixam de ser
  // comparaveis, e mudar isso aqui faria o ensaio mentir sobre a producao.
  Motion := TFrameDiffMotionDetector.Create(Threshold, SceneThreshold, StepMs * 4);

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

    if FGrabber.Decode(AU, Extra, Codec, FRAME_MAX_W, FRAME_MAX_H, Img) and
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
