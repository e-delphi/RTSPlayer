unit Vms.Analytics.Onnx;

// O detector de objetos, por cima do onnx-pascal.
//
// E a UNICA unit do VMS que fala com o vendor. Tudo acima dela conhece
// IObjectDetector, TObjectHit e TEventBox — vocabulario do VMS — e nada de
// tensor, sessao ou letterbox. Trocar YOLO por outra coisa, ou por um servico
// remoto, e escrever outra classe deste tamanho.
//
// Duas fronteiras que esta unit atravessa, e por isso existe:
//
//   * TRgbImage (registro, TBytes, do subsistema de miniaturas) vira IImage
//     (interface, do vendor). Sao o mesmo RGB24 sem alinhamento de linha, entao
//     a conversao e uma copia — mas a copia acontece AQUI e nao vaza para
//     nenhum dos dois lados.
//   * A caixa em pixels da imagem vira caixa normalizada 0..1. O app desenha a
//     caixa sobre um video que pode estar em qualquer resolucao; guardar pixels
//     de 1080p num evento tornaria o evento invalido no dia em que a camera
//     mudar de perfil.
//
// Ausencia nao e erro: sem a DLL do onnxruntime, ou sem o `.onnx`, o construtor
// nao levanta — marca-se indisponivel e a composicao segue com movimento so.
// Uma dependencia que falta nao pode virar excecao dentro da analise.
//
// Threading: uma instancia so, compartilhada pelos workers de todas as cameras
// (o modelo ocupa memoria demais para ter um por camera), com a inferencia
// serializada por um lock proprio.

interface

{$IFDEF MSWINDOWS}

uses
  System.SysUtils,
  System.SyncObjs,
  System.Math,
  VMS.Domain.Logging,
  ONNX.Types,
  ONNX.Runtime,
  Vision.Types,
  Vision.Image,
  Vision.Model,
  Vision.Predictor,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

type
  TOnnxObjectDetector = class(TInterfacedObject, IObjectDetector)
  strict private
    FRuntime: IONNXRuntime;
    FPredictor: IVisionPredictor;
    FLogger: ILogger;
    FLock: TCriticalSection;
    FAvail: Boolean;
    FDescription: string;
    procedure Load(const ModelPath, DllPath: string; IoU: Single;
                   MaxDetections, Threads: Integer);
  public
    // Nunca levanta. Falhou em carregar = Available False, e o motivo vai para
    // o log uma vez, na subida.
    constructor Create(const ModelPath, DllPath: string; IoU: Single;
                       MaxDetections, Threads: Integer; const ALogger: ILogger);
    destructor Destroy; override;
    { IObjectDetector }
    function Detect(const Img: Vms.Thumb.Intf.TRgbImage; MinScore: Single;
                    out Hits: TObjectHits): Boolean;
    function Available: Boolean;
    function Describe: string;
  end;

{$ENDIF}

implementation

{$IFDEF MSWINDOWS}

{ TOnnxObjectDetector }

