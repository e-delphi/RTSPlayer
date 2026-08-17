unit UI.List;

// Frame da lista de câmeras. Renderiza os cards e avisa o shell (via eventos)
// quando o usuário quer adicionar, tocar, editar ou remover uma câmera.

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  System.Generics.Collections,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.Dialogs, FMX.StdCtrls,
  FMX.Objects, FMX.Controls.Presentation, FMX.Layouts,
  VMS.App.Config,
  UI.Common;

type
  TFrameList = class(TFrame)
    barList: TRectangle;
    lblTitle: TLabel;
    btnAdd: TRectangle;
    pathAdd: TPath;
    btnEdit: TRectangle;
    lblEditMode: TLabel;
    sbCameras: TVertScrollBox;
  private
    FCameras: TArray<TCameraConfigEntry>;
    FCards: TList<TRectangle>;
    FEmptyLabel: TLabel; // mensagem de lista vazia (criada em código)
    FEditMode: Boolean;
    FOnAdd: TNotifyEvent;
    FOnPlay: TCamIndexEvent;
    FOnEdit: TCamIndexEvent;
    FOnDelete: TCamIndexEvent;
    procedure ClearCards;
    procedure RefreshList;
    procedure btnAddClick(Sender: TObject);
    procedure btnEditClick(Sender: TObject);
    procedure CardClick(Sender: TObject);
    procedure CardDeleteClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetCameras(const Cameras: TArray<TCameraConfigEntry>);
    procedure ResetEditMode;
    property OnAdd: TNotifyEvent read FOnAdd write FOnAdd;
    property OnPlayCamera: TCamIndexEvent read FOnPlay write FOnPlay;
    property OnEditCamera: TCamIndexEvent read FOnEdit write FOnEdit;
    property OnDeleteCamera: TCamIndexEvent read FOnDelete write FOnDelete;
  end;

implementation

{$R *.fmx}

constructor TFrameList.Create(AOwner: TComponent);
begin
  inherited;
  FCards := TList<TRectangle>.Create;
  pathAdd.Data.Data := ICON_ADD;
  btnAdd.OnClick := btnAddClick;
  btnEdit.OnClick := btnEditClick;

  // Mensagem centralizada quando não há nenhuma câmera.
  FEmptyLabel := TLabel.Create(Self);
  FEmptyLabel.Parent := Self;
  FEmptyLabel.Align := TAlignLayout.Client;
  FEmptyLabel.Margins.Rect := RectF(24, 24, 24, 24);
  FEmptyLabel.HitTest := False;
  FEmptyLabel.StyledSettings := FEmptyLabel.StyledSettings - [TStyledSetting.FontColor];
  FEmptyLabel.TextSettings.FontColor := COLOR_DIM;
  FEmptyLabel.TextSettings.HorzAlign := TTextAlign.Center;
  FEmptyLabel.TextSettings.VertAlign := TTextAlign.Center;
  FEmptyLabel.Text := 'Nenhuma câmera — toque em + para adicionar';
  FEmptyLabel.Visible := False;
end;

destructor TFrameList.Destroy;
begin
  ClearCards;
  FCards.Free;
  inherited;
end;

procedure TFrameList.SetCameras(const Cameras: TArray<TCameraConfigEntry>);
begin
  FCameras := Cameras;
  RefreshList;
end;

procedure TFrameList.ResetEditMode;
begin
  if FEditMode then
  begin
    FEditMode := False;
    lblEditMode.Text := 'Editar';
    RefreshList;
  end;
end;

procedure TFrameList.ClearCards;
var
  I: Integer;
begin
  if FCards = nil then Exit;
  for I := FCards.Count - 1 downto 0 do
    FCards[I].Free;
  FCards.Clear;
end;

procedure TFrameList.RefreshList;
var
  I: Integer;
  Card, Trash: TRectangle;
  LblN, LblU: TLabel;
  PTrash: TPath;
  Cap: string;
