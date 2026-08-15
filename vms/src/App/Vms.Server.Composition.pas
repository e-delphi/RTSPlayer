unit Vms.Server.Composition;

// Monta um supervisor por câmera habilitada, sempre gravando .vms.
//
// Os dois caminhos gravam de formas diferentes:
//   rtsp://  -> o próprio TCameraSession grava (SessionCfg.RecordEnabled)
//   dvrip:// -> TDvripSession não tem writer, então entra um TRecordingSink
//               como IMediaSink para gravar o mesmo .vms
// Reusa BuildSessionConfig/BuildReconnectPolicy/DefaultDepacketizerFactory do
// VMS.App.Composition (compartilhado com o RTSPlayer).
//
// Com o hub ao vivo ligado, cada câmera ganha um TLiveSink por fora: o mesmo
// sample vai para a memória (de onde o servidor RTSP publica /live/<camera>, sem
// esperar o bloco fechar no disco) e para a gravação. Hub nil = servidor lê do
// arquivo, como antes.

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
  VMS.App.Composition,
  Vms.Server.LiveHub;

function IsDvripUrl(const Url: string): Boolean;

// Recebe só a config comum: os campos próprios do servidor (porta, bind) não
// interessam aqui, então esta unit não precisa conhecer a config derivada.
// Hub nil = sem publicação ao vivo pela memória.
function BuildServerSupervisors(const App: TAppConfig; const Logger: ILogger;
                                const Clock: IClock;
                                const Hub: TLiveHub = nil): TAppSupervisorList;

implementation

uses
  Vms.Server.RecSink;

function IsDvripUrl(const Url: string): Boolean;
begin
  Result := SameText(Copy(Trim(Url), 1, 5), 'dvrip');
end;

function BuildServerSupervisors(const App: TAppConfig; const Logger: ILogger;
  const Clock: IClock; const Hub: TLiveHub): TAppSupervisorList;
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

      // Por fora do que já existia: publica na memória e repassa para o sink de
      // gravação (dvrip) ou para ninguém (rtsp, que grava dentro da sessão).
      // O áudio segue a mesma regra da gravação — quem desligou recordAudio não
      // quer a trilha, nem no arquivo nem ao vivo.
      if Hub <> nil then
      begin
        Sink := TLiveSink.Create(Hub.GetOrCreate(Cam.Name), Sink, Cam.RecordAudio);
        Logger.Info('composition', Format('Camera "%s": ao vivo pela memória', [Cam.Name]));
      end;

      Result.Add(TCameraSupervisor.Create(SessionCfg, Logger, Clock, Factory, Policy, Sink));
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
