unit Vms.Analytics.Motion;

// Mexeu? — decidido em aritmetica de inteiros sobre uma grade de 64x36 celulas.
//
// Nao depende de nada: nem de ONNX, nem de FFmpeg, nem de Windows. E de
// proposito, porque este e o detector que sempre roda. A rede neural e opcional
// e cara; movimento e obrigatorio e tem de custar quase nada, senao analisar
// varias cameras ao mesmo tempo deixa de ser possivel.
//
// Tres decisoes que valem estar escritas, porque as tres vieram de como camera
// de vigilancia se comporta de verdade:
//
// 1. A referencia e um FUNDO que se adapta devagar, nao o quadro anterior.
//    Comparar com o quadro anterior parece obvio e e ruim: a analise anda de
//    2 em 2 segundos, e nesse intervalo a luz do dia muda o suficiente para o
//    quadro inteiro "mexer". Uma media exponencial lenta acompanha a luz e
//    ignora o que e permanente, deixando so o que e transitorio — que e a
//    definicao operacional de movimento aqui.
//
// 2. Quadro que muda INTEIRO nao e movimento, e cena nova. Luz que acende, o
//    filtro IR que comuta a noite, alguem que reposiciona a camera: todos fazem
//    quase 100% das celulas passarem do limiar. Marcar isso como movimento
//    encheria a linha do tempo de eventos gigantes justamente nos momentos em
//    que a imagem esta menos util. Passando de SceneChangeThreshold, o fundo e
//    refeito na hora e nenhum evento sai.
//
// 3. Salto no tempo zera a referencia. O worker pula buracos de gravacao e
//    troca de arquivo; comparar o primeiro quadro depois do buraco com o fundo
//    de antes dele acusaria movimento em toda retomada de gravacao.

interface

uses
  System.SysUtils,
  System.Math,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

type
  TFrameDiffMotionDetector = class(TInterfacedObject, IMotionDetector)
  strict private
    FThreshold: Single;         // fracao de celulas para valer movimento
    FSceneThreshold: Single;
    FCellDelta: Integer;        // diferenca de luma que faz uma celula "mexer"
    // A grade em uso. Nao e constante: com 32x18 cada celula cobre quatro das
    // de 64x36, e o que acendia uma agora tem de levantar a media de quatro --
    // o que filtra e o POUCO CONTRASTE, e nao o tamanho em si. Ver GRID_W.
    FGridW, FGridH, FGridCells: Integer;
    FBg: TArray<Integer>;       // fundo, luma * 256 (ponto fixo)
    FCur: TArray<Byte>;
    FHasBg: Boolean;
    FLastMs: Int64;
    FMaxGapMs: Int64;
    procedure Downsample(const Img: TRgbImage);
    procedure SeedBackground;
  public
    // Threshold e SceneThreshold sao fracoes 0..1. MaxGapMs e a distancia no
    // tempo a partir da qual dois quadros deixam de ser comparaveis.
    //
    // AGridScale encolhe o lado da grade (1 = 64x36, 0.5 = 32x18, 0.25 = 16x9);
    // ACellDelta e quanto o cinza medio de uma celula precisa mudar, em 0..255,
    // e 0 usa o padrao. Os dois sao filtros contra coisas diferentes: a grade
    // contra movimento pequeno, o delta contra oscilacao de brilho.
    constructor Create(AThreshold, ASceneThreshold: Single; AMaxGapMs: Int64;
                       AGridScale: Single = 1.0; ACellDelta: Integer = 0);
    { IMotionDetector }
    function Feed(Ms: Int64; const Img: TRgbImage): TMotionResult;
    procedure Reset;
  end;

implementation

const
  // A grade. 64x36 e 16:9 e da 2.304 celulas: fino o bastante para uma pessoa
  // ao longe ocupar algumas celulas, grosso o bastante para o ruido de sensor
  // de uma camera barata nao acender celula sozinho.
  GRID_W = 64;
  GRID_H = 36;
  GRID_CELLS = GRID_W * GRID_H;
  // O menor lado que ainda descreve alguma coisa. Abaixo disto a grade vira um
  // punhado de celulas e qualquer sombra cobre uma fracao enorme dela.
  GRID_MIN_W = 8;
  GRID_MIN_H = 5;
  // Quanto o fundo anda na direcao do quadro atual a cada analise, em 1/256.
  // 26/256 ~ 10%: com um quadro a cada 2 s, o fundo leva ~20 s para absorver
  // uma mudanca permanente. Rapido o bastante para a luz do entardecer, lento
  // o bastante para uma pessoa parada ainda contar como evento por um tempo.
  BG_ALPHA = 26;
  // Diferenca de luma (0..255) que faz uma celula contar como mexida. Abaixo de
  // ~12 e ruido de compressao: o bloco de um H.264 a bitrate baixo oscila
  // sozinho alguns niveis entre keyframes, com a cena completamente parada.
  CELL_DELTA = 14;

constructor TFrameDiffMotionDetector.Create(AThreshold, ASceneThreshold: Single;
  AMaxGapMs: Int64; AGridScale: Single; ACellDelta: Integer);
