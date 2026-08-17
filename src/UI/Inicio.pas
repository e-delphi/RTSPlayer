// Eduardo - Player RTSP - shell que hospeda os frames (lista / player / editor /
// gravações)
//
// Níveis de menu. Voltar (seta ou botão do Android) sobe UM nível, sempre pelo
// mesmo caminho — nenhuma tela devolve para quem a abriu por atalho, senão duas
// telas ficam se empurrando uma para a outra:
//
//   Câmeras (raiz)                        voltar = minimiza o app
//   ├── Editor de câmera                  voltar = Câmeras
//   ├── Player AO VIVO                    voltar = Câmeras (para o ao vivo)
//   │     └── [relógio] ────────┐         atalho para o galho de gravação
//   └── Gravações (dias) ◄──────┘         voltar = Câmeras (para tudo)
//         └── Player GRAVAÇÃO             voltar = Gravações
//               └── [ao vivo]             volta para o Player AO VIVO
//
// O relógio e o "ao vivo" são os atalhos que cruzam de um galho para o outro; o
// voltar nunca cruza.
unit Inicio;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.IOUtils,
  System.JSON, System.DateUtils, System.Generics.Collections,
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
  VMS.Net.Probe,
  VMS.Net.Tailscale,
  VMS.Media.Renderer,
  VMS.Api.Client,
  VMS.Play.Engine,
  VMS.Android.MemoLogger,
  UI.Common,
  UI.List,
  UI.Player,
  UI.Editor,
  UI.Days,
  UI.Timeline;

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
    // Estas duas não são TFrame: montadas em código, sem .fmx (ver as units).
    FFrameDays: TFrameDays;
    FTimeline: TFrameTimeline;
    FActive: TControl;
    FTmrStatus: TTimer;
    FPlaying: Boolean;
    FWasPlaying: Boolean;
    FCurrentIndex: Integer;
    // playback de gravação: cliente da API do vmsserver e a engine que ritma a
    // mídia até o renderer (o mesmo do ao vivo)
    FApi: TVmsApiClient;
    FPlayback: TPlaybackEngine;
    FPlaybackOn: Boolean;
    FPlaybackCam: string;   // nome da câmera COMO O SERVIDOR a conhece
    FPlaybackBase: string;  // http://host:porta do caminho que respondeu
    FPlaybackDay: string;   // 'YYYY-MM-DD' do dia aberto
    // Cada consulta assíncrona leva um número; resposta de consulta velha (o
    // usuário já trocou de câmera ou de dia) é descartada na volta.
    FLoadToken: Integer;
    FClosing: Boolean;
    // aviso de buraco na gravação: fica alguns segundos na pílula, senão o salto
    // no tempo parece defeito
    FGapMsgUntil: Int64;
    FGapMsgText: string;
    // posição da gravação quando o app foi para o segundo plano; 0 = não
    // estava tocando gravação
    FResumePlaybackMs: Int64;
    procedure DefaultAppCfg;
    function CamerasFilePath: string;
    procedure LoadCameras;
    procedure SaveCameras;
    procedure RemoveCamera(Index: Integer);
    procedure ShowFrame(F: TControl);
    procedure ShowList;
    procedure ShowPlayer;
    procedure ShowEditor(Index: Integer);
    procedure ShowDays(Index: Integer);
    procedure LoadDaysAsync(Index: Integer);
    procedure LoadSegmentsAsync(const Camera, Day: string);
    procedure DaysBack(Sender: TObject);
    procedure DaysPickDay(Sender: TObject; const Day: string; StartMs, EndMs: Int64);
    procedure TimelineSeek(Sender: TObject; UnixMs: Int64);
    procedure TimelineTogglePlay(Sender: TObject);
    procedure TimelineSpeed(Sender: TObject; MilliX: Int64);
    procedure TimelineLive(Sender: TObject);
    procedure StartPlay(Index: Integer);
    procedure StopPlay;
    // Gravação: entra no modo playback a partir de um instante (ms unix). A tela
    // e o decodificador são os mesmos do ao vivo, então o supervisor para antes.
    procedure StartPlayback(Index: Integer; FromMs: Int64);
    procedure StopPlayback;
    procedure PlayerPlayback(Sender: TObject);
    procedure UpdatePlaybackStatus;
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
  FFramePlayer.OnPlayback := PlayerPlayback;

  // Tela de dias e barra de tempo: montadas em código (ver UI.Days/UI.Timeline).
  // A barra vive dentro do player, alinhada embaixo, e some no modo ao vivo.
  FFrameDays := TFrameDays.Create(Self);
  FFrameDays.Parent := Self;
  FFrameDays.Align := TAlignLayout.Contents;
  FFrameDays.Visible := False;
  FFrameDays.OnBack := DaysBack;
  FFrameDays.OnPickDay := DaysPickDay;

  FTimeline := TFrameTimeline.Create(Self);
  FTimeline.Parent := FFramePlayer;
  FTimeline.Align := TAlignLayout.Bottom;
  FTimeline.Visible := False;
  FTimeline.OnSeek := TimelineSeek;
  FTimeline.OnTogglePlay := TimelineTogglePlay;
  FTimeline.OnSpeedChange := TimelineSpeed;
  FTimeline.OnLive := TimelineLive;

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
  // consultas assíncronas em voo não devem tocar em nada depois daqui
  FClosing := True;
  if FTmrStatus <> nil then
    FTmrStatus.Enabled := False;
  StopPlay;
  StopPlayback;
  // a engine tem threads que usam o cliente: ela morre primeiro
  FreeAndNil(FPlayback);
  FreeAndNil(FApi);
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
  V, EpValue: TJSONValue;
  Arr, Eps: TJSONArray;
  I, J, Count: Integer;
  O: TJSONObject;
  Cam: TCameraConfigEntry;
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
        Cam := MakeCamera(JsonStr(O, 'name'), JsonStr(O, 'url'),
                          JsonStr(O, 'user'), JsonStr(O, 'password'),
                          ParseTransports(JsonStr(O, 'transport')),
                          JsonInt(O, 'maxRetries', 0),
                          JsonInt(O, 'audioDelayMs', 200),
                          JsonInt(O, 'videoDelayMs', 200),
                          JsonBool(O, 'tailscale', False));

        // Os caminhos alternativos. O SaveCameras sempre gravou este array, mas
        // ninguém o lia de volta: toda partida colapsava a câmera no espelho do
        // caminho principal, e os outros sumiam da tela.
        EpValue := O.GetValue('endpoints');
        if EpValue is TJSONArray then
        begin
          Eps := TJSONArray(EpValue);
          SetLength(Cam.Endpoints, Eps.Count);
          Count := 0;
          for J := 0 to Eps.Count - 1 do
            if Eps.Items[J] is TJSONObject then
            begin
              Cam.Endpoints[Count] := ParseEndpoint(TJSONObject(Eps.Items[J]), Count);
              if Trim(Cam.Endpoints[Count].Url) <> '' then
                Inc(Count);
            end;
          SetLength(Cam.Endpoints, Count);
        end;

        // Espelho do primeiro caminho: é o que a lista mostra e o que vale de
        // padrão. Cadastro antigo (uma url só) não tem endpoints e segue igual.
        if Length(Cam.Endpoints) > 0 then
        begin
          Cam.Url := Cam.Endpoints[0].Url;
          Cam.User := Cam.Endpoints[0].User;
          Cam.Password := Cam.Endpoints[0].Password;
          Cam.Transports := Cam.Endpoints[0].Transports;
          Cam.UsesTailscale := Cam.Endpoints[0].UsesTailscale;
        end;
        List.Add(Cam);
      end;
    FCameras := List.ToArray;
  finally
    List.Free;
    V.Free;
  end;