constructor TOnnxObjectDetector.Create(const ModelPath, DllPath: string;
  IoU: Single; MaxDetections, Threads: Integer; const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FAvail := False;
  FDescription := 'sem deteccao de objetos';
  try
    Load(ModelPath, DllPath, IoU, MaxDetections, Threads);
  except
    on E: Exception do
    begin
      FRuntime := nil;
      FPredictor := nil;
      FAvail := False;
      FDescription := 'falhou: ' + E.Message;
      if FLogger <> nil then
        FLogger.Warn('analytics', Format('modelo nao carregou (%s): %s. ' +
          'A analise segue so com movimento.', [ModelPath, E.Message]));
    end;
  end;
end;

destructor TOnnxObjectDetector.Destroy;
begin
  FPredictor := nil;
  FRuntime := nil;
  FLock.Free;
  inherited;
end;

procedure TOnnxObjectDetector.Load(const ModelPath, DllPath: string; IoU: Single;
  MaxDetections, Threads: Integer);
var
  Opts: TPredictorOptions;
  SessCfg: TSessionConfig;
  Spec: TModelSpec;
begin
  if Trim(ModelPath) = '' then Exit;
  if not FileExists(ModelPath) then
    raise Exception.CreateFmt('modelo nao encontrado: %s', [ModelPath]);

  FRuntime := TONNXRuntime.Create(DllPath);

  Opts := TPredictorOptions.Default;
  // A confianca fica em 0.01 aqui de proposito: o corte de verdade e o
  // MinScore que o Detect recebe a cada chamada, porque quem sabe o limiar e a
  // configuracao da analise, nao o modelo. Cortar cedo demais no decoder
  // impediria baixar o limiar sem recarregar o modelo.
  Opts.ConfidenceThreshold := 0.01;
  Opts.ConfidenceWasSet := True;
  if IoU > 0 then Opts.IoUThreshold := IoU;
  if MaxDetections > 0 then Opts.MaxDetections := MaxDetections;
  Opts.TaskOverride := vtDetect;

  SessCfg := TSessionConfig.Default;
  // Deixar o ORT abrir uma thread por nucleo faz a analise competir com a
  // GRAVACAO, que e o trabalho que nao pode atrasar. O padrao aqui e metade
  // dos nucleos, com o minimo de 1.
  SessCfg.IntraOpThreads := Threads;

  FPredictor := TVisionPredictorFactory.Build(FRuntime, ModelPath, Opts, SessCfg);
  Spec := FPredictor.Spec;
  FAvail := True;
  FDescription := Format('%s (%s, %dx%d, %d classes)',
    [ExtractFileName(ModelPath), VisionTaskToString(Spec.Task),
     Spec.InputWidth, Spec.InputHeight, Length(Spec.ClassNames)]);
  if FLogger <> nil then
  begin
    FLogger.Info('analytics', 'onnxruntime ' + FRuntime.Version);
    FLogger.Info('analytics', 'modelo: ' + FDescription);
  end;
end;

function TOnnxObjectDetector.Available: Boolean;
begin
  Result := FAvail and (FPredictor <> nil);
end;

function TOnnxObjectDetector.Describe: string;
begin
  Result := FDescription;
end;

// A copia de TRgbImage para IImage. Os dois sao RGB24 com stride = largura * 3,
// entao e Move e nada mais; se um dia um dos lados ganhar alinhamento de linha,
// e aqui que a conversao passa a existir de verdade.
// Os dois lados batizaram o buffer de TRGBImage — o vendor, uma classe; o
// subsistema de miniaturas, um registro — e Pascal nao distingue maiuscula de
// minuscula. Sem qualificar pela unit, `Dst` viraria o registro e a copia
// escreveria em cima de nada. Nao renomeio o do vendor de proposito: ver o
// README de vendor/onnx-pascal.
function ToVisionImage(const Img: Vms.Thumb.Intf.TRgbImage): IImage;
var
  Dst: Vision.Image.TRGBImage;
  Bytes: Integer;
begin
  Dst := Vision.Image.CreateImage(Img.Width, Img.Height);
  // A interface primeiro: dai em diante a contagem de referencia e dona do
  // objeto, e uma excecao no Move nao vaza um TRGBImage.
  Result := Dst;
  Bytes := Img.Width * Img.Height * 3;
  Move(Img.Pixels[0], Dst.Data^, Bytes);
end;

function TOnnxObjectDetector.Detect(const Img: Vms.Thumb.Intf.TRgbImage; MinScore: Single;
  out Hits: TObjectHits): Boolean;
var
  Pred: TVisionResult;
  Vis: IImage;
  I, Usados: Integer;
  W, H: Single;
  Cx: TBoxF;
begin
  Hits := nil;
  Result := False;
  if not Available then Exit;
  if not Img.IsValid then Exit;
  if (Img.Width < 16) or (Img.Height < 16) then Exit;

  FLock.Enter;
  try
    try
      Vis := ToVisionImage(Img);
      Pred := FPredictor.Predict(Vis);
    except
      on E: Exception do
      begin
        // Uma inferencia que explode nao pode parar a analise da gravacao: o
        // quadro seguinte tem chance de passar, e movimento continua valendo.
        if FLogger <> nil then
          FLogger.Warn('analytics', 'inferencia falhou: ' + E.Message);
        Exit(False);
      end;
    end;
  finally
    FLock.Leave;
  end;

  W := Img.Width;
  H := Img.Height;
  if (W <= 0) or (H <= 0) then Exit;

  SetLength(Hits, Length(Pred.Detections));
  Usados := 0;
  for I := 0 to High(Pred.Detections) do
  begin
    if Pred.Detections[I].Score < MinScore then Continue;
    Cx := Pred.Detections[I].Box.Normalized;
    Hits[Usados].Name := LowerCase(Pred.Detections[I].DisplayName);
    Hits[Usados].Score := Pred.Detections[I].Score;
    Hits[Usados].Box := TEventBox.FromLTRB(Cx.Left / W, Cx.Top / H,
                                           Cx.Right / W, Cx.Bottom / H).Clamped;
    Inc(Usados);
  end;
  SetLength(Hits, Usados);
  Result := True;
end;

{$ENDIF}

end.
