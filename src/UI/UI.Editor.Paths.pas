unit UI.Editor.Paths;

// Lista de caminhos da tela de cadastro: os endereços da MESMA câmera (ver
// TCameraEndpoint), em ordem de tentativa, mais o "+ caminho" e o nome do
// caminho selecionado.
//
// Sai do UI.Editor por dois motivos. O primeiro é tamanho: era um pedaço de
// tela inteiro montado à mão no meio de um frame que já tem trinta componentes.
// O segundo é ordem: montado lá, ele entrava no scroll pelo fim e tinha que ser
// reposicionado por Index — e uma conta de índice errada mandava a barra (ou o
// vizinho) para o lugar errado da tela.
//
// A lista é VERTICAL de propósito. Em abas lado a lado, três caminhos já não
// cabiam na largura de um celular, e o nome de cada um ficava espremido em meia
// dúzia de caracteres. Na vertical cabe nome E endereço, a altura cresce à
// vontade (o scroll da tela de cadastro resolve) e sobra lugar para os botões
// de subir/descer — que são o que define a ORDEM DE TENTATIVA, a informação
// mais importante desta tela depois do endereço.
//
// TUDO AQUI É POSICIONADO POR COORDENADA (Align = None + SetBounds), de
// propósito. Vários irmãos com Align = Top criados em tempo de execução não
// empilham na ordem de criação no FMX: a primeira versão desta tela saiu com as
// linhas fora de ordem (1, 3, 2) e com o endereço impresso ACIMA do nome dentro
// de cada linha. Como esta tela já calcula todas as alturas para dizer ao
// hospedeiro de quanto ela precisa (ContentHeight), posicionar na mão não custa
// nada e não deixa margem para essa surpresa. É o mesmo caminho que UI.Days usa
// dentro dos cards.
//
// Ele não conhece TCameraEndpoint: recebe nome e endereço de cada caminho e
// devolve o que o usuário pediu (trocar, criar, apagar, renomear, mover). Quem
// guarda os endereços é o editor.

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

  // Os controles de uma linha. Guardados porque o posicionamento é na mão e
  // precisa acontecer de novo a cada mudança de largura.
  TPathRow = record
    Box: TRectangle;
    Num: TLabel;
    LblName: TLabel;
    LblAddr: TLabel;
    BtnUp: TRectangle;    // nil no primeiro caminho
    BtnDown: TRectangle;  // nil no último
    BtnDel: TRectangle;   // nil quando só existe um caminho
  end;

  TFrameCameraPaths = class(TLayout)
  private
    FLbl: TLabel;
    FList: TLayout;
    FBtnAdd: TRectangle;
    FEdName: TEdit;
    FLblHint: TLabel;
    FRows: TArray<TPathRow>;
    FSelected: Integer;
    FContentHeight: Single;
    FOnSelect: TPathIndexEvent;
    FOnAdd: TNotifyEvent;
    FOnRemove: TPathIndexEvent;
    FOnMoveUp: TPathIndexEvent;
    FOnMoveDown: TPathIndexEvent;
    FOnRename: TNotifyEvent;
    function MakeButton(AParent: TFmxObject; const AText: string; AColor: TAlphaColor;
      AIndex: Integer; AOnClick: TNotifyEvent): TRectangle;
    function MakeLabel(AParent: TFmxObject; ASize: Single; AColor: TAlphaColor): TLabel;
    procedure BuildRow(Index: Integer; const Name, Address: string; Last, Only: Boolean);
    procedure LayoutRow(Index: Integer; W: Single);
    procedure LayoutAll;
    procedure FrameResize(Sender: TObject);
    procedure RowClick(Sender: TObject);
    procedure UpClick(Sender: TObject);
    procedure DownClick(Sender: TObject);
    procedure DelClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure NameChange(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    // Redesenha a lista. Names/Addresses em ordem de prioridade; Selected é o
    // caminho que está na tela (os campos do editor mostram esse).
    procedure ShowPaths(const Names, Addresses: TArray<string>; Selected: Integer);
    procedure SetCurrentName(const S: string);
    function CurrentName: string;
    // Reflete na lista o nome que está sendo digitado, sem refazer as linhas.
    procedure RenameSelected(const S: string);
    // Altura que o hospedeiro precisa ter para a lista caber inteira. Muda com
    // a quantidade de caminhos, então o editor lê isto depois de cada ShowPaths.
    property ContentHeight: Single read FContentHeight;
    // O editor estiliza este campo com o mesmo fundo escuro dos outros e engata
    // o reposicionamento do teclado (ver SetupEdit lá).
    property NameEdit: TEdit read FEdName;
    property Selected: Integer read FSelected;
    property OnSelect: TPathIndexEvent read FOnSelect write FOnSelect;
    property OnAdd: TNotifyEvent read FOnAdd write FOnAdd;
    property OnRemove: TPathIndexEvent read FOnRemove write FOnRemove;
    property OnMoveUp: TPathIndexEvent read FOnMoveUp write FOnMoveUp;
    property OnMoveDown: TPathIndexEvent read FOnMoveDown write FOnMoveDown;
    property OnRename: TNotifyEvent read FOnRename write FOnRename;
  end;

implementation

const
  LBL_H     = 20;   // rótulo do topo
  GAP_LBL   = 6;
  ROW_H     = 48;   // cada caminho
  ROW_GAP   = 6;
  GAP_ADD   = 8;
  ADD_H     = 40;   // botão "+ caminho"
  GAP_NAME  = 8;
  NAME_H    = 36;   // campo do nome do caminho
  GAP_HINT  = 4;
  HINT_H    = 44;   // dica (duas ou três linhas em tela estreita)
  BTN_W     = 34;   // subir / descer / apagar
  BTN_GAP   = 4;
  NUM_W     = 30;   // coluna da posição na fila

constructor TFrameCameraPaths.Create(AOwner: TComponent);
var
  Cap: TLabel;
begin
  inherited;
  FSelected := 0;
  OnResize := FrameResize;

  FLbl := MakeLabel(Self, 12, COLOR_DIM);
  FLbl.Text := 'Caminhos at'#$E9' esta c'#$E2'mera (na ordem em que s'#$E3'o tentados)';

  FList := TLayout.Create(Self);
  FList.Parent := Self;
  FList.Align := TAlignLayout.None;

  FBtnAdd := TRectangle.Create(Self);
  FBtnAdd.Parent := Self;
  FBtnAdd.Align := TAlignLayout.None;
  FBtnAdd.XRadius := 6;
  FBtnAdd.YRadius := 6;
  FBtnAdd.Fill.Color := COLOR_SURFACE2;
  FBtnAdd.Stroke.Kind := TBrushKind.None;
  FBtnAdd.HitTest := True;
  FBtnAdd.OnClick := AddClick;

  Cap := TLabel.Create(Self);
  Cap.Parent := FBtnAdd;
  Cap.Align := TAlignLayout.Client;   // filho único: aqui não há ordem a errar
  Cap.HitTest := False;
  Cap.StyledSettings := [];
  Cap.TextSettings.FontColor := COLOR_TEXT;
  Cap.TextSettings.Font.Size := 14;
  Cap.TextSettings.HorzAlign := TTextAlign.Center;
  Cap.TextSettings.VertAlign := TTextAlign.Center;
  Cap.Text := '+ caminho';

  FEdName := TEdit.Create(Self);
  FEdName.Parent := Self;
  FEdName.Align := TAlignLayout.None;
  FEdName.TextPrompt := 'nome do caminho selecionado (Local, Online...)';
  FEdName.OnChangeTracking := NameChange;

  FLblHint := MakeLabel(Self, 11, COLOR_DIM);
  FLblHint.TextSettings.WordWrap := True;
  FLblHint.Text := '';
end;

function TFrameCameraPaths.MakeLabel(AParent: TFmxObject; ASize: Single;
  AColor: TAlphaColor): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Align := TAlignLayout.None;
  Result.HitTest := False;
  Result.StyledSettings := [];
  Result.TextSettings.FontColor := AColor;
  Result.TextSettings.Font.Size := ASize;
  Result.TextSettings.VertAlign := TTextAlign.Center;
end;

function TFrameCameraPaths.MakeButton(AParent: TFmxObject; const AText: string;
  AColor: TAlphaColor; AIndex: Integer; AOnClick: TNotifyEvent): TRectangle;
var
  Cap: TLabel;
begin
  Result := TRectangle.Create(Self);
  Result.Parent := AParent;
  Result.Align := TAlignLayout.None;
  Result.XRadius := 5;
  Result.YRadius := 5;
  Result.Fill.Color := COLOR_SURFACE;
  Result.Stroke.Kind := TBrushKind.None;
  Result.HitTest := True;
  Result.Tag := AIndex;
  Result.OnClick := AOnClick;

  Cap := TLabel.Create(Self);
  Cap.Parent := Result;
  Cap.Align := TAlignLayout.Client;   // filho único
  Cap.HitTest := False;
  Cap.StyledSettings := [];
  Cap.TextSettings.FontColor := AColor;
  Cap.TextSettings.Font.Size := 15;
  Cap.TextSettings.HorzAlign := TTextAlign.Center;
  Cap.TextSettings.VertAlign := TTextAlign.Center;
  Cap.Text := AText;
end;

// Uma linha: [n] nome / endereço .......... [↑] [↓] [×]
procedure TFrameCameraPaths.BuildRow(Index: Integer; const Name, Address: string;
  Last, Only: Boolean);
var
  R: TPathRow;
begin
  FillChar(R, SizeOf(R), 0);

  R.Box := TRectangle.Create(Self);
  R.Box.Parent := FList;
  R.Box.Align := TAlignLayout.None;
  R.Box.XRadius := 6;
  R.Box.YRadius := 6;
  R.Box.Stroke.Kind := TBrushKind.None;
  R.Box.HitTest := True;
  R.Box.Tag := Index;
  R.Box.OnClick := RowClick;
  if Index = FSelected then
    R.Box.Fill.Color := COLOR_ACCENT
  else
    R.Box.Fill.Color := COLOR_SURFACE2;

  // Posição na fila: é o que o usuário está ordenando, então vem primeiro e em
  // destaque, não escondido no meio do nome.
  R.Num := MakeLabel(R.Box, 15, COLOR_TEXT);
  R.Num.TextSettings.HorzAlign := TTextAlign.Center;
  R.Num.Text := IntToStr(Index + 1);

  R.LblName := MakeLabel(R.Box, 14, COLOR_TEXT);
  R.LblName.Text := Name;

  // No selecionado o fundo é claro; cinza sobre azul não se lê.
  if Index = FSelected then
    R.LblAddr := MakeLabel(R.Box, 11, COLOR_TEXT)
  else
    R.LblAddr := MakeLabel(R.Box, 11, COLOR_DIM);
  R.LblAddr.Text := Address;

  // Botão que não faria nada não aparece: o último caminho não se apaga, o
  // primeiro não sobe e o último não desce.
  if not Only then
    R.BtnDel := MakeButton(R.Box, #$00D7, COLOR_DANGER, Index, DelClick);
  if not Last then
    R.BtnDown := MakeButton(R.Box, #$2193, COLOR_TEXT, Index, DownClick);
  if Index > 0 then
    R.BtnUp := MakeButton(R.Box, #$2191, COLOR_TEXT, Index, UpClick);

  if Index >= Length(FRows) then
    SetLength(FRows, Index + 1);
  FRows[Index] := R;
end;

procedure TFrameCameraPaths.LayoutRow(Index: Integer; W: Single);
var
  R: TPathRow;
  X, TextW: Single;
begin
  R := FRows[Index];
  if R.Box = nil then Exit;
  R.Box.SetBounds(0, Index * (ROW_H + ROW_GAP), W, ROW_H);

  // Botões da direita para a esquerda, na ordem em que a mão os procura.
  X := W - BTN_GAP;
  if R.BtnDel <> nil then
  begin
    R.BtnDel.SetBounds(X - BTN_W, 6, BTN_W, ROW_H - 12);
    X := X - BTN_W - BTN_GAP;
  end;
  if R.BtnDown <> nil then
  begin
    R.BtnDown.SetBounds(X - BTN_W, 6, BTN_W, ROW_H - 12);
    X := X - BTN_W - BTN_GAP;
  end;
  if R.BtnUp <> nil then
  begin
    R.BtnUp.SetBounds(X - BTN_W, 6, BTN_W, ROW_H - 12);
    X := X - BTN_W - BTN_GAP;
  end;

  R.Num.SetBounds(2, 0, NUM_W, ROW_H);
  TextW := X - NUM_W - 6;
  if TextW < 40 then TextW := 40;
  R.LblName.SetBounds(NUM_W + 4, 5, TextW, 21);
  R.LblAddr.SetBounds(NUM_W + 4, 26, TextW, 17);
end;

procedure TFrameCameraPaths.LayoutAll;
var
  W, Y: Single;
  I: Integer;
  NameHost: TControl;
begin
  // A ALTURA não depende da largura, e quem pergunta por ela é o hospedeiro no
  // scroll (ContentHeight). Calcular sempre, mesmo sem largura ainda: sair sem
  // calcular deixaria o hospedeiro com altura zero, e um controle de altura
  // zero nunca recebe largura — não haveria segunda chance.
  FContentHeight := LBL_H + GAP_LBL + Length(FRows) * (ROW_H + ROW_GAP) +
    GAP_ADD + ADD_H + GAP_NAME + NAME_H + GAP_HINT + HINT_H + 4;

  W := Width;
  if W <= 0 then Exit;   // sem largura ainda; o OnResize traz de volta

  Y := 0;
  FLbl.SetBounds(0, Y, W, LBL_H);
  Y := Y + LBL_H + GAP_LBL;

  FList.SetBounds(0, Y, W, Length(FRows) * (ROW_H + ROW_GAP));
  for I := 0 to High(FRows) do
    LayoutRow(I, W);
  Y := Y + FList.Height + GAP_ADD;

  FBtnAdd.SetBounds(0, Y, W, ADD_H);
  Y := Y + ADD_H + GAP_NAME;

  // O SetupEdit do editor põe o campo dentro de um retângulo de fundo; quem
  // ocupa o lugar na tela passa a ser esse retângulo, não o TEdit.
  NameHost := FEdName;
  if (FEdName.Parent <> nil) and (FEdName.Parent is TControl) and
     (FEdName.Parent <> Self) then
    NameHost := TControl(FEdName.Parent);
  NameHost.SetBounds(0, Y, W, NAME_H);
  Y := Y + NAME_H + GAP_HINT;

  FLblHint.SetBounds(0, Y, W, HINT_H);
end;

procedure TFrameCameraPaths.FrameResize(Sender: TObject);
begin
  LayoutAll;
end;

procedure TFrameCameraPaths.ShowPaths(const Names, Addresses: TArray<string>;
  Selected: Integer);
var
  I: Integer;
  Addr: string;
begin
  if FList = nil then Exit;
  FSelected := Selected;
  for I := FList.ChildrenCount - 1 downto 0 do
    FList.Children[I].Free;
  SetLength(FRows, 0);
  SetLength(FRows, Length(Names));

  for I := 0 to High(Names) do
  begin
    if I <= High(Addresses) then Addr := Addresses[I] else Addr := '';
    BuildRow(I, Names[I], Addr, I = High(Names), Length(Names) = 1);
  end;
  LayoutAll;

  if Length(Names) > 1 then
    FLblHint.Text := Format('Os campos abaixo s'#$E3'o do caminho %d. Antes de cada' +
      ' conex'#$E3'o o app testa nesta ordem e usa o primeiro que responder;' +
      ' use as setas para mudar a ordem.', [FSelected + 1])
  else
    FLblHint.Text := 'Os campos abaixo s'#$E3'o deste caminho. Toque em "+ caminho" para' +
      ' cadastrar outro endere'#$E7'o da MESMA c'#$E2'mera (pela LAN, pelo servidor, pelo Tailscale).';
end;

procedure TFrameCameraPaths.SetCurrentName(const S: string);
begin
  FEdName.Text := S;
end;

procedure TFrameCameraPaths.RenameSelected(const S: string);
begin
  if (FSelected >= 0) and (FSelected <= High(FRows)) and
     (FRows[FSelected].LblName <> nil) then
    FRows[FSelected].LblName.Text := S;
end;

function TFrameCameraPaths.CurrentName: string;
begin
  Result := Trim(FEdName.Text);
end;

procedure TFrameCameraPaths.RowClick(Sender: TObject);
begin
  if not (Sender is TRectangle) then Exit;
  if Assigned(FOnSelect) then FOnSelect(Self, TRectangle(Sender).Tag);
end;

procedure TFrameCameraPaths.UpClick(Sender: TObject);
begin
  if not (Sender is TRectangle) then Exit;
  if Assigned(FOnMoveUp) then FOnMoveUp(Self, TRectangle(Sender).Tag);
end;

procedure TFrameCameraPaths.DownClick(Sender: TObject);
begin
  if not (Sender is TRectangle) then Exit;
  if Assigned(FOnMoveDown) then FOnMoveDown(Self, TRectangle(Sender).Tag);
end;

procedure TFrameCameraPaths.DelClick(Sender: TObject);
begin
  if not (Sender is TRectangle) then Exit;
  if Assigned(FOnRemove) then FOnRemove(Self, TRectangle(Sender).Tag);
end;

procedure TFrameCameraPaths.AddClick(Sender: TObject);
begin
  if Assigned(FOnAdd) then FOnAdd(Self);
end;

procedure TFrameCameraPaths.NameChange(Sender: TObject);
begin
  if Assigned(FOnRename) then FOnRename(Self);
end;

end.
