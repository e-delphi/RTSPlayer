unit Vms.Db.Config;

// A configuracao, vinda das tabelas `setting`, `camera` e `camera_endpoint`, e
// a importacao unica do vmsserver.json antigo.
//
// ## A ordem na subida, e por que ela e assim
//
//   1. le do JSON so o `dbPath`  (ou usa o padrao)
//   2. abre o banco e garante o esquema
//   3. SE nunca importou: le o JSON inteiro e despeja nas tabelas
//   4. le a configuracao DO BANCO — e e essa que vale
//
// O passo 3 roda uma vez so, marcado em `db_meta.config_imported_at_ms`. O
// arquivo NAO e renomeado: ele continua sendo o bootstrap (e quem guarda o
// dbPath, que por definicao nao pode morar dentro do banco que ele localiza) e
// tambem uma copia de seguranca do que havia antes. Do passo 3 em diante,
// editar o JSON nao muda mais nada exceto o caminho do banco.
//
// ## Por que setting e chave/valor
//
// Sao ~25 ajustes heterogeneos de seis secoes. Com chave/valor, a importacao e
// um laco, acrescentar um ajuste e um INSERT em vez de um ALTER TABLE, e os
// GetJsonInt/Bool/Str que ja existiam viram SettingInt/Bool/Str com a mesma
// forma — o leitor abaixo e quase o mesmo codigo que lia o JSON.

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Rtsp.Client,
  VMS.App.Config,
  Vms.Db.Intf,
  Vms.Server.Retention,
  Vms.Server.LiveHub,
  Vms.Server.Api,
  Vms.Analytics.Types;

type
  // O mesmo conjunto que o TVmsServerConfig entrega, so que lido do banco.
  TDbConfig = class
  strict private
    FDb: IDbQueue;
    FLogger: ILogger;
    FValues: TDictionary<string, string>;
    FConfig: TAppConfig;
    FRtspPort: Word;
    FBindAddress: string;
    FRetention: TRetentionPolicy;
    FLive: TLiveConfig;
    FApi: TApiConfig;
    FAnalytics: TAnalyticsConfig;
    procedure LoadSettings;
    procedure LoadCameras;
    function Str(const Key, Default: string): string;
    function Int(const Key: string; Default: Int64): Int64;
    function Num(const Key: string; Default: Double): Double;
    function Bool(const Key: string; Default: Boolean): Boolean;
  public
    constructor Create(const ADb: IDbQueue; const ALogger: ILogger);
    destructor Destroy; override;
    procedure Load;
    property Config: TAppConfig read FConfig;
    property RtspPort: Word read FRtspPort;
    property BindAddress: string read FBindAddress;
    property Retention: TRetentionPolicy read FRetention;
    property Live: TLiveConfig read FLive;
    property Api: TApiConfig read FApi;
    property Analytics: TAnalyticsConfig read FAnalytics;
  end;

// Ja importou alguma vez?
function ConfigImported(const Db: IDbQueue): Boolean;

// Despeja no banco o que veio do JSON. Nao apaga nada do que ja esta la: as
// cameras entram por ON CONFLICT (nome), e os ajustes por INSERT OR REPLACE.
procedure ImportConfig(const Db: IDbQueue; const App: TAppConfig;
                       ARtspPort: Word; const ABindAddress: string;
                       const ARetention: TRetentionPolicy;
                       const ALive: TLiveConfig; const AApi: TApiConfig;
                       const AAnalytics: TAnalyticsConfig;
                       const Clock: IClock; const Logger: ILogger);

// Garante que existe linha em `camera` para cada nome. Chamado sempre, e nao so
// na importacao: uma camera acrescentada ao JSON depois (ou o dia em que a
// escrita pela API existir) precisa da linha, senao os eventos e o inventario
// dela caem na chave estrangeira e nao gravam.
procedure EnsureCameras(const Db: IDbQueue; const Cameras: TArray<TCameraConfigEntry>;
                        const Clock: IClock);

implementation

uses
  System.StrUtils;

// ------------------------------------------------------------ helpers

