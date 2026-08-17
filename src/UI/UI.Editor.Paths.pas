unit UI.Editor.Paths;

// Barra de caminhos da tela de cadastro: as abas dos endereços da MESMA câmera
// (ver TCameraEndpoint), o "+ caminho", o "x", o nome do caminho e a dica.
//
// Sai do UI.Editor por dois motivos. O primeiro é tamanho: era um pedaço de
// tela inteiro montado à mão no meio de um frame que já tem trinta componentes.
// O segundo é ordem: montado lá, ele entrava no scroll pelo fim e tinha que ser
// reposicionado por Index — e uma conta de índice errada mandava a barra (ou o
// vizinho) para o lugar errado da tela. Aqui ele é um controle só, que o
// designer coloca onde quiser dentro de um layout hospedeiro.
//
// Ele não conhece TCameraEndpoint: recebe os NOMES dos caminhos e devolve o que
// o usuário pediu (trocar, criar, apagar, renomear). Quem guarda os endereços é
// o editor.

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
  FMX.Edit,
  UI.Common;

type
  TPathIndexEvent = procedure(Sender: TObject; Index: Integer) of object;

  TFrameCameraPaths = class(TLayout)
  private
    FRow: TLayout;
    FTabs: TLayout;
    FBtnAdd: TRectangle;
    FBtnDel: TRectangle;
    FEdName: TEdit;
    FLblHint: TLabel;
    FCount: Integer;
    FSelected: Integer;
    FOnSelect: TPathIndexEvent;
    FOnAdd: TNotifyEvent;
    FOnRemove: TNotifyEvent;
    FOnRename: TNotifyEvent;
    function MakeButton(const AText: string; AWidth: Single; AColor: TAlphaColor;
      AOnClick: TNotifyEvent): TRectangle;
    procedure LayoutTabs;
    procedure TabsResize(Sender: TObject);
    procedure TabClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure DelClick(Sender: TObject);
    procedure NameChange(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    // Redesenha as abas. Names em ordem de prioridade; Selected é a que está na
    // tela (os campos do editor mostram esse caminho).
    procedure ShowPaths(const Names: TArray<string>; Selected: Integer);
    procedure SetCurrentName(const S: string);
    function CurrentName: string;
    // O editor estiliza este campo com o mesmo fundo escuro dos outros e engata
    // o reposicionamento do teclado (ver SetupEdit lá).
    property NameEdit: TEdit read FEdName;
    property Selected: Integer read FSelected;
    property OnSelect: TPathIndexEvent read FOnSelect write FOnSelect;
    property OnAdd: TNotifyEvent read FOnAdd write FOnAdd;
    property OnRemove: TNotifyEvent read FOnRemove write FOnRemove;
    property OnRename: TNotifyEvent read FOnRename write FOnRename;
  end;

// Altura que o hospedeiro precisa ter no designer para a barra caber inteira.
const
  PATHS_BAR_HEIGHT = 152;

implementation

constructor TFrameCameraPaths.Create(AOwner: TComponent);
var
  Lbl: TLabel;
begin
  inherited;
  FSelected := 0;
  FCount := 0;

  Lbl := TLabel.Create(Self);
  Lbl.Parent := Self;
  Lbl.Align := TAlignLayout.Top;
  Lbl.Height := 20;
  Lbl.StyledSettings := [];
  Lbl.TextSettings.FontColor := COLOR_DIM;
  Lbl.TextSettings.Font.Size := 12;
  Lbl.Text := 'Caminhos at'#$E9' esta c'#$E2'mera (em ordem de prioridade)';

  // Abas e botões numa fila só: soltos no corpo da barra, eles disputavam a
  // altura com o rótulo e o campo de baixo e acabavam com altura zero — era por
  // isso que o "+" não aparecia na tela.
  FRow := TLayout.Create(Self);
  FRow.Parent := Self;
  FRow.Align := TAlignLayout.Top;
  FRow.Height := 40;
  FRow.Margins.Top := 6;

  // Criado primeiro = mais à direita. O "+" fica na quina, que é onde a mão vai.
  FBtnAdd := MakeButton('+ caminho', 104, COLOR_TEXT, AddClick);
  FBtnDel := MakeButton('x', 40, COLOR_DANGER, DelClick);

  FTabs := TLayout.Create(Self);
  FTabs.Parent := FRow;
  FTabs.Align := TAlignLayout.Client;
  FTabs.OnResize := TabsResize;

  // Alinhados ao fundo: o primeiro criado fica mais abaixo, então a dica é o
  // último item da barra e o campo de nome fica logo acima dela.
  FLblHint := TLabel.Create(Self);
  FLblHint.Parent := Self;
  FLblHint.Align := TAlignLayout.Bottom;
  FLblHint.Height := 34;
  FLblHint.StyledSettings := [];
  FLblHint.TextSettings.FontColor := COLOR_DIM;
  FLblHint.TextSettings.Font.Size := 11;
  FLblHint.TextSettings.WordWrap := True;
  FLblHint.Text := '';

  FEdName := TEdit.Create(Self);
  FEdName.Parent := Self;
  FEdName.Align := TAlignLayout.Bottom;
  FEdName.Height := 36;
  FEdName.Margins.Bottom := 4;
  FEdName.TextPrompt := 'nome deste caminho (Local, Online...)';
  FEdName.OnChangeTracking := NameChange;
end;

function TFrameCameraPaths.MakeButton(const AText: string; AWidth: Single;
  AColor: TAlphaColor; AOnClick: TNotifyEvent): TRectangle;
var
  Cap: TLabel;
begin
  Result := TRectangle.Create(Self);
  Result.Parent := FRow;
  Result.Align := TAlignLayout.Right;
  Result.Width := AWidth;
  Result.Margins.Left := 6;
  Result.XRadius := 6;
  Result.YRadius := 6;
  Result.Fill.Color := COLOR_SURFACE2;
  Result.Stroke.Kind := TBrushKind.None;
  Result.HitTest := True;
  Result.OnClick := AOnClick;

  Cap := TLabel.Create(Self);
  Cap.Parent := Result;
  Cap.Align := TAlignLayout.Client;
  Cap.HitTest := False;
  Cap.StyledSettings := [];
  Cap.TextSettings.FontColor := AColor;
  Cap.TextSettings.Font.Size := 14;
  Cap.TextSettings.HorzAlign := TTextAlign.Center;
  Cap.TextSettings.VertAlign := TTextAlign.Center;
  Cap.Text := AText;
end;

// As abas dividem a largura que sobra dos botões. Sem isso, três caminhos de 96
// px estouram a fila num celular e o terceiro fica fora da tela.
procedure TFrameCameraPaths.LayoutTabs;
var
  I, N: Integer;
  W, TabW: Single;
begin
  if FTabs = nil then Exit;
  N := FTabs.ChildrenCount;
  W := FTabs.Width;
  if (N = 0) or (W <= 0) then Exit;
  TabW := (W / N) - 6;
  if TabW > 140 then TabW := 140;
  if TabW < 54 then TabW := 54;
  for I := 0 to N - 1 do
    if FTabs.Children[I] is TControl then
      TControl(FTabs.Children[I]).Width := TabW;
end;

procedure TFrameCameraPaths.TabsResize(Sender: TObject);
begin
  LayoutTabs;
end;

procedure TFrameCameraPaths.ShowPaths(const Names: TArray<string>; Selected: Integer);
var
  I: Integer;
  Tab: TRectangle;
  Cap: TLabel;
begin
  if FTabs = nil then Exit;
  FCount := Length(Names);
  FSelected := Selected;
  for I := FTabs.ChildrenCount - 1 downto 0 do
    FTabs.Children[I].Free;

  for I := 0 to High(Names) do
  begin
    Tab := TRectangle.Create(Self);
    Tab.Parent := FTabs;
    Tab.Align := TAlignLayout.Left;
    Tab.Width := 96;          // provisório; LayoutTabs ajusta à largura real
    Tab.Margins.Right := 6;
    Tab.XRadius := 6;
    Tab.YRadius := 6;
    Tab.Stroke.Kind := TBrushKind.None;
    Tab.HitTest := True;
    Tab.Tag := I;
    Tab.OnClick := TabClick;
    if I = FSelected then
      Tab.Fill.Color := COLOR_ACCENT
    else
      Tab.Fill.Color := COLOR_SURFACE2;

    Cap := TLabel.Create(Self);
    Cap.Parent := Tab;
    Cap.Align := TAlignLayout.Client;
    Cap.HitTest := False;
    Cap.StyledSettings := [];
    Cap.TextSettings.FontColor := COLOR_TEXT;
    Cap.TextSettings.Font.Size := 13;
    Cap.TextSettings.HorzAlign := TTextAlign.Center;
    Cap.TextSettings.VertAlign := TTextAlign.Center;
    // o primeiro é o preferido; os outros só entram se ele não responder
    Cap.Text := Format('%d. %s', [I + 1, Names[I]]);
  end;
  LayoutTabs;

  // O último caminho não se apaga, então o botão some em vez de ficar ali sem
  // fazer nada quando só há um.
  FBtnDel.Visible := FCount > 1;

  if FCount > 1 then
    FLblHint.Text := Format('%d caminhos: os campos abaixo s'#$E3'o do caminho %d.' +
      ' Antes de cada conex'#$E3'o o app testa na ordem e usa o primeiro que responder.',
      [FCount, FSelected + 1])
  else
    FLblHint.Text := 'Os campos abaixo s'#$E3'o deste caminho. Toque em "+ caminho" para' +
      ' cadastrar outro endere'#$E7'o da MESMA c'#$E2'mera (pela LAN, pelo servidor, pelo Tailscale).';
end;

procedure TFrameCameraPaths.SetCurrentName(const S: string);
begin
  FEdName.Text := S;
end;

function TFrameCameraPaths.CurrentName: string;
begin
  Result := Trim(FEdName.Text);
end;

procedure TFrameCameraPaths.TabClick(Sender: TObject);
begin
  if not (Sender is TRectangle) then Exit;
  if Assigned(FOnSelect) then FOnSelect(Self, TRectangle(Sender).Tag);
end;

procedure TFrameCameraPaths.AddClick(Sender: TObject);
begin
  if Assigned(FOnAdd) then FOnAdd(Self);
end;

procedure TFrameCameraPaths.DelClick(Sender: TObject);
begin
  if Assigned(FOnRemove) then FOnRemove(Self);
end;

procedure TFrameCameraPaths.NameChange(Sender: TObject);
begin
  if Assigned(FOnRename) then FOnRename(Self);
end;

end.
