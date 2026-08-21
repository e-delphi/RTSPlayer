unit UI.Timeline;

// Barra de tempo do dia, na base do player: faixas gravadas, régua de horários,
// cabeça de leitura, zoom, play/pausa, velocidade e o botão de voltar ao vivo.
//
// As faixas vêm de GET /api/segments já coladas pelo servidor — aqui elas são só
// retângulos proporcionais. O buraco entre duas faixas é câmera fora do ar, e é
// para isso que a barra existe: mostrar onde há e onde não há gravação.
//
// **Zoom.** Um dia inteiro em ~1000 px dá 86 s por pixel: 20 min de gravação
// viram um risco de 14 px, e arrastar não tem precisão nenhuma. Por isso a barra
// desenha uma JANELA (FViewStartMs..FViewEndMs) e não o dia todo.
//
// **Arrastar navega, tocar posiciona.** Arrastar move a JANELA no tempo e não
// mexe no player — é como se olha o resto do dia sem interromper o que está
// tocando. Um toque simples (sem arrasto) é que manda o player para aquele
// instante. Enquanto a janela foi movida na mão, ela para de seguir a
// reprodução; o seguimento volta no próximo seek, zoom ou dia novo.
//
// Montada em código, sem .fmx, como a UI.Days. O layout usa um hospedeiro
// Align=Top e outro Align=Bottom porque dois filhos com o MESMO Align empilham
// na ordem inversa da criação — o que já rendeu a barra invertida uma vez.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Types,
  System.UITypes,
  System.DateUtils,
  FMX.Types,
  FMX.Controls,
  FMX.Objects,
  FMX.Layouts,
  FMX.StdCtrls,
  FMX.Graphics,
  VMS.Api.Client,
  UI.Common;

type
  TTimelineSeekEvent = procedure(Sender: TObject; UnixMs: Int64) of object;

  TFrameTimeline = class(TLayout)
  private
    FTrackHost: TLayout;
    FRuler: TLayout;             // faixa de rótulos de horário, sob a barra
    FRow: TLayout;
    FTrack: TRectangle;          // fundo da barra (a janela visível)
    FCursor: TRectangle;         // cabeça de leitura
    FLblTime: TLabel;
    FLblZoom: TLabel;
    FPathPlay: TPath;
    FLblSpeed: TLabel;
    FSegments: TArray<TApiSegment>;
    FDayStartMs: Int64;
    FDayEndMs: Int64;
    FViewStartMs: Int64;         // janela visível: é ela que a barra desenha
    FViewEndMs: Int64;
    FZoom: Integer;              // índice em ZOOM_SPANS
    FPositionMs: Int64;
    FFollow: Boolean;            // a janela acompanha a reprodução?
    FPanActive: Boolean;
    FPanMoved: Boolean;
    FPanStartX: Single;
    FPanStartView: Int64;
    FPlaying: Boolean;
    FSpeed: Double;
    FOnSeek: TTimelineSeekEvent;
    FOnTogglePlay: TNotifyEvent;
    FOnSpeedChange: TTimelineSeekEvent; // UnixMs carrega a velocidade x1000
    FOnLive: TNotifyEvent;
    function XToMs(X: Single): Int64;
    function MsToX(Ms: Int64): Single;
    function ViewSpanMs: Int64;
    procedure PanToStart(NewStartMs: Int64);
    procedure TrackMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure TrackMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure TrackMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PlayClick(Sender: TObject);
    procedure SpeedClick(Sender: TObject);
    procedure LiveClick(Sender: TObject);
    procedure ZoomInClick(Sender: TObject);
    procedure ZoomOutClick(Sender: TObject);
    procedure CenterView(OnMs: Int64);
    procedure RedrawTrack;
    procedure RedrawRuler;
    procedure UpdateCursor;
    procedure UpdatePlayIcon;
    procedure UpdateZoomLabel;
    function MakeButton(AParent: TFmxObject; AWidth: Single;
                        AAlign: TAlignLayout): TRectangle;
    function MakeTextButton(AParent: TFmxObject; AWidth: Single; AAlign: TAlignLayout;
                            const AText: string; AColor: TAlphaColor;
                            AOnClick: TNotifyEvent): TLabel;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    // Desenha o dia: limites (fuso do servidor) e as faixas com gravação.
    procedure SetDay(DayStartMs, DayEndMs: Int64; const Segments: TArray<TApiSegment>);
    procedure SetPosition(UnixMs: Int64);
    procedure SetPlaying(Value: Boolean);
    procedure SetSpeedLabel(Value: Double);
    property OnSeek: TTimelineSeekEvent read FOnSeek write FOnSeek;
    property OnTogglePlay: TNotifyEvent read FOnTogglePlay write FOnTogglePlay;
    property OnSpeedChange: TTimelineSeekEvent read FOnSpeedChange write FOnSpeedChange;
    property OnLive: TNotifyEvent read FOnLive write FOnLive;
  end;

