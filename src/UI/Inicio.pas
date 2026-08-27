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
  FMX.Platform, FMX.VirtualKeyboard, FMX.DialogService,
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
  VMS.App.Share,
  UI.Common,
  UI.List,
  UI.Import,
  UI.Player,
  UI.Thumbs,
  UI.Editor,
  UI.Days,
  UI.Events,
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
    // Estas três não são TFrame: montadas em código, sem .fmx (ver as units).
    FFrameDays: TFrameDays;
    FFrameEvents: TFrameEvents;
    FFrameImport: TFrameImport;
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
    // Miniaturas da barra do tempo. A barra recebe a interface e não sabe que
    // existe HTTP por trás (ver UI.Thumbs).
    FThumbs: IThumbProvider;
    FPlaybackOn: Boolean;
    FPlaybackCam: string;   // nome da câmera COMO O SERVIDOR a conhece
    FPlaybackBase: string;  // http://host:porta do caminho que respondeu
    FPlaybackDay: string;   // 'YYYY-MM-DD' do dia aberto
    // Limites do dia aberto, no fuso do SERVIDOR. Guardados porque a tela de
    // eventos volta para a gravação e precisa refazer a régua com a mesma
    // janela — recalculá-la aqui daria outro dia com o app em outro fuso.
    FEventsFromMs: Int64;
    FEventsToMs: Int64;
    // Token PRÓPRIO da consulta de eventos. Ela e a das faixas saem juntas do
    // mesmo clique: com um contador só, o Inc da segunda faria a resposta da
    // primeira ser descartada na volta, e a barra ficaria sem as faixas do dia.
    FEventsToken: Integer;
    // Quando as faixas do dia foram buscadas pela última vez. Elas envelhecem
    // sozinhas: a gravação continua e o fim do último trecho anda.
    FSegsAtualizadoMs: Int64;
    // Onde a reprodução estava ao abrir a lista de eventos, para voltar no
    // mesmo ponto em vez de no fim do dia.
    FEventsResumeMs: Int64;
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
    procedure ShowEvents;
    procedure LoadDaysAsync(Index: Integer);
    // Reenquadrar = True na primeira carga (escolhe zoom e centro); False
    // quando é só a atualização periódica, que não pode mexer na vista.
    procedure LoadSegmentsAsync(const Camera, Day: string;
                                Reenquadrar: Boolean = True);
    // Rebusca as faixas de tempos em tempos, enquanto o dia aberto ainda está
    // sendo gravado.
    procedure RefreshSegmentsIfStale;
    // Os eventos do dia aberto. Alimentam DUAS telas com uma requisição só: a
    // faixa de marcas na barra e a lista da tela de eventos.
    procedure LoadEventsAsync(const Camera: string; FromMs, ToMs: Int64);
    procedure ResumeAt(UnixMs: Int64);
    procedure EventsBack(Sender: TObject);
    procedure EventsPick(Sender: TObject; UnixMs: Int64);
    procedure TimelineEvents(Sender: TObject);
    // Uma miniatura nova chegou. O provedor é compartilhado e só aceita um
    // assinante, então quem o assina é este formulário e repassa para quem está
    // na tela — ver TFrameTimeline.ThumbsArrived.
    procedure ThumbsArrived;
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
    procedure ConfirmRemoveCamera(Index: Integer; AfterRemove: TProc);
    procedure ListExport(Sender: TObject; Index: Integer);
    procedure ListImport(Sender: TObject);
    procedure ImportBack(Sender: TObject);
    procedure ImportPaste(Sender: TObject);
    procedure ImportDo(Sender: TObject; const Text: string);
    function MergeCameras(const Novas: TArray<TCameraConfigEntry>;
      out Add, Upd: Integer): Boolean;
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

