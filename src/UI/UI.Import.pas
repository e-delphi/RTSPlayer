unit UI.Import;

// Tela de importar câmeras: uma caixa de texto onde se cola o JSON exportado do
// outro aparelho.
//
// É texto e não arquivo de propósito. O caminho real do usuário é exportar,
// mandar por WhatsApp e colar aqui — e texto atravessa qualquer app de mensagem
// sem depender de permissão de armazenamento, de SAF, nem de o outro app saber
// abrir uma extensão nossa.
//
// Montada em código, sem .fmx, como UI.Days e UI.Timeline.

interface

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  FMX.Types,
  FMX.Controls,
  FMX.Graphics,
  FMX.Objects,
  FMX.Layouts,
  FMX.StdCtrls,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.ScrollBox,
  UI.Common;

type
  TImportTextEvent = procedure(Sender: TObject; const Text: string) of object;

  TFrameImport = class(TLayout)
  private
    FTop: TRectangle;
    FBtnBack: TRectangle;
    FPathBack: TPath;
    FLblTitle: TLabel;
    FMemo: TMemo;
    FLblHint: TLabel;
    FBtnPaste: TRectangle;
    FBtnDo: TRectangle;
    FLblResult: TLabel;
    FOnBack: TNotifyEvent;
    FOnPaste: TNotifyEvent;
    FOnImport: TImportTextEvent;
    function MakeButton(const AText: string; AFill: TAlphaColor;
      AOnClick: TNotifyEvent): TRectangle;
    procedure BackClick(Sender: TObject);
    procedure PasteClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Reset;
    procedure SetText(const S: string);
    procedure SetResult(const S: string; Bad: Boolean);
    property OnBack: TNotifyEvent read FOnBack write FOnBack;
    property OnPaste: TNotifyEvent read FOnPaste write FOnPaste;
    property OnImport: TImportTextEvent read FOnImport write FOnImport;
  end;

implementation

constructor TFrameImport.Create(AOwner: TComponent);
var
  Bg: TRectangle;
  Row: TLayout;
