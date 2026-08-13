// Eduardo - Player RTSP - shell que hospeda os frames (lista / player / editor)
unit Inicio;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.IOUtils,
  System.JSON, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Objects, FMX.Layouts,
  FMX.Platform, FMX.VirtualKeyboard,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.Supervisor,
  VMS.Rtsp.Client,
  VMS.App.Config,
  VMS.App.Composition,
  VMS.App.ScreenAwake,
  VMS.Media.Renderer,
  VMS.Android.MemoLogger,
  UI.Common,
  UI.List,
  UI.Player,
  UI.Editor;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FRenderer: TMediaRenderer;
    FSupervisor: TCameraSupervisor;
    FLogger: ILogger;
    FMemoLog: TMemoLogger;
    FClock: IClock;
    FAppCfg: TAppConfig;
    FCameras: TArray<TCameraConfigEntry>;
    FFrameList: TFrameList;
    FFramePlayer: TFramePlayer;
    FFrameEditor: TFrameEditor;
    FActive: TFrame;
    FTmrStatus: TTimer;
    FPlaying: Boolean;
    FWasPlaying: Boolean;
    FCurrentIndex: Integer;
    procedure DefaultAppCfg;
    function CamerasFilePath: string;
    procedure LoadCameras;
    procedure SaveCameras;
    procedure RemoveCamera(Index: Integer);
    procedure ShowFrame(F: TFrame);
    procedure ShowList;
    procedure ShowPlayer;
    procedure ShowEditor(Index: Integer);
    procedure StartPlay(Index: Integer);
    procedure StopPlay;
    procedure tmrStatusTimer(Sender: TObject);
    // eventos vindos dos frames
    procedure ListAdd(Sender: TObject);
    procedure ListPlay(Sender: TObject; Index: Integer);
    procedure ListEdit(Sender: TObject; Index: Integer);
    procedure ListDelete(Sender: TObject; Index: Integer);
    procedure EditorSave(Sender: TObject; const Entry: TCameraConfigEntry; EditIndex: Integer);
    procedure EditorCancel(Sender: TObject);
    procedure EditorDelete(Sender: TObject; Index: Integer);
    procedure PlayerBack(Sender: TObject);
    // globais
    function CloseKeyboardIfOpen: Boolean;
    function HandleAppEvent(AAppEvent: TApplicationEvent; AContext: TObject): Boolean;
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormVirtualKeyboardShown(Sender: TObject; KeyboardVisible: Boolean; const Bounds: TRect);
    procedure FormVirtualKeyboardHidden(Sender: TObject; KeyboardVisible: Boolean; const Bounds: TRect);
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
var
  Svc: IFMXApplicationEventService;
  Bg: TRectangle;
begin
{$IFDEF MSWINDOWS}
  // No Windows abre numa janela retrato de tamanho típico de desktop; no Android
  // continua em tela cheia, na proporção do aparelho.
  Self.Width := 960;
  Self.Height := 540;
  Self.Position := TFormPosition.ScreenCenter;
{$ENDIF}
  FCurrentIndex := -1;

  FClock := BuildClock;
  DefaultAppCfg;
  FMemoLog := TMemoLogger.Create(llDebug);
  FLogger := FMemoLog;
  FRenderer := TMediaRenderer.Create(FLogger);
  LoadCameras;

  // fundo escuro atrás dos frames
  Bg := TRectangle.Create(Self);
  Bg.Parent := Self;
  Bg.Align := TAlignLayout.Contents;
  Bg.Fill.Color := COLOR_BG;
  Bg.Stroke.Kind := TBrushKind.None;
  Bg.HitTest := False;
  Bg.SendToBack;

  // frames (todos ocupam a tela; só um fica visível por vez)
  FFrameList := TFrameList.Create(Self);
  FFrameList.Parent := Self;
  FFrameList.Align := TAlignLayout.Contents;
  FFrameList.OnAdd := ListAdd;
  FFrameList.OnPlayCamera := ListPlay;
  FFrameList.OnEditCamera := ListEdit;
  FFrameList.OnDeleteCamera := ListDelete;

  FFramePlayer := TFramePlayer.Create(Self);
  FFramePlayer.Parent := Self;
  FFramePlayer.Align := TAlignLayout.Contents;
  FFramePlayer.Bind(FRenderer, FLogger);
  FFramePlayer.OnBack := PlayerBack;

  FFrameEditor := TFrameEditor.Create(Self);
  FFrameEditor.Parent := Self;
  FFrameEditor.Align := TAlignLayout.Contents;
  FFrameEditor.Bind(FAppCfg, FLogger, FClock);
  FFrameEditor.OnSave := EditorSave;
  FFrameEditor.OnCancel := EditorCancel;
  FFrameEditor.OnDelete := EditorDelete;

  // o renderer entrega os frames de vídeo ao frame do player
  FRenderer.OnVideoFrame :=
    procedure
    begin
      FFramePlayer.PresentFrame;
    end;

  FTmrStatus := TTimer.Create(Self);
  FTmrStatus.Interval := 500;
  FTmrStatus.OnTimer := tmrStatusTimer;
  FTmrStatus.Enabled := True;

  ShowList;

  if TPlatformServices.Current.SupportsPlatformService(IFMXApplicationEventService, Svc) then
    Svc.SetApplicationEventHandler(HandleAppEvent);

  // Usabilidade Android: botão voltar do sistema + compensação do teclado.
  Self.OnKeyUp := FormKeyUp;
  Self.OnVirtualKeyboardShown := FormVirtualKeyboardShown;
  Self.OnVirtualKeyboardHidden := FormVirtualKeyboardHidden;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if FTmrStatus <> nil then
    FTmrStatus.Enabled := False;
  StopPlay;
  FMemoLog := nil;
  if FRenderer <> nil then
  begin
    FRenderer.OnVideoFrame := nil;
    FreeAndNil(FRenderer);
  end;
