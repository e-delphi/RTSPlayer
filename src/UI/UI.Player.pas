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

const
  VIDEO_ZOOM_MIN  = 1.0;
  VIDEO_ZOOM_MAX  = 6.0;
  VIDEO_ZOOM_STEP = 1.25;   // por entalhe da roda
  VIDEO_TAP_PX    = 8;      // acima disto é arrasto, não toque

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
    // Camada transparente sobre o vídeo que recebe o toque. Ela existe porque o
    // imgVideo passa a ser ESCALADO no zoom, e as coordenadas locais de um
    // controle escalado já vêm divididas pela escala — arrastar por elas daria
    // realimentação. Esta camada nunca é escalada, então o pixel que ela
    // reporta é o pixel da tela.
    FGesture: TRectangle;
    FZoom: Single;             // 1 = imagem inteira na tela
    FOffX, FOffY: Single;      // canto do vídeo ampliado, em pixels da moldura
    FPinchDist: Integer;       // distância entre os dedos no quadro anterior
    FPinched: Boolean;         // houve pinça neste toque: não é um toque simples
    FVDown: Boolean;
    FVMoved: Boolean;
    FVStartX, FVStartY: Single;
    FVStartOffX, FVStartOffY: Single;
    FVLastX, FVLastY: Single;  // último ponto sob o ponteiro, para a roda
    procedure CreateGestureLayer;
    procedure ApplyVideoTransform;
    procedure VideoHostResize(Sender: TObject);
    // Leva o zoom para NewZoom mantendo parado o ponto (SX,SY), em pixels da
    // camada de toque — que são pixels de tela.
    procedure ZoomAt(NewZoom, SX, SY: Single);
    procedure VideoMouseDown(Sender: TObject; Button: TMouseButton;
                             Shift: TShiftState; X, Y: Single);
    procedure VideoMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure VideoMouseUp(Sender: TObject; Button: TMouseButton;
                           Shift: TShiftState; X, Y: Single);
    procedure VideoMouseWheel(Sender: TObject; Shift: TShiftState;
                              WheelDelta: Integer; var Handled: Boolean);
    procedure VideoGesture(Sender: TObject; const EventInfo: TGestureEventInfo;
                           var Handled: Boolean);
    procedure VideoDblClick(Sender: TObject);
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
    // Volta o vídeo ao enquadramento inteiro. Chamada ao trocar de câmera ou de
    // gravação: zoom é do que se estava vendo, não do player.
    procedure ResetVideoZoom;
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
  CreateGestureLayer;

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

// ---------------------------------------------------------------------------
// Zoom no vídeo
//
// O zoom é uma transformação do CONTROLE, não do bitmap: o quadro continua
// chegando do decodificador no tamanho que ele tem, e quem amplia é o FMX. Assim
// o PresentFrame não muda em nada e ampliar não custa CPU por quadro.
//
// Ampliar é dar ao imgVideo um retângulo MAIOR que a área de vídeo e deslizá-lo
// por baixo dela; o recorte do frame esconde o que sobra. Nada de Scale nem de
// RotationCenter: sem rotação o FMX ignora o RotationCenter e escala a partir do
// canto (ver TControl.DoMatrixChanged), então a única coisa que translada um
// controle é mesmo o Position.
//
//   x_tela(p) = Off + p*W0*Z      p = ponto do vídeo, 0..1
//
// Daí saem as duas contas: arrastar é somar o deslocamento do dedo em Off, e
// ampliar em torno de um ponto é achar que p está sob ele e recalcular Off para
// que continue lá.
// ---------------------------------------------------------------------------