implementation

const
  BAR_HEIGHT = 28;
  // marca cheia (6) + rótulo: apertar mais corta o texto embaixo
  RULER_HEIGHT = 20;
  ICON_PLAY  = 'M7 4 L19 12 L7 20 Z';
  ICON_PAUSE = 'M6 4 L10 4 L10 20 L6 20 Z M14 4 L18 4 L18 20 L14 20 Z';
  ONE_MIN_MS = Int64(60000);
  ONE_HOUR_MS = 60 * ONE_MIN_MS;
  // 0 = o dia inteiro; os demais são a largura da janela em ms
  ZOOM_SPANS: array[0..4] of Int64 =
    (0, 4 * ONE_HOUR_MS, ONE_HOUR_MS, 15 * ONE_MIN_MS, 3 * ONE_MIN_MS);
  ZOOM_NAMES: array[0..4] of string = ('dia', '4h', '1h', '15min', '3min');
  // Abaixo disto o arrasto é toque, não navegação: dedo em tela nunca fica
  // parado de verdade.
  DRAG_THRESHOLD_PX = 6;
  // Espaço mínimo entre dois rótulos de horário para não virarem uma mancha.
  MIN_LABEL_PX = 64;
  // Idem para as marcas sem rótulo: abaixo disso somem em vez de virar um risco
  // cinza contínuo.
  MIN_MINOR_PX = 5;
  // Marca menor: mesma cor dos rótulos, com transparência — hierarquia visual
  // sem inventar mais uma cor na paleta.
  TICK_MINOR = TAlphaColor($66B0B0B0);

{ TFrameTimeline }

function TFrameTimeline.MakeButton(AParent: TFmxObject; AWidth: Single;
  AAlign: TAlignLayout): TRectangle;
begin
  Result := TRectangle.Create(Self);
  Result.Parent := AParent;
  Result.Align := AAlign;
  Result.Width := AWidth;
  Result.Margins.Left := 4;
  Result.Margins.Right := 4;
  Result.Margins.Top := 4;
  Result.Margins.Bottom := 4;
  Result.XRadius := 6;
  Result.YRadius := 6;
  Result.Fill.Color := COLOR_SURFACE2;
  Result.Stroke.Kind := TBrushKind.None;
  Result.HitTest := True;
end;

function TFrameTimeline.MakeTextButton(AParent: TFmxObject; AWidth: Single;
  AAlign: TAlignLayout; const AText: string; AColor: TAlphaColor;
  AOnClick: TNotifyEvent): TLabel;
var
  Btn: TRectangle;
begin
  Btn := MakeButton(AParent, AWidth, AAlign);
  Btn.OnClick := AOnClick;
  Result := TLabel.Create(Self);
  Result.Parent := Btn;
  Result.Align := TAlignLayout.Client;
  Result.HitTest := False;
  Result.StyledSettings := [];
  Result.TextSettings.FontColor := AColor;
  Result.TextSettings.Font.Size := 14;
  Result.TextSettings.HorzAlign := TTextAlign.Center;
  Result.TextSettings.VertAlign := TTextAlign.Center;
  Result.Text := AText;
end;

constructor TFrameTimeline.Create(AOwner: TComponent);
var
  BtnPlay: TRectangle;
