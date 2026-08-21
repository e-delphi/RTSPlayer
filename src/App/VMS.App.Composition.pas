unit VMS.App.Composition;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.Reconnect,
  VMS.Domain.MediaSink,
  VMS.Domain.Session,
  VMS.Domain.Supervisor,
  VMS.Depk.Intf,
  VMS.Depk.Factory,
  VMS.App.Config,
  VMS.App.Logger,
  VMS.App.Clock;

type
  TAppSupervisorList = TObjectList<TCameraSupervisor>;

function BuildLogger(const AppCfg: TAppConfig): ILogger;
function BuildClock: IClock;

function BuildSessionConfig(const AppCfg: TAppConfig; const Cam: TCameraConfigEntry): TCameraSessionConfig;
function BuildReconnectPolicy(const Cam: TCameraConfigEntry): IReconnectPolicy;

function DefaultDepacketizerFactory: TDepacketizerFactoryFn;

function BuildSupervisors(const AppCfg: TAppConfig; const Logger: ILogger;
                          const Clock: IClock): TAppSupervisorList;

// Player puro: um supervisor para a câmera escolhida, sem gravação .vms,
// entregando o stream ao sink (renderer Android).
function BuildPlayerSupervisor(const AppCfg: TAppConfig; const Cam: TCameraConfigEntry;
                               const Logger: ILogger; const Clock: IClock;
                               const Sink: IMediaSink): TCameraSupervisor;

implementation

function BuildClock: IClock;
begin
  Result := TSystemClock.Create;
end;

function BuildLogger(const AppCfg: TAppConfig): ILogger;
var
  Composite: TCompositeLogger;
  Console: TConsoleLogger;
  FileL: TFileLogger;
  LogPath, AbsDir: string;
begin
  Composite := TCompositeLogger.Create;
  try
    Composite.SetMinLevel(AppCfg.LogLevel);
    Console := TConsoleLogger.Create(AppCfg.LogLevel);
    Composite.Add(Console);
    if Trim(AppCfg.LogDir) <> '' then
    begin
      AbsDir := ExpandFileName(AppCfg.LogDir);
      if not DirectoryExists(AbsDir) then
        ForceDirectories(AbsDir);
      LogPath := IncludeTrailingPathDelimiter(AbsDir) +
                 FormatDateTime('yyyy-mm-dd', Now) + '.log';
      FileL := TFileLogger.Create(LogPath, AppCfg.LogLevel);
      Composite.Add(FileL);
    end;
  except
    Composite.Free;
    raise;
  end;
  Result := Composite;
end;

function BuildSessionConfig(const AppCfg: TAppConfig; const Cam: TCameraConfigEntry): TCameraSessionConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Name := Cam.Name;
  Result.Url := Cam.Url;
  Result.User := Cam.User;
  Result.Password := Cam.Password;
  Result.Transports := Copy(Cam.Transports, 0, Length(Cam.Transports));
  Result.RecordAudio := Cam.RecordAudio;
  Result.FilenamePattern := Cam.FilenamePattern;
  Result.StorageDir := AppCfg.StorageDir;
  Result.NoRtpTimeoutMs := Cam.Reconnect.NoRtpTimeoutMs;
  Result.TransportFallbackTimeoutMs := AppCfg.TransportFallbackTimeoutMs;
  Result.KeepAliveMethod := AppCfg.KeepAliveMethod;
  Result.MaxBlockSamples := AppCfg.MaxBlockSamples;
  Result.MaxBlockDurationMs := AppCfg.MaxBlockDurationMs;
  Result.MaxBlockSizeBytes := AppCfg.MaxBlockSizeBytes;
  Result.RotateMs := AppCfg.RotateMs;
  Result.ConnectTimeoutMs := 5000;
  Result.RtspTimeoutMs := 10000;
  Result.RecordEnabled := True;
  Result.MaxReconnectAttempts := Cam.MaxReconnectAttempts;
  Result.UsesTailscale := Cam.UsesTailscale;
  // A lista inteira vai junto: quem escolhe o caminho é o supervisor, a cada
  // tentativa, e não a composição uma vez só.
  Result.Endpoints := Copy(Cam.Endpoints, 0, Length(Cam.Endpoints));
end;

function BuildReconnectPolicy(const Cam: TCameraConfigEntry): IReconnectPolicy;
begin
  Result := TExponentialBackoffPolicy.Create(Cam.Reconnect.InitialDelayMs,
                                             Cam.Reconnect.MaxDelayMs,
                                             Cam.Reconnect.BackoffMultiplier);
end;

function DefaultDepacketizerFactory: TDepacketizerFactoryFn;
begin
  Result :=
    function(VideoCodec: TVideoCodec; AudioCodec: TAudioCodec; Kind: TTrackKind): IDepacketizer
    begin
      Result := CreateDepacketizer(VideoCodec, AudioCodec, Kind);
    end;
end;

function BuildPlayerSupervisor(const AppCfg: TAppConfig; const Cam: TCameraConfigEntry;
                               const Logger: ILogger; const Clock: IClock;
                               const Sink: IMediaSink): TCameraSupervisor;
var
  SessionCfg: TCameraSessionConfig;
  Policy: IReconnectPolicy;
  Factory: TDepacketizerFactoryFn;
begin
  SessionCfg := BuildSessionConfig(AppCfg, Cam);
  SessionCfg.RecordEnabled := False;
  Policy := BuildReconnectPolicy(Cam);
  Factory := DefaultDepacketizerFactory();
  Result := TCameraSupervisor.Create(SessionCfg, Logger, Clock, Factory, Policy, Sink);
end;

function BuildSupervisors(const AppCfg: TAppConfig; const Logger: ILogger;
                          const Clock: IClock): TAppSupervisorList;
var
  I: Integer;
  Sup: TCameraSupervisor;
  SessionCfg: TCameraSessionConfig;
  Policy: IReconnectPolicy;
  Factory: TDepacketizerFactoryFn;
begin
  Result := TAppSupervisorList.Create(True);
  try
    Factory := DefaultDepacketizerFactory();
    for I := 0 to High(AppCfg.Cameras) do
    begin
      if not AppCfg.Cameras[I].Enabled then
      begin
        Logger.Info('composition',
          Format('Camera "%s" disabled, skipping', [AppCfg.Cameras[I].Name]));
        Continue;
      end;
      SessionCfg := BuildSessionConfig(AppCfg, AppCfg.Cameras[I]);
      Policy := BuildReconnectPolicy(AppCfg.Cameras[I]);
      Sup := TCameraSupervisor.Create(SessionCfg, Logger, Clock, Factory, Policy);
      Result.Add(Sup);
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.

