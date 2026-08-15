unit UI.Editor;

// Frame de configuração da câmera. Autocontido: decompõe/recompõe a URL, seleciona
// protocolo e transporte, mostra/oculta senha e testa a conexão (só handshake).
// Avisa o shell via OnSave / OnCancel / OnDelete.

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  System.SyncObjs,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.Dialogs, FMX.StdCtrls,
  FMX.Layouts, FMX.Edit, FMX.Controls.Presentation, FMX.Objects, FMX.Ani,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.Session,
  VMS.Dvrip.Session,
  VMS.App.Config,
  VMS.App.Composition,
  UI.Common;

type
  TFrameEditor = class(TFrame)
    barEdit: TRectangle;
    btnCancel: TRectangle;
    lblCancel: TLabel;
    btnSave: TRectangle;
    lblSave: TLabel;
    lblEditTitle: TLabel;
    btnDelete: TRectangle;
    lblDelete: TLabel;
    sbEditor: TVertScrollBox;
    edName: TEdit;
    lblProto: TLabel;
    layProto: TLayout;
    chipRtsp: TRectangle;
    lblChipRtsp: TLabel;
    chipDvrip: TRectangle;
    lblChipDvrip: TLabel;
    edHost: TEdit;
    edPort: TEdit;
    edPath: TEdit;
    edUser: TEdit;
    edPass: TEdit;
    btnShowPass: TRectangle;
    lblShowPass: TLabel;
    lblTransp: TLabel;
    layChips: TLayout;
    chipAuto: TRectangle;
    lblChipAuto: TLabel;
    chipTcpUdp: TRectangle;
    lblChipTcpUdp: TLabel;
    chipUdpTcp: TRectangle;
    lblChipUdpTcp: TLabel;
    chipTcp: TRectangle;
    lblChipTcp: TLabel;
    chipUdp: TRectangle;
    lblChipUdp: TLabel;
    lblMaxRetries: TLabel;
    edMaxRetries: TEdit;
    lblAudioDelay: TLabel;
    edAudioDelay: TEdit;
    lblVideoDelay: TLabel;
    edVideoDelay: TEdit;
    lblTailscale: TLabel;
    swTailscale: TSwitch;
    Layout1: TLayout;
    btnTestConn: TRectangle;
    lblTestConn: TLabel;
    lblTestResult: TLabel;
  private
    FAppCfg: TAppConfig;
    FLogger: ILogger;
    FClock: IClock;
    FChips: array[0..4] of TRectangle;
    FSelectedChip: Integer;
    FSelectedProto: Integer; // 0=rtsp, 1=dvrip
    FEditIndex: Integer;
    FKbShown: Boolean;
    FKbTop: Single;
    FLayBody: TLayout;
    FOnSave: TCamEntryEvent;
    FOnCancel: TNotifyEvent;
    FOnDelete: TCamIndexEvent;
    procedure SetupEdit(E: TEdit);
    function WrapEditBackground(E: TEdit): TRectangle;
    procedure EditApplyStyle(Sender: TObject);
    procedure EditEnter(Sender: TObject);
    procedure SelectChip(Idx: Integer);
    procedure SelectProto(Idx: Integer);
    procedure chipClick(Sender: TObject);
    procedure protoChipClick(Sender: TObject);
    procedure btnShowPassClick(Sender: TObject);
    procedure btnTestConnClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnDeleteClick(Sender: TObject);
    procedure AdjustForFocused(Ctrl: TControl);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Bind(const AppCfg: TAppConfig; const Logger: ILogger; const Clock: IClock);
    procedure LoadEntry(Index: Integer; const Cameras: TArray<TCameraConfigEntry>);
    procedure KeyboardShown(KbTop: Single; FocusedCtrl: TControl);
    procedure KeyboardHidden;
    property OnSave: TCamEntryEvent read FOnSave write FOnSave;
    property OnCancel: TNotifyEvent read FOnCancel write FOnCancel;
    property OnDelete: TCamIndexEvent read FOnDelete write FOnDelete;
  end;

implementation

{$R *.fmx}

