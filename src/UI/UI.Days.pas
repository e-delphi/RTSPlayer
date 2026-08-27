unit UI.Days;

// Tela de escolha do dia: um item por dia com gravação, do mais recente para o
// mais antigo. Vem de GET /api/days.
//
// Montada em código, sem .fmx: é uma tela de lista simples, e um arquivo de
// forma a mais só existiria para ser editado no designer.
//
// Cada item mostra a data, quanto foi gravado e uma barrinha de cobertura — que
// é o que deixa "bater o olho e ver onde há buraco" antes de abrir o dia.

interface

uses
  System.SysUtils,
  System.Classes,
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
  TDayPickEvent = procedure(Sender: TObject; const Day: string;
    StartMs, EndMs: Int64) of object;

  TFrameDays = class(TLayout)
  private
    FTop: TRectangle;
    FBtnBack: TRectangle;
    FPathBack: TPath;
    FLblTitle: TLabel;
    FList: TVertScrollBox;
    FLblEmpty: TLabel;
    // a lista que está na tela: o Tag de cada card é o índice aqui
    FDays: TArray<TApiDay>;
    FOnBack: TNotifyEvent;
    FOnPickDay: TDayPickEvent;
    procedure BackClick(Sender: TObject);
    procedure ItemClick(Sender: TObject);
    procedure ClearItems;
    function AddItem(const Day: TApiDay; Index: Integer): TRectangle;
    procedure SetMessage(const S: string);
    procedure CoverResize(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetTitle(const S: string);
    procedure SetLoading;
    procedure SetError(const Msg: string);
    procedure SetDays(const Days: TArray<TApiDay>);
    property OnBack: TNotifyEvent read FOnBack write FOnBack;
    property OnPickDay: TDayPickEvent read FOnPickDay write FOnPickDay;
  end;

// '2026-08-15' -> 'sáb, 15/08'. Nome do dia em português fixo aqui: depender do
// FormatSettings da máquina daria inglês em algumas instalações.
function FormatDayLabel(const Day: string): string;
// 71300000 -> '19h 48min'
function FormatDurationMs(Ms: Int64): string;
function ParseApiDay(const S: string; out D: TDateTime): Boolean;

implementation

const
  ITEM_HEIGHT = 72;
  // Margem superior de cada card. Entra na conta do Y porque é ela que separa
  // um do outro depois do alinhamento.
  ITEM_GAP = 8;
  WEEKDAYS: array[1..7] of string = ('dom', 'seg', 'ter', 'qua', 'qui', 'sex', 's'#$E1'b');

function ParseApiDay(const S: string; out D: TDateTime): Boolean;
var
  Y, M, Dy: Integer;
begin
  Result := False;
  if Length(S) <> 10 then Exit;
  if not TryStrToInt(Copy(S, 1, 4), Y) then Exit;
  if not TryStrToInt(Copy(S, 6, 2), M) then Exit;
  if not TryStrToInt(Copy(S, 9, 2), Dy) then Exit;
  Result := TryEncodeDate(Y, M, Dy, D);
end;

function FormatDayLabel(const Day: string): string;
var
  D: TDateTime;
begin
  if not ParseApiDay(Day, D) then Exit(Day);
  Result := Format('%s, %.2d/%.2d', [WEEKDAYS[DayOfWeek(D)], DayOf(D), MonthOf(D)]);
  if DateOf(Now) = D then
    Result := 'hoje, ' + Format('%.2d/%.2d', [DayOf(D), MonthOf(D)])
  else if DateOf(Now) - 1 = D then
    Result := 'ontem, ' + Format('%.2d/%.2d', [DayOf(D), MonthOf(D)]);
end;

function FormatDurationMs(Ms: Int64): string;
var
  Mins, H, M: Int64;
begin
  Mins := Ms div 60000;
  H := Mins div 60;
  M := Mins mod 60;
  if H > 0 then
    Result := Format('%dh %02dmin', [H, M])
  else
    Result := Format('%dmin', [M]);
end;

{ TFrameDays }

constructor TFrameDays.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Name := '';

  FTop := TRectangle.Create(Self);
  FTop.Parent := Self;
  FTop.Align := TAlignLayout.Top;
  FTop.Height := 52;
  FTop.Fill.Color := COLOR_SURFACE;
  FTop.Stroke.Kind := TBrushKind.None;

  FBtnBack := TRectangle.Create(Self);
  FBtnBack.Parent := FTop;
  FBtnBack.Align := TAlignLayout.Left;
  FBtnBack.Width := 52;
  FBtnBack.Fill.Kind := TBrushKind.None;
  FBtnBack.Stroke.Kind := TBrushKind.None;
  FBtnBack.HitTest := True;
  FBtnBack.OnClick := BackClick;

  FPathBack := TPath.Create(Self);
  FPathBack.Parent := FBtnBack;
  FPathBack.Align := TAlignLayout.Center;
  FPathBack.Width := 22;
  FPathBack.Height := 22;
  FPathBack.HitTest := False;
  FPathBack.WrapMode := TPathWrapMode.Fit;
  FPathBack.Fill.Color := COLOR_TEXT;
  FPathBack.Stroke.Kind := TBrushKind.None;
  FPathBack.Data.Data := ICON_BACK;

  FLblTitle := TLabel.Create(Self);
  FLblTitle.Parent := FTop;
  FLblTitle.Align := TAlignLayout.Client;
  FLblTitle.Margins.Left := 4;
  FLblTitle.StyledSettings := [];
  FLblTitle.TextSettings.FontColor := COLOR_TEXT;
  FLblTitle.TextSettings.Font.Size := 16;
  FLblTitle.TextSettings.VertAlign := TTextAlign.Center;
  FLblTitle.Text := 'Grava'#$E7#$F5'es';

  FList := TVertScrollBox.Create(Self);
  FList.Parent := Self;
  FList.Align := TAlignLayout.Client;

  FLblEmpty := TLabel.Create(Self);
  FLblEmpty.Parent := Self;
  FLblEmpty.Align := TAlignLayout.Client;
  FLblEmpty.StyledSettings := [];
  FLblEmpty.TextSettings.FontColor := COLOR_DIM;
  FLblEmpty.TextSettings.Font.Size := 14;
  FLblEmpty.TextSettings.HorzAlign := TTextAlign.Center;
  FLblEmpty.TextSettings.VertAlign := TTextAlign.Center;
  FLblEmpty.Visible := False;
end;

procedure TFrameDays.SetTitle(const S: string);
begin
  FLblTitle.Text := S;
end;

procedure TFrameDays.BackClick(Sender: TObject);
begin
  if Assigned(FOnBack) then FOnBack(Self);
end;

procedure TFrameDays.ClearItems;
var
  I: Integer;
begin
  for I := FList.Content.ChildrenCount - 1 downto 0 do
    FList.Content.Children[I].Free;
end;

procedure TFrameDays.SetMessage(const S: string);
begin
  ClearItems;
  FLblEmpty.Text := S;
  FLblEmpty.Visible := True;
  FLblEmpty.BringToFront;
  FList.Visible := False;
end;

procedure TFrameDays.SetLoading;
begin
  SetMessage('Consultando o servidor'#$85);
end;

procedure TFrameDays.SetError(const Msg: string);
begin
  SetMessage(Msg);
end;

// O TAG de cada item guarda o índice; os dados ficam no próprio controle para a
// tela não precisar de uma cópia paralela da lista.
function TFrameDays.AddItem(const Day: TApiDay; Index: Integer): TRectangle;
var
  Card: TRectangle;
  LblDay, LblDur: TLabel;
  Track, Fill: TRectangle;
  Cov: Double;
begin
  Card := TRectangle.Create(Self);
  Card.Parent := FList.Content;
  Card.Align := TAlignLayout.Top;
  Card.Height := ITEM_HEIGHT;
  Card.Margins.Left := 8;
  Card.Margins.Right := 8;
  Card.Margins.Top := ITEM_GAP;
  Card.XRadius := 8;
  Card.YRadius := 8;
  Card.Fill.Color := COLOR_SURFACE;
  Card.Stroke.Kind := TBrushKind.None;
  Card.HitTest := True;
  Card.Tag := Index;
  Card.OnClick := ItemClick;

  LblDay := TLabel.Create(Self);
  LblDay.Parent := Card;
  LblDay.SetBounds(12, 8, 200, 22);
  LblDay.HitTest := False;
  LblDay.StyledSettings := [];
  LblDay.TextSettings.FontColor := COLOR_TEXT;
  LblDay.TextSettings.Font.Size := 15;
  LblDay.Text := FormatDayLabel(Day.Day);

  LblDur := TLabel.Create(Self);
  LblDur.Parent := Card;
  LblDur.SetBounds(12, 30, 260, 18);
  LblDur.HitTest := False;
  LblDur.StyledSettings := [];
  LblDur.TextSettings.FontColor := COLOR_DIM;
  LblDur.TextSettings.Font.Size := 12;
  if Day.Segments > 1 then
    LblDur.Text := Format('%s gravados, %d trechos',
      [FormatDurationMs(Day.RecordedMs), Day.Segments])
  else
    LblDur.Text := Format('%s gravados', [FormatDurationMs(Day.RecordedMs)]);

  // barra de cobertura: fundo + preenchimento proporcional
  Track := TRectangle.Create(Self);
  Track.Parent := Card;
  Track.Align := TAlignLayout.Bottom;
  Track.Height := 6;
  Track.Margins.Left := 12;
  Track.Margins.Right := 12;
  Track.Margins.Bottom := 10;
  Track.XRadius := 3;
  Track.YRadius := 3;
  Track.HitTest := False;
  Track.Fill.Color := COLOR_SURFACE2;
  Track.Stroke.Kind := TBrushKind.None;
  Cov := Day.Coverage;
  if Cov < 0 then Cov := 0;
  if Cov > 1 then Cov := 1;
  // A fração fica guardada no Tag (por mil) e a largura é recalculada no
  // Resize: quando o card é criado a lista ainda não tem a largura final, então
  // calcular agora daria uma barra do tamanho errado até o primeiro giro de tela.
  Track.Tag := Round(Cov * 1000);
  Track.OnResize := CoverResize;

  Fill := TRectangle.Create(Self);
  Fill.Parent := Track;
  Fill.Align := TAlignLayout.Left;
  Fill.Width := 0;
  Fill.XRadius := 3;
  Fill.YRadius := 3;
  Fill.HitTest := False;
  Fill.Fill.Color := COLOR_ACCENT;
  Fill.Stroke.Kind := TBrushKind.None;
  // Com a tela já montada, o Resize do fundo acontece na hora em que o Align é
  // atribuído — antes de este preenchimento existir — e não voltaria a
  // acontecer. Por isso a largura é calculada aqui também: sem esta linha a
  // barra só aparecia depois de redimensionar a janela.
  CoverResize(Track);

  Result := Card;
end;

procedure TFrameDays.SetDays(const Days: TArray<TApiDay>);
var
  I: Integer;
  Y: Single;
begin
  ClearItems;
  FDays := Days;
  if Length(Days) = 0 then
  begin
    SetMessage('Nenhuma grava'#$E7#$E3'o para esta c'#$E2'mera.');
    Exit;
  end;
  FLblEmpty.Visible := False;
  FList.Visible := True;
  // Do mais recente para o mais antigo: a API devolve em ordem crescente.
  //
  // O Y é atribuído à mão, e isso NÃO é decoração. O FMX ordena os irmãos
  // Align=Top comparando `C1.Top < C2.Top` (ver AlignObjects em FMX.Types):
  // não é a ordem de criação que manda, é a posição. Todo card nasce com Y = 0,
  // então a comparação empata e o desempate depende de quando o realinhamento
  // acontece — na primeira montagem saía certo por acidente, e ao reabrir a
  // lista saía embaralhado. Com Y crescente não há empate para desfazer.
  Y := 0;
  for I := High(Days) downto 0 do
  begin
    AddItem(Days[I], I).Position.Y := Y;
    Y := Y + ITEM_HEIGHT + ITEM_GAP;
  end;
end;

// A barra de cobertura acompanha a largura da lista (giro de tela, janela
// redimensionada). A fração está no Tag do fundo, em milésimos.
procedure TFrameDays.CoverResize(Sender: TObject);
var
  Track: TRectangle;
begin
  if not (Sender is TRectangle) then Exit;
  Track := TRectangle(Sender);
  if Track.ChildrenCount = 0 then Exit;
  if Track.Children[0] is TControl then
    TControl(Track.Children[0]).Width := Track.Width * (Track.Tag / 1000);
end;

procedure TFrameDays.ItemClick(Sender: TObject);
var
  Idx: Integer;
begin
  if not Assigned(FOnPickDay) then Exit;
  if not (Sender is TRectangle) then Exit;
  Idx := TRectangle(Sender).Tag;
  if (Idx < 0) or (Idx > High(FDays)) then Exit;
  FOnPickDay(Self, FDays[Idx].Day, FDays[Idx].StartMs, FDays[Idx].EndMs);
end;

end.
