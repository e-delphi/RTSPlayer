program vmsserver;

// Servidor VMS: conecta nas câmeras (mesmo cliente do RTSPlayer, rtsp e dvrip),
// grava cada uma em .vms e publica todas em UMA porta RTSP, uma rota por
// câmera:  rtsp://<host>:8554/live/<nome-da-camera>
//
// Pensado para rodar na máquina que enxerga as câmeras e ser acessado pelo
// celular via Tailscale (ver bindAddress em vmsserver.json).
//
// As units VMS.* vêm de ..\src (compartilhadas com o app RTSPlayer); as Tx.*
// implementam o servidor RTSP. As ONNX.*/Vision.* são cópia literal do projeto
// onnx-pascal (ver ..\vendor\onnx-pascal\README.md) e só a Vms.Analytics.Onnx
// fala com elas.

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  // ---- compartilhado com o RTSPlayer (mesmo repositório) ----
  VMS.Domain.Types in '..\src\Domain\VMS.Domain.Types.pas',
  VMS.Domain.Logging in '..\src\Domain\VMS.Domain.Logging.pas',
  VMS.Domain.Clock in '..\src\Domain\VMS.Domain.Clock.pas',
  VMS.Domain.MediaSink in '..\src\Domain\VMS.Domain.MediaSink.pas',
  VMS.Domain.Reconnect in '..\src\Domain\VMS.Domain.Reconnect.pas',
  VMS.Domain.Session in '..\src\Domain\VMS.Domain.Session.pas',
  VMS.Domain.Supervisor in '..\src\Domain\VMS.Domain.Supervisor.pas',
  VMS.Net.Intf in '..\src\Net\VMS.Net.Intf.pas',
  VMS.Net.Tcp in '..\src\Net\VMS.Net.Tcp.pas',
  VMS.Net.Tailscale in '..\src\Net\VMS.Net.Tailscale.pas',
  VMS.Net.Udp in '..\src\Net\VMS.Net.Udp.pas',
  VMS.Net.Probe in '..\src\Net\VMS.Net.Probe.pas',
  VMS.Rtp.Demux in '..\src\Rtp\VMS.Rtp.Demux.pas',
  VMS.Rtp.Packet in '..\src\Rtp\VMS.Rtp.Packet.pas',
  VMS.Rtsp.Auth in '..\src\Rtsp\VMS.Rtsp.Auth.pas',
  VMS.Rtsp.Client in '..\src\Rtsp\VMS.Rtsp.Client.pas',
  VMS.Rtsp.Messages in '..\src\Rtsp\VMS.Rtsp.Messages.pas',
  VMS.Rtsp.Transport in '..\src\Rtsp\VMS.Rtsp.Transport.pas',
  VMS.Rtsp.Url in '..\src\Rtsp\VMS.Rtsp.Url.pas',
  VMS.Rtsp.WireReader in '..\src\Rtsp\VMS.Rtsp.WireReader.pas',
  VMS.Sdp.Parser in '..\src\Sdp\VMS.Sdp.Parser.pas',
  VMS.Sdp.Types in '..\src\Sdp\VMS.Sdp.Types.pas',
  VMS.Depk.Intf in '..\src\Depacketizer\VMS.Depk.Intf.pas',
  VMS.Depk.Base in '..\src\Depacketizer\VMS.Depk.Base.pas',
  VMS.Depk.Factory in '..\src\Depacketizer\VMS.Depk.Factory.pas',
  VMS.Depk.H264 in '..\src\Depacketizer\VMS.Depk.H264.pas',
  VMS.Depk.H265 in '..\src\Depacketizer\VMS.Depk.H265.pas',
  VMS.Depk.AAC in '..\src\Depacketizer\VMS.Depk.AAC.pas',
  VMS.Depk.G711 in '..\src\Depacketizer\VMS.Depk.G711.pas',
  VMS.Depk.G726 in '..\src\Depacketizer\VMS.Depk.G726.pas',
  VMS.Depk.MJPEG in '..\src\Depacketizer\VMS.Depk.MJPEG.pas',
  VMS.Depk.PCM in '..\src\Depacketizer\VMS.Depk.PCM.pas',
  VMS.Dvrip.Protocol in '..\src\Dvrip\VMS.Dvrip.Protocol.pas',
  VMS.Dvrip.Media in '..\src\Dvrip\VMS.Dvrip.Media.pas',
  VMS.Dvrip.Session in '..\src\Dvrip\VMS.Dvrip.Session.pas',
  VMS.Rec.Crc32 in '..\src\Recording\VMS.Rec.Crc32.pas',
  VMS.Rec.Format in '..\src\Recording\VMS.Rec.Format.pas',
  VMS.Rec.Block in '..\src\Recording\VMS.Rec.Block.pas',
  VMS.Rec.Writer in '..\src\Recording\VMS.Rec.Writer.pas',
  VMS.Rec.Sidecar in '..\src\Recording\VMS.Rec.Sidecar.pas',
  VMS.Rec.Reader in '..\src\Recording\VMS.Rec.Reader.pas',
  VMS.Rec.Paths in '..\src\Recording\VMS.Rec.Paths.pas',
  VMS.App.Clock in '..\src\App\VMS.App.Clock.pas',
  VMS.App.Logger in '..\src\App\VMS.App.Logger.pas',
  VMS.App.Config in '..\src\App\VMS.App.Config.pas',
  VMS.App.Composition in '..\src\App\VMS.App.Composition.pas',
  // ---- servidor RTSP ----
  Tx.Pkt.RtpBuilder in 'src\Packetizer\Tx.Pkt.RtpBuilder.pas',
  Tx.Pkt.Intf in 'src\Packetizer\Tx.Pkt.Intf.pas',
  Tx.Pkt.Base in 'src\Packetizer\Tx.Pkt.Base.pas',
  Tx.Pkt.H264 in 'src\Packetizer\Tx.Pkt.H264.pas',
  Tx.Pkt.H265 in 'src\Packetizer\Tx.Pkt.H265.pas',
  Tx.Pkt.AAC in 'src\Packetizer\Tx.Pkt.AAC.pas',
  Tx.Pkt.MJPEG in 'src\Packetizer\Tx.Pkt.MJPEG.pas',
  Tx.Pkt.Passthrough in 'src\Packetizer\Tx.Pkt.Passthrough.pas',
  Tx.Pkt.Factory in 'src\Packetizer\Tx.Pkt.Factory.pas',
  Tx.Server.Types in 'src\Server\Tx.Server.Types.pas',
  Tx.Server.Sdp in 'src\Server\Tx.Server.Sdp.pas',
  Tx.Server.Session in 'src\Server\Tx.Server.Session.pas',
  Tx.Server.Listener in 'src\Server\Tx.Server.Listener.pas',
  // ---- deste app ----
  Vms.Server.LiveHub in 'src\Live\Vms.Server.LiveHub.pas',
  Vms.Server.IndexCache in 'src\Api\Vms.Server.IndexCache.pas',
  Vms.Server.Media in 'src\Api\Vms.Server.Media.pas',
  Vms.Server.Api in 'src\Api\Vms.Server.Api.pas',
  Vms.Server.RecSink in 'src\Recording\Vms.Server.RecSink.pas',
  Vms.Server.Logger in 'src\App\Vms.Server.Logger.pas',
  Vms.Server.LoggerDb in 'src\App\Vms.Server.LoggerDb.pas',
  Vms.Server.Retention in 'src\App\Vms.Server.Retention.pas',
  Vms.Server.Repair in 'src\App\Vms.Server.Repair.pas',
  Vms.Thumb.Intf in 'src\Thumbs\Vms.Thumb.Intf.pas',
  Vms.Thumb.Cache in 'src\Thumbs\Vms.Thumb.Cache.pas',
  Vms.Thumb.Keyframe in 'src\Thumbs\Vms.Thumb.Keyframe.pas',
  Vms.Thumb.Service in 'src\Thumbs\Vms.Thumb.Service.pas',
  Vms.Thumb.FFmpeg in 'src\Thumbs\Vms.Thumb.FFmpeg.pas',
  Vms.Thumb.JpegVcl in 'src\Thumbs\Vms.Thumb.JpegVcl.pas',
  Vms.Thumb.IndexDb in 'src\Thumbs\Vms.Thumb.IndexDb.pas',
  FFmpegLib in '..\src\Win\FFmpegLib.pas',
  // ---- visão computacional: cópia do onnx-pascal, não editar ----
  ONNX.CApi in '..\vendor\onnx-pascal\ONNX.CApi.pas',
  ONNX.Types in '..\vendor\onnx-pascal\ONNX.Types.pas',
  ONNX.Runtime in '..\vendor\onnx-pascal\ONNX.Runtime.pas',
  ONNX.Session in '..\vendor\onnx-pascal\ONNX.Session.pas',
  Vision.Types in '..\vendor\onnx-pascal\Vision.Types.pas',
  Vision.Image in '..\vendor\onnx-pascal\Vision.Image.pas',
  Vision.Preprocess in '..\vendor\onnx-pascal\Vision.Preprocess.pas',
  Vision.Nms in '..\vendor\onnx-pascal\Vision.Nms.pas',
  Vision.Model in '..\vendor\onnx-pascal\Vision.Model.pas',
  Vision.Decoder in '..\vendor\onnx-pascal\Vision.Decoder.pas',
  // O decoder se registra sozinho no initialization: estar no uses É o que
  // habilita a cabeça de detecção. Nenhum `case` conhece o nome dela.
  Vision.Decoder.Detect in '..\vendor\onnx-pascal\Vision.Decoder.Detect.pas',
  Vision.Predictor in '..\vendor\onnx-pascal\Vision.Predictor.pas',
  // ---- análise de imagem: eventos de movimento e de objeto ----
  Vms.Analytics.Types in 'src\Analytics\Vms.Analytics.Types.pas',
  Vms.Analytics.Intf in 'src\Analytics\Vms.Analytics.Intf.pas',
  Vms.Analytics.Motion in 'src\Analytics\Vms.Analytics.Motion.pas',
  Vms.Analytics.Store in 'src\Analytics\Vms.Analytics.Store.pas',
  Vms.Analytics.Onnx in 'src\Analytics\Vms.Analytics.Onnx.pas',
  Vms.Analytics.Analyzer in 'src\Analytics\Vms.Analytics.Analyzer.pas',
  Vms.Analytics.Worker in 'src\Analytics\Vms.Analytics.Worker.pas',
  // ---- banco: uma thread dona da conexao, as outras enfileiram ----
  Vms.Db.Intf in 'src\Db\Vms.Db.Intf.pas',
  Vms.Db.Schema.Sql in 'src\Db\Vms.Db.Schema.Sql.pas',
  Vms.Db.Queue in 'src\Db\Vms.Db.Queue.pas',
  Vms.Db.Schema in 'src\Db\Vms.Db.Schema.pas',
  Vms.Db.Config in 'src\Db\Vms.Db.Config.pas',
  Vms.Analytics.StoreDb in 'src\Analytics\Vms.Analytics.StoreDb.pas',
  Vms.Server.Config in 'src\App\Vms.Server.Config.pas',
  Vms.Server.Composition in 'src\App\Vms.Server.Composition.pas';

