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

const
  // De quanto em quanto tempo a gravação roda de arquivo, quando a config não
  // diz. Uma hora dá ~290 MB por arquivo a 650 kbps e 24 arquivos por dia por
  // câmera — pasta que continua legível, retenção com granularidade fina, e
  // índice de ~43 KB por arquivo na memória do servidor.
  DEFAULT_ROTATE_MINUTES = 60;
  // Um dia inteiro num arquivo só já é mais do que qualquer uso quer; acima
  // disso a conta em ms nem cabe num Integer.
  MAX_ROTATE_MINUTES = 1440;

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
    // Caminhos até ESTA câmera, em ordem de prioridade (a LAN dela, o servidor
    // que a republica, o mesmo servidor pela tailnet). Quem conecta testa qual
    // responde — ver VMS.Net.Probe. Os campos Url/User/Password/Transports/
    // UsesTailscale abaixo espelham o PRIMEIRO endpoint: é o que a lista mostra,
    // e o que vale quando a câmera tem um caminho só.
    Endpoints: TCameraEndpoints;
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
    // Câmera que só existe dentro da tailnet: antes de conectar, garante que o
    // túnel do Tailscale esteja de pé (ver VMS.App.Tailscale). Fica desligado
    // por padrão — quem está na LAN não deve pagar por essa espera.
    UsesTailscale: Boolean;
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
    // De quanto em quanto tempo a gravação roda de arquivo, em ms. É o que
    // decide o tamanho de cada segmento e quantos arquivos ficam na pasta da
    // câmera. 0 = não roda, e um arquivo cobre a sessão inteira.
    RotateMs: Integer;
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

// Um caminho até a câmera, do array "endpoints". Exportado porque o app lê o
// cameras.json dele com regras próprias de reconexão (ver MakeCamera), mas o
// objeto do caminho tem que ser lido do MESMO jeito nos dois lados — foi
// justamente ler diferente que fez o app carregar só o primeiro caminho.
function ParseEndpoint(Obj: TJSONObject; Index: Integer): TCameraEndpoint;

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

function ParseEndpoint(Obj: TJSONObject; Index: Integer): TCameraEndpoint;
begin
  Result.Name := GetJsonStr(Obj, 'name', '');
  if Result.Name = '' then
    Result.Name := Format('conex'#$E3'o %d', [Index + 1]);
  Result.Url := GetJsonStr(Obj, 'url', '');
  Result.User := GetJsonStr(Obj, 'user', '');
  Result.Password := GetJsonStr(Obj, 'password', '');
  Result.Transports := ParseTransportValue(Obj.GetValue('transport'));
  Result.UsesTailscale := GetJsonBool(Obj, 'tailscale', False);
end;

function ParseCamera(Obj: TJSONObject): TCameraConfigEntry;
var
  ReconnectObj, EpValue: TJSONValue;
  Arr: TJSONArray;
  I, Count: Integer;
begin
  Result.Name := GetJsonStr(Obj, 'name', '');
  Result.Enabled := GetJsonBool(Obj, 'enabled', True);

  // Formato novo: lista de caminhos. Formato antigo (uma url por câmera)
  // continua sendo lido — vira uma câmera com um endpoint só, e nada muda para
  // quem não tem mais de um jeito de chegar na câmera.
  Result.Endpoints := nil;
  EpValue := Obj.GetValue('endpoints');
  if EpValue is TJSONArray then
  begin
    Arr := TJSONArray(EpValue);
    SetLength(Result.Endpoints, Arr.Count);
    Count := 0;
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        Result.Endpoints[Count] := ParseEndpoint(TJSONObject(Arr.Items[I]), Count);
        if Trim(Result.Endpoints[Count].Url) <> '' then
          Inc(Count);
      end;
    SetLength(Result.Endpoints, Count);
  end;

  if Length(Result.Endpoints) > 0 then
  begin
    // espelho do primeiro: é o que a lista mostra e o que vale como padrão
    Result.Url := Result.Endpoints[0].Url;
    Result.User := Result.Endpoints[0].User;
    Result.Password := Result.Endpoints[0].Password;
    Result.Transports := Result.Endpoints[0].Transports;
    Result.UsesTailscale := Result.Endpoints[0].UsesTailscale;
  end
  else
  begin
    Result.Url := GetJsonStr(Obj, 'url', '');
    Result.User := GetJsonStr(Obj, 'user', '');
    Result.Password := GetJsonStr(Obj, 'password', '');
    Result.Transports := ParseTransportValue(Obj.GetValue('transport'));
    Result.UsesTailscale := GetJsonBool(Obj, 'tailscale', False);
  end;
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
  I, RotateMin: Integer;
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

    // Em minutos na config: é a unidade em que se pensa "de quanto em quanto
    // tempo quero um arquivo novo". Aparado antes de virar ms, senão um número
    // grande demais estoura o Integer e vira rotação a cada instante.
    RotateMin := GetJsonInt(Obj, 'rotateMinutes', DEFAULT_ROTATE_MINUTES);
    if RotateMin < 0 then RotateMin := 0;
    if RotateMin > MAX_ROTATE_MINUTES then RotateMin := MAX_ROTATE_MINUTES;
    FConfig.RotateMs := RotateMin * 60000;

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
