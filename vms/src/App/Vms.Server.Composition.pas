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
//
// A análise de imagem (BuildAnalytics) é montada aqui pelo mesmo motivo que as
// miniaturas: é o único lugar do servidor que pode conhecer implementação
// concreta. É daqui que sai a decisão de rodar só movimento quando o modelo ONNX
// não está no disco — decisão que, feita em qualquer outro lugar, viraria um
// `if` espalhado por três camadas.

interface

uses
  System.SysUtils,
  System.SyncObjs,      // TEvent: o sinal de parada que os workers observam
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.Reconnect,
  VMS.Domain.MediaSink,
  VMS.Domain.Session,
  VMS.Domain.Supervisor,
  VMS.Depk.Intf,
  VMS.App.Config,
  VMS.App.Composition,
  Vms.Server.IndexCache,   // TVmsIndexCache, que a fonte de miniaturas consulta
  Vms.Thumb.Intf,          // IThumbSource, o que esta unit devolve
  Vms.Db.Intf,             // IDbQueue: o banco entra por interface, so
  Vms.Analytics.Types,
  Vms.Analytics.Intf,      // IEventSource, o que a rota /api/events enxerga
  Vms.Analytics.Worker,
  Vms.Server.LiveHub;

function IsDvripUrl(const Url: string): Boolean;

// Monta a cadeia das miniaturas. É aqui — e só aqui — que as implementações
// concretas aparecem: quem acha o keyframe, quem decodifica, quem encoda e onde
// guardar. Sem FFmpeg na máquina, devolve a fonte nula, e nada acima disto muda
// de comportamento.
// StorageDir nao entra mais: as miniaturas moram em DefaultCacheDir, ao lado
// do executavel. Ver o cabecalho do Vms.Thumb.Cache.
function BuildThumbSource(Cache: TVmsIndexCache;
                          ThumbWidth, ThumbHeight: Integer;
                          const Logger: ILogger): IThumbSource;

type
  // O que a análise devolve para o `.dpr` amarrar: a fonte que a API consulta,
  // o dono do arquivo de eventos e as threads que precisam ser paradas.
  // Um registro, e não uma classe, porque não há comportamento aqui — é o
  // resultado da montagem, e quem o recebe só guarda e libera.
  TAnalyticsRig = record
    Events: IEventSource;
    Workers: TArray<TAnalyticsWorker>;
    procedure Stop;
    // Não se chama Free: quem chama isto é um registro, não um objeto, e a
    // ordem importa — os workers antes das interfaces que eles seguram.
    procedure Release;
  end;

// Monta a análise: um detector de movimento e um analisador POR CÂMERA (têm
// estado e comparam quadros consecutivos), um detector de objetos para TODAS
// (o modelo ocupa memória demais para ter um por câmera) e um arquivo de
// eventos compartilhado.
//
// Reusa a cadeia das miniaturas inteira: quem acha o keyframe e quem decodifica
// são exatamente as mesmas interfaces. Sem FFmpeg na máquina não há como
// decodificar quadro nenhum, e aí a análise nem sobe — com um aviso, porque
// nesse caso o usuário pediu algo que não vai acontecer.
function BuildAnalytics(const Cfg: TAnalyticsConfig; const Db: IDbQueue;
                        const Cameras: TArray<string>; Cache: TVmsIndexCache;
                        const Clock: IClock; const Logger: ILogger;
                        Stop: TEvent): TAnalyticsRig;

// Recebe só a config comum: os campos próprios do servidor (porta, bind) não
// interessam aqui, então esta unit não precisa conhecer a config derivada.
// Hub nil = sem publicação ao vivo pela memória.
function BuildServerSupervisors(const App: TAppConfig; const Logger: ILogger;
                                const Clock: IClock;
                                const Hub: TLiveHub = nil): TAppSupervisorList;

implementation

uses
  Vms.Thumb.Cache,
  Vms.Thumb.Keyframe,
  Vms.Thumb.Service,
  Vms.Analytics.Motion,
  Vms.Analytics.Analyzer,
  Vms.Analytics.StoreDb,
{$IFDEF MSWINDOWS}
  Vms.Thumb.FFmpeg,
  Vms.Thumb.JpegVcl,
  Vms.Analytics.Onnx,
{$ENDIF}
  Vms.Server.RecSink;

function BuildThumbSource(Cache: TVmsIndexCache;
  ThumbWidth, ThumbHeight: Integer; const Logger: ILogger): IThumbSource;
{$IFDEF MSWINDOWS}
var
  Grabber: IFrameGrabber;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Grabber := TFFmpegFrameGrabber.Create(Logger);
  // Pergunta uma vez, na subida: sem as DLLs do FFmpeg ao lado do exe não há
  // como decodificar, e é melhor a barra ficar sem miniatura do que cada
  // requisição descobrir isso de novo.
  if Grabber.Available then
    Exit(TThumbService.Create(TVmsKeyframeSource.Create(Cache, Logger),
                              Grabber,
                              TVclJpegEncoder.Create,
                              TThumbDiskCache.Create(DefaultCacheDir),
                              ThumbWidth, ThumbHeight, Logger));
{$ENDIF}
  Result := TNullThumbSource.Create;
