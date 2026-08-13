unit Vms.Server.Composition;

// Monta um supervisor por câmera habilitada, sempre gravando .vms — é do
// arquivo ao vivo que o servidor RTSP lê para publicar /live/<camera>.
//
// Os dois caminhos gravam de formas diferentes:
//   rtsp://  -> o próprio TCameraSession grava (SessionCfg.RecordEnabled)
//   dvrip:// -> TDvripSession não tem writer, então entra um TRecordingSink
//               como IMediaSink para gravar o mesmo .vms
// Reusa BuildSessionConfig/BuildReconnectPolicy/DefaultDepacketizerFactory do
// VMS.App.Composition (compartilhado com o RTSPlayer).

interface

uses
  System.SysUtils,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.Reconnect,
  VMS.Domain.MediaSink,
  VMS.Domain.Session,
  VMS.Domain.Supervisor,
  VMS.Depk.Intf,
  VMS.App.Config,
  VMS.App.Composition;

function IsDvripUrl(const Url: string): Boolean;

// Recebe só a config comum: os campos próprios do servidor (porta, bind) não
// interessam aqui, então esta unit não precisa conhecer a config derivada.
function BuildServerSupervisors(const App: TAppConfig; const Logger: ILogger;
                                const Clock: IClock): TAppSupervisorList;

implementation

uses
  Vms.Server.RecSink;

function IsDvripUrl(const Url: string): Boolean;
begin
  Result := SameText(Copy(Trim(Url), 1, 5), 'dvrip');
end;

function BuildServerSupervisors(const App: TAppConfig; const Logger: ILogger;
  const Clock: IClock): TAppSupervisorList;
var
  I: Integer;
  Cam: TCameraConfigEntry;
  SessionCfg: TCameraSessionConfig;
  Policy: IReconnectPolicy;
  Factory: TDepacketizerFactoryFn;
  Sink: IMediaSink;
begin
  Result := TAppSupervisorList.Create(True);
  try
    Factory := DefaultDepacketizerFactory();
    for I := 0 to High(App.Cameras) do
    begin
      Cam := App.Cameras[I];
      if not Cam.Enabled then
      begin
        Logger.Info('composition', Format('Camera "%s" desabilitada, pulando', [Cam.Name]));
        Continue;
      end;

      SessionCfg := BuildSessionConfig(App, Cam);
      Policy := BuildReconnectPolicy(Cam);
      Sink := nil;

      if IsDvripUrl(Cam.Url) then
      begin
        SessionCfg.RecordEnabled := False; // TDvripSession ignora esse flag
        Sink := TRecordingSink.Create(Cam.Name, App.StorageDir, Cam.FilenamePattern,
                                      Cam.Url, Cam.RecordAudio,
                                      App.MaxBlockSamples, App.MaxBlockDurationMs,
                                      App.MaxBlockSizeBytes, Logger, Clock);
        Logger.Info('composition', Format('Camera "%s": dvrip, gravando via sink', [Cam.Name]));
      end
      else
      begin
        SessionCfg.RecordEnabled := True;
        Logger.Info('composition', Format('Camera "%s": rtsp, gravando na sessão', [Cam.Name]));
      end;

      Result.Add(TCameraSupervisor.Create(SessionCfg, Logger, Clock, Factory, Policy, Sink));
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