constructor TFrameEditor.Create(AOwner: TComponent);
begin
  inherited;
  FEditIndex := -1;

  // Envolve o scrollbox num container próprio (FLayBody). Assim eu subo só os
  // campos animando o Padding.Top DESSE container, mantendo a barEdit (topo) fixa.
  // FLayBody vai pra trás pra barEdit/btnDelete ficarem por cima (a barEdit é
  // opaca e cobre os campos que passam por baixo dela).
  FLayBody := TLayout.Create(Self);
  FLayBody.Parent := Self;
  FLayBody.Align := TAlignLayout.Client;
  sbEditor.Parent := FLayBody;
  sbEditor.Align := TAlignLayout.Client;
  FLayBody.SendToBack;

  FChips[0] := chipAuto;
  FChips[1] := chipTcpUdp;
  FChips[2] := chipUdpTcp;
  FChips[3] := chipTcp;
  FChips[4] := chipUdp;
  // Tags no código (independe do .fmx) para a lógica dos chips funcionar.
  chipAuto.Tag := 0;
  chipTcpUdp.Tag := 1;
  chipUdpTcp.Tag := 2;
  chipTcp.Tag := 3;
  chipUdp.Tag := 4;
  chipRtsp.Tag := 0;
  chipDvrip.Tag := 1;

  chipAuto.OnClick := chipClick;
  chipTcpUdp.OnClick := chipClick;
  chipUdpTcp.OnClick := chipClick;
  chipTcp.OnClick := chipClick;
  chipUdp.OnClick := chipClick;
  chipRtsp.OnClick := protoChipClick;
  chipDvrip.OnClick := protoChipClick;
  btnCancel.OnClick := btnCancelClick;
  btnSave.OnClick := btnSaveClick;
  btnDelete.OnClick := btnDeleteClick;
  btnShowPass.OnClick := btnShowPassClick;
  btnTestConn.OnClick := btnTestConnClick;

  // Campos escuros com texto claro (o estilo padrão pinta o fundo de branco no
  // Windows e usa texto escuro, ilegível no tema escuro do app) + OnEnter para
  // reposicionar o scroll ao trocar de campo com o teclado já aberto (o
  // OnVirtualKeyboardShown nem sempre dispara de novo).
  SetupEdit(edName);
  SetupEdit(edHost);
  SetupEdit(edPort);
  SetupEdit(edPath);
  SetupEdit(edUser);
  SetupEdit(edPass);
  SetupEdit(edMaxRetries);
  SetupEdit(edAudioDelay);
  SetupEdit(edVideoDelay);

  SelectChip(0);
  SelectProto(0);
end;

procedure TFrameEditor.Bind(const AppCfg: TAppConfig; const Logger: ILogger;
  const Clock: IClock);
begin
  FAppCfg := AppCfg;
  FLogger := Logger;
  FClock := Clock;
end;

procedure TFrameEditor.LoadEntry(Index: Integer; const Cameras: TArray<TCameraConfigEntry>);
var
  Proto, Host, Port, Path: string;
begin
  FEditIndex := Index;
  edPass.Password := True;
  lblShowPass.Text := 'Mostrar';
  lblTestResult.Text := '';
  if (Index >= 0) and (Index <= High(Cameras)) then
  begin
    edName.Text := Cameras[Index].Name;
    SplitUrl(Cameras[Index].Url, Proto, Host, Port, Path);
    if Proto = 'dvrip' then SelectProto(1) else SelectProto(0);
    edHost.Text := Host;
    edPort.Text := Port;
    edPath.Text := Path;
    edUser.Text := Cameras[Index].User;
    edPass.Text := Cameras[Index].Password;
    SelectChip(StrToChip(TransportsToStr(Cameras[Index].Transports)));
    edMaxRetries.Text := IntToStr(Cameras[Index].MaxReconnectAttempts);
    edAudioDelay.Text := IntToStr(Cameras[Index].AudioDelayMs);
    edVideoDelay.Text := IntToStr(Cameras[Index].VideoDelayMs);
    swTailscale.IsChecked := Cameras[Index].UsesTailscale;
    lblEditTitle.Text := 'Editar câmera';
    btnDelete.Visible := True;
  end
  else
  begin
    edName.Text := '';
    SelectProto(0);
    edHost.Text := '';
    edPort.Text := '554';
    edPath.Text := '';
    edUser.Text := '';
    edPass.Text := '';
    SelectChip(0);
    edMaxRetries.Text := '0';
    edAudioDelay.Text := '200';
    edVideoDelay.Text := '200';
    swTailscale.IsChecked := False;
    lblEditTitle.Text := 'Nova câmera';
    btnDelete.Visible := False;
  end;
end;

procedure TFrameEditor.SelectChip(Idx: Integer);
var
  I: Integer;
begin
  if (Idx < 0) or (Idx > 4) then Exit;
  FSelectedChip := Idx;
  for I := 0 to 4 do
    if I = Idx then
      FChips[I].Fill.Color := COLOR_ACCENT
    else
      FChips[I].Fill.Color := COLOR_SURFACE2;
end;

procedure TFrameEditor.chipClick(Sender: TObject);
begin
  if Sender is TRectangle then
    SelectChip(TRectangle(Sender).Tag);
end;

procedure TFrameEditor.SelectProto(Idx: Integer);
begin
  if (Idx < 0) or (Idx > 1) then Exit;
  FSelectedProto := Idx;
  if Idx = 0 then chipRtsp.Fill.Color := COLOR_ACCENT else chipRtsp.Fill.Color := COLOR_SURFACE2;
  if Idx = 1 then chipDvrip.Fill.Color := COLOR_ACCENT else chipDvrip.Fill.Color := COLOR_SURFACE2;