const
  // Quanto o histórico recua ao abrir um dia. No dia de hoje isso é "10 minutos
  // atrás"; num dia passado, os últimos 10 minutos gravados dele.
  OPEN_BACK_MS = Int64(10 * 60 * 1000);
  // De quanto em quanto tempo as faixas do dia são rebuscadas enquanto ele
  // ainda está sendo gravado. Ver RefreshSegmentsIfStale.
  SEGS_REFRESH_MS = Int64(30 * 1000);

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
  FMemoLog := TMemoLogger.Create;
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
  FFrameList.OnExportCamera := ListExport;
  FFrameList.OnImport := ListImport;

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

  FFrameEvents := TFrameEvents.Create(Self);
  FFrameEvents.Parent := Self;
  FFrameEvents.Align := TAlignLayout.Contents;
  FFrameEvents.Visible := False;
  FFrameEvents.OnBack := EventsBack;
  FFrameEvents.OnPickEvent := EventsPick;

  FFrameImport := TFrameImport.Create(Self);
  FFrameImport.Parent := Self;
  FFrameImport.Align := TAlignLayout.Contents;
  FFrameImport.Visible := False;
  FFrameImport.OnBack := ImportBack;
  FFrameImport.OnPaste := ImportPaste;
  FFrameImport.OnImport := ImportDo;

  FTimeline := TFrameTimeline.Create(Self);
  FTimeline.Parent := FFramePlayer;
  FTimeline.Align := TAlignLayout.Bottom;
  FTimeline.Visible := False;
  FTimeline.OnSeek := TimelineSeek;
  FTimeline.OnTogglePlay := TimelineTogglePlay;
  FTimeline.OnSpeedChange := TimelineSpeed;
  FTimeline.OnLive := TimelineLive;
  FTimeline.OnEvents := TimelineEvents;

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
  FAppCfg.TransportFallbackTimeoutMs := 5000;
  FAppCfg.KeepAliveMethod := kamGetParameter;
  FAppCfg.MaxBlockSamples := 256;
  FAppCfg.MaxBlockDurationMs := 2000;
  FAppCfg.MaxBlockSizeBytes := 1048576;
  FAppCfg.RotateMs := DEFAULT_ROTATE_MINUTES * 60000;
end;

function TForm1.CamerasFilePath: string;
begin
  Result := System.IOUtils.TPath.Combine(System.IOUtils.TPath.GetDocumentsPath, 'cameras.json');
end;

procedure TForm1.LoadCameras;
var
  S: string;
begin
  SetLength(FCameras, 0);
  if not TFile.Exists(CamerasFilePath) then
    Exit; // começa vazio; o arquivo é criado ao adicionar a primeira câmera
  try
    S := TFile.ReadAllText(CamerasFilePath, TEncoding.UTF8);
  except
    Exit;
  end;
  // Mesmo leitor da importação: o que o outro aparelho exporta pode ser colado
  // direto neste arquivo, e vice-versa.
  if not CamerasFromJson(S, FCameras) then
    SetLength(FCameras, 0);
end;

procedure TForm1.SaveCameras;
begin
  // O texto é o mesmo que a exportação manda para o outro aparelho: um
  // serializador só (ver CamerasToJson em UI.Common).
  TFile.WriteAllText(CamerasFilePath, CamerasToJson(FCameras), TEncoding.UTF8);
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
  // Sair da tela do player para QUALQUER outra encerra o que estava tocando.
  // Trocar de tela escondia o vídeo mas não parava a engine: o áudio continuava
  // saindo por trás da lista de gravações, e o decodificador seguia gastando
  // bateria e rede numa tela que ninguém está vendo. Aqui é o único ponto por
  // onde toda navegação passa, então é aqui que a regra vale para todos os
  // caminhos — inclusive os que ainda não existem.
  if (FActive = FFramePlayer) and (F <> FFramePlayer) then
  begin
    StopPlayback;
    StopPlay;
  end;
  FFrameList.Visible := F = FFrameList;
  FFramePlayer.Visible := F = FFramePlayer;
  FFrameEditor.Visible := F = FFrameEditor;
  if FFrameDays <> nil then
    FFrameDays.Visible := F = FFrameDays;
  if FFrameEvents <> nil then
    FFrameEvents.Visible := F = FFrameEvents;
  if FFrameImport <> nil then
    FFrameImport.Visible := F = FFrameImport;
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

