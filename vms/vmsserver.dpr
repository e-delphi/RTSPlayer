program vmsserver;

// Servidor VMS: conecta nas câmeras (mesmo cliente do RTSPlayer, rtsp e dvrip),
// grava cada uma em .vms e publica todas em UMA porta RTSP, uma rota por
// câmera:  rtsp://<host>:8554/live/<nome-da-camera>
//
// Pensado para rodar na máquina que enxerga as câmeras e ser acessado pelo
// celular via Tailscale (ver bindAddress em vmsserver.json).
//
// As units VMS.* vêm de ..\src (compartilhadas com o app RTSPlayer); as Tx.*
// implementam o servidor RTSP.

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
  VMS.Rec.Reader in '..\src\Recording\VMS.Rec.Reader.pas',
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
  Vms.Server.RecSink in 'src\Recording\Vms.Server.RecSink.pas',
  Vms.Server.Logger in 'src\App\Vms.Server.Logger.pas',
  Vms.Server.Retention in 'src\App\Vms.Server.Retention.pas',
  Vms.Server.Config in 'src\App\Vms.Server.Config.pas',
  Vms.Server.Composition in 'src\App\Vms.Server.Composition.pas';

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
  Logger: ILogger;
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
  finally
    Cfg.Free;
  end;

  // um arquivo de log por câmera (+ o geral), gravando todos os níveis
  Logger := TPerCameraLogger.Create(App.LogDir, App.Cameras);
  Clock := BuildClock;

  StorageDir := ExpandFileName(App.StorageDir);
  if not DirectoryExists(StorageDir) then
    ForceDirectories(StorageDir);

  Logger.Info('main', 'Config: ' + ConfigPath);
  Logger.Info('main', 'Gravacoes: ' + StorageDir);
  Logger.Info('main', Format('Espaco livre: %.1f GB | retencao: %s',
    [FreeSpaceOf(StorageDir) / GIGABYTE, Retention.Describe]));

  // Uma varredura antes de começar a gravar: se o disco já está no limite, é
  // agora que se abre espaço, não cinco minutos depois.
  Sweeper := nil;
  if Retention.Enabled then
    SweepRetention(StorageDir, Retention, Logger);

  Supervisors := BuildServerSupervisors(App, Logger, Clock);
  try
    for I := 0 to Supervisors.Count - 1 do
      Supervisors[I].Start;

    if Retention.Enabled then
    begin
      Sweeper := TRetentionThread.Create(StorageDir, Retention, Logger, GStopEvent);
      Sweeper.Start;
    end;

    // loop=False: modo ao vivo sempre segue o arquivo que está sendo gravado
    Listener := TTxServerListener.Create(RtspPort, BindAddress, StorageDir, False,
                                         Logger, Clock);
    try
      Listener.Start;
      for I := 0 to High(App.Cameras) do
        if App.Cameras[I].Enabled then
          Logger.Info('main', Format('  rtsp://<host>:%d/live/%s', [RtspPort, App.Cameras[I].Name]));
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