end;

procedure TForm1.DefaultAppCfg;
begin
  FAppCfg.StorageDir := '';
  FAppCfg.LogDir := '';
  FAppCfg.LogLevel := llInfo;
  FAppCfg.TransportFallbackTimeoutMs := 5000;
  FAppCfg.KeepAliveMethod := kamGetParameter;
  FAppCfg.MaxBlockSamples := 256;
  FAppCfg.MaxBlockDurationMs := 2000;
  FAppCfg.MaxBlockSizeBytes := 1048576;
end;

function TForm1.CamerasFilePath: string;
begin
  Result := System.IOUtils.TPath.Combine(System.IOUtils.TPath.GetDocumentsPath, 'cameras.json');
end;

procedure TForm1.LoadCameras;
var
  S: string;
  V: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
  O: TJSONObject;
  List: TList<TCameraConfigEntry>;
begin
  SetLength(FCameras, 0);
  if not TFile.Exists(CamerasFilePath) then
    Exit; // começa vazio; o arquivo é criado ao adicionar a primeira câmera
  try
    S := TFile.ReadAllText(CamerasFilePath, TEncoding.UTF8);
    V := TJSONObject.ParseJSONValue(S);
  except
    Exit;
  end;
  if not (V is TJSONArray) then
  begin
    if V <> nil then V.Free;
    Exit;
  end;
  Arr := TJSONArray(V);
  List := TList<TCameraConfigEntry>.Create;
  try
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        O := TJSONObject(Arr.Items[I]);
        List.Add(MakeCamera(JsonStr(O, 'name'), JsonStr(O, 'url'),
                            JsonStr(O, 'user'), JsonStr(O, 'password'),
                            ParseTransports(JsonStr(O, 'transport')),
                            JsonInt(O, 'maxRetries', 0),
                            JsonInt(O, 'audioDelayMs', 200),
                            JsonInt(O, 'videoDelayMs', 200)));
      end;
    FCameras := List.ToArray;
  finally
    List.Free;
    V.Free;
  end;
end;

procedure TForm1.SaveCameras;
var
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(FCameras) do
    begin
      O := TJSONObject.Create;
      O.AddPair('name', FCameras[I].Name);
      O.AddPair('url', FCameras[I].Url);
      O.AddPair('user', FCameras[I].User);
      O.AddPair('password', FCameras[I].Password);
      O.AddPair('transport', TransportsToStr(FCameras[I].Transports));
      O.AddPair('maxRetries', TJSONNumber.Create(FCameras[I].MaxReconnectAttempts));
      O.AddPair('audioDelayMs', TJSONNumber.Create(FCameras[I].AudioDelayMs));
      O.AddPair('videoDelayMs', TJSONNumber.Create(FCameras[I].VideoDelayMs));
      Arr.AddElement(O);
    end;
    TFile.WriteAllText(CamerasFilePath, Arr.ToJSON, TEncoding.UTF8);
  finally
    Arr.Free;
  end;
end;

procedure TForm1.RemoveCamera(Index: Integer);
var
  I: Integer;
  NewList: TArray<TCameraConfigEntry>;
begin
  if (Index < 0) or (Index > High(FCameras)) then Exit;
  SetLength(NewList, 0);
  for I := 0 to High(FCameras) do
    if I <> Index then
      NewList := NewList + [FCameras[I]];
  FCameras := NewList;
  SaveCameras;