end;

{ TAnalyticsRig }

// Sinaliza todos antes de esperar por qualquer um: parar em série custaria o
// tempo de cada thread somado, e uma delas pode estar no meio de uma
// inferência de centenas de milissegundos.
procedure TAnalyticsRig.Stop;
var
  I: Integer;
begin
  for I := 0 to High(Workers) do
    if Workers[I] <> nil then Workers[I].Terminate;
  for I := 0 to High(Workers) do
    if Workers[I] <> nil then Workers[I].WaitFor;
end;

procedure TAnalyticsRig.Release;
var
  I: Integer;
begin
  for I := 0 to High(Workers) do
    Workers[I].Free;
  Workers := nil;
  // Depois dos workers: são eles que seguram o analisador, que segura o store.
  Events := nil;
end;

// Metade dos núcleos, no mínimo 1. A outra metade é da gravação, que é o
// trabalho que não pode atrasar: uma câmera cujo RTP não é lido a tempo perde
// pacote, e pacote perdido é buraco no arquivo — enquanto uma análise mais
// lenta só demora mais a chegar ao presente.
function ThreadsParaInferencia: Integer;
begin
  Result := CPUCount div 2;
  if Result < 1 then Result := 1;
end;

function BuildAnalytics(const Cfg: TAnalyticsConfig; const Db: IDbQueue;
  const Cameras: TArray<string>; Cache: TVmsIndexCache; const Clock: IClock;
  const Logger: ILogger; Stop: TEvent): TAnalyticsRig;
var
  Grabber: IFrameGrabber;
  Keyframes: IKeyframeSource;
  Objetos: IObjectDetector;
  Store: TSqliteEventStore;
  Analyzer: IFrameAnalyzer;
  I: Integer;
begin
  Result.Events := nil;
  Result.Workers := nil;
  if not Cfg.Enabled then Exit;
  if Length(Cameras) = 0 then Exit;
  if (Db = nil) or (not Db.IsOpen) then
  begin
    Logger.Warn('analytics', 'ligada na config, mas o banco nao esta aberto. ' +
      'A analise nao vai subir.');
    Exit;
  end;

  Grabber := nil;
{$IFDEF MSWINDOWS}
  Grabber := TFFmpegFrameGrabber.Create(Logger, 'analytics');
{$ENDIF}
  // Sem decodificador não há quadro para analisar, e nenhuma parte do resto
  // adiantaria. É diferente do modelo ausente, que só desliga metade.
  if (Grabber = nil) or (not Grabber.Available) then
  begin
    Logger.Warn('analytics', 'ligada na config, mas nao ha como decodificar ' +
      'video nesta maquina (FFmpeg ausente). A analise nao vai subir.');
    Exit;
  end;

  Objetos := nil;
{$IFDEF MSWINDOWS}
  if Cfg.ModelPath <> '' then
    Objetos := TOnnxObjectDetector.Create(Cfg.ModelPath, Cfg.OnnxDllPath,
                 0, 0, ThreadsParaInferencia, Logger);
{$ENDIF}
  // Modelo ausente, DLL ausente ou modelo que não carregou: segue só com
  // movimento. Ver o cabeçalho — ausência de recurso não vira exceção.
  if (Objetos = nil) or (not Objetos.Available) then
    Objetos := TNullObjectDetector.Create;

  // O mesmo objeto pelas TRÊS interfaces: escreve evento (IEventStore), a API
  // consulta (IEventSource) e o worker guarda o progresso (IAnalysisProgress).
  Store := TSqliteEventStore.Create(Db, Clock, Cfg.MaxEventMs, Logger);
  // Primeira referencia de interface: a partir daqui a contagem e dona do
  // objeto, e ele morre junto com o rig.
  Result.Events := Store;
  Keyframes := TVmsKeyframeSource.Create(Cache, Logger);

  Logger.Info('analytics', Cfg.Describe);
  Logger.Info('analytics', Objetos.Describe);

  SetLength(Result.Workers, Length(Cameras));
  for I := 0 to High(Cameras) do
  begin
    // Um detector de movimento e um analisador POR CÂMERA: os dois comparam o
    // quadro atual com o que veio antes NAQUELA cena. Compartilhá-los faria
    // cada câmera apagar a referência da outra.
    Analyzer := TFrameAnalyzer.Create(Cameras[I],
      TFrameDiffMotionDetector.Create(Cfg.MotionThreshold,
        Cfg.SceneChangeThreshold, Cfg.StepMs * 4),
      Objetos, Store, Cfg, Logger);
    Result.Workers[I] := TAnalyticsWorker.Create(Cameras[I], Keyframes, Grabber,
      Analyzer, Store, Cache, Cfg, Clock, Logger, Stop);
    // (Store entra como IAnalysisProgress; a conversão é implícita.)
  end;
end;

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
                                      App.MaxBlockSizeBytes, Logger, Clock,
                                      1500, App.RotateMs);
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