begin
  inherited Create(AOwner);
  Name := '';
  Height := BAR_HEIGHT + 12 + RULER_HEIGHT + 44;
  FSpeed := 1.0;
  FPlaying := True;
  FZoom := 0;
  FFollow := True;

  // hospedeiro de cima: a barra e, logo abaixo dela, a régua de horários
  FTrackHost := TLayout.Create(Self);
  FTrackHost.Parent := Self;
  FTrackHost.Align := TAlignLayout.Top;
  FTrackHost.Height := BAR_HEIGHT + 12 + RULER_HEIGHT;

  FRuler := TLayout.Create(Self);
  FRuler.Parent := FTrackHost;
  FRuler.Align := TAlignLayout.Bottom;
  FRuler.Height := RULER_HEIGHT;
  FRuler.Margins.Left := 8;
  FRuler.Margins.Right := 8;
  FRuler.HitTest := False;

  FTrack := TRectangle.Create(Self);
  FTrack.Parent := FTrackHost;
  FTrack.Align := TAlignLayout.Client;
  FTrack.Margins.Left := 8;
  FTrack.Margins.Right := 8;
  FTrack.Margins.Top := 6;
  FTrack.Margins.Bottom := 4;
  FTrack.XRadius := 4;
  FTrack.YRadius := 4;
  FTrack.Fill.Color := COLOR_SURFACE2;
  FTrack.Stroke.Kind := TBrushKind.None;
  FTrack.HitTest := True;
  // Sem isto o arrasto trava "segurando": o FMX só entrega MouseMove/MouseUp
  // enquanto o ponteiro está SOBRE o controle, então soltar o dedo (ou o mouse)
  // fora da barra nunca chegava aqui e o FPanActive ficava ligado para sempre.
  // Com AutoCapture o controle captura no MouseDown e recebe o resto do gesto
  // onde quer que ele termine — inclusive fora da janela.
  FTrack.AutoCapture := True;
  FTrack.OnMouseDown := TrackMouseDown;
  FTrack.OnMouseMove := TrackMouseMove;
  FTrack.OnMouseUp := TrackMouseUp;

  FCursor := TRectangle.Create(Self);
  FCursor.Parent := FTrack;
  FCursor.Align := TAlignLayout.None;
  FCursor.Width := 3;
  FCursor.Height := BAR_HEIGHT;
  FCursor.HitTest := False;
  FCursor.Fill.Color := COLOR_TEXT;
  FCursor.Stroke.Kind := TBrushKind.None;

  // hospedeiro de baixo: os controles
  FRow := TLayout.Create(Self);
  FRow.Parent := Self;
  FRow.Align := TAlignLayout.Bottom;
  FRow.Height := 44;

  BtnPlay := MakeButton(FRow, 46, TAlignLayout.Left);
  BtnPlay.OnClick := PlayClick;
  FPathPlay := TPath.Create(Self);
  FPathPlay.Parent := BtnPlay;
  FPathPlay.Align := TAlignLayout.Center;
  FPathPlay.Width := 16;
  FPathPlay.Height := 16;
  FPathPlay.HitTest := False;
  FPathPlay.WrapMode := TPathWrapMode.Fit;
  FPathPlay.Fill.Color := COLOR_TEXT;
  FPathPlay.Stroke.Kind := TBrushKind.None;
  FPathPlay.Data.Data := ICON_PAUSE;

  FLblSpeed := MakeTextButton(FRow, 46, TAlignLayout.Left, '1x', COLOR_TEXT, SpeedClick);

  // zoom: menos abre a janela, mais fecha. O rótulo no meio diz onde se está.
  MakeTextButton(FRow, 40, TAlignLayout.Left, '-', COLOR_TEXT, ZoomOutClick);
  FLblZoom := TLabel.Create(Self);
  FLblZoom.Parent := FRow;
  FLblZoom.Align := TAlignLayout.Left;
  FLblZoom.Width := 52;
  FLblZoom.HitTest := False;
  FLblZoom.StyledSettings := [];
  FLblZoom.TextSettings.FontColor := COLOR_DIM;
  FLblZoom.TextSettings.Font.Size := 13;
  FLblZoom.TextSettings.HorzAlign := TTextAlign.Center;
  FLblZoom.TextSettings.VertAlign := TTextAlign.Center;
  FLblZoom.Text := ZOOM_NAMES[0];
  MakeTextButton(FRow, 40, TAlignLayout.Left, '+', COLOR_TEXT, ZoomInClick);

  MakeTextButton(FRow, 84, TAlignLayout.Right, 'ao vivo', STAT_GREEN, LiveClick);

  FLblTime := TLabel.Create(Self);
  FLblTime.Parent := FRow;
  FLblTime.Align := TAlignLayout.Right;
  FLblTime.Width := 92;
  FLblTime.HitTest := False;
  FLblTime.StyledSettings := [];
  FLblTime.TextSettings.FontColor := COLOR_TEXT;
  FLblTime.TextSettings.Font.Size := 15;
  FLblTime.TextSettings.HorzAlign := TTextAlign.Center;
  FLblTime.TextSettings.VertAlign := TTextAlign.Center;
  FLblTime.Text := '--:--:--';
