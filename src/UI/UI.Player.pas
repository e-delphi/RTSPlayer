unit UI.Player;

// Frame do player. Exibe o vídeo (blit do frame RGBA do renderer), a pílula de
// status, o spinner e o painel de log. Trata os controles (auto-ocultar) e avisa
// o shell via OnBack. O shell dirige play/stop e empurra status/log pra cá.

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Graphics, FMX.Controls, FMX.Forms, FMX.Dialogs, FMX.StdCtrls,
  FMX.Memo.Types, FMX.ScrollBox, FMX.Memo, FMX.Controls.Presentation,
  FMX.Objects, FMX.Ani, FMX.Layouts,
  VMS.Domain.Logging,
  VMS.Media.Renderer,
  UI.Common;

type
  TFramePlayer = class(TFrame)
    imgVideo: TImage;
    laySpinner: TLayout;
    arcSpin: TArc;
    aniSpin: TFloatAnimation;
    layTop: TRectangle;
    btnBack: TRectangle;
    pathBack: TPath;
    btnDebug: TRectangle;
    pathLog: TPath;
    btnMute: TRectangle;
    pathMute: TPath;
    pillStatus: TRectangle;
    dotStatus: TCircle;
    lblStatus: TLabel;
    lblCamName: TLabel;
    panelDebug: TRectangle;
    memLog: TMemo;
    rectPlaceholder: TRectangle;
    lytCenter: TLayout;
    pathCamera: TPath;
    lblPlaceholder: TLabel;
  private
    FRenderer: TMediaRenderer;
    FLogger: ILogger;
    FPlaying: Boolean;
    FMuted: Boolean;
    FLoggedShown: Boolean;
    FTmrHide: TTimer;
    FOnBack: TNotifyEvent;
    FOnPlayback: TNotifyEvent;
    // Criado em código, e não no .fmx: um controle a mais no arquivo de forma
    // exigiria abrir o designer só para isto.
    FBtnPlayback: TRectangle;
    FPathPlayback: TPath;
    procedure CreatePlaybackButton;
    procedure btnBackClick(Sender: TObject);
    procedure btnDebugClick(Sender: TObject);
    procedure btnMuteClick(Sender: TObject);
    procedure btnPlaybackClick(Sender: TObject);
    procedure imgVideoClick(Sender: TObject);
    procedure tmrHideTimer(Sender: TObject);
    procedure UpdateMuteIcon;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Bind(const Renderer: TMediaRenderer; const Logger: ILogger);
    procedure PresentFrame;
    procedure SetPlaying(Value: Boolean);
    procedure SetMuted(Value: Boolean);
    procedure SetCamName(const S: string);
    procedure SetStatus(C: TAlphaColor; const S: string);
    procedure SetSpinner(AOn: Boolean);
    procedure ShowControls;
    procedure HideControls;
    procedure ClearVideo;
    procedure ResetForNewPlay;
    procedure AppendLog(const Lines: TArray<string>);
    procedure ClearLog;
    property Muted: Boolean read FMuted write SetMuted;
    property OnBack: TNotifyEvent read FOnBack write FOnBack;
    // Alterna entre ao vivo e gravação (o shell decide o que fazer).
    property OnPlayback: TNotifyEvent read FOnPlayback write FOnPlayback;
  end;

implementation

{$R *.fmx}

constructor TFramePlayer.Create(AOwner: TComponent);
begin
  inherited;
  pathBack.Data.Data := ICON_BACK;
  pathLog.Data.Data := ICON_LOG;
  pathCamera.Data.Data := ICON_CAMERA;

  FTmrHide := TTimer.Create(Self);
  FTmrHide.Enabled := False;
  FTmrHide.Interval := 4000;
  FTmrHide.OnTimer := tmrHideTimer;

  btnBack.OnClick := btnBackClick;
  btnDebug.OnClick := btnDebugClick;
  btnMute.OnClick := btnMuteClick;
  imgVideo.OnClick := imgVideoClick;
  UpdateMuteIcon;
  CreatePlaybackButton;

  // layTop é overlay sobre o vídeo (não ocupa espaço): precisa ficar por cima do
  // placeholder e do vídeo na ordem-z. O spinner logo abaixo dele.
  laySpinner.BringToFront;
  layTop.BringToFront;