const
  // Tamanho máximo da miniatura, em pixels. 160 de largura enche a barra do app
  // sem passar de ~4 KB por imagem; a proporção do vídeo é preservada dentro
  // desta caixa, então 16:9 sai 160x90.
  THUMB_W = 160;
  THUMB_H = 120;

var
  GStopEvent: TEvent;

{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  case CtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
    begin
      if GStopEvent <> nil then
        GStopEvent.SetEvent;
      Result := True;
    end;
  else
    Result := False;
  end;
end;
{$ENDIF}

function ResolveConfigPath: string;
var
  Arg, ConfigName: string;
begin
  if ParamCount >= 1 then
  begin
    Arg := ParamStr(1);
    if FileExists(Arg) then Exit(Arg);
  end;
  ConfigName := ChangeFileExt(ExtractFileName(ParamStr(0)), '.json');
  Result := ExtractFilePath(ParamStr(0)) + ConfigName;
  if FileExists(Result) then Exit;
  Result := GetCurrentDir + PathDelim + ConfigName;
end;

procedure RunApp;
var
  ConfigPath, StorageDir, BindAddress: string;
  Cfg: TVmsServerConfig;
  App: TAppConfig;
  RtspPort: Word;
  Retention: TRetentionPolicy;
  Sweeper: TRetentionThread;
  LiveCfg: TLiveConfig;
  Hub: TLiveHub;
  ApiCfg: TApiConfig;
  Api: TApiRouter;
  Cache: TVmsIndexCache;
  Thumbs: IThumbSource;
  AnalyticsCfg: TAnalyticsConfig;
  Analytics: TAnalyticsRig;
  Db: IDbQueue;
  CameraNames: TArray<string>;
  Logger: ILogger;
  // Console. Comeca sozinho (antes de o banco existir, nao ha onde mais
  // escrever) e depois vira a metade "console" do TSqliteLogger.
  Boot: ILogger;
  DbCfg: TDbConfig;
  Clock: IClock;
  Supervisors: TAppSupervisorList;
  Listener: TTxServerListener;
  I: Integer;
begin
  ConfigPath := ResolveConfigPath;
  Cfg := TVmsServerConfig.Create;
  try
    Cfg.LoadFromFile(ConfigPath);
    App := Cfg.Config;          // parte comum, igual à do RTSPlayer
    RtspPort := Cfg.RtspPort;   // campos que só o servidor tem
    BindAddress := Cfg.BindAddress;
    Retention := Cfg.Retention;
    LiveCfg := Cfg.Live;
    ApiCfg := Cfg.Api;
    AnalyticsCfg := Cfg.Analytics;
  finally
    Cfg.Free;
  end;

  Clock := BuildClock;

  // O banco precisa subir ANTES do logger, porque agora é dele que sai a
  // configuração — inclusive o logDir e a lista de câmeras que o logger usa.
  // Até aqui só existe console: o TPerCameraLogger ainda não tem como saber
  // onde gravar.
  Boot := TConsoleLogger.Create;
  // Lugar fixo, ao lado do executavel: o caminho do banco nao pode morar na
  // configuracao que esta dentro dele.
  Db := TDbQueue.Create(DefaultDbPath);
  EnsureSchema(Db, Clock, Boot);

  // Uma vez, e só uma: o que estava no vmsserver.json vai para as tabelas.
  // Marcado em db_meta; o arquivo NÃO é renomeado, porque ele continua sendo
  // quem guarda o dbPath — que por definição não pode morar dentro do banco
  // que ele localiza.
  if not ConfigImported(Db) then
    ImportConfig(Db, App, RtspPort, BindAddress, Retention, LiveCfg, ApiCfg,
                 AnalyticsCfg, Clock, Boot);

  // Daqui em diante a verdade é o banco. Editar o json não muda mais nada
  // exceto o caminho do próprio banco.
  DbCfg := TDbConfig.Create(Db, Boot);
  try
    DbCfg.Load;
    App := DbCfg.Config;
    RtspPort := DbCfg.RtspPort;
    BindAddress := DbCfg.BindAddress;
    Retention := DbCfg.Retention;
    LiveCfg := DbCfg.Live;
    ApiCfg := DbCfg.Api;
    AnalyticsCfg := DbCfg.Analytics;
  finally
    DbCfg.Free;
  end;

  // Câmera acrescentada depois precisa da LINHA em `camera`, senão os eventos e
  // o inventário dela caem na chave estrangeira e não gravam — em silêncio, no
  // log de emergência da fila. Barato o bastante para rodar toda subida.
  EnsureCameras(Db, App.Cameras, Clock);

  // O log vai para a tabela `log`, e sai no console ao mesmo tempo. Nada é
  // descartado por nível: `level` é coluna, nunca filtro (ver LoggerDb).
  //
  // O `logDir` da configuração deixa de ser usado; fica lá porque o
  // TPerCameraLogger continua no repositório, e voltar a ele é trocar esta
  // linha por `TPerCameraLogger.Create(App.LogDir, App.Cameras)`.
  Logger := TSqliteLogger.Create(Db, Clock, Boot);

  StorageDir := ExpandFileName(App.StorageDir);
  if not DirectoryExists(StorageDir) then
    ForceDirectories(StorageDir);

  Logger.Info('main', 'Config: ' + ConfigPath);
  Logger.Info('main', 'Gravacoes: ' + StorageDir);
  Logger.Info('main', Format('Espaco livre: %.1f GB | retencao: %s',
    [FreeSpaceOf(StorageDir) / GIGABYTE, Retention.Describe]));
  Logger.Info('main', 'Ao vivo: ' + LiveCfg.Describe);
  Logger.Info('main', 'API de gravacoes: ' + ApiCfg.Describe);
  Logger.Info('main', 'Analise de imagem: ' + AnalyticsCfg.Describe);
  if ApiCfg.Enabled and (BindAddress = '') then
    Logger.Warn('main', 'API sem autenticacao escutando em todas as interfaces: ' +
      'quem alcanca esta porta baixa gravacao. Use bindAddress para limitar ao tailnet.');

  Logger.Info('main', 'Banco: ' + DescribeDb(Db));

  // Uma varredura antes de começar a gravar: se o disco já está no limite, é
  // agora que se abre espaço, não cinco minutos depois.
  Sweeper := nil;
  if Retention.Enabled then
    SweepRetention(StorageDir, Retention, Logger);

  // Gravações que ficaram abertas (queda de energia, processo morto) ganham
  // agora o índice e o rodapé que não deu tempo de escrever. Tem de ser ANTES de
  // subir os supervisores: depois deles, o arquivo mais recente de cada câmera
  // está sendo gravado, e ninguém deve mexer nele.
  SetLength(CameraNames, Length(App.Cameras));
  for I := 0 to High(App.Cameras) do
    CameraNames[I] := App.Cameras[I].Name;
  FinalizeOrphanRecordings(StorageDir, CameraNames, Logger);

  // O hub nasce antes dos supervisores (os sinks deles publicam nele) e morre
  // depois (o servidor RTSP lê dele).
  Hub := nil;
  if LiveCfg.Enabled then
    Hub := TLiveHub.Create(LiveCfg, Logger, Clock);
  try
    // CameraNames já está montado (a finalização acima usa a mesma lista): é
    // com ele que a API confere o nome que o cliente manda, antes de virar
    // caminho de arquivo.
    // O cache das gravações e a fonte de miniaturas nascem aqui, e não dentro
    // do roteador: composição é o único lugar que pode conhecer implementação
    // concreta, e é o que deixa o roteador falar só com interfaces.
    Api := nil;
    Cache := nil;
    Thumbs := nil;
    Analytics := Default(TAnalyticsRig);
    if ApiCfg.Enabled then
    begin
      Cache := TVmsIndexCache.Create(StorageDir, Db, Logger);
      Thumbs := BuildThumbSource(Cache, Db, Clock, THUMB_W, THUMB_H, Logger);
      // A análise depende do MESMO cache de índices das miniaturas — é ele que
      // faz achar o keyframe de um instante custar uma busca binária. Por isso
      // ela sobe junto com a API, e não antes.
      Analytics := BuildAnalytics(AnalyticsCfg, Db, CameraNames, Cache,
                                  Clock, Logger, GStopEvent);
      Api := TApiRouter.Create(ApiCfg, CameraNames, Cache, Hub, Thumbs,
                               Analytics.Events, Logger);
    end
    else if AnalyticsCfg.Enabled then
      Logger.Warn('main', 'analise ligada mas API desligada: os eventos seriam ' +
        'gravados e ninguem poderia le-los. Nao vai subir.');
    try
      Supervisors := BuildServerSupervisors(App, Logger, Clock, Hub);
      try
        for I := 0 to Supervisors.Count - 1 do
          Supervisors[I].Start;

        if Retention.Enabled then
        begin
          Sweeper := TRetentionThread.Create(StorageDir, Retention, Logger, GStopEvent);
          Sweeper.Start;
        end;

        // Log e evento tambem envelhecem. Sem isto a tabela cresce para sempre,
        // que e o unico jeito de um log em banco ficar pior que um em arquivo.
        // Uma passada na subida; a periodica entra quando a retencao souber do
        // banco (ver docs/banco-de-dados.md).
        if (Retention.Enabled) and (Retention.MaxDays > 0) then
          Logger.Info('main', Format('Banco: %d linha(s) de log antiga(s) apagada(s)',
            [PruneLog(Db, Clock.NowUtcMs - Int64(Retention.MaxDays) * 86400000)]));

        // loop=False: modo ao vivo nunca reinicia a gravação do começo. Com o
        // hub, o /live/ sai da memória; sem ele (ou com a câmera fora do ar), do
        // arquivo. O mesmo listener responde a API HTTP das gravações.
        Listener := TTxServerListener.Create(RtspPort, BindAddress, StorageDir, False,
                                             Logger, Clock, Hub, Api);
        try
          Listener.Start;
          for I := 0 to High(App.Cameras) do
            if App.Cameras[I].Enabled then
              Logger.Info('main', Format('  rtsp://<host>:%d/live/%s', [RtspPort, App.Cameras[I].Name]));
          if Api <> nil then
            Logger.Info('main', Format('  http://<host>:%d/api/cameras', [RtspPort]));
          Logger.Info('main', 'No ar. Ctrl+C para parar.');

          while GStopEvent.WaitFor(500) <> wrSignaled do ;

          Logger.Info('main', 'Parando...');
          Listener.Stop;
        finally
          Listener.Free;
        end;
      finally
        if Sweeper <> nil then
        begin
          Sweeper.Terminate;
          Sweeper.WaitFor;
          Sweeper.Free;
        end;
        // sinaliza todos antes de liberar: o destrutor de cada supervisor faz
        // WaitFor, então parar em série custaria o tempo de cada um somado
        for I := 0 to Supervisors.Count - 1 do
          Supervisors[I].Stop;
        Supervisors.Free;
      end;
    finally
      // depois do listener: são as sessões dele que consultam o roteador
      Api.Free;
      // As threads de análise antes do cache: elas o consultam a cada quadro.
      Analytics.Stop;
      Analytics.Release;
      Thumbs := nil;   // solta a interface antes do cache que ela usa
      Cache.Free;
    end;
  finally
    Hub.Free;
  end;
  // Solta a interface: o destrutor drena a fila, fecha o lote aberto, roda o
  // PRAGMA optimize e fecha a conexao.
  if Db <> nil then
  begin
    if Db.Pending > 0 then
      Logger.Info('main', Format('Banco: %d escrita(s) na fila ao fechar',
        [Db.Pending]));
    Db := nil;
  end;
  Logger.Info('main', 'Parado.');
end;

begin
  Randomize;
  GStopEvent := TEvent.Create(nil, True, False, '');
  try
    {$IFDEF MSWINDOWS}
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
    {$ENDIF}
    try
      RunApp;
      ExitCode := 0;
    except
      on E: Exception do
      begin
        Writeln('FATAL: ', E.ClassName, ': ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    GStopEvent.Free;
  end;
end.