procedure TFramePlayer.CreateGestureLayer;
begin
  FGesture := TRectangle.Create(Self);
  FGesture.Parent := Self;
  FGesture.Align := TAlignLayout.Client;
  FGesture.Fill.Kind := TBrushKind.None;     // invisível: só serve de alvo
  FGesture.Stroke.Kind := TBrushKind.None;
  FGesture.HitTest := True;
  // Sem isto o arrasto morre assim que o dedo sai do controle.
  FGesture.AutoCapture := True;
  FGesture.OnMouseDown := VideoMouseDown;
  FGesture.OnMouseMove := VideoMouseMove;
  FGesture.OnMouseUp := VideoMouseUp;
  FGesture.OnMouseWheel := VideoMouseWheel;
  FGesture.OnDblClick := VideoDblClick;
  FGesture.OnGesture := VideoGesture;
  // A camada é Align=Client, então ela SEMPRE tem o tamanho da área de vídeo.
  // É dela que sai a moldura de referência, e é o Resize dela que avisa que a
  // tela girou ou a janela mudou de tamanho.
  FGesture.OnResize := VideoHostResize;
  FGesture.Touch.InteractiveGestures := [TInteractiveGesture.Zoom];
  // Ordem-z: o vídeo no fundo, a camada de toque logo acima dele, e as barras
  // (criadas antes, no .fmx) acima de tudo — daí os BringToFront no construtor.
  // O rectPlaceholder (tela preta de "sem vídeo") fica acima da camada, e é ele
  // que recebe o toque enquanto não há imagem — que é o que já acontecia antes.
  FGesture.SendToBack;
  imgVideo.SendToBack;
  // Ampliado, o vídeo desenha além do retângulo dele. Sem recorte isso vazaria
  // para fora do frame.
  Self.ClipChildren := True;
  // Quem responde ao toque agora é a camada; o vídeo vira só pixel.
  imgVideo.HitTest := False;
  // Sai do alinhamento: quem posiciona e dimensiona o vídeo agora é o zoom, e
  // o alinhador sobrescreveria o Position a cada realinhamento.
  imgVideo.Align := TAlignLayout.None;

  FZoom := 1;
  FOffX := 0;
  FOffY := 0;
  ApplyVideoTransform;
end;

procedure TFramePlayer.VideoHostResize(Sender: TObject);
begin
  ApplyVideoTransform;
end;

procedure TFramePlayer.ApplyVideoTransform;
var
  W0, H0, MinX, MinY: Single;
begin
  if (imgVideo = nil) or (FGesture = nil) then Exit;
  W0 := FGesture.Width;
  H0 := FGesture.Height;
  if (W0 <= 0) or (H0 <= 0) then Exit;

  if FZoom < VIDEO_ZOOM_MIN then FZoom := VIDEO_ZOOM_MIN;
  if FZoom > VIDEO_ZOOM_MAX then FZoom := VIDEO_ZOOM_MAX;

  // Sem ampliação o vídeo é exatamente a moldura; ampliado, ele é maior e
  // desliza por baixo dela. O recorte do frame é que esconde o que sobra.
  MinX := W0 - W0 * FZoom;   // <= 0
  MinY := H0 - H0 * FZoom;
  if FOffX > 0 then FOffX := 0;
  if FOffX < MinX then FOffX := MinX;
  if FOffY > 0 then FOffY := 0;
  if FOffY < MinY then FOffY := MinY;

  imgVideo.SetBounds(FGesture.Position.X + FOffX, FGesture.Position.Y + FOffY,
                     W0 * FZoom, H0 * FZoom);
end;

procedure TFramePlayer.ZoomAt(NewZoom, SX, SY: Single);
var
  W0, H0, PX, PY: Single;
begin
  if (FGesture = nil) then Exit;
  W0 := FGesture.Width;
  H0 := FGesture.Height;
  if (W0 <= 0) or (H0 <= 0) then Exit;
  if NewZoom < VIDEO_ZOOM_MIN then NewZoom := VIDEO_ZOOM_MIN;
  if NewZoom > VIDEO_ZOOM_MAX then NewZoom := VIDEO_ZOOM_MAX;

  // Que ponto do vídeo (0..1) está sob (SX,SY) agora...
  PX := (SX - FOffX) / (W0 * FZoom);
  PY := (SY - FOffY) / (H0 * FZoom);
  FZoom := NewZoom;
  // ...e onde o canto tem de ficar para ele continuar exatamente ali.
  FOffX := SX - PX * W0 * FZoom;
  FOffY := SY - PY * H0 * FZoom;
  ApplyVideoTransform;
end;