end;

function TFrameTimeline.ViewSpanMs: Int64;
begin
  Result := FViewEndMs - FViewStartMs;
end;

function TFrameTimeline.XToMs(X: Single): Int64;
var
  W: Single;
  Frac: Double;
begin
  W := FTrack.Width;
  if (W <= 0) or (ViewSpanMs <= 0) then Exit(FViewStartMs);
  Frac := X / W;
  if Frac < 0 then Frac := 0;
  if Frac > 1 then Frac := 1;
  Result := FViewStartMs + Round(ViewSpanMs * Frac);
end;

function TFrameTimeline.MsToX(Ms: Int64): Single;
begin
  if ViewSpanMs <= 0 then Exit(0);
  if Ms < FViewStartMs then Ms := FViewStartMs;
  if Ms > FViewEndMs then Ms := FViewEndMs;
  Result := FTrack.Width * ((Ms - FViewStartMs) / ViewSpanMs);
end;

// Recentra a janela num instante, sem sair dos limites do dia.
procedure TFrameTimeline.CenterView(OnMs: Int64);
var
  Span: Int64;
begin
  Span := ZOOM_SPANS[FZoom];
  if (Span <= 0) or (Span >= FDayEndMs - FDayStartMs) then
  begin
    FViewStartMs := FDayStartMs;
    FViewEndMs := FDayEndMs;
    Exit;
  end;
  FViewStartMs := OnMs - Span div 2;
  FViewEndMs := FViewStartMs + Span;
  if FViewStartMs < FDayStartMs then
  begin
    FViewStartMs := FDayStartMs;
    FViewEndMs := FViewStartMs + Span;
  end;
  if FViewEndMs > FDayEndMs then
  begin
    FViewEndMs := FDayEndMs;
    FViewStartMs := FViewEndMs - Span;
    if FViewStartMs < FDayStartMs then FViewStartMs := FDayStartMs;
  end;
end;

// Move a janela mantendo a largura, presa aos limites do dia.
procedure TFrameTimeline.PanToStart(NewStartMs: Int64);
var
  Span: Int64;
begin
  Span := ViewSpanMs;
  if Span <= 0 then Exit;
  if NewStartMs < FDayStartMs then NewStartMs := FDayStartMs;
  if NewStartMs + Span > FDayEndMs then NewStartMs := FDayEndMs - Span;
  if NewStartMs = FViewStartMs then Exit;
  FViewStartMs := NewStartMs;
  FViewEndMs := NewStartMs + Span;
  RedrawTrack;
  UpdateCursor;
end;

procedure TFrameTimeline.SetDay(DayStartMs, DayEndMs: Int64;
  const Segments: TArray<TApiSegment>);
var
  Covered, CenterOn: Int64;
  I: Integer;
begin
  FDayStartMs := DayStartMs;
  FDayEndMs := DayEndMs;
  FSegments := Segments;
  FFollow := True;
  if FPositionMs < FDayStartMs then FPositionMs := FDayStartMs;
  if FPositionMs > FDayEndMs then FPositionMs := FDayEndMs;
  CenterOn := FPositionMs;

  // Zoom inicial que ENQUADRA o gravado. Vinte minutos num dia de 24 h dariam um
  // risco de poucos pixels no zoom "dia" — quem abre o histórico quer ver o que
  // existe, não o vazio em volta. A partir daí o - e o + mandam.
  if Length(Segments) > 0 then
  begin
    Covered := Segments[High(Segments)].EndMs - Segments[0].StartMs;
    FZoom := 0;
    for I := High(ZOOM_SPANS) downto 1 do
      if ZOOM_SPANS[I] >= Covered then
        FZoom := I;
    // Centra na gravação, não na cabeça de leitura: mover a cabeça aqui seria
    // mentir sobre onde o playback está.
    if FZoom > 0 then
      CenterOn := Segments[0].StartMs + Covered div 2;
  end;

  CenterView(CenterOn);
  RedrawTrack;
  UpdateCursor;
  UpdateZoomLabel;