// "Câmera offline" mais a hora da imagem que está na tela. Sem a hora, o texto
// diria que algo está errado sem dizer o que se está vendo — e é justamente a
// idade da imagem que muda o que a pessoa faz a seguir.
function OfflineStatusText(MediaStartMs: Int64): string;
begin
  if MediaStartMs <= 0 then
    Exit('C'#$E2'mera offline; gravac'#$E3'o');
  Result := 'C'#$E2'mera offline; imagem de ' +
    FormatDateTime('dd/mm hh:nn',
      TTimeZone.Local.ToLocalTime(UnixToDateTime(MediaStartMs div 1000, True)));
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

type
  // Um caminho da câmera que pode ter gravação atrás dele.
  TApiCandidate = record
    Url: string;     // endereço RTSP de onde saiu (para o teste rápido de porta)
    Base: string;    // http://host:porta da API
    Cam: string;     // nome da câmera na rota /live/<nome>
    Quick: Boolean;  // respondeu ao teste rápido
  end;

// Quais caminhos desta câmera podem ter gravação, na ordem do cadastro.
//
// O histórico não vem da câmera: vem do vmsserver que a grava. Então, mesmo
// conectado DIRETO na câmera, é nos outros caminhos que se procura — o que
// denuncia um servidor é a rota /live/<nome>. Ligação direta (dvrip://, ou
// rtsp://ip:554/onvif1) não vira candidato.
function CollectApiCandidates(const Cam: TCameraConfigEntry): TArray<TApiCandidate>;
var
  Eps: TCameraEndpoints;
  I, N: Integer;
  C: TApiCandidate;
begin
  Result := nil;
  Eps := Cam.Endpoints;
  if Length(Eps) = 0 then
  begin
    // câmera de caminho único: o próprio campo url
    SetLength(Eps, 1);
    Eps[0].Url := Cam.Url;
  end;
  SetLength(Result, Length(Eps));
  N := 0;
  for I := 0 to High(Eps) do
  begin
    C.Url := Eps[I].Url;
    C.Base := ApiBaseFromCameraUrl(C.Url);
    C.Cam := CameraNameFromCameraUrl(C.Url);
    C.Quick := False;
    if (C.Base = '') or (C.Cam = '') then Continue;
    Result[N] := C;
    Inc(N);
  end;
  SetLength(Result, N);
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
      Cands: TArray<TApiCandidate>;
      I, Pass: Integer;
      Ok, NoServerPath: Boolean;
    begin
      Base := '';
      ServerCam := '';
      Err := '';
      Ok := False;
      Cands := CollectApiCandidates(Cam);
      NoServerPath := Length(Cands) = 0;
      // Teste rápido de porta só para ORDENAR: quem responde na hora vai antes.
      // Ele não elimina ninguém — no 4G, com a tailnet acordando, 700 ms recusam
      // um servidor que está de pé, e aí a resposta seria "não há gravação"
      // quando há.
      for I := 0 to High(Cands) do
        Cands[I].Quick := UrlReachable(Cands[I].Url);
      for Pass := 0 to 1 do
      begin
        if Ok then Break;
        for I := 0 to High(Cands) do
        begin
          if Cands[I].Quick <> (Pass = 0) then Continue;
          Api.BaseUrl := Cands[I].Base;
          if Api.GetDays(Cands[I].Cam, Days) then
          begin
            Base := Cands[I].Base;
            ServerCam := Cands[I].Cam;
            Ok := True;
            Break;
          end;
          // Um relato por candidato. Guardar só o último enganava: com o
          // servidor em primeiro e a tailnet em terceiro, a tela mostrava o
          // timeout da tailnet e escondia o que houve com o servidor, que é o
          // caminho que interessa.
          if Err <> '' then Err := Err + #13#10;
          Err := Err + Format('%s: %s', [Cands[I].Base, Api.LastError]);
        end;
      end;
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
          else if NoServerPath then
            // Nada a tentar de novo: nenhum caminho cadastrado aponta para um
            // servidor. Conexão direta na câmera não guarda histórico.
            FFrameDays.SetError('Esta c'#$E2'mera n'#$E3'o passa por um vmsserver.'#13#10 +
              'Nenhum caminho dela aponta para uma rota /live/.')
          else
            FFrameDays.SetError('N'#$E3'o consegui falar com o servidor.'#13#10 + Err);
        end);
    end).Start;