end;

// Mesmo desenho dos botões do .fmx (retângulo transparente, ícone centralizado,
// Align=Right), para entrar na barra sem destoar.
procedure TFramePlayer.CreatePlaybackButton;
begin
  FBtnPlayback := TRectangle.Create(Self);
  FBtnPlayback.Parent := layTop;
  FBtnPlayback.Align := TAlignLayout.Right;
  FBtnPlayback.Width := 48;
  FBtnPlayback.Fill.Kind := TBrushKind.None;
  FBtnPlayback.Stroke.Kind := TBrushKind.None;
  FBtnPlayback.HitTest := True;
  FBtnPlayback.OnClick := btnPlaybackClick;

  FPathPlayback := TPath.Create(Self);
  FPathPlayback.Parent := FBtnPlayback;
  FPathPlayback.Align := TAlignLayout.Center;
  FPathPlayback.Width := 20;
  FPathPlayback.Height := 20;
  FPathPlayback.HitTest := False;
  FPathPlayback.WrapMode := TPathWrapMode.Fit;
  FPathPlayback.Fill.Color := COLOR_DIM;
  FPathPlayback.Stroke.Kind := TBrushKind.None;
  FPathPlayback.Data.Data := ICON_CLOCK;
end;

procedure TFramePlayer.btnPlaybackClick(Sender: TObject);
begin
  ShowControls; // o toque foi na barra: reinicia o auto-ocultar
  if Assigned(FOnPlayback) then FOnPlayback(Self);
end;

procedure TFramePlayer.Bind(const Renderer: TMediaRenderer; const Logger: ILogger);
begin
  FRenderer := Renderer;
  FLogger := Logger;
  SetMuted(FMuted); // deixa o renderer no mesmo estado que o botão mostra
end;

procedure TFramePlayer.SetPlaying(Value: Boolean);
begin
  FPlaying := Value;
  rectPlaceholder.Visible := not Value;
  if not Value then
    SetSpinner(False);
end;

procedure TFramePlayer.UpdateMuteIcon;
begin
  if pathMute = nil then Exit;
  if FMuted then
  begin
    pathMute.Data.Data := ICON_MUTE;
    pathMute.Fill.Color := COLOR_DANGER;
  end
  else
  begin
    pathMute.Data.Data := ICON_SOUND;
    pathMute.Fill.Color := COLOR_DIM;
  end;
end;

procedure TFramePlayer.SetMuted(Value: Boolean);
begin
  FMuted := Value;
  // o mute vive no renderer (instância única), então sobrevive a reconexão e a
  // troca de câmera sem a UI precisar reaplicar
  if FRenderer <> nil then
    FRenderer.AudioEnabled := not FMuted;
  UpdateMuteIcon;
end;

procedure TFramePlayer.SetCamName(const S: string);
begin
  lblCamName.Text := S;
end;

procedure TFramePlayer.SetStatus(C: TAlphaColor; const S: string);
begin
  dotStatus.Fill.Color := C;
  lblStatus.Text := S;
end;

procedure TFramePlayer.SetSpinner(AOn: Boolean);
begin
  laySpinner.Visible := AOn;
  aniSpin.Enabled := AOn;
end;

procedure TFramePlayer.ShowControls;
begin
  layTop.Visible := True;
  FTmrHide.Enabled := False;
  if FPlaying then
    FTmrHide.Enabled := True;
end;

procedure TFramePlayer.HideControls;
begin
  layTop.Visible := False;
  FTmrHide.Enabled := False;
end;