end;

// De quanto em quanto tempo marcar a régua, para os rótulos ficarem legíveis em
// qualquer zoom. Todos os valores dividem uma hora, então as marcas caem em
// horários redondos (o dia começa na meia-noite local).
function TickIntervalMs(Span: Int64): Int64;
begin
  if Span >= 12 * ONE_HOUR_MS then Exit(2 * ONE_HOUR_MS);
  if Span >= 4 * ONE_HOUR_MS then Exit(ONE_HOUR_MS);
  if Span >= ONE_HOUR_MS then Exit(15 * ONE_MIN_MS);
  if Span >= 15 * ONE_MIN_MS then Exit(5 * ONE_MIN_MS);
  if Span >= 3 * ONE_MIN_MS then Exit(ONE_MIN_MS);
  Result := 15000;
end;

// Subdivisão sem rótulo entre duas marcas com hora: é o que dá noção de onde
// caem os segundos dentro do minuto. Divisor escolhido para o resultado
// continuar sendo um valor redondo de relógio.
function MinorIntervalMs(Major: Int64): Int64;
begin
  if Major = 2 * ONE_HOUR_MS then Exit(30 * ONE_MIN_MS);
  if Major = ONE_HOUR_MS then Exit(15 * ONE_MIN_MS);
  if Major = 15 * ONE_MIN_MS then Exit(5 * ONE_MIN_MS);
  if Major = 5 * ONE_MIN_MS then Exit(ONE_MIN_MS);
  if Major = ONE_MIN_MS then Exit(15000);
  Result := 5000;
end;

// As faixas são retângulos posicionados em pixels, então tudo que muda a escala
// (zoom, pan, giro de tela, dia novo) passa por aqui.
procedure TFrameTimeline.RedrawTrack;
var
  I: Integer;
  Seg: TRectangle;
  X1, X2: Single;
begin
  if FTrack = nil then Exit;
  for I := FTrack.ChildrenCount - 1 downto 0 do
    if FTrack.Children[I] <> FCursor then
      FTrack.Children[I].Free;

  for I := 0 to High(FSegments) do
  begin
    // fora da janela: nem cria
    if FSegments[I].EndMs < FViewStartMs then Continue;
    if FSegments[I].StartMs > FViewEndMs then Continue;
    X1 := MsToX(FSegments[I].StartMs);
    X2 := MsToX(FSegments[I].EndMs);
    Seg := TRectangle.Create(Self);
    Seg.Parent := FTrack;
    Seg.Align := TAlignLayout.None;
    Seg.HitTest := False;   // o toque é da barra, não das faixas
    Seg.Fill.Color := COLOR_ACCENT;
    Seg.Stroke.Kind := TBrushKind.None;
    Seg.Height := FTrack.Height;
    Seg.Position.Y := 0;
    Seg.Position.X := X1;
    Seg.Width := X2 - X1;
    if Seg.Width < 2 then Seg.Width := 2; // trecho curto ainda precisa aparecer
  end;

  RedrawRuler;
  FCursor.BringToFront;
end;

// Marcas e horários sob a barra: sem isso não dá para saber que horas são as
// faixas, que era a maior falta da tela.
procedure TFrameTimeline.RedrawRuler;
var
  I, Step: Integer;
  Interval, Minor, T: Int64;
  X, PxPerTick, PxPerMinor: Single;
  Tick: TRectangle;
  Lbl: TLabel;
  Fine: Boolean;