begin
  ClearCards;
  if FEmptyLabel <> nil then
    FEmptyLabel.Visible := Length(FCameras) = 0;
  for I := 0 to High(FCameras) do
  begin
    Card := TRectangle.Create(Self);
    Card.Parent := sbCameras;
    Card.Align := TAlignLayout.Top;
    // Y crescente: o Align=Top do FMX ordena os irmãos pelo Position.Y; sem isso
    // (todos em Y=0) o sort fica instável e a lista reordena a cada RefreshList.
    Card.Position.Y := I * 82;
    Card.Height := 72;
    Card.Margins.Rect := RectF(12, 10, 12, 0);
    Card.XRadius := 12;
    Card.YRadius := 12;
    Card.Fill.Color := COLOR_SURFACE;
    Card.Stroke.Kind := TBrushKind.None;
    Card.HitTest := True;
    Card.Tag := I;
    Card.OnClick := CardClick;
    FCards.Add(Card);

    Trash := TRectangle.Create(Card);
    Trash.Parent := Card;
    Trash.Align := TAlignLayout.Right;
    Trash.Width := 56;
    Trash.Fill.Kind := TBrushKind.None;
    Trash.Stroke.Kind := TBrushKind.None;
    Trash.HitTest := True;
    Trash.Tag := I;
    Trash.Visible := FEditMode;
    Trash.OnClick := CardDeleteClick;
    PTrash := TPath.Create(Trash);
    PTrash.Parent := Trash;
    PTrash.Align := TAlignLayout.Center;
    PTrash.Width := 22;
    PTrash.Height := 22;
    PTrash.HitTest := False;
    PTrash.Stroke.Kind := TBrushKind.None;
    PTrash.Fill.Color := COLOR_DANGER;
    PTrash.Data.Data := ICON_TRASH;

    LblN := TLabel.Create(Card);
    LblN.Parent := Card;
    LblN.Align := TAlignLayout.Top;
    LblN.Height := 28;
    LblN.Margins.Rect := RectF(16, 10, 8, 0);
    LblN.HitTest := False;
    LblN.StyledSettings := LblN.StyledSettings - [TStyledSetting.FontColor, TStyledSetting.Size];
    LblN.TextSettings.FontColor := COLOR_TEXT;
    LblN.TextSettings.Font.Size := 16;
    Cap := FCameras[I].Name;
    if Cap = '' then Cap := FCameras[I].Url;
    LblN.Text := Cap;

    LblU := TLabel.Create(Card);
    LblU.Parent := Card;
    LblU.Align := TAlignLayout.Top;
    LblU.Height := 20;
    LblU.Margins.Rect := RectF(16, 0, 8, 0);
    LblU.HitTest := False;
    LblU.StyledSettings := LblU.StyledSettings - [TStyledSetting.FontColor, TStyledSetting.Size];
    LblU.TextSettings.FontColor := COLOR_DIM;
    LblU.TextSettings.Font.Size := 12;
    // Com mais de um caminho até a câmera, a URL sozinha mentiria (quem conecta
    // escolhe na hora): mostra o principal e quantos caminhos existem.
    if Length(FCameras[I].Endpoints) > 1 then
      LblU.Text := Format('%s   ·   %d conex'#$F5'es',
        [FCameras[I].Url, Length(FCameras[I].Endpoints)])
    else
      LblU.Text := FCameras[I].Url + '   ·   ' + TransportsToStr(FCameras[I].Transports);
  end;
end;

procedure TFrameList.CardClick(Sender: TObject);
var
  Idx: Integer;
begin
  if not (Sender is TRectangle) then Exit;
  Idx := TRectangle(Sender).Tag;
  if FEditMode then
  begin
    if Assigned(FOnEdit) then FOnEdit(Self, Idx);
  end
  else
    if Assigned(FOnPlay) then FOnPlay(Self, Idx);
end;

procedure TFrameList.CardDeleteClick(Sender: TObject);
var
  Idx: Integer;
begin
  if not (Sender is TRectangle) then Exit;
  Idx := TRectangle(Sender).Tag;
  if Assigned(FOnDelete) then FOnDelete(Self, Idx);
end;

procedure TFrameList.btnAddClick(Sender: TObject);
begin
  if Assigned(FOnAdd) then FOnAdd(Self);
end;

procedure TFrameList.btnEditClick(Sender: TObject);
begin
  FEditMode := not FEditMode;
  if FEditMode then
    lblEditMode.Text := 'Concluir'
  else
    lblEditMode.Text := 'Editar';
  RefreshList;
end;

end.