begin
  inherited;

  Bg := TRectangle.Create(Self);
  Bg.Parent := Self;
  Bg.Align := TAlignLayout.Contents;
  Bg.Fill.Color := COLOR_BG;
  Bg.Stroke.Kind := TBrushKind.None;
  Bg.HitTest := False;

  FTop := TRectangle.Create(Self);
  FTop.Parent := Self;
  FTop.Align := TAlignLayout.Top;
  FTop.Height := 56;
  FTop.Fill.Color := COLOR_SURFACE;
  FTop.Stroke.Kind := TBrushKind.None;

  FBtnBack := TRectangle.Create(Self);
  FBtnBack.Parent := FTop;
  FBtnBack.Align := TAlignLayout.Left;
  FBtnBack.Width := 56;
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
  FLblTitle.StyledSettings := [];
  FLblTitle.TextSettings.FontColor := COLOR_TEXT;
  FLblTitle.TextSettings.Font.Size := 16;
  FLblTitle.Text := 'Importar c'#$E2'meras';

  // Rodapé com os dois botões: alinhado ao fundo, fica sempre alcançável e não
  // disputa espaço com a caixa de texto quando o teclado abre.
  Row := TLayout.Create(Self);
  Row.Parent := Self;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := 56;
  Row.Margins.Left := 12;
  Row.Margins.Right := 12;
  Row.Margins.Bottom := 8;

  FBtnDo := MakeButton('Importar', COLOR_ACCENT, ImportClick);
  FBtnDo.Parent := Row;
  FBtnDo.Align := TAlignLayout.Client;
  FBtnDo.Margins.Left := 8;

  FBtnPaste := MakeButton('Colar', COLOR_SURFACE2, PasteClick);
  FBtnPaste.Parent := Row;
  FBtnPaste.Align := TAlignLayout.Left;
  FBtnPaste.Width := 110;

  FLblResult := TLabel.Create(Self);
  FLblResult.Parent := Self;
  FLblResult.Align := TAlignLayout.Bottom;
  FLblResult.Height := 34;
  FLblResult.Margins.Left := 14;
  FLblResult.Margins.Right := 14;
  FLblResult.StyledSettings := [];
  FLblResult.TextSettings.Font.Size := 12;
  FLblResult.TextSettings.FontColor := COLOR_DIM;
  FLblResult.TextSettings.WordWrap := True;
  FLblResult.Text := '';

  FLblHint := TLabel.Create(Self);
  FLblHint.Parent := Self;
  FLblHint.Align := TAlignLayout.Top;
  FLblHint.Height := 52;
  FLblHint.Margins.Left := 14;
  FLblHint.Margins.Right := 14;
  FLblHint.Margins.Top := 6;
  FLblHint.StyledSettings := [];
  FLblHint.TextSettings.Font.Size := 12;
  FLblHint.TextSettings.FontColor := COLOR_DIM;
  FLblHint.TextSettings.WordWrap := True;
  FLblHint.Text := 'Cole aqui o texto exportado do outro aparelho. C'#$E2'mera com o' +
    ' mesmo nome '#$E9' atualizada; as demais s'#$E3'o acrescentadas.';

  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := TAlignLayout.Client;
  FMemo.Margins.Left := 12;
  FMemo.Margins.Right := 12;
  FMemo.Margins.Top := 4;
  FMemo.Margins.Bottom := 4;
  // Cor e fonte ficam com o estilo da plataforma, como no memo do log: mexer só
  // no tamanho evita texto branco em fundo branco quando o estilo é claro.
  FMemo.StyledSettings := FMemo.StyledSettings - [TStyledSetting.Size];
  FMemo.TextSettings.Font.Size := 12;
  FMemo.WordWrap := True;
  // Os mesmos gestos do memo de log: sem LongTap não aparece o menu nativo de
  // colar, que é justamente como o texto entra aqui.
  FMemo.Touch.InteractiveGestures := [TInteractiveGesture.Pan,
    TInteractiveGesture.LongTap, TInteractiveGesture.DoubleTap];
end;

function TFrameImport.MakeButton(const AText: string; AFill: TAlphaColor;
  AOnClick: TNotifyEvent): TRectangle;
var
  Cap: TLabel;
begin
  Result := TRectangle.Create(Self);
  Result.XRadius := 8;
  Result.YRadius := 8;
  Result.Fill.Color := AFill;
  Result.Stroke.Kind := TBrushKind.None;
  Result.HitTest := True;
  Result.OnClick := AOnClick;

  Cap := TLabel.Create(Self);
  Cap.Parent := Result;
  Cap.Align := TAlignLayout.Client;
  Cap.HitTest := False;
  Cap.StyledSettings := [];
  Cap.TextSettings.FontColor := COLOR_TEXT;
  Cap.TextSettings.Font.Size := 15;
  Cap.TextSettings.HorzAlign := TTextAlign.Center;
  Cap.TextSettings.VertAlign := TTextAlign.Center;
  Cap.Text := AText;
end;

procedure TFrameImport.Reset;
begin
  FMemo.Text := '';
  FLblResult.Text := '';
end;

procedure TFrameImport.SetText(const S: string);
begin
  FMemo.Text := S;
end;

procedure TFrameImport.SetResult(const S: string; Bad: Boolean);
begin
  if Bad then
    FLblResult.TextSettings.FontColor := COLOR_DANGER
  else
    FLblResult.TextSettings.FontColor := COLOR_DIM;
  FLblResult.Text := S;
end;

procedure TFrameImport.BackClick(Sender: TObject);
begin
  if Assigned(FOnBack) then FOnBack(Self);
end;

procedure TFrameImport.PasteClick(Sender: TObject);
begin
  if Assigned(FOnPaste) then FOnPaste(Self);
end;

procedure TFrameImport.ImportClick(Sender: TObject);
begin
  if Assigned(FOnImport) then FOnImport(Self, FMemo.Text);
end;

end.