end;

procedure TForm1.LoadSegmentsAsync(const Camera, Day: string;
  Reenquadrar: Boolean);
var
  Token: Integer;
  Api: TVmsApiClient;
begin
  if FClock <> nil then
    FSegsAtualizadoMs := FClock.NowUtcMs;
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
          begin
            if Reenquadrar then
              FTimeline.SetDay(DayStart, DayEnd, Segs)
            else
              // Só as faixas: o usuário pode ter dado zoom ou arrastado, e a
              // atualização não pode desfazer isso a cada meio minuto.
              FTimeline.SetSegments(Segs);
          end
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
var
  Target: Int64;
begin
  FPlaybackDay := Day;
  ShowPlayer;
  // Começa perto do FIM do que foi gravado no dia, não no começo. Abrindo o dia
  // de hoje isso é "10 minutos atrás", que é o que quase sempre se quer ver;
  // num dia passado, são os últimos 10 minutos daquele dia. Começar às 0h fazia
  // o usuário arrastar a barra o dia inteiro antes de chegar em qualquer coisa.
  Target := EndMs - OPEN_BACK_MS;
  if Target < StartMs then Target := StartMs;
  if Target > EndMs then Target := EndMs;
  StartPlayback(FCurrentIndex, Target);
  // A barra precisa saber a posição ANTES do SetDay: é ela que decide onde a
  // janela vai ficar centrada.
  FTimeline.SetPosition(Target);
  FTimeline.SetDay(StartMs, EndMs, nil); // régua provisória até as faixas virem
  // Dia novo: o que estava desenhado é de outro dia, e some agora — senão as
  // marcas antigas ficariam na barra até a resposta chegar.
  FTimeline.SetEvents(nil);
  FTimeline.SetHasEvents(False);
  LoadSegmentsAsync(FPlaybackCam, Day);
  LoadEventsAsync(FPlaybackCam, StartMs, EndMs);
end;

// Uma requisição, duas telas. A lista do dia inteiro cabe folgada na memória
// (são registros pequenos), e é o que permite trocar a aba do filtro sem
// voltar ao servidor.
procedure TForm1.LoadEventsAsync(const Camera: string; FromMs, ToMs: Int64);
var
  Token: Integer;
  Api: TVmsApiClient;