end;

procedure TFrameEditor.protoChipClick(Sender: TObject);
var
  Idx: Integer;
  Cur: string;
begin
  if not (Sender is TRectangle) then Exit;
  Idx := TRectangle(Sender).Tag;
  SelectProto(Idx);
  // sugere a porta padrão se estiver vazia ou for um dos padrões conhecidos
  Cur := Trim(edPort.Text);
  if (Cur = '') or (Cur = '554') or (Cur = '34567') then
  begin
    if Idx = 1 then edPort.Text := '34567' else edPort.Text := '554';
  end;
end;

procedure TFrameEditor.btnShowPassClick(Sender: TObject);
begin
  edPass.Password := not edPass.Password;
  if edPass.Password then
    lblShowPass.Text := 'Mostrar'
  else
    lblShowPass.Text := 'Ocultar';
end;

procedure TFrameEditor.btnTestConnClick(Sender: TObject);
var
  Cam: TCameraConfigEntry;
  Cfg: TCameraSessionConfig;
  IsDvrip: Boolean;
begin
  if Trim(edHost.Text) = '' then
  begin
    lblTestResult.Text := 'Informe o host/IP';
    Exit;
  end;
  // O teste passa pelo mesmo caminho de conexão, então precisa do mesmo tratamento
  // de VPN: testar câmera da tailnet com o túnel baixo falharia sempre.
  Cam := MakeCamera(Trim(edName.Text),
    BuildUrl(ProtoStr(FSelectedProto), edHost.Text, edPort.Text, edPath.Text),
    edUser.Text, edPass.Text, ParseTransports(ChipToStr(FSelectedChip)),
    0, 200, 200, swTailscale.IsChecked);
  Cfg := BuildSessionConfig(FAppCfg, Cam);
  Cfg.RecordEnabled := False;
  Cfg.ConnectTimeoutMs := 4000;
  Cfg.RtspTimeoutMs := 5000;
  Cfg.NoRtpTimeoutMs := 4000;
  IsDvrip := SameText(Copy(Trim(Cfg.Url), 1, 5), 'dvrip');

  lblTestResult.Text := 'Testando conexão...';
  btnTestConn.Enabled := False;

  TThread.CreateAnonymousThread(
    procedure
    var
      Ok: Boolean;
      Msg: string;
      StopEv: TEvent;
      Sess: TCameraSession;
      Dv: TDvripSession;
    begin
      Ok := False;
      Msg := '';
      StopEv := TEvent.Create(nil, True, False, '');
      try
        if IsDvrip then
        begin
          Dv := TDvripSession.Create(Cfg, FLogger, FClock, StopEv, nil);
          try Ok := Dv.TestConnection(Msg); finally Dv.Free; end;
        end
        else
        begin
          Sess := TCameraSession.Create(Cfg, FLogger, FClock, DefaultDepacketizerFactory(), StopEv, nil);
          try Ok := Sess.TestConnection(Msg); finally Sess.Free; end;
        end;
      finally
        StopEv.Free;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if Ok then
            lblTestResult.Text := 'OK — ' + Msg
          else
            lblTestResult.Text := 'Falha: ' + Msg;
          btnTestConn.Enabled := True;
        end);
    end).Start;
end;

procedure TFrameEditor.btnSaveClick(Sender: TObject);
var
  Cam: TCameraConfigEntry;
begin
  if Trim(edHost.Text) = '' then
  begin
    lblEditTitle.Text := 'Informe o host/IP';
    Exit;
  end;
  Cam := MakeCamera(Trim(edName.Text),
                    BuildUrl(ProtoStr(FSelectedProto), edHost.Text, edPort.Text, edPath.Text),
                    edUser.Text, edPass.Text,
                    ParseTransports(ChipToStr(FSelectedChip)),
                    StrToIntDef(Trim(edMaxRetries.Text), 0),
                    StrToIntDef(Trim(edAudioDelay.Text), 200),
                    StrToIntDef(Trim(edVideoDelay.Text), 200),
                    swTailscale.IsChecked);
  if Assigned(FOnSave) then FOnSave(Self, Cam, FEditIndex);
end;

procedure TFrameEditor.btnCancelClick(Sender: TObject);
begin
  if Assigned(FOnCancel) then FOnCancel(Self);
end;

procedure TFrameEditor.btnDeleteClick(Sender: TObject);
begin
  if Assigned(FOnDelete) then FOnDelete(Self, FEditIndex);
end;

procedure TFrameEditor.AdjustForFocused(Ctrl: TControl);
var
  BodyBottomAbs, Overlap, CtrlTopAbs, CtrlBottomAbs, VisTop: Single;