end;

procedure TForm1.SaveCameras;
var
  Arr, Eps: TJSONArray;
  O, Ep: TJSONObject;
  I, J: Integer;
begin
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(FCameras) do
    begin
      O := TJSONObject.Create;
      O.AddPair('name', FCameras[I].Name);
      // Os caminhos alternativos são gravados como estão; o editor mexe no
      // primeiro deles, e os outros passam por aqui intactos.
      if Length(FCameras[I].Endpoints) > 0 then
      begin
        Eps := TJSONArray.Create;
        for J := 0 to High(FCameras[I].Endpoints) do
        begin
          Ep := TJSONObject.Create;
          Ep.AddPair('name', FCameras[I].Endpoints[J].Name);
          Ep.AddPair('url', FCameras[I].Endpoints[J].Url);
          Ep.AddPair('user', FCameras[I].Endpoints[J].User);
          Ep.AddPair('password', FCameras[I].Endpoints[J].Password);
          Ep.AddPair('transport', TransportsToStr(FCameras[I].Endpoints[J].Transports));
          Ep.AddPair('tailscale', TJSONBool.Create(FCameras[I].Endpoints[J].UsesTailscale));
          Eps.AddElement(Ep);
        end;
        O.AddPair('endpoints', Eps);
      end;
      // Espelho do caminho principal: mantém o arquivo legível por quem só
      // entende o formato antigo (e é o que vale se 'endpoints' não existir).
      O.AddPair('url', FCameras[I].Url);
      O.AddPair('user', FCameras[I].User);
      O.AddPair('password', FCameras[I].Password);
      O.AddPair('transport', TransportsToStr(FCameras[I].Transports));
      O.AddPair('maxRetries', TJSONNumber.Create(FCameras[I].MaxReconnectAttempts));
      O.AddPair('audioDelayMs', TJSONNumber.Create(FCameras[I].AudioDelayMs));
      O.AddPair('videoDelayMs', TJSONNumber.Create(FCameras[I].VideoDelayMs));
      O.AddPair('tailscale', TJSONBool.Create(FCameras[I].UsesTailscale));
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

