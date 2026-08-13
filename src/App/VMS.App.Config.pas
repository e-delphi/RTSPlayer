unit VMS.App.Config;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.IOUtils,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rtsp.Client,
  VMS.Domain.Session;

type
  TReconnectConfig = record
    InitialDelayMs: Cardinal;
    MaxDelayMs: Cardinal;
    BackoffMultiplier: Double;
    NoRtpTimeoutMs: Cardinal;
  end;

  TCameraConfigEntry = record
    Name: string;
    Enabled: Boolean;
    Url: string;
    User: string;
    Password: string;
    Transports: TArray<TTransportKind>;
    RecordAudio: Boolean;
    FilenamePattern: string;
    Reconnect: TReconnectConfig;
    // 0 = reconecta pra sempre; N > 0 = desiste após N falhas seguidas de conexão
    MaxReconnectAttempts: Integer;
    // atrasos (ms) p/ sincronizar A/V no Windows (jitter buffer). Default 200.
    AudioDelayMs: Integer;
    VideoDelayMs: Integer;
  end;

  TAppConfig = record
    StorageDir: string;
    LogDir: string;
    LogLevel: TLogLevel;
    TransportFallbackTimeoutMs: Cardinal;
    KeepAliveMethod: TRtspKeepAliveMethod;
    MaxBlockSamples: Integer;
    MaxBlockDurationMs: Integer;
    MaxBlockSizeBytes: Integer;
    Cameras: TArray<TCameraConfigEntry>;
  end;

  // Leitor da configuração. A parte comum (câmeras, storage, block, log) é lida
  // AQUI e só aqui — quem precisa de campos a mais herda e sobrescreve
  // LoadExtra, que recebe a raiz do mesmo JSON já carregado. Assim não existe
  // um segundo parser (nem um segundo formato) por app.
  TAppConfigLoader = class
  strict private
    FConfig: TAppConfig;
  protected
    // campos que só a config derivada tem
    procedure LoadExtra(Root: TJSONObject); virtual;
    // validação extra da derivada; a comum já rodou
    procedure ValidateExtra; virtual;
  public
    procedure LoadFromFile(const FilePath: string);
    property Config: TAppConfig read FConfig;
  end;

// Helpers de JSON — expostos para que as configs derivadas leiam os campos
// delas do mesmo jeito que a base lê os dela.
function GetJsonStr(Obj: TJSONObject; const Name, Default: string): string;
function GetJsonBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
function GetJsonInt(Obj: TJSONObject; const Name: string; Default: Integer): Integer;
function GetJsonDouble(Obj: TJSONObject; const Name: string; Default: Double): Double;

// Atalho para quem não precisa de campos extras (é o TAppConfigLoader puro).
function LoadAppConfig(const FilePath: string): TAppConfig;

implementation

function GetJsonStr(Obj: TJSONObject; const Name, Default: string): string;
var
  V: TJSONValue;
begin
  if Obj = nil then Exit(Default);
  V := Obj.GetValue(Name);
  if V = nil then Exit(Default);
  if V is TJSONString then
    Result := TJSONString(V).Value
  else
    Result := V.ToString;
end;

function GetJsonBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
var
  V: TJSONValue;
begin
  if Obj = nil then Exit(Default);
  V := Obj.GetValue(Name);
  if V = nil then Exit(Default);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean
  else
    Result := Default;
end;

function GetJsonInt(Obj: TJSONObject; const Name: string; Default: Integer): Integer;
var
  V: TJSONValue;
  D: Double;
begin
  if Obj = nil then Exit(Default);
  V := Obj.GetValue(Name);
  if V = nil then Exit(Default);
  if V is TJSONNumber then
  begin
    D := TJSONNumber(V).AsDouble;
    Result := Trunc(D);
  end
  else
    Result := Default;
end;

function GetJsonDouble(Obj: TJSONObject; const Name: string; Default: Double): Double;
var
  V: TJSONValue;
begin
  if Obj = nil then Exit(Default);
  V := Obj.GetValue(Name);
  if V = nil then Exit(Default);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsDouble
  else
    Result := Default;
end;