begin
  if (FRuler = nil) or (ViewSpanMs <= 0) or (FTrack.Width <= 0) then Exit;
  for I := FRuler.ChildrenCount - 1 downto 0 do
    FRuler.Children[I].Free;

  Interval := TickIntervalMs(ViewSpanMs);
  PxPerTick := FTrack.Width * (Interval / ViewSpanMs);
  // Marcas muito juntas: rotula uma a cada N, mas mantém o risco de todas.
  Step := 1;
  if PxPerTick > 0 then
    while (PxPerTick * Step) < MIN_LABEL_PX do
      Inc(Step);
  Fine := Interval < ONE_MIN_MS;

  // Subdivisões sem rótulo, mais curtas e mais apagadas. Só entram se houver
  // espaço: encostadas umas nas outras virariam um borrão cinza.
  Minor := MinorIntervalMs(Interval);
  PxPerMinor := FTrack.Width * (Minor / ViewSpanMs);
  if PxPerMinor >= MIN_MINOR_PX then
  begin
    T := FDayStartMs + ((FViewStartMs - FDayStartMs + Minor - 1) div Minor) * Minor;
    while T <= FViewEndMs do
    begin
      // a marca cheia já é desenhada no laço principal
      if ((T - FDayStartMs) mod Interval) <> 0 then
      begin
        Tick := TRectangle.Create(Self);
        Tick.Parent := FRuler;
        Tick.Align := TAlignLayout.None;
        Tick.HitTest := False;
        Tick.Stroke.Kind := TBrushKind.None;
        Tick.Fill.Color := TICK_MINOR;
        Tick.Width := 1;
        Tick.Height := 3;
        Tick.Position.X := MsToX(T);
        Tick.Position.Y := 0;
      end;
      Inc(T, Minor);
    end;
  end;

  // primeira marca >= início da janela, contada a partir da meia-noite local
  T := FDayStartMs + ((FViewStartMs - FDayStartMs + Interval - 1) div Interval) * Interval;
  I := 0;
  while T <= FViewEndMs do
  begin
    X := MsToX(T);

    Tick := TRectangle.Create(Self);
    Tick.Parent := FRuler;
    Tick.Align := TAlignLayout.None;
    Tick.HitTest := False;
    Tick.Stroke.Kind := TBrushKind.None;
    Tick.Fill.Color := COLOR_DIM;
    Tick.Width := 1;
    Tick.Height := 6;
    Tick.Position.X := X;
    Tick.Position.Y := 0;

    if (I mod Step) = 0 then
    begin
      Lbl := TLabel.Create(Self);
      Lbl.Parent := FRuler;
      Lbl.HitTest := False;
      Lbl.StyledSettings := [];
      Lbl.TextSettings.FontColor := COLOR_DIM;
      Lbl.TextSettings.Font.Size := 11;
      Lbl.TextSettings.HorzAlign := TTextAlign.Center;
      Lbl.Width := 60;
      Lbl.Height := RULER_HEIGHT - 6;
      Lbl.Position.X := X - 30;
      Lbl.Position.Y := 6;   // logo abaixo da marca cheia
      if Fine then
        Lbl.Text := FormatDateTime('hh:nn:ss',
          TTimeZone.Local.ToLocalTime(UnixToDateTime(T div 1000, True)))
      else
        Lbl.Text := FormatDateTime('hh:nn',
          TTimeZone.Local.ToLocalTime(UnixToDateTime(T div 1000, True)));
    end;

    Inc(T, Interval);
    Inc(I);
  end;
end;

procedure TFrameTimeline.Resize;
begin
  inherited;
  // A largura da barra mudou: faixas e régua estão em pixels e precisam ser
  // recalculadas a partir do tempo.
  RedrawTrack;
  UpdateCursor;
end;

procedure TFrameTimeline.UpdateCursor;
begin
  if FCursor = nil then Exit;
  FCursor.Height := FTrack.Height;
  FCursor.Position.Y := 0;
  // Fora da janela a cabeça encosta na borda; é o que acontece quando se navega
  // para longe de onde o player está.
  FCursor.Position.X := MsToX(FPositionMs) - 1;
  FCursor.Visible := (FPositionMs >= FViewStartMs) and (FPositionMs <= FViewEndMs);
  if FDayEndMs > FDayStartMs then
    FLblTime.Text := FormatDateTime('hh:nn:ss',
      TTimeZone.Local.ToLocalTime(UnixToDateTime(FPositionMs div 1000, True)));