procedure TForm1.ShowFrame(F: TControl);
begin
  FFrameList.Visible := F = FFrameList;
  FFramePlayer.Visible := F = FFramePlayer;
  FFrameEditor.Visible := F = FFrameEditor;
  if FFrameDays <> nil then
    FFrameDays.Visible := F = FFrameDays;
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
  // ao vivo e gravação disputam o mesmo decodificador
  StopPlayback;
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

// Botão do relógio na barra do player: abre a tela de dias com gravação. Em
// modo gravação ele volta ao vivo, que é o caminho de saída mais curto.
procedure TForm1.PlayerPlayback(Sender: TObject);
begin
  if FPlaybackOn then
  begin
    TimelineLive(Sender);
    Exit;
  end;
  ShowDays(FCurrentIndex);
end;

procedure TForm1.ShowDays(Index: Integer);
begin
  if (Index < 0) or (Index > High(FCameras)) then Exit;
  FCurrentIndex := Index;
  FFrameDays.SetTitle(FCameras[Index].Name);
  ShowFrame(FFrameDays);
  // Qual dos caminhos tem servidor de gravação atrás é decidido na thread da
  // consulta: descobrir isso aqui custaria um TCP connect por caminho na thread
  // da UI, e a tela travaria antes de aparecer.
  LoadDaysAsync(Index);
end;

// Primeiro caminho da câmera que tenha um vmsserver atrás E responda. Função
// pura de propósito: roda na thread de rede, sem tocar em nada da tela.
function PickApiEndpoint(const Cam: TCameraConfigEntry;
  out Base, ServerCam: string): Boolean;
var
  Eps: TCameraEndpoints;
  I: Integer;
begin
  Base := '';
  ServerCam := '';
  Eps := Cam.Endpoints;
  if Length(Eps) = 0 then
  begin
    // câmera de caminho único: o próprio campo url
    SetLength(Eps, 1);
    Eps[0].Url := Cam.Url;
  end;
  for I := 0 to High(Eps) do
  begin
    Base := ApiBaseFromCameraUrl(Eps[I].Url);
    ServerCam := CameraNameFromCameraUrl(Eps[I].Url);
    // rota /live/ é o que denuncia um vmsserver; ligação direta na câmera não tem
    if (Base = '') or (ServerCam = '') then Continue;
    if UrlReachable(Eps[I].Url) then Exit(True);
  end;
  Base := '';
  ServerCam := '';
  Result := False;
end;

// A API bloqueia: consultar na thread da UI congelaria a tela por segundos numa
// rede ruim. O resultado volta pela fila da thread principal, e um número de
// consulta descarta resposta que chegou tarde demais.
procedure TForm1.LoadDaysAsync(Index: Integer);
var
  Token: Integer;
  Api: TVmsApiClient;
  Cam: TCameraConfigEntry;