procedure TFramePlayer.tmrHideTimer(Sender: TObject);
begin
  FTmrHide.Enabled := False;
  if FPlaying then
    HideControls;
end;

procedure TFramePlayer.ClearVideo;
begin
  if imgVideo <> nil then
  begin
    imgVideo.Bitmap.SetSize(0, 0);
    imgVideo.Repaint;
  end;
end;

procedure TFramePlayer.ResetForNewPlay;
begin
  FLoggedShown := False;
  ClearLog;
end;

procedure TFramePlayer.ClearLog;
begin
  if memLog <> nil then
    memLog.Lines.Clear;
end;

procedure TFramePlayer.AppendLog(const Lines: TArray<string>);
var
  I: Integer;
begin
  if (memLog = nil) or (Length(Lines) = 0) then Exit;
  memLog.Lines.BeginUpdate;
  try
    for I := 0 to High(Lines) do
      memLog.Lines.Add(Lines[I]);
    while memLog.Lines.Count > 500 do
      memLog.Lines.Delete(0);
  finally
    memLog.Lines.EndUpdate;
  end;
  memLog.GoToTextEnd;
end;

procedure TFramePlayer.btnBackClick(Sender: TObject);
begin
  if Assigned(FOnBack) then FOnBack(Self);
end;

procedure TFramePlayer.btnDebugClick(Sender: TObject);
begin
  panelDebug.Visible := not panelDebug.Visible;
end;

procedure TFramePlayer.btnMuteClick(Sender: TObject);
begin
  SetMuted(not FMuted);
  ShowControls; // reinicia o timer de auto-ocultar (o toque foi na barra)
  if FLogger <> nil then
    if FMuted then
      FLogger.Info('ui', 'audio mudo')
    else
      FLogger.Info('ui', 'audio ligado');
end;

procedure TFramePlayer.imgVideoClick(Sender: TObject);
begin
  if not FPlaying then
  begin
    ShowControls;
    Exit;
  end;
  if layTop.Visible then
    HideControls
  else
    ShowControls;
end;

procedure TFramePlayer.PresentFrame;
var
  RGBA: TBytes;
  W, H, X, Y, SrcStride: Integer;
  Data: TBitmapData;
  Src, Dst: PByte;
begin
  if (not FPlaying) or (FRenderer = nil) or (imgVideo = nil) then Exit;
  if not FRenderer.LockLatestFrame(RGBA, W, H) then Exit;
  try
    if (W <= 0) or (H <= 0) then Exit;
    if (imgVideo.Bitmap.Width <> W) or (imgVideo.Bitmap.Height <> H) then
      imgVideo.Bitmap.SetSize(W, H);
    if imgVideo.Bitmap.Map(TMapAccess.Write, Data) then
    try
      SrcStride := W * 4;
      for Y := 0 to H - 1 do
      begin
        Src := @RGBA[Y * SrcStride];
        Dst := PByte(Data.GetScanline(Y));
        if Data.PixelFormat = TPixelFormat.BGRA then
        begin
          for X := 0 to W - 1 do
          begin
            Dst[X * 4 + 0] := Src[X * 4 + 2];
            Dst[X * 4 + 1] := Src[X * 4 + 1];
            Dst[X * 4 + 2] := Src[X * 4 + 0];
            Dst[X * 4 + 3] := Src[X * 4 + 3];
          end;
        end
        else
          System.Move(Src^, Dst^, SrcStride);
      end;
    finally
      imgVideo.Bitmap.Unmap(Data);
    end;
  finally
    FRenderer.UnlockFrame;
  end;
  imgVideo.Repaint;
  if not FLoggedShown then
  begin
    FLoggedShown := True;
    SetSpinner(False);
    imgVideo.Opacity := 1; // garante visível (sem depender de animação de fade)
    if FLogger <> nil then
      FLogger.Info('ui', Format('primeiro frame exibido %dx%d', [W, H]));
  end;
end;

end.
