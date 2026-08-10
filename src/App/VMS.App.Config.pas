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

function ParseTransportArray(Arr: TJSONArray): TArray<TTransportKind>;
var
  I, Count: Integer;
  V: TJSONValue;
  S: string;
  T: TTransportKind;
begin
  Result := nil;
  if (Arr = nil) or (Arr.Count = 0) then
  begin
    SetLength(Result, 2);
    Result[0] := txTcp;
    Result[1] := txUdp;
    Exit;
  end;
  Count := 0;
  SetLength(Result, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    V := Arr.Items[I];
    if V is TJSONString then
    begin
      S := TJSONString(V).Value;
      if ParseTransportKind(S, T) then
      begin
        Result[Count] := T;
        Inc(Count);
      end;
    end;
  end;
  SetLength(Result, Count);
  if Count = 0 then
  begin
    SetLength(Result, 2);
    Result[0] := txTcp;
    Result[1] := txUdp;
  end;
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
  TransportArr: TJSONArray;
  ReconnectObj: TJSONValue;
begin
  Result.Name := GetJsonStr(Obj, 'name', '');
  Result.Enabled := GetJsonBool(Obj, 'enabled', True);
  Result.Url := GetJsonStr(Obj, 'url', '');
  Result.User := GetJsonStr(Obj, 'user', '');
  Result.Password := GetJsonStr(Obj, 'password', '');
  TransportArr := GetJsonArray(Obj, 'transport');
  Result.Transports := ParseTransportArray(TransportArr);
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

function LoadAppConfig(const FilePath: string): TAppConfig;
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

    FillChar(Result, SizeOf(Result), 0);
    Result.StorageDir := GetJsonStr(Obj, 'storageDir', '');
    Result.LogDir := GetJsonStr(Obj, 'logDir', '');

    LevelStr := GetJsonStr(Obj, 'logLevel', 'info');
    if ParseLogLevel(LevelStr, Level) then
      Result.LogLevel := Level
    else
      Result.LogLevel := llInfo;

    Result.TransportFallbackTimeoutMs := Cardinal(GetJsonInt(Obj, 'transportFallbackTimeoutMs', 5000));

    KaStr := LowerCase(GetJsonStr(Obj, 'keepAliveMethod', 'get_parameter'));
    if (KaStr = 'options') then
      Result.KeepAliveMethod := kamOptions
    else
      Result.KeepAliveMethod := kamGetParameter;

    V := Obj.GetValue('block');
    if V is TJSONObject then
    begin
      BlockObj := TJSONObject(V);
      Result.MaxBlockSamples := GetJsonInt(BlockObj, 'maxSamples', 256);
      Result.MaxBlockDurationMs := GetJsonInt(BlockObj, 'maxDurationMs', 2000);
      Result.MaxBlockSizeBytes := GetJsonInt(BlockObj, 'maxSizeBytes', 1048576);
    end
    else
    begin
      Result.MaxBlockSamples := 256;
      Result.MaxBlockDurationMs := 2000;
      Result.MaxBlockSizeBytes := 1048576;
    end;

    Arr := GetJsonArray(Obj, 'cameras');
    if Arr <> nil then
    begin
      SetLength(Result.Cameras, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        V := Arr.Items[I];
        if V is TJSONObject then
          Result.Cameras[I] := ParseCamera(TJSONObject(V))
        else
          raise EVmsConfigError.CreateFmt('cameras[%d] must be an object', [I]);
      end;
    end;
    ValidateConfig(Result);
  finally
    Root.Free;
  end;
end;

end.