function GetJsonArray(Obj: TJSONObject; const Name: string): TJSONArray;
var
  V: TJSONValue;
begin
  Result := nil;
  if Obj = nil then Exit;
  V := Obj.GetValue(Name);
  if V is TJSONArray then
    Result := TJSONArray(V);
end;

function DefaultTransports: TArray<TTransportKind>;
begin
  SetLength(Result, 2);
  Result[0] := txTcp;
  Result[1] := txUdp;
end;

// "transport" é uma string separada por vírgula: "tcp", "udp", "tcp,udp".
// É o formato único do repo — o mesmo que o app RTSPlayer grava no
// cameras.json. Ausente ou irreconhecível cai no default (tcp,udp).
function ParseTransportValue(V: TJSONValue): TArray<TTransportKind>;
var
  I, Count: Integer;
  Parts: TArray<string>;
  T: TTransportKind;
begin
  Result := nil;
  Count := 0;
  if V is TJSONString then
  begin
    Parts := TJSONString(V).Value.Split([',']);
    SetLength(Result, Length(Parts));
    for I := 0 to High(Parts) do
      if ParseTransportKind(Trim(Parts[I]), T) then
      begin
        Result[Count] := T;
        Inc(Count);
      end;
  end;
  SetLength(Result, Count);
  if Count = 0 then
    Result := DefaultTransports;
end;

function ParseReconnect(Obj: TJSONObject): TReconnectConfig;
begin
  Result.InitialDelayMs := Cardinal(GetJsonInt(Obj, 'initialDelayMs', 2000));
  Result.MaxDelayMs := Cardinal(GetJsonInt(Obj, 'maxDelayMs', 30000));
  Result.BackoffMultiplier := GetJsonDouble(Obj, 'backoffMultiplier', 2.0);
  Result.NoRtpTimeoutMs := Cardinal(GetJsonInt(Obj, 'noRtpTimeoutMs', 10000));
end;

function ParseCamera(Obj: TJSONObject): TCameraConfigEntry;
var
  ReconnectObj: TJSONValue;
begin
  Result.Name := GetJsonStr(Obj, 'name', '');
  Result.Enabled := GetJsonBool(Obj, 'enabled', True);
  Result.Url := GetJsonStr(Obj, 'url', '');
  Result.User := GetJsonStr(Obj, 'user', '');
  Result.Password := GetJsonStr(Obj, 'password', '');
  Result.Transports := ParseTransportValue(Obj.GetValue('transport'));
  Result.RecordAudio := GetJsonBool(Obj, 'recordAudio', True);
  Result.FilenamePattern := GetJsonStr(Obj, 'filenamePattern', '{name}_{yyyy-MM-dd_HH-mm-ss}.vms');
  ReconnectObj := Obj.GetValue('reconnect');
  if ReconnectObj is TJSONObject then
    Result.Reconnect := ParseReconnect(TJSONObject(ReconnectObj))
  else
    Result.Reconnect := ParseReconnect(nil);
  Result.MaxReconnectAttempts := GetJsonInt(Obj, 'maxRetries', 0);
  Result.AudioDelayMs := GetJsonInt(Obj, 'audioDelayMs', 200);
  Result.VideoDelayMs := GetJsonInt(Obj, 'videoDelayMs', 200);
end;

procedure ValidateConfig(const Cfg: TAppConfig);
var
  I, J: Integer;
  Names: TStringList;
begin
  if Cfg.StorageDir = '' then
    raise EVmsConfigError.Create('storageDir is required');
  if Length(Cfg.Cameras) = 0 then
    raise EVmsConfigError.Create('At least one camera must be configured');
  Names := TStringList.Create;
  try
    Names.CaseSensitive := False;
    Names.Sorted := True;
    Names.Duplicates := dupError;
    for I := 0 to High(Cfg.Cameras) do
    begin
      if Cfg.Cameras[I].Name = '' then
        raise EVmsConfigError.CreateFmt('Camera index %d has empty name', [I]);
      if Cfg.Cameras[I].Url = '' then
        raise EVmsConfigError.CreateFmt('Camera "%s" has empty url', [Cfg.Cameras[I].Name]);
      try
        Names.Add(Cfg.Cameras[I].Name);
      except
        on E: EStringListError do
          raise EVmsConfigError.CreateFmt('Duplicate camera name: %s', [Cfg.Cameras[I].Name]);
      end;
      if Length(Cfg.Cameras[I].Transports) = 0 then
        raise EVmsConfigError.CreateFmt('Camera "%s" has no valid transport', [Cfg.Cameras[I].Name]);
      for J := 0 to High(Cfg.Cameras[I].Transports) do ;
    end;
  finally
    Names.Free;
  end;