end;

procedure TForm1.ShowFrame(F: TFrame);
begin
  FFrameList.Visible := F = FFrameList;
  FFramePlayer.Visible := F = FFramePlayer;
  FFrameEditor.Visible := F = FFrameEditor;
  FActive := F;
  if F <> nil then F.BringToFront;
end;

procedure TForm1.ShowList;
begin
  FFrameList.ResetEditMode;
  FFrameList.SetCameras(FCameras);
  ShowFrame(FFrameList);
end;

procedure TForm1.ShowPlayer;
begin
  ShowFrame(FFramePlayer);
  FFramePlayer.ShowControls;
end;

procedure TForm1.ShowEditor(Index: Integer);
begin
  FFrameEditor.LoadEntry(Index, FCameras);
  ShowFrame(FFrameEditor);
end;

procedure TForm1.StartPlay(Index: Integer);
begin
  StopPlay;
  // limpa o log ao trocar de câmera: descarta o buffer pendente e a tela
  if FMemoLog <> nil then FMemoLog.Drain;
  FFramePlayer.ResetForNewPlay;
  if (Index < 0) or (Index > High(FCameras)) then
  begin
    FFramePlayer.SetStatus(STAT_GRAY, 'Sem c'#$E2'mera');
    Exit;
  end;
  FCurrentIndex := Index;
  FFramePlayer.SetCamName(FCameras[Index].Name);
  FLogger.Info('ui', Format('Play "%s" -> %s', [FCameras[Index].Name, FCameras[Index].Url]));
  if FRenderer <> nil then
    FRenderer.SetDelays(FCameras[Index].AudioDelayMs, FCameras[Index].VideoDelayMs);
  FPlaying := False;
  try
    FSupervisor := BuildPlayerSupervisor(FAppCfg, FCameras[Index], FLogger, FClock, FRenderer);
    FSupervisor.Start;
    FPlaying := True;
    FFramePlayer.SetStatus(STAT_YELLOW, 'Conectando');
    FFramePlayer.SetSpinner(True);
  except
    on E: Exception do
    begin
      FLogger.Error('ui', 'Falha ao iniciar: ' + E.ClassName + ': ' + E.Message);
      FFramePlayer.SetStatus(COLOR_DANGER, 'Erro');
    end;
  end;
  // enquanto a câmera está no ar a tela não pode apagar (o toque some com os
  // controles, então o usuário fica minutos sem tocar em nada)
  SetKeepScreenOn(FPlaying);
  FFramePlayer.SetPlaying(FPlaying);
  FFramePlayer.ShowControls;
end;

procedure TForm1.StopPlay;
begin
  if FPlaying then
    FLogger.Info('ui', 'Stop');
  FPlaying := False;
  SetKeepScreenOn(False); // volta ao timeout normal de tela do aparelho
  if FSupervisor <> nil then
  begin
    FSupervisor.Stop;
    FSupervisor.Free;
    FSupervisor := nil;
  end;
  if FRenderer <> nil then
    FRenderer.OnStreamStopped;
  if FFramePlayer <> nil then
  begin
    FFramePlayer.ClearVideo;
    FFramePlayer.SetSpinner(False);
    FFramePlayer.SetStatus(STAT_GRAY, 'Parado');
    FFramePlayer.SetPlaying(False);
  end;
end;

procedure TForm1.tmrStatusTimer(Sender: TObject);
var
  Lines: TArray<string>;
begin
  if FMemoLog <> nil then
  begin
    Lines := FMemoLog.Drain;
    if Length(Lines) > 0 then
      FFramePlayer.AppendLog(Lines);
  end;
  if (not FPlaying) or (FSupervisor = nil) then Exit;
  case FSupervisor.State of
    svConnecting:
      begin FFramePlayer.SetStatus(STAT_YELLOW, 'Conectando'); FFramePlayer.SetSpinner(True); end;
    svStreaming:
      begin FFramePlayer.SetStatus(STAT_GREEN, 'Ao vivo'); FFramePlayer.SetSpinner(False); end;
    svDraining, svBackoff:
      begin FFramePlayer.SetStatus(STAT_ORANGE, 'Reconectando'); FFramePlayer.SetSpinner(True); end;
    svStopping:
      FFramePlayer.SetStatus(STAT_GRAY, 'Parando');
  else
    FFramePlayer.SetStatus(STAT_GRAY, '...');
  end;
end;

procedure TForm1.ListAdd(Sender: TObject);
begin
  ShowEditor(-1);
end;

procedure TForm1.ListPlay(Sender: TObject; Index: Integer);
begin
  StartPlay(Index);
  ShowPlayer;
end;

procedure TForm1.ListEdit(Sender: TObject; Index: Integer);
begin
  ShowEditor(Index);
end;

procedure TForm1.ListDelete(Sender: TObject; Index: Integer);
begin
  if FCurrentIndex = Index then
    StopPlay;
  RemoveCamera(Index);
  FFrameList.SetCameras(FCameras);
end;

procedure TForm1.EditorSave(Sender: TObject; const Entry: TCameraConfigEntry; EditIndex: Integer);
begin
  if (EditIndex >= 0) and (EditIndex <= High(FCameras)) then
    FCameras[EditIndex] := Entry
  else
    FCameras := FCameras + [Entry];
  SaveCameras;
  ShowList;
end;

procedure TForm1.EditorCancel(Sender: TObject);
begin
  ShowList;
end;

procedure TForm1.EditorDelete(Sender: TObject; Index: Integer);
begin
  if (Index < 0) or (Index > High(FCameras)) then Exit;
  if FCurrentIndex = Index then
    StopPlay;
  RemoveCamera(Index);
  ShowList;
end;

procedure TForm1.PlayerBack(Sender: TObject);
begin
  StopPlay;
  ShowList;
end;

function TForm1.CloseKeyboardIfOpen: Boolean;
var
  KbSvc: IFMXVirtualKeyboardService;
begin
  Result := False;
  if TPlatformServices.Current.SupportsPlatformService(IFMXVirtualKeyboardService, KbSvc)
     and (KbSvc <> nil)
     and (TVirtualKeyboardState.Visible in KbSvc.VirtualKeyBoardState) then
  begin
    KbSvc.HideVirtualKeyboard; // fecha o teclado
    Result := True;
  end;
end;

procedure TForm1.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar;
  Shift: TShiftState);