begin
  inherited Create;
  FThreshold := AThreshold;
  if FThreshold <= 0 then FThreshold := 0.012;
  FSceneThreshold := ASceneThreshold;
  if FSceneThreshold <= FThreshold then FSceneThreshold := 0.55;
  FCellDelta := ACellDelta;
  if (FCellDelta <= 0) or (FCellDelta > 255) then FCellDelta := CELL_DELTA;
  FMaxGapMs := AMaxGapMs;
  if FMaxGapMs <= 0 then FMaxGapMs := 15000;

  FGridW := GRID_W;
  FGridH := GRID_H;
  if (AGridScale > 0) and (AGridScale < 1) then
  begin
    FGridW := Round(GRID_W * AGridScale);
    FGridH := Round(GRID_H * AGridScale);
  end;
  if FGridW < GRID_MIN_W then FGridW := GRID_MIN_W;
  if FGridH < GRID_MIN_H then FGridH := GRID_MIN_H;
  FGridCells := FGridW * FGridH;

  // Os vetores nascem no tamanho MAXIMO e so os primeiros FGridCells sao
  // usados: assim o Downsample continua podendo usar vetores de pilha de
  // tamanho fixo, sem alocar nada por quadro analisado.
  SetLength(FBg, GRID_CELLS);
  SetLength(FCur, GRID_CELLS);
end;

procedure TFrameDiffMotionDetector.Reset;
begin
  FHasBg := False;
  FLastMs := 0;
end;

// Media de caixa: cada celula e a luma media dos pixels que caem nela. Media, e
// nao amostragem de um pixel, porque amostrar deixa o ruido de sensor passar
// inteiro para a grade — e ai o limiar teria de subir tanto que uma pessoa ao
// longe deixaria de acender celula nenhuma.
procedure TFrameDiffMotionDetector.Downsample(const Img: TRgbImage);
var
  Somas, Contas: array[0..GRID_CELLS - 1] of Integer;
  X, Y, GX, GY, Cel, Base, Pos: Integer;
  P: PByte;
  Luma: Integer;
begin
  FillChar(Somas, SizeOf(Somas), 0);
  FillChar(Contas, SizeOf(Contas), 0);
  P := PByte(Img.Pixels);
  for Y := 0 to Img.Height - 1 do
  begin
    GY := (Y * FGridH) div Img.Height;
    if GY >= FGridH then GY := FGridH - 1;
    Base := GY * FGridW;
    for X := 0 to Img.Width - 1 do
    begin
      GX := (X * FGridW) div Img.Width;
      if GX >= FGridW then GX := FGridW - 1;
      // Luma inteira da BT.601 com pesos 77/150/29 sobre 256. Nao precisa ser
      // colorimetricamente exata: o que importa e ser a MESMA conta em todos os
      // quadros, e ponto fixo evita centenas de milhares de conversoes para
      // float por quadro analisado.
      Pos := (Y * Img.Width + X) * 3;
      Luma := (77 * P[Pos] + 150 * P[Pos + 1] + 29 * P[Pos + 2]) shr 8;
      Inc(Somas[Base + GX], Luma);
      Inc(Contas[Base + GX]);
    end;
  end;
  for Cel := 0 to FGridCells - 1 do
    if Contas[Cel] > 0 then
      FCur[Cel] := Byte(Somas[Cel] div Contas[Cel])
    else
      FCur[Cel] := 0;
end;

procedure TFrameDiffMotionDetector.SeedBackground;
var
  I: Integer;
begin
  for I := 0 to FGridCells - 1 do
    FBg[I] := Integer(FCur[I]) shl 8;
  FHasBg := True;
end;

function TFrameDiffMotionDetector.Feed(Ms: Int64;
  const Img: TRgbImage): TMotionResult;
var
  I, GX, GY, Movidas, Diff: Integer;
  MinX, MinY, MaxX, MaxY: Integer;
  Fracao: Single;
  Saltou: Boolean;
begin
  Result.Moved := False;
  Result.Score := 0;
  Result.SceneChanged := False;
  Result.Box := TEventBox.Empty;
  if not Img.IsValid then Exit;

  Saltou := (FLastMs > 0) and (Abs(Ms - FLastMs) > FMaxGapMs);
  FLastMs := Ms;
  Downsample(Img);

  // Primeiro quadro, ou quadro depois de um salto: vira a referencia e nao
  // gera evento. Nao ha com o que comparar, e inventar uma comparacao aqui e
  // exatamente o que faria toda retomada de gravacao virar um evento.
  if (not FHasBg) or Saltou then
  begin
    SeedBackground;
    Exit;
  end;

  Movidas := 0;
  MinX := FGridW; MinY := FGridH; MaxX := -1; MaxY := -1;
  for I := 0 to FGridCells - 1 do
  begin
    Diff := Abs(Integer(FCur[I]) - (FBg[I] shr 8));
    if Diff < FCellDelta then Continue;
    Inc(Movidas);
    GX := I mod FGridW;
    GY := I div FGridW;
    if GX < MinX then MinX := GX;
    if GX > MaxX then MaxX := GX;
    if GY < MinY then MinY := GY;
    if GY > MaxY then MaxY := GY;
  end;

  Fracao := Movidas / FGridCells;
  Result.Score := Fracao;

  if Fracao >= FSceneThreshold then
  begin
    // Cena nova (ver o cabecalho). O fundo antigo nao descreve mais nada:
    // mante-lo faria os proximos quadros continuarem acusando movimento ate a
    // media exponencial alcancar a cena, o que levaria dezenas de segundos.
    Result.SceneChanged := True;
    SeedBackground;
    Exit;
  end;

  // O fundo so anda quando NAO houve mudanca brusca: absorver o quadro em que
  // alguem esta passando ensinaria a pessoa ao fundo.
  for I := 0 to FGridCells - 1 do
    FBg[I] := FBg[I] + ((Integer(FCur[I]) shl 8) - FBg[I]) * BG_ALPHA div 256;

  if Fracao < FThreshold then Exit;

  Result.Moved := True;
  // A caixa vai ate a borda EXTERNA da ultima celula (+1), senao uma regiao de
  // uma celula so sairia com largura zero.
  Result.Box := TEventBox.FromLTRB(MinX / FGridW, MinY / FGridH,
                                   (MaxX + 1) / FGridW, (MaxY + 1) / FGridH);
end;

end.