end;

procedure TFrameTimeline.UpdateZoomLabel;
begin
  if FLblZoom <> nil then
    FLblZoom.Text := ZOOM_NAMES[FZoom];
end;

procedure TFrameTimeline.SetPosition(UnixMs: Int64);
var
  Margin: Int64;
begin
  FPositionMs := UnixMs;
  // Janela movida na mão não é arrastada de volta pela reprodução: quem está
  // olhando outro trecho fica olhando outro trecho.
  if FFollow and (not FPanActive) and (ViewSpanMs > 0) and
     (ViewSpanMs < FDayEndMs - FDayStartMs) then
  begin
    Margin := ViewSpanMs div 10;
    if (UnixMs < FViewStartMs + Margin) or (UnixMs > FViewEndMs - Margin) then
    begin
      CenterView(UnixMs);
      RedrawTrack;
    end;
  end;
  UpdateCursor;
end;

procedure TFrameTimeline.SetPlaying(Value: Boolean);
begin
  FPlaying := Value;
  UpdatePlayIcon;
end;

procedure TFrameTimeline.UpdatePlayIcon;
begin
  if FPathPlay = nil then Exit;
  if FPlaying then
    FPathPlay.Data.Data := ICON_PAUSE
  else
    FPathPlay.Data.Data := ICON_PLAY;
end;

procedure TFrameTimeline.SetSpeedLabel(Value: Double);
begin
  FSpeed := Value;
  FLblSpeed.Text := Format('%gx', [Value]);
end;

procedure TFrameTimeline.ZoomInClick(Sender: TObject);
begin
  if FZoom >= High(ZOOM_SPANS) then Exit;
  Inc(FZoom);
  FFollow := True;
  CenterView(FPositionMs);
  RedrawTrack;
  UpdateCursor;
  UpdateZoomLabel;
end;

procedure TFrameTimeline.ZoomOutClick(Sender: TObject);
begin
  if FZoom <= 0 then Exit;
  Dec(FZoom);
  FFollow := True;
  CenterView(FPositionMs);
  RedrawTrack;
  UpdateCursor;
  UpdateZoomLabel;
end;

procedure TFrameTimeline.TrackMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FPanActive := True;
  FPanMoved := False;
  FPanStartX := X;
  FPanStartView := FViewStartMs;
end;

procedure TFrameTimeline.TrackMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
var
  DeltaPx: Single;
  DeltaMs: Int64;
begin
  if not FPanActive then Exit;
  DeltaPx := X - FPanStartX;
  if (not FPanMoved) and (Abs(DeltaPx) < DRAG_THRESHOLD_PX) then Exit;
  FPanMoved := True;
  FFollow := False;
  if FTrack.Width <= 0 then Exit;
  // Arrastar para a esquerda avança no tempo, como puxar um mapa.
  DeltaMs := Round(ViewSpanMs * (DeltaPx / FTrack.Width));
  PanToStart(FPanStartView - DeltaMs);
end;

procedure TFrameTimeline.TrackMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  if not FPanActive then Exit;
  FPanActive := False;
  // Arrastou = navegou, e o player continua onde estava. Só o toque simples
  // manda o player para outro instante.
  if FPanMoved then Exit;
  FPositionMs := XToMs(X);
  FFollow := True;
  UpdateCursor;
  if Assigned(FOnSeek) then FOnSeek(Self, FPositionMs);
end;

procedure TFrameTimeline.PlayClick(Sender: TObject);
begin
  if Assigned(FOnTogglePlay) then FOnTogglePlay(Self);
end;

// 1x -> 2x -> 4x -> 1x. Fora de 1x o áudio não sai (o AudioTrack não acompanha).
procedure TFrameTimeline.SpeedClick(Sender: TObject);
begin
  if FSpeed >= 4 then
    FSpeed := 1
  else
    FSpeed := FSpeed * 2;
  SetSpeedLabel(FSpeed);
  if Assigned(FOnSpeedChange) then
    FOnSpeedChange(Self, Round(FSpeed * 1000));
end;

procedure TFrameTimeline.LiveClick(Sender: TObject);
begin
  if Assigned(FOnLive) then FOnLive(Self);
end;

end.