procedure TFramePlayer.ResetVideoZoom;
begin
  FZoom := 1;
  FOffX := 0;
  FOffY := 0;
  FPinchDist := 0;
  ApplyVideoTransform;
end;

procedure TFramePlayer.VideoDblClick(Sender: TObject);
begin
  ResetVideoZoom;
end;

procedure TFramePlayer.VideoMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FVDown := True;
  FVMoved := False;
  FPinched := False;
  FVStartX := X;
  FVStartY := Y;
  FVStartOffX := FOffX;
  FVStartOffY := FOffY;
  FVLastX := X;
  FVLastY := Y;
end;

procedure TFramePlayer.VideoMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  FVLastX := X;
  FVLastY := Y;
  if not FVDown then Exit;
  // Pinça em andamento: os dois dedos também geram evento de mouse, e deixar o
  // arrasto correr junto faria a imagem escorregar enquanto se amplia.
  if FPinchDist > 0 then Exit;
  // Botão solto sem o MouseUp ter chegado (a captura se perdeu): encerra aqui,
  // senão o vídeo continua panoramizando preso ao ponteiro.
  if not (ssLeft in Shift) then
  begin
    FVDown := False;
    Exit;
  end;
  if (Abs(X - FVStartX) > VIDEO_TAP_PX) or (Abs(Y - FVStartY) > VIDEO_TAP_PX) then
    FVMoved := True;
  if FZoom <= VIDEO_ZOOM_MIN + 0.001 then Exit;  // sem ampliação não se arrasta

  // A camada não é escalada, então o que ela reporta é pixel de tela, e o
  // Position do vídeo está na mesma escala: o vídeo segue o dedo 1 para 1.
  FOffX := FVStartOffX + (X - FVStartX);
  FOffY := FVStartOffY + (Y - FVStartY);
  ApplyVideoTransform;
end;

procedure TFramePlayer.VideoMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
var
  Moved: Boolean;
begin
  if not FVDown then Exit;
  Moved := FVMoved or FPinched;
  FVDown := False;
  FVMoved := False;
  FPinched := False;
  // Arrastar e ampliar é enquadrar; só o toque simples mostra/esconde os
  // controles.
  if Moved then Exit;
  imgVideoClick(Sender);
end;

procedure TFramePlayer.VideoMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; var Handled: Boolean);
var
  Factor: Single;
begin
  if WheelDelta > 0 then Factor := VIDEO_ZOOM_STEP else Factor := 1 / VIDEO_ZOOM_STEP;
  // Amplia em torno do ponteiro: é o que faz a roda parecer uma lupa em vez de
  // um controle de escala.
  ZoomAt(FZoom * Factor, FVLastX, FVLastY);
  Handled := True;
end;

procedure TFramePlayer.VideoGesture(Sender: TObject;
  const EventInfo: TGestureEventInfo; var Handled: Boolean);
var
  P: TPointF;
begin
  if EventInfo.GestureID <> igiZoom then Exit;
  if TInteractiveGestureFlag.gfBegin in EventInfo.Flags then
  begin
    FPinchDist := EventInfo.Distance;
    Handled := True;
    Exit;
  end;
  if TInteractiveGestureFlag.gfEnd in EventInfo.Flags then
  begin
    FPinchDist := 0;
    Handled := True;
    Exit;
  end;
  if (FPinchDist > 0) and (EventInfo.Distance > 0) then
  begin
    // Location vem em coordenadas de tela e é o ponto entre os dois dedos.
    P := FGesture.ScreenToLocal(EventInfo.Location);
    ZoomAt(FZoom * (EventInfo.Distance / FPinchDist), P.X, P.Y);
    FPinched := True;
  end;
  if EventInfo.Distance > 0 then
    FPinchDist := EventInfo.Distance;
  Handled := True;
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
  // O vídeo saiu do alinhamento automático, então o retângulo dele é calculado.
  // No construtor a moldura ainda não tem o tamanho final; aqui já tem.
  if Value then ApplyVideoTransform;
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
  // Zoom é do que se estava vendo: câmera nova entra enquadrada.
  ResetVideoZoom;
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