begin
  Api := FApi;
  if Api = nil then Exit;
  Inc(FEventsToken);
  Token := FEventsToken;
  FEventsFromMs := FromMs;
  FEventsToMs := ToMs;
  FFrameEvents.SetLoading;
  TThread.CreateAnonymousThread(
    procedure
    var
      Evs: TArray<TApiEvent>;
      Ok: Boolean;
      Status: Integer;
      Err: string;
    begin
      Ok := Api.GetEvents(Camera, FromMs, ToMs, '', Evs);
      Status := Api.LastStatus;
      Err := Api.LastError;
      TThread.Queue(nil,
        procedure
        begin
          if FClosing or (Token <> FEventsToken) then Exit;
          // Sucesso, ainda que com zero eventos, é o que diz que o servidor TEM
          // análise. 503 é o servidor dizendo que não tem, e aí o botão nem
          // aparece: uma tela que só poderia mostrar "nada aqui" é pior que
          // botão nenhum.
          FTimeline.SetHasEvents(Ok);
          if Ok then
          begin
            FTimeline.SetEvents(Evs);
            FFrameEvents.SetEvents(Evs);
          end
          else if Status = 503 then
            FFrameEvents.SetError('Este servidor n'#$E3'o tem an'#$E1'lise de imagem.')
          else
            FFrameEvents.SetError('N'#$E3'o consegui carregar os eventos.' +
              sLineBreak + Err);
        end);
    end).Start;
end;

// As faixas do dia são uma FOTOGRAFIA do momento em que se abriu o histórico.
// Se o dia aberto é o de hoje, a gravação continua andando: o último trecho
// cresce, e a barra azul fica cada vez mais atrás do que existe de verdade —
// enquanto o cursor e as miniaturas avançam. Dá a impressão de que o vídeo
// passou do fim da gravação.
//
// Rebuscar a cada meio minuto custa uma consulta pequena e mantém as três
// coisas contando a mesma história. Dia passado não muda mais: não se rebusca.
procedure TForm1.RefreshSegmentsIfStale;
var
  Agora: Int64;
begin
  if (not FPlaybackOn) or (FPlaybackCam = '') or (FPlaybackDay = '') then Exit;
  if FClock = nil then Exit;
  Agora := FClock.NowUtcMs;
  if (FSegsAtualizadoMs > 0) and ((Agora - FSegsAtualizadoMs) < SEGS_REFRESH_MS) then
    Exit;
  // Só o dia que ainda está sendo gravado: o de ontem não ganha faixa nova.
  if FEventsToMs <= Agora then
  begin
    FSegsAtualizadoMs := Agora;
    LoadSegmentsAsync(FPlaybackCam, FPlaybackDay, False);
  end;
end;

procedure TForm1.ShowEvents;
begin
  FFrameEvents.SetTitle(Format('Eventos - %s',
    [FormatDayLabel(FPlaybackDay)]));
  // Só agora a lista é construída. Montá-la ao receber os eventos fazia o
  // PLAYER demorar a abrir — são ~1.500 eventos por câmera por dia, e eles
  // chegam junto com as faixas do dia, antes de alguém pedir esta tela.
  FFrameEvents.Montar;
  ShowFrame(FFrameEvents);
end;

procedure TForm1.TimelineEvents(Sender: TObject);
begin
  // Onde se estava, para o voltar não jogar o usuário para o fim do dia. É
  // preciso ler ANTES do ShowFrame: sair da tela do player para a lista encerra
  // a engine (ver ShowFrame), e depois disso a posição já não existe.
  FEventsResumeMs := 0;
  if (FPlayback <> nil) and FPlaybackOn then
    FEventsResumeMs := FPlayback.PositionMs;
  ShowEvents;
end;

// Retoma a gravação do dia num instante. É o caminho de saída da lista de
// eventos, tanto pelo voltar (onde se estava) quanto por um item (onde o evento
// começou).
procedure TForm1.ResumeAt(UnixMs: Int64);
begin
  if FEventsToMs <= FEventsFromMs then Exit;
  if UnixMs < FEventsFromMs then UnixMs := FEventsFromMs;
  if UnixMs > FEventsToMs then UnixMs := FEventsToMs;
  ShowPlayer;
  StartPlayback(FCurrentIndex, UnixMs);
  // A barra precisa da posição ANTES do SetDay: é ela que decide onde a janela
  // fica centrada (mesma ordem do DaysPickDay).
  FTimeline.SetPosition(UnixMs);
  FTimeline.SetDay(FEventsFromMs, FEventsToMs, nil);
  LoadSegmentsAsync(FPlaybackCam, FPlaybackDay);
  LoadEventsAsync(FPlaybackCam, FEventsFromMs, FEventsToMs);
end;

procedure TForm1.EventsBack(Sender: TObject);
var
  Alvo: Int64;
begin
  Alvo := FEventsResumeMs;
  // Sem posição guardada (a lista foi aberta sem reprodução em curso): cai na
  // mesma regra do histórico, perto do fim do dia.
  if Alvo <= 0 then Alvo := FEventsToMs - OPEN_BACK_MS;
  ResumeAt(Alvo);
end;

procedure TForm1.EventsPick(Sender: TObject; UnixMs: Int64);
begin
  ResumeAt(UnixMs);
end;

procedure TForm1.ThumbsArrived;
begin
  if FClosing then Exit;
  if (FActive = FFrameEvents) and (FFrameEvents <> nil) then
    FFrameEvents.ThumbsArrived
  else if (FActive = FFramePlayer) and (FTimeline <> nil) then
    FTimeline.ThumbsArrived;
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
  Cands: TArray<TApiCandidate>;
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
    // Primeiro caminho que pareça servidor — e não o espelho do caminho 1, que
    // muda de dono quando o usuário reordena os caminhos.
    Cands := CollectApiCandidates(FCameras[Index]);
    if Length(Cands) > 0 then
    begin
      Base := Cands[0].Base;
      ServerCam := Cands[0].Cam;
    end;
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
  // O provedor de miniaturas nasce aqui, e não no FormCreate, porque depende do
  // cliente de API — que só existe quando se sabe qual servidor respondeu. Como
  // o cliente é reusado (só troca a base da URL), um provedor basta.
  if FThumbs = nil then
  begin
    FThumbs := TApiThumbProvider.Create(FApi, FLogger);
    FTimeline.SetThumbProvider(FThumbs);
    FFrameEvents.SetThumbProvider(FThumbs);
    FThumbs.SetOnArrived(ThumbsArrived);
  end;

  FLogger.Info('ui', Format('playback "%s" (camera "%s" no servidor %s) a partir de %d',
    [FCameras[Index].Name, ServerCam, Base, FromMs]));
  FPlaybackOn := True;
  FPlaying := True;              // a tela do player se comporta igual
  SetKeepScreenOn(True);
  FTimeline.Visible := True;
  FTimeline.SetPlaying(True);
  // Gravação nova começa em 1x — no rótulo E na engine. O SeekTo passa pelo
  // mesmo Start, então zerar a velocidade lá dentro faria arrastar a barra a 8x
  // cair para 1x; aqui é o único ponto que significa "outra gravação".
  FTimeline.SetSpeedLabel(1);
  FPlayback.SetSpeed(1);
  // As miniaturas são da câmera que se vai assistir: trocar aqui descarta as da
  // anterior, que não dizem nada sobre esta.
  if FThumbs <> nil then FThumbs.SetCamera(ServerCam);
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
    RefreshSegmentsIfStale;
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
      begin
        // Chegando mídia, mas do ARQUIVO: a câmera está fora do ar e o servidor
        // está servindo a última gravação dela. Verde aqui era a pílula dizendo
        // "ao vivo" sobre uma imagem de horas atrás.
        if not FSupervisor.Metrics.SourceIsLive then
          FFramePlayer.SetStatus(COLOR_DANGER, OfflineStatusText(FSupervisor.Metrics.MediaStartMs))
        else
          FFramePlayer.SetStatus(STAT_GREEN, 'Ao vivo');
        FFramePlayer.SetSpinner(False);
      end;
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

// Apagar câmera é a única ação sem volta do app, e chega por dois caminhos (a
// lixeira da lista e o botão da tela de cadastro). A pergunta mora aqui, no
// único ponto que de fato remove: uma confirmação por caminho acabaria virando
// duas em cima da outra, ou nenhuma no caminho que alguém esquecesse.
//
// O MessageDialog assíncrono é o que funciona no Android — lá o diálogo não
// bloqueia, e a resposta chega pelo callback, na thread da UI.
procedure TForm1.ConfirmRemoveCamera(Index: Integer; AfterRemove: TProc);
var
  Nome, Msg: string;
begin
  if (Index < 0) or (Index > High(FCameras)) then Exit;
  Nome := Trim(FCameras[Index].Name);
  if Nome = '' then Nome := 'esta c'#$E2'mera';
  Msg := Format('Excluir "%s"?' + sLineBreak + sLineBreak +
    'Sai da lista deste aparelho, com todos os caminhos cadastrados.' +
    ' As grava'#$E7#$F5'es no servidor n'#$E3'o s'#$E3'o apagadas.', [Nome]);
  TDialogService.MessageDialog(Msg, TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbNo, 0,
    procedure(const AResult: TModalResult)
    begin
      if AResult <> mrYes then Exit;
      if FCurrentIndex = Index then
        StopPlay;
      RemoveCamera(Index);
      if Assigned(AfterRemove) then AfterRemove();
    end);
end;

procedure TForm1.ListDelete(Sender: TObject; Index: Integer);
begin
  ConfirmRemoveCamera(Index,
    procedure
    begin
      FFrameList.SetCameras(FCameras);
    end);
end;

// Exportar: o MESMO texto do cameras.json vai para a bandeja de compartilhar do
// sistema, e o usuário escolhe o destino (WhatsApp, e-mail, arquivo). Não
// gravamos arquivo nenhum — isso exigiria SAF e permissão de armazenamento para
// resolver um problema que o compartilhamento já resolve.
//
// As senhas das câmeras vão no texto, em claro. É o mesmo que já está no
// cameras.json do aparelho, mas aqui ele sai do aparelho: o aviso é o mínimo
// devido.
// Exporta UMA câmera, com todos os caminhos dela. O texto sai no mesmo formato
// do cameras.json (uma lista, aqui de um item só), então a importação do outro
// lado é a mesma, e o arquivo do aparelho continua sendo o mesmo formato.
//
// Uma de cada vez porque é assim que se usa: a câmera nova vai para o aparelho
// de alguém, e não o cadastro inteiro da casa.
procedure TForm1.ListExport(Sender: TObject; Index: Integer);
var
  Texto, Nome: string;
  Uma: TArray<TCameraConfigEntry>;
begin
  if (Index < 0) or (Index > High(FCameras)) then Exit;
  Nome := Trim(FCameras[Index].Name);
  if Nome = '' then Nome := 'c'#$E2'mera';
  SetLength(Uma, 1);
  Uma[0] := FCameras[Index];
  Texto := CamerasToJson(Uma);
  // Pergunta antes: aqui os dados SAEM do aparelho, e vão com as senhas em
  // claro. Depois que o texto entra numa conversa, não volta.
  TDialogService.MessageDialog(
    Format('Exportar "%s" com %d caminho(s)?' + sLineBreak + sLineBreak +
      'O texto leva a SENHA da c'#$E2'mera em claro. Mande s'#$F3' para quem deve ter' +
      ' acesso a ela, e apague a mensagem depois de importar.',
      [Nome, Length(FCameras[Index].Endpoints)]),
    TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbNo, 0,
    procedure(const AResult: TModalResult)
    begin
      if AResult <> mrYes then Exit;
      FLogger.Info('ui', Format('exportando "%s" (%d caminhos, %d caracteres)',
        [Nome, Length(Uma[0].Endpoints), Length(Texto)]));
      if ShareText(Format('C'#$E2'mera %s (RTSPlayer)', [Nome]), Texto) then Exit;
      // Sem bandeja (Windows): a área de transferência faz o mesmo papel.
      if ClipboardSetText(Texto) then
        TDialogService.ShowMessage(Format('"%s" copiada para a '#$E1'rea de' +
          ' transfer'#$EA'ncia.', [Nome]))
      else
        TDialogService.ShowMessage('N'#$E3'o consegui exportar neste aparelho.');
    end);
end;

procedure TForm1.ListImport(Sender: TObject);
begin
  FFrameImport.Reset;
  ShowFrame(FFrameImport);
end;

procedure TForm1.ImportBack(Sender: TObject);
begin
  ShowList;
end;

procedure TForm1.ImportPaste(Sender: TObject);
var
  S: string;
begin
  if ClipboardGetText(S) and (Trim(S) <> '') then
    FFrameImport.SetText(S)
  else
    FFrameImport.SetResult('N'#$E3'o h'#$E1' texto na '#$E1'rea de transfer'#$EA'ncia.', True);
end;

// Junta o que veio com o que já existe. Casa por NOME (sem diferenciar
// maiúsculas): mesma câmera vira atualização, nome novo entra no fim. Substituir
// a lista inteira seria mais simples e apagaria o que só existe neste aparelho.
function TForm1.MergeCameras(const Novas: TArray<TCameraConfigEntry>;
  out Add, Upd: Integer): Boolean;
var
  I, J, K: Integer;
  Achou: Boolean;
begin
  Add := 0;
  Upd := 0;
  for I := 0 to High(Novas) do
  begin
    Achou := False;
    for J := 0 to High(FCameras) do
      if SameText(Trim(FCameras[J].Name), Trim(Novas[I].Name)) then
      begin
        // Mantém a câmera tocando se for a atual: só os dados mudam.
        FCameras[J] := Novas[I];
        Inc(Upd);
        Achou := True;
        Break;
      end;
    if not Achou then
    begin
      K := Length(FCameras);
      SetLength(FCameras, K + 1);
      FCameras[K] := Novas[I];
      Inc(Add);
    end;
  end;
  Result := (Add + Upd) > 0;
end;

procedure TForm1.ImportDo(Sender: TObject; const Text: string);
var
  Novas: TArray<TCameraConfigEntry>;
  Add, Upd: Integer;
begin
  if Trim(Text) = '' then
  begin
    FFrameImport.SetResult('Cole o texto exportado antes de importar.', True);
    Exit;
  end;
  if not CamerasFromJson(Text, Novas) then
  begin
    FFrameImport.SetResult('N'#$E3'o entendi esse texto: era para ser a lista JSON' +
      ' que o outro aparelho exportou.', True);
    Exit;
  end;
  if Length(Novas) = 0 then
  begin
    FFrameImport.SetResult('O texto '#$E9' uma lista v'#$E1'lida, mas sem nenhuma' +
      ' c'#$E2'mera com endere'#$E7'o.', True);
    Exit;
  end;
  if not MergeCameras(Novas, Add, Upd) then
  begin
    FFrameImport.SetResult('Nada a importar.', True);
    Exit;
  end;
  SaveCameras;
  FLogger.Info('ui', Format('importadas %d nova(s), %d atualizada(s)', [Add, Upd]));
  FFrameImport.SetResult(Format('%d c'#$E2'mera(s) nova(s) e %d atualizada(s).', [Add, Upd]), False);
  ShowList;
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
  ConfirmRemoveCamera(Index,
    procedure
    begin
      ShowList;
    end);
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
  end
  else if FActive = FFrameImport then
  begin
    ShowList; // desiste da importação
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
        // OS DOIS eventos chegam ao sair do app, nesta ordem: WillBecomeInactive
        // e depois EnteredBackground. Por isso nada aqui pode ZERAR o que o
        // evento anterior guardou — a primeira passagem para o que estava
        // tocando, e a segunda encontraria tudo parado e apagaria a intenção de
        // retomar. Era o que fazia a câmera não voltar sozinha depois de passar
        // pelo app do Tailscale: o app parava e, na volta, não tentava de novo.
        //
        // Gravação também solta o decodificador ao sair: sem isto ela continuava
        // decodificando em segundo plano e, na volta, o ao vivo entrava POR CIMA
        // dela — duas fontes no mesmo decodificador.
        if FPlaybackOn and (FPlayback <> nil) then
        begin
          FResumePlaybackMs := FPlayback.PositionMs;
          StopPlayback;
        end;
        if FPlaying then
        begin
          FWasPlaying := True;
          StopPlay;
        end;
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