end;

{ TAppConfigLoader }

procedure TAppConfigLoader.LoadExtra(Root: TJSONObject);
begin
  // sem campos extras na config base
end;

procedure TAppConfigLoader.ValidateExtra;
begin
  // nada a validar além do comum
end;

procedure TAppConfigLoader.LoadFromFile(const FilePath: string);
var
  Json: string;
  Root: TJSONValue;
  Obj, BlockObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  V: TJSONValue;
  LevelStr: string;
  Level: TLogLevel;
  KaStr: string;
begin
  if not TFile.Exists(FilePath) then
    raise EVmsConfigError.CreateFmt('Config file not found: %s', [FilePath]);
  Json := TFile.ReadAllText(FilePath, TEncoding.UTF8);
  Root := TJSONObject.ParseJSONValue(Json);
  if Root = nil then
    raise EVmsConfigError.Create('Failed to parse config JSON');
  try
    if not (Root is TJSONObject) then
      raise EVmsConfigError.Create('Config root must be a JSON object');
    Obj := TJSONObject(Root);

    FillChar(FConfig, SizeOf(FConfig), 0);
    FConfig.StorageDir := GetJsonStr(Obj, 'storageDir', '');
    FConfig.LogDir := GetJsonStr(Obj, 'logDir', '');

    LevelStr := GetJsonStr(Obj, 'logLevel', 'info');
    if ParseLogLevel(LevelStr, Level) then
      FConfig.LogLevel := Level
    else
      FConfig.LogLevel := llInfo;

    FConfig.TransportFallbackTimeoutMs := Cardinal(GetJsonInt(Obj, 'transportFallbackTimeoutMs', 5000));

    KaStr := LowerCase(GetJsonStr(Obj, 'keepAliveMethod', 'get_parameter'));
    if (KaStr = 'options') then
      FConfig.KeepAliveMethod := kamOptions
    else
      FConfig.KeepAliveMethod := kamGetParameter;

    V := Obj.GetValue('block');
    if V is TJSONObject then
    begin
      BlockObj := TJSONObject(V);
      FConfig.MaxBlockSamples := GetJsonInt(BlockObj, 'maxSamples', 256);
      FConfig.MaxBlockDurationMs := GetJsonInt(BlockObj, 'maxDurationMs', 2000);
      FConfig.MaxBlockSizeBytes := GetJsonInt(BlockObj, 'maxSizeBytes', 1048576);
    end
    else
    begin
      FConfig.MaxBlockSamples := 256;
      FConfig.MaxBlockDurationMs := 2000;
      FConfig.MaxBlockSizeBytes := 1048576;
    end;

    Arr := GetJsonArray(Obj, 'cameras');
    if Arr <> nil then
    begin
      SetLength(FConfig.Cameras, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        V := Arr.Items[I];
        if V is TJSONObject then
          FConfig.Cameras[I] := ParseCamera(TJSONObject(V))
        else
          raise EVmsConfigError.CreateFmt('cameras[%d] must be an object', [I]);
      end;
    end;

    // a derivada lê os campos dela do mesmo JSON, sem reabrir o arquivo
    LoadExtra(Obj);
  finally
    Root.Free;
  end;

  ValidateConfig(FConfig);
  ValidateExtra;
end;

function LoadAppConfig(const FilePath: string): TAppConfig;
var
  Loader: TAppConfigLoader;
begin
  Loader := TAppConfigLoader.Create;
  try
    Loader.LoadFromFile(FilePath);
    Result := Loader.Config;
  finally
    Loader.Free;
  end;
end;

end.