begin
  // Botão voltar do Android: navega dentro do app em vez de fechar.
  if Key <> vkHardwareBack then Exit;
  // 1º back fecha o teclado (se aberto), sem navegar — comportamento padrão Android.
  if CloseKeyboardIfOpen then
  begin
    Key := 0;
    Exit;
  end;
  if FActive = FFramePlayer then
  begin
    StopPlay;
    ShowList;
    Key := 0; // consome: não fecha o app
  end
  else if FActive = FFrameEditor then
  begin
    ShowList; // cancela a edição
    Key := 0;
  end;
  // na lista: deixa o Key passar -> comportamento padrão (minimiza o app)
end;

procedure TForm1.FormVirtualKeyboardShown(Sender: TObject; KeyboardVisible: Boolean;
  const Bounds: TRect);
var
  KbRect: TRectF;
  Obj: TFmxObject;
  FocusedCtrl: TControl;
begin
  if FActive <> FFrameEditor then Exit;
  // Bounds do teclado vêm em coordenadas de TELA (pixels no Android). A forma
  // confiável de converter pra unidades lógicas é ScreenToClient (dividir pela
  // escala manualmente não é confiável entre versões/aparelhos). É o que o sample
  // oficial FMX.ScrollableForm faz.
  KbRect := RectF(Bounds.Left, Bounds.Top, Bounds.Right, Bounds.Bottom);
  KbRect.TopLeft := ScreenToClient(KbRect.TopLeft);
  KbRect.BottomRight := ScreenToClient(KbRect.BottomRight);
  FocusedCtrl := nil;
  if Focused <> nil then
  begin
    Obj := Focused.GetObject;
    if Obj is TControl then FocusedCtrl := TControl(Obj);
  end;
  // KbRect.Top = topo do teclado em coord. do cliente (= absoluto, form tela cheia).
  FFrameEditor.KeyboardShown(KbRect.Top, FocusedCtrl);
end;

procedure TForm1.FormVirtualKeyboardHidden(Sender: TObject; KeyboardVisible: Boolean;
  const Bounds: TRect);
begin
  if FFrameEditor <> nil then
    FFrameEditor.KeyboardHidden;
end;

function TForm1.HandleAppEvent(AAppEvent: TApplicationEvent; AContext: TObject): Boolean;
begin
  Result := True;
  case AAppEvent of
    TApplicationEvent.EnteredBackground,
    TApplicationEvent.WillBecomeInactive:
      begin
        FWasPlaying := FPlaying;
        if FPlaying then
          StopPlay;
      end;
    TApplicationEvent.BecameActive:
      begin
        if FWasPlaying then
        begin
          FWasPlaying := False;
          StartPlay(FCurrentIndex);
        end;
      end;
  end;
end;

end.