begin
  Inc(FLoadToken);
  Token := FLoadToken;
  Cam := FCameras[Index];
  if FApi = nil then
    FApi := TVmsApiClient.Create('', FLogger);
  Api := FApi;
  FFrameDays.SetLoading;
  TThread.CreateAnonymousThread(
    procedure
    var
      Days: TArray<TApiDay>;
      Base, ServerCam, Err: string;
      Ok: Boolean;
    begin
      Ok := PickApiEndpoint(Cam, Base, ServerCam);
      if Ok then
      begin
        Api.BaseUrl := Base;
        Ok := Api.GetDays(ServerCam, Days);
        Err := Api.LastError;
      end
      else
        Err := '';
      TThread.Queue(nil,
        procedure
        begin
          if FClosing or (Token <> FLoadToken) then Exit;
          if Ok then
          begin
            FPlaybackCam := ServerCam;
            FPlaybackBase := Base;
            FFrameDays.SetDays(Days);
          end
          else if Base = '' then
            FFrameDays.SetError('Nenhum caminho desta c'#$E2'mera passa por um'#13#10 +
              'vmsserver que esteja respondendo agora.')
          else
            FFrameDays.SetError('N'#$E3'o consegui falar com o servidor.'#13#10 + Err);
        end);
    end).Start;
end;

procedure TForm1.LoadSegmentsAsync(const Camera, Day: string);
var
  Token: Integer;
  Api: TVmsApiClient;
begin
  Inc(FLoadToken);
  Token := FLoadToken;
  Api := FApi;
  TThread.CreateAnonymousThread(
    procedure
    var
      Segs: TArray<TApiSegment>;
      DayStart, DayEnd: Int64;
      Ok: Boolean;
    begin
      Ok := Api.GetSegments(Camera, Day, Segs, DayStart, DayEnd);
      TThread.Queue(nil,
        procedure
        begin
          if FClosing or (Token <> FLoadToken) or (not FPlaybackOn) then Exit;
          if Ok and (DayEnd > DayStart) then
            FTimeline.SetDay(DayStart, DayEnd, Segs)
          else
            FLogger.Warn('ui', 'nao consegui carregar as faixas do dia ' + Day);
        end);
    end).Start;
end;

// Voltar sobe UM nível na árvore de telas (ver "Níveis de menu" no cabeçalho da
// unit). Gravações é filha da lista de câmeras, não do player: se voltasse para
// o player, os dois ficariam num vaivém sem saída, que foi o que aconteceu.
procedure TForm1.DaysBack(Sender: TObject);
begin
  StopPlayback;
  StopPlay;
  ShowList;
end;

procedure TForm1.DaysPickDay(Sender: TObject; const Day: string; StartMs, EndMs: Int64);
begin
  FPlaybackDay := Day;
  ShowPlayer;
  // Começa no primeiro instante gravado do dia; a barra chega logo depois, e o
  // usuário arrasta dali.
  StartPlayback(FCurrentIndex, StartMs);
  FTimeline.SetDay(StartMs, EndMs, nil); // régua provisória até as faixas virem
  LoadSegmentsAsync(FPlaybackCam, Day);
end;

procedure TForm1.TimelineSeek(Sender: TObject; UnixMs: Int64);
begin
  if (not FPlaybackOn) or (FPlayback = nil) then Exit;
  FLogger.Info('ui', Format('seek para %s',
    [FormatDateTime('hh:nn:ss', TTimeZone.Local.ToLocalTime(
      UnixToDateTime(UnixMs div 1000, True)))]));
  FFramePlayer.SetSpinner(True);
  FGapMsgUntil := 0;
  FPlayback.SeekTo(UnixMs);
  FTimeline.SetPlaying(True);
end;

procedure TForm1.TimelineTogglePlay(Sender: TObject);
begin
  if (not FPlaybackOn) or (FPlayback = nil) then Exit;
  if FPlayback.State = pbPaused then
  begin
    FPlayback.Resume;
    FTimeline.SetPlaying(True);
  end
  else
  begin
    FPlayback.Pause;
    FTimeline.SetPlaying(False);
  end;
end;

procedure TForm1.TimelineSpeed(Sender: TObject; MilliX: Int64);
begin
  if (not FPlaybackOn) or (FPlayback = nil) then Exit;
  FPlayback.SetSpeed(MilliX / 1000);
end;

procedure TForm1.TimelineLive(Sender: TObject);
begin
  StopPlayback;
  StartPlay(FCurrentIndex);
end;

procedure TForm1.StartPlayback(Index: Integer; FromMs: Int64);
var
  Base, ServerCam: string;
begin
  if (Index < 0) or (Index > High(FCameras)) then Exit;
  // O caminho já foi escolhido (e testado) pela tela de dias; só se veio de
  // outro lugar é que se deriva do endereço principal da câmera. O servidor
  // conhece a câmera pelo nome da ROTA, não pelo rótulo que o usuário deu a ela
  // aqui: "Servidor - frente" no app é 'frente' em rtsp://host:8554/live/frente.
  Base := FPlaybackBase;
  ServerCam := FPlaybackCam;
  if (Base = '') or (ServerCam = '') then
  begin
    Base := ApiBaseFromCameraUrl(FCameras[Index].Url);
    ServerCam := CameraNameFromCameraUrl(FCameras[Index].Url);
  end;
  if (Base = '') or (ServerCam = '') then
  begin
    FLogger.Warn('ui', 'esta camera nao aponta para uma rota /live/ de vmsserver: ' +
      FCameras[Index].Url);
    FFramePlayer.SetStatus(COLOR_DANGER, 'Sem grava'#$E7#$E3'o');
    Exit;
  end;

  // Ao vivo e gravação disputam o mesmo decodificador: um de cada vez.
  StopPlay;
  FCurrentIndex := Index;
  FFramePlayer.ResetForNewPlay;
  FFramePlayer.SetCamName(FCameras[Index].Name + ' (grava'#$E7#$E3'o)');

  // Cliente e engine são criados uma vez e reusados; trocar de câmera troca só
  // a base da URL. Liberar o cliente aqui deixaria a thread de rede da engine
  // com um ponteiro morto.
  if FApi = nil then
    FApi := TVmsApiClient.Create(Base, FLogger)
  else
    FApi.BaseUrl := Base;
  if FPlayback = nil then
    FPlayback := TPlaybackEngine.Create(FRenderer, FApi, FLogger, FClock);

  FLogger.Info('ui', Format('playback "%s" (camera "%s" no servidor %s) a partir de %d',
    [FCameras[Index].Name, ServerCam, Base, FromMs]));
  FPlaybackOn := True;
  FPlaying := True;              // a tela do player se comporta igual
  SetKeepScreenOn(True);
  FTimeline.Visible := True;
  FTimeline.SetPlaying(True);
  FTimeline.SetSpeedLabel(1);
  FFramePlayer.SetPlaying(True);
  FFramePlayer.SetSpinner(True);
  FFramePlayer.SetStatus(STAT_YELLOW, 'Carregando');
  FPlayback.Start(ServerCam, FromMs);
end;

procedure TForm1.StopPlayback;
begin
  if not FPlaybackOn then Exit;
  FPlaybackOn := False;
  if FTimeline <> nil then
    FTimeline.Visible := False;
  if FPlayback <> nil then
    FPlayback.Stop;
  FPlaying := False;
  SetKeepScreenOn(False);
  if FFramePlayer <> nil then
  begin
    FFramePlayer.SetPlaying(False);
    FFramePlayer.SetSpinner(False);
    FFramePlayer.ClearVideo;
  end;
end;

// Chamado pelo timer de status, como o do ao vivo: a engine não empurra evento,
// ela guarda estado e posição.
procedure TForm1.UpdatePlaybackStatus;
var
  Pos, Gap: Int64;
begin
  case FPlayback.State of
    pbPlaying:
      begin
        FFramePlayer.SetSpinner(False);
        Pos := FPlayback.PositionMs;
        // Pulou um trecho sem gravação: diz isso por alguns segundos antes de
        // voltar ao relógio. Sem o aviso, a imagem salta no tempo e parece que
        // o player travou e recuperou.
        if FPlayback.TakeGapNotice(Gap) then
        begin
          FGapMsgUntil := FClock.MonotonicMs + 5000;
          if Gap >= 60000 then
            FGapMsgText := Format('sem grava'#$E7#$E3'o: pulei %d min', [Gap div 60000])
          else
            FGapMsgText := Format('sem grava'#$E7#$E3'o: pulei %d s', [Gap div 1000]);
          FLogger.Info('ui', FGapMsgText);
        end;
        if FClock.MonotonicMs < FGapMsgUntil then
          FFramePlayer.SetStatus(STAT_ORANGE, FGapMsgText)
        else
          FFramePlayer.SetStatus(STAT_GREEN,
            FormatDateTime('hh:nn:ss', TTimeZone.Local.ToLocalTime(
              UnixToDateTime(Pos div 1000, True))));
        FTimeline.SetPosition(Pos);
      end;
    pbBuffering:
      begin
        FFramePlayer.SetStatus(STAT_YELLOW, 'Carregando');
        FFramePlayer.SetSpinner(True);
      end;
    pbPaused:
      FFramePlayer.SetStatus(STAT_GRAY, 'Pausado');
    pbEnded:
      begin
        FFramePlayer.SetStatus(STAT_GRAY, 'Fim da grava'#$E7#$E3'o');
        FFramePlayer.SetSpinner(False);
      end;
    pbError:
      begin
        // Não deixa a tela parada num erro: avisa e volta ao vivo, que é o que
        // o usuário estava vendo antes de tocar no relógio. O porquê fica no log.
        FFramePlayer.SetStatus(COLOR_DANGER, 'Sem grava'#$E7#$E3'o; voltando ao vivo');
        FFramePlayer.SetSpinner(False);
        FLogger.Warn('ui', 'playback falhou; voltando ao vivo');
        StopPlayback;
        StartPlay(FCurrentIndex);
      end;
  end;
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
  // Modo gravação: quem tem estado é a engine, não o supervisor.
  if FPlaybackOn and (FPlayback <> nil) then
  begin
    UpdatePlaybackStatus;
    Exit;
  end;
  if (not FPlaying) or (FSupervisor = nil) then Exit;
  // A sessão está parada esperando o túnel subir: quem tem de agir é o usuário,
  // no app do Tailscale. Dizer "Conectando" aqui esconde justamente isso — ele
  // fica olhando a pílula amarela sem saber que a ação está no outro app.
  if TailnetWaiting and (FSupervisor.State in [svConnecting, svDraining, svBackoff]) then
  begin
    FFramePlayer.SetStatus(STAT_ORANGE, 'Aguardando a VPN');
    FFramePlayer.SetSpinner(True);
    Exit;
  end;
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
var
  Merged: TCameraConfigEntry;
begin
  Merged := Entry;
  // O editor manda a LISTA inteira de caminhos (ele edita todos, um por aba),
  // então é ela que vale. O remendo abaixo só existe para o caso de ela vir
  // vazia: aí o que a câmera já tinha continua valendo, e os campos da tela
  // atualizam o caminho principal — era assim que funcionava quando o editor
  // ainda mexia num caminho só.
  if (Length(Merged.Endpoints) = 0) and
     (EditIndex >= 0) and (EditIndex <= High(FCameras)) and
     (Length(FCameras[EditIndex].Endpoints) > 0) then
  begin
    Merged.Endpoints := Copy(FCameras[EditIndex].Endpoints);
    Merged.Endpoints[0].Url := Entry.Url;
    Merged.Endpoints[0].User := Entry.User;
    Merged.Endpoints[0].Password := Entry.Password;
    Merged.Endpoints[0].Transports := Entry.Transports;
    Merged.Endpoints[0].UsesTailscale := Entry.UsesTailscale;
  end;

  if (EditIndex >= 0) and (EditIndex <= High(FCameras)) then
    FCameras[EditIndex] := Merged
  else
    FCameras := FCameras + [Merged];
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
  // Assistindo gravação, o voltar sobe um nível na navegação — para a lista de
  // dias, de onde se veio — em vez de saltar direto para a lista de câmeras. Sair
  // do histórico é o botão "ao vivo".
  if FPlaybackOn then
  begin
    ShowDays(FCurrentIndex);
    Exit;
  end;
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
  if FActive = FFrameDays then
  begin
    DaysBack(Self); // volta para o player (ao vivo ou gravação), não para a lista
    Key := 0;
  end
  else if FActive = FFramePlayer then
  begin
    PlayerBack(Self); // gravação volta para os dias; ao vivo volta para a lista
    Key := 0;         // consome: não fecha o app
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
        // Gravação também solta o decodificador ao sair: sem isto ela continuava
        // decodificando em segundo plano e, na volta, o ao vivo entrava POR CIMA
        // dela — duas fontes no mesmo decodificador.
        FResumePlaybackMs := 0;
        if FPlaybackOn and (FPlayback <> nil) then
        begin
          FResumePlaybackMs := FPlayback.PositionMs;
          StopPlayback;
        end;
        FWasPlaying := FPlaying;
        if FPlaying then
          StopPlay;
      end;
    TApplicationEvent.BecameActive:
      begin
        // Voltar reconecta do zero, e é isso que faz o caminho ser reescolhido:
        // ligar o Tailscale e voltar ao app acha o endereço da tailnet sozinho,
        // sem ter que passar pela lista de câmeras (ver VMS.Net.Probe).
        if FResumePlaybackMs > 0 then
        begin
          FWasPlaying := False;
          StartPlayback(FCurrentIndex, FResumePlaybackMs);
          FResumePlaybackMs := 0;
        end
        else if FWasPlaying then
        begin
          FWasPlaying := False;
          StartPlay(FCurrentIndex);
        end;
      end;
  end;
end;

end.