function TransportsToText(const T: TArray<TTransportKind>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(T) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + TransportKindToStr(T[I]);
  end;
  if Result = '' then Result := 'tcp,udp';
end;

// tcp e udp, nesta ordem. E o mesmo padrao do DefaultTransports do
// VMS.App.Config, repetido aqui porque aquele mora na implementation dele e
// nao e visivel de fora — e exportar uma funcao de uma unit que o app Android
// tambem compila, so para dois valores, seria pior.
function TransportesPadrao: TArray<TTransportKind>;
begin
  SetLength(Result, 2);
  Result[0] := txTcp;
  Result[1] := txUdp;
end;

function TextToTransports(const S: string): TArray<TTransportKind>;
var
  Partes: TArray<string>;
  I, N: Integer;
  T: TTransportKind;
begin
  Partes := SplitString(LowerCase(Trim(S)), ',');
  SetLength(Result, Length(Partes));
  N := 0;
  for I := 0 to High(Partes) do
    if ParseTransportKind(Trim(Partes[I]), T) then
    begin
      Result[N] := T;
      Inc(N);
    end;
  SetLength(Result, N);
  if N = 0 then
    Result := TransportesPadrao;
end;

function ClassesToText(const C: TArray<string>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(C) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + C[I];
  end;
end;

function TextToClasses(const S: string): TArray<string>;
var
  Partes: TArray<string>;
  I, N: Integer;
begin
  if Trim(S) = '' then Exit(nil);
  Partes := SplitString(LowerCase(S), ',');
  SetLength(Result, Length(Partes));
  N := 0;
  for I := 0 to High(Partes) do
    if Trim(Partes[I]) <> '' then
    begin
      Result[N] := Trim(Partes[I]);
      Inc(N);
    end;
  SetLength(Result, N);
end;

// ------------------------------------------------------------ importacao

function ConfigImported(const Db: IDbQueue): Boolean;
var
  Cams, Eps: Int64;
begin
  Result := False;
  if (Db = nil) or (not Db.IsOpen) then Exit;
  if Db.ReadInt64(
       'SELECT COUNT(*) AS n FROM db_meta WHERE key = ''config_imported_at_ms''',
       [], 'n', 0) = 0 then Exit;

  // Reparo de UMA situacao especifica: existem cameras, mas nenhum caminho
  // para chegar nelas. Isso nao acontece de forma legitima — camera sem URL
  // nao conecta — e e exatamente o que uma build anterior deixou, ao importar
  // ignorando o formato antigo de camera. Nesse caso vale importar de novo, e a
  // reimportacao e segura (ON CONFLICT atualiza, endpoints sao regravados).
  Cams := Db.ReadInt64('SELECT COUNT(*) AS n FROM camera', [], 'n', 0);
  Eps := Db.ReadInt64('SELECT COUNT(*) AS n FROM camera_endpoint', [], 'n', 0);
  if (Cams > 0) and (Eps = 0) then Exit;

  Result := True;
end;

procedure EnsureCameras(const Db: IDbQueue;
  const Cameras: TArray<TCameraConfigEntry>; const Clock: IClock);
var
  I: Integer;
  Agora: Int64;
begin
  if (Db = nil) or (not Db.IsOpen) then Exit;
  Agora := 0;
  if Clock <> nil then Agora := Clock.NowUtcMs;
  for I := 0 to High(Cameras) do
  begin
    if Trim(Cameras[I].Name) = '' then Continue;
    // OR IGNORE: se ja existe, nada muda. Isto aqui garante a LINHA, nao a
    // configuracao dela — quem configura e a importacao.
    Db.Exec('INSERT OR IGNORE INTO camera (name, enabled, created_at_ms, ' +
            '  updated_at_ms) VALUES (?, ?, ?, ?)',
            [Cameras[I].Name, Ord(Cameras[I].Enabled), Agora, Agora]);
  end;
end;

procedure ImportConfig(const Db: IDbQueue; const App: TAppConfig;
  ARtspPort: Word; const ABindAddress: string;
  const ARetention: TRetentionPolicy; const ALive: TLiveConfig;
  const AApi: TApiConfig; const AAnalytics: TAnalyticsConfig;
  const Clock: IClock; const Logger: ILogger);
var
  Agora: Int64;
  I, J: Integer;
  Cam: TCameraConfigEntry;

  procedure Grava(const Key: string; const Value: string);
  begin
    Db.Exec('INSERT INTO setting (key, value, updated_at_ms) VALUES (?, ?, ?) ' +
            '  ON CONFLICT(key) DO UPDATE SET value = excluded.value, ' +
            '    updated_at_ms = excluded.updated_at_ms',
            [Key, Value, Agora]);
  end;

  procedure GravaInt(const Key: string; Value: Int64);
  begin
    Grava(Key, IntToStr(Value));
  end;

  procedure GravaBool(const Key: string; Value: Boolean);
  begin
    Grava(Key, IfThen(Value, '1', '0'));
  end;

  procedure GravaNum(const Key: string; Value: Double);
  var
    Fs: TFormatSettings;
  begin
    // Ponto como separador decimal, sempre: o banco nao pode depender de como a
    // maquina esta configurada, senao '0,35' vira 35 na proxima leitura.
    Fs := TFormatSettings.Invariant;
    Grava(Key, FloatToStr(Value, Fs));
  end;

begin
  if (Db = nil) or (not Db.IsOpen) then Exit;
  Agora := 0;
  if Clock <> nil then Agora := Clock.NowUtcMs;

  // ---- ajustes gerais
  GravaInt('rtspPort', ARtspPort);
  Grava('bindAddress', ABindAddress);
  Grava('storageDir', App.StorageDir);
  Grava('logDir', App.LogDir);
  GravaInt('transportFallbackTimeoutMs', App.TransportFallbackTimeoutMs);
  if App.KeepAliveMethod = kamOptions then
    Grava('keepAliveMethod', 'options')
  else
    Grava('keepAliveMethod', 'get_parameter');
  GravaInt('rotateMinutes', App.RotateMs div 60000);
  GravaInt('block.maxSamples', App.MaxBlockSamples);
  GravaInt('block.maxDurationMs', App.MaxBlockDurationMs);
  GravaInt('block.maxSizeBytes', App.MaxBlockSizeBytes);

  GravaInt('retention.maxDays', ARetention.MaxDays);
  GravaNum('retention.maxTotalGB', ARetention.MaxTotalBytes / GIGABYTE);
  GravaNum('retention.minFreeGB', ARetention.MinFreeBytes / GIGABYTE);
  GravaInt('retention.intervalMinutes', ARetention.IntervalMs div 60000);

  GravaBool('live.enabled', ALive.Enabled);
  GravaInt('live.bufferMs', ALive.BufferMs);
  GravaNum('live.maxBufferMB', ALive.MaxBytes / (1024 * 1024));

  GravaBool('api.enabled', AApi.Enabled);
  GravaInt('api.maxBlocksPerRequest', AApi.MaxBlocksPerRequest);

  GravaBool('analytics.enabled', AAnalytics.Enabled);
  GravaInt('analytics.stepMs', AAnalytics.StepMs);
  GravaNum('analytics.motionThreshold', AAnalytics.MotionThreshold);
  GravaNum('analytics.sceneChangeThreshold', AAnalytics.SceneChangeThreshold);
  GravaInt('analytics.mergeGapMs', AAnalytics.MergeGapMs);
  GravaInt('analytics.maxEventMs', AAnalytics.MaxEventMs);
  GravaInt('analytics.backfillHours', AAnalytics.BackfillMs div 3600000);
  GravaInt('analytics.lagMs', AAnalytics.LagMs);
  Grava('analytics.modelPath', AAnalytics.ModelPath);
  Grava('analytics.onnxDll', AAnalytics.OnnxDllPath);
  GravaInt('analytics.objectIntervalMs', AAnalytics.ObjectMinIntervalMs);
  GravaNum('analytics.objectThreshold', AAnalytics.ObjectThreshold);
  Grava('analytics.classes', ClassesToText(AAnalytics.Classes));

  // ---- cameras
  for I := 0 to High(App.Cameras) do
  begin
    Cam := App.Cameras[I];
    if Trim(Cam.Name) = '' then Continue;
    Db.Exec(
      'INSERT INTO camera (name, enabled, record_audio, filename_pattern, ' +
      '    audio_delay_ms, video_delay_ms, max_reconnect_attempts, ' +
      '    reconnect_initial_ms, reconnect_max_ms, reconnect_multiplier, ' +
      '    no_rtp_timeout_ms, created_at_ms, updated_at_ms) ' +
      '  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ' +
      '  ON CONFLICT(name) DO UPDATE SET ' +
      '    enabled = excluded.enabled, record_audio = excluded.record_audio, ' +
      '    filename_pattern = excluded.filename_pattern, ' +
      '    audio_delay_ms = excluded.audio_delay_ms, ' +
      '    video_delay_ms = excluded.video_delay_ms, ' +
      '    max_reconnect_attempts = excluded.max_reconnect_attempts, ' +
      '    reconnect_initial_ms = excluded.reconnect_initial_ms, ' +
      '    reconnect_max_ms = excluded.reconnect_max_ms, ' +
      '    reconnect_multiplier = excluded.reconnect_multiplier, ' +
      '    no_rtp_timeout_ms = excluded.no_rtp_timeout_ms, ' +
      '    updated_at_ms = excluded.updated_at_ms',
      [Cam.Name, Ord(Cam.Enabled), Ord(Cam.RecordAudio), Cam.FilenamePattern,
       Cam.AudioDelayMs, Cam.VideoDelayMs, Cam.MaxReconnectAttempts,
       Int64(Cam.Reconnect.InitialDelayMs), Int64(Cam.Reconnect.MaxDelayMs),
       Cam.Reconnect.BackoffMultiplier, Int64(Cam.Reconnect.NoRtpTimeoutMs),
       Agora, Agora]);

    // Endpoints: apaga e regrava. E a unica forma simples de refletir remocao
    // de um caminho, e a lista e de tres itens no maximo.
    Db.Exec('DELETE FROM camera_endpoint WHERE camera_id = ' +
            '(SELECT id FROM camera WHERE name = ?)', [Cam.Name]);

    // O ParseCamera so preenche Endpoints quando o json traz o array
    // `endpoints`. No formato antigo — uma `url` solta na camera, que e o que
    // a maioria das configuracoes usa — ele preenche os campos ESPELHO e deixa
    // Endpoints vazio. Sem este ramo, a importacao gravava zero caminhos e a
    // camera saia do banco sem URL nenhuma: nao conectava, e sem erro.
    if (Length(Cam.Endpoints) = 0) and (Trim(Cam.Url) <> '') then
      Db.Exec(
        'INSERT INTO camera_endpoint (camera_id, ord, label, url, user_name, ' +
        '    password, transports, uses_tailscale) ' +
        '  VALUES ((SELECT id FROM camera WHERE name = ?), 0, ?, ?, ?, ?, ?, ?)',
        [Cam.Name, '', Cam.Url, Cam.User, Cam.Password,
         TransportsToText(Cam.Transports), Ord(Cam.UsesTailscale)])
    else
      for J := 0 to High(Cam.Endpoints) do
        Db.Exec(
          'INSERT INTO camera_endpoint (camera_id, ord, label, url, user_name, ' +
          '    password, transports, uses_tailscale) ' +
          '  VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?, ?, ?)',
          [Cam.Name, J, Cam.Endpoints[J].Name, Cam.Endpoints[J].Url,
           Cam.Endpoints[J].User, Cam.Endpoints[J].Password,
           TransportsToText(Cam.Endpoints[J].Transports),
           Ord(Cam.Endpoints[J].UsesTailscale)]);
  end;

  Db.Exec('INSERT OR REPLACE INTO db_meta (key, value) VALUES (?, ?)',
          ['config_imported_at_ms', IntToStr(Agora)]);

  if Logger <> nil then
    Logger.Info('db', Format('config importada do json: %d camera(s)',
      [Length(App.Cameras)]));
end;

// --------------------------------------------------------------- leitura

constructor TDbConfig.Create(const ADb: IDbQueue; const ALogger: ILogger);
begin
  inherited Create;
  FDb := ADb;
  FLogger := ALogger;
  FValues := TDictionary<string, string>.Create;
end;

destructor TDbConfig.Destroy;
begin
  FValues.Free;
  inherited;
end;

function TDbConfig.Str(const Key, Default: string): string;
begin
  if not FValues.TryGetValue(Key, Result) then
    Result := Default;
end;

function TDbConfig.Int(const Key: string; Default: Int64): Int64;
begin
  Result := StrToInt64Def(Trim(Str(Key, '')), Default);
end;

function TDbConfig.Num(const Key: string; Default: Double): Double;
var
  Fs: TFormatSettings;
begin
  // Invariant na leitura tambem: foi assim que se gravou.
  Fs := TFormatSettings.Invariant;
  Result := StrToFloatDef(Trim(Str(Key, '')), Default, Fs);
end;

function TDbConfig.Bool(const Key: string; Default: Boolean): Boolean;
var
  S: string;
begin
  S := LowerCase(Trim(Str(Key, '')));
  if S = '' then Exit(Default);
  Result := (S <> '0') and (S <> 'false') and (S <> 'no');
end;

procedure TDbConfig.LoadSettings;
begin
  FValues.Clear;
  FDb.Read('SELECT key, value FROM setting', [],
    procedure(const Row: IDbRow)
    begin
      FValues.AddOrSetValue(Row.AsString('key'), Row.AsString('value'));
    end);
end;

procedure TDbConfig.LoadCameras;
var
  Lista: TList<TCameraConfigEntry>;
  I: Integer;
  Nomes: TArray<string>;
  Cam: TCameraConfigEntry;
  Eps: TArray<TCameraEndpoint>;
begin
  Lista := TList<TCameraConfigEntry>.Create;
  try
    SetLength(Nomes, 0);
    FDb.Read(
      'SELECT name, enabled, record_audio, filename_pattern, audio_delay_ms, ' +
      '       video_delay_ms, max_reconnect_attempts, reconnect_initial_ms, ' +
      '       reconnect_max_ms, reconnect_multiplier, no_rtp_timeout_ms ' +
      '  FROM camera ORDER BY id', [],
      procedure(const Row: IDbRow)
      var
        Cam: TCameraConfigEntry;
      begin
        Cam := Default(TCameraConfigEntry);
        Cam.Name := Row.AsString('name');
        Cam.Enabled := Row.AsBool('enabled');
        Cam.RecordAudio := Row.AsBool('record_audio');
        Cam.FilenamePattern := Row.AsString('filename_pattern');
        Cam.AudioDelayMs := Row.AsInt('audio_delay_ms');
        Cam.VideoDelayMs := Row.AsInt('video_delay_ms');
        Cam.MaxReconnectAttempts := Row.AsInt('max_reconnect_attempts');
        Cam.Reconnect.InitialDelayMs := Cardinal(Row.AsInt('reconnect_initial_ms'));
        Cam.Reconnect.MaxDelayMs := Cardinal(Row.AsInt('reconnect_max_ms'));
        Cam.Reconnect.BackoffMultiplier := Row.AsFloat('reconnect_multiplier');
        Cam.Reconnect.NoRtpTimeoutMs := Cardinal(Row.AsInt('no_rtp_timeout_ms'));
        Lista.Add(Cam);
        SetLength(Nomes, Length(Nomes) + 1);
        Nomes[High(Nomes)] := Cam.Name;
      end);

    // Endpoints numa segunda passada: uma consulta por camera, e nao um Read
    // aninhado — a fila e de uma thread so, e um Read dentro do OnRow de outro
    // Read seria a propria thread esperando por si mesma.
    for I := 0 to Lista.Count - 1 do
    begin
      Cam := Lista[I];
      SetLength(Eps, 0);
      FDb.Read(
        'SELECT e.label, e.url, e.user_name, e.password, e.transports, ' +
        '       e.uses_tailscale ' +
        '  FROM camera_endpoint e JOIN camera c ON c.id = e.camera_id ' +
        ' WHERE c.name = ? ORDER BY e.ord', [Nomes[I]],
        procedure(const Row: IDbRow)
        var
          Ep: TCameraEndpoint;
        begin
          Ep := Default(TCameraEndpoint);
          Ep.Name := Row.AsString('label');
          Ep.Url := Row.AsString('url');
          Ep.User := Row.AsString('user_name');
          Ep.Password := Row.AsString('password');
          Ep.Transports := TextToTransports(Row.AsString('transports'));
          Ep.UsesTailscale := Row.AsBool('uses_tailscale');
          SetLength(Eps, Length(Eps) + 1);
          Eps[High(Eps)] := Ep;
        end);
      if Length(Eps) = 0 then
        // Nao ha o que fazer aqui alem de dizer: sem caminho, o supervisor vai
        // tentar conectar em lugar nenhum e o log so mostraria timeout.
        if FLogger <> nil then
          FLogger.Warn('config', Format('camera "%s" nao tem nenhum endpoint ' +
            'no banco; ela nao vai conectar', [Nomes[I]]));
      Cam.Endpoints := Eps;
      // Os campos soltos espelham o PRIMEIRO endpoint — mesma regra do
      // TCameraConfigEntry lido do json (ver o comentario dele).
      if Length(Eps) > 0 then
      begin
        Cam.Url := Eps[0].Url;
        Cam.User := Eps[0].User;
        Cam.Password := Eps[0].Password;
        Cam.Transports := Eps[0].Transports;
        Cam.UsesTailscale := Eps[0].UsesTailscale;
      end;
      Lista[I] := Cam;
    end;

    FConfig.Cameras := Lista.ToArray;
  finally
    Lista.Free;
  end;
end;

procedure TDbConfig.Load;
var
  Gb: Double;
begin
  LoadSettings;

  FRtspPort := Word(Int('rtspPort', 8554));
  FBindAddress := Trim(Str('bindAddress', ''));

  FConfig.StorageDir := Str('storageDir', 'recordings');
  FConfig.LogDir := Str('logDir', 'logs');
  FConfig.TransportFallbackTimeoutMs :=
    Cardinal(Int('transportFallbackTimeoutMs', 5000));
  if SameText(Str('keepAliveMethod', 'get_parameter'), 'options') then
    FConfig.KeepAliveMethod := kamOptions
  else
    FConfig.KeepAliveMethod := kamGetParameter;
  FConfig.RotateMs := Integer(Int('rotateMinutes', 60) * 60000);
  FConfig.MaxBlockSamples := Integer(Int('block.maxSamples', 256));
  FConfig.MaxBlockDurationMs := Integer(Int('block.maxDurationMs', 2000));
  FConfig.MaxBlockSizeBytes := Integer(Int('block.maxSizeBytes', 1048576));

  FillChar(FRetention, SizeOf(FRetention), 0);
  FRetention.MaxDays := Integer(Int('retention.maxDays', 0));
  Gb := Num('retention.maxTotalGB', 0);
  if Gb > 0 then FRetention.MaxTotalBytes := Round(Gb * GIGABYTE);
  Gb := Num('retention.minFreeGB', 0);
  if Gb > 0 then FRetention.MinFreeBytes := Round(Gb * GIGABYTE);
  FRetention.IntervalMs := Integer(Int('retention.intervalMinutes', 5) * 60000);
  // TRetentionPolicy.Enabled e FUNCAO: ela mesma responde a partir dos limites
  // acima. Nao ha o que atribuir — e e melhor assim, porque nao da para os dois
  // discordarem.

  FLive.Enabled := Bool('live.enabled', True);
  FLive.BufferMs := Integer(Int('live.bufferMs', LIVE_DEFAULT_BUFFER_MS));
  Gb := Num('live.maxBufferMB', 0);
  if Gb > 0 then FLive.MaxBytes := Round(Gb * 1024 * 1024)
  else FLive.MaxBytes := LIVE_DEFAULT_MAX_BYTES;
  if FLive.BufferMs < 500 then FLive.BufferMs := 500;

  FApi.Enabled := Bool('api.enabled', True);
  FApi.MaxBlocksPerRequest :=
    Integer(Int('api.maxBlocksPerRequest', API_DEFAULT_MAX_BLOCKS));
  if FApi.MaxBlocksPerRequest < 1 then FApi.MaxBlocksPerRequest := 1;

  FAnalytics := TAnalyticsConfig.Default;
  FAnalytics.Enabled := Bool('analytics.enabled', False);
  FAnalytics.StepMs := Int('analytics.stepMs', 2000);
  FAnalytics.MotionThreshold := Num('analytics.motionThreshold', 0.012);
  FAnalytics.SceneChangeThreshold := Num('analytics.sceneChangeThreshold', 0.55);
  FAnalytics.MergeGapMs := Int('analytics.mergeGapMs', 8000);
  FAnalytics.MaxEventMs := Int('analytics.maxEventMs', 300000);
  FAnalytics.BackfillMs := Int('analytics.backfillHours', 6) * 3600000;
  FAnalytics.LagMs := Int('analytics.lagMs', 30000);
  FAnalytics.ModelPath := Trim(Str('analytics.modelPath', ''));
  // Relativo resolve contra o EXECUTAVEL, nao contra o diretorio de trabalho:
  // o servidor costuma subir como servico, e ai o cwd e C:\Windows\System32.
  // Mesma regra que valia quando isto vinha do json.
  if (FAnalytics.ModelPath <> '') and
     (not TPath.IsPathRooted(FAnalytics.ModelPath)) then
    FAnalytics.ModelPath := ExtractFilePath(ParamStr(0)) + FAnalytics.ModelPath;
  FAnalytics.OnnxDllPath := Trim(Str('analytics.onnxDll', 'onnxruntime.dll'));
  FAnalytics.ObjectMinIntervalMs := Int('analytics.objectIntervalMs', 5000);
  FAnalytics.ObjectThreshold := Num('analytics.objectThreshold', 0.35);
  FAnalytics.Classes := TextToClasses(Str('analytics.classes', ''));
  if FAnalytics.StepMs < 500 then FAnalytics.StepMs := 500;
  if FAnalytics.LagMs < 5000 then FAnalytics.LagMs := 5000;

  LoadCameras;
end;

end.