begin
  // 1. Encolhe o scrollbox pra terminar no topo do teclado. A área visível fica
  //    [abaixo da barEdit, topo do teclado] e o scroll ganha alcance pra alcançar
  //    os últimos campos. A barEdit (opaca, por cima) fica fixa e cobre o que
  //    rola por baixo dela.
  BodyBottomAbs := FLayBody.LocalToAbsolute(PointF(0, FLayBody.Height)).Y;
  Overlap := BodyBottomAbs - FKbTop;
  if Overlap < 0 then Overlap := 0;
  sbEditor.Margins.Bottom := Overlap;
  // 2. Rola o campo focado pra dentro da área visível.
  CtrlTopAbs := Ctrl.LocalToAbsolute(PointF(0, 0)).Y;
  CtrlBottomAbs := Ctrl.LocalToAbsolute(PointF(0, Ctrl.Height)).Y;
  VisTop := sbEditor.LocalToAbsolute(PointF(0, 0)).Y; // topo visível = base da barEdit
  if CtrlBottomAbs > FKbTop - 8 then
    // campo abaixo do teclado -> sobe
    sbEditor.ViewportPosition := PointF(sbEditor.ViewportPosition.X,
      sbEditor.ViewportPosition.Y + (CtrlBottomAbs - (FKbTop - 8)))
  else if CtrlTopAbs < VisTop + 8 then
    // campo acima da área visível (atrás da barEdit) -> desce
    sbEditor.ViewportPosition := PointF(sbEditor.ViewportPosition.X,
      sbEditor.ViewportPosition.Y - ((VisTop + 8) - CtrlTopAbs));
end;

procedure TFrameEditor.KeyboardShown(KbTop: Single; FocusedCtrl: TControl);
begin
  FKbShown := True;
  FKbTop := KbTop;
  if FocusedCtrl <> nil then
    AdjustForFocused(FocusedCtrl);
end;

procedure TFrameEditor.KeyboardHidden;
begin
  FKbShown := False;
  sbEditor.Margins.Bottom := 0; // devolve o tamanho normal do scroll
end;

function TFrameEditor.WrapEditBackground(E: TEdit): TRectangle;
var
  R: TRectangle;
  Idx: Integer;
begin
  // Fundo próprio: um retângulo escuro atrás do TEdit. Filho não serve (filhos
  // do edit são desenhados por cima do texto), então o edit passa a morar dentro
  // do retângulo, herdando o Align/Margins/posição que ele tinha no scrollbox.
  Idx := E.Index;
  R := TRectangle.Create(Self);
  R.Parent := E.Parent;
  R.Align := E.Align;
  R.Margins.Rect := E.Margins.Rect;
  R.Position.Y := E.Position.Y;
  R.Size.Size := E.Size.Size;
  R.Fill.Color := COLOR_FIELD;
  R.Stroke.Color := COLOR_FIELD_BORDER;
  R.Stroke.Thickness := 1;
  R.XRadius := 8;
  R.YRadius := 8;
  R.HitTest := False; // o clique tem que chegar no edit
  E.Parent := R;
  E.Align := TAlignLayout.Client;
  E.Margins.Rect := RectF(6, 0, 6, 0);
  R.Index := Idx; // devolve o campo à posição original na pilha do scrollbox
  Result := R;
end;

procedure TFrameEditor.EditApplyStyle(Sender: TObject);
var
  Obj: TFmxObject;
begin
  // O 'background' do estilo é opaco (branco no Windows): recolore quando é uma
  // forma e esconde quando é bitmap, deixando aparecer o retângulo escuro.
  if not (Sender is TEdit) then Exit;
  Obj := TEdit(Sender).FindStyleResource('background');
  if Obj is TShape then
  begin
    TShape(Obj).Fill.Kind := TBrushKind.Solid;
    TShape(Obj).Fill.Color := COLOR_FIELD;
    TShape(Obj).Stroke.Kind := TBrushKind.None;
  end
  else if Obj is TControl then
    TControl(Obj).Opacity := 0;
end;

procedure TFrameEditor.SetupEdit(E: TEdit);
begin
  E.StyledSettings := E.StyledSettings - [TStyledSetting.FontColor];
  E.TextSettings.FontColor := COLOR_TEXT;
  if E.Caret <> nil then
    E.Caret.Color := COLOR_TEXT;
  WrapEditBackground(E);
  E.OnApplyStyleLookup := EditApplyStyle;
  E.OnEnter := EditEnter;
  EditApplyStyle(E); // caso o estilo já esteja aplicado
end;

procedure TFrameEditor.EditEnter(Sender: TObject);
begin
  // Teclado já aberto + troca de campo: o OnVirtualKeyboardShown pode não
  // disparar de novo, então reposiciona o conteúdo aqui.
  if FKbShown and (Sender is TControl) then
    AdjustForFocused(TControl(Sender));
end;

end.
