unit VMS.Api.Client;

// Cliente das rotas de gravação do vmsserver (ver vms/src/Api).
//
// A URL sai da própria câmera: como a API mora na mesma porta do RTSP,
// `rtsp://host:8554/live/isis` vira `http://host:8554/api/...` — nenhum campo
// novo de configuração, e câmera apontada direto para o equipamento simplesmente
// não responde (e aí o app não oferece playback).
//
// THTTPClient em vez de Indy: é o que já funciona no Android com a permissão de
// internet que o app tem, e fala HTTP de verdade (keep-alive, timeout, status).
//
// **HTTP em claro no Android.** Do Android 9 em diante o sistema bloqueia
// cleartext por padrão, e a chamada morre com "Cleartext HTTP traffic to X not
// permitted" — o ao vivo continua funcionando porque RTSP não passa pela pilha
// HTTP do sistema. O vmsserver não fala TLS (é servidor de casa, alcançado pela
// LAN ou pelo túnel do Tailscale, que já cifra), então o app declara
// android:usesCleartextTraffic="true" no AndroidManifest.template.xml. Se um dia
// o servidor ganhar TLS, é essa linha que sai.
//
// Threading: as chamadas BLOQUEIAM. Quem usa é a thread de rede da engine de
// playback, nunca a thread da UI.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.NetEncoding,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging;

type
  TApiCamera = record
    Name: string;
    Live: Boolean;
    Files: Integer;
    Bytes: Int64;
    FirstMs: Int64;
    LastMs: Int64;
  end;

  TApiDay = record
    Day: string;         // 'YYYY-MM-DD', no fuso do servidor
    StartMs: Int64;
    EndMs: Int64;
    RecordedMs: Int64;
    Coverage: Double;
    Segments: Integer;
  end;

  TApiSegment = record
    StartMs: Int64;
    EndMs: Int64;
  end;

  // Um pedaço de mídia: o corpo é um .vms completo (header + N blocos), e os
  // cabeçalhos dizem onde ele cai na linha do tempo e como continuar.
  TApiMediaChunk = record
    Data: TBytes;
    Cursor: string;
    BlockCount: Integer;
    StartMs: Int64;
    EndMs: Int64;
    NextMs: Int64;        // -1 = acabou a gravação
    GapMs: Int64;
    Discontinuity: Boolean;
    Keyframe: Boolean;
    Growing: Boolean;
  end;

  TVmsApiClient = class
  strict private
    FBaseUrl: string;
    FBaseLock: TCriticalSection;
    FLogger: ILogger;
    FHttp: THTTPClient;
    FLastError: string;
    FLastStatus: Integer;
    function GetBaseUrl: string;
    procedure SetBaseUrl(const Value: string);
    function Get(const PathAndQuery: string; out Body: TBytes;
                 Headers: TStrings = nil): Boolean;
    function GetJson(const PathAndQuery: string; out Obj: TJSONObject): Boolean;
    function FetchMedia(const Query: string; out Chunk: TApiMediaChunk): Boolean;
    procedure Log(Level: TLogLevel; const Msg: string);
  public
    constructor Create(const ABaseUrl: string; const ALogger: ILogger);
    destructor Destroy; override;
    function GetCameras(out Cameras: TArray<TApiCamera>): Boolean;
    function GetDays(const Camera: string; out Days: TArray<TApiDay>): Boolean;
    // DayStartMs/DayEndMs são os limites do dia no fuso do SERVIDOR: é a régua
    // da barra de tempo, e calcular isso no cliente daria outro dia quando os
    // dois estão em fusos diferentes.
    function GetSegments(const Camera, Day: string; out Segments: TArray<TApiSegment>;
                         out DayStartMs, DayEndMs: Int64): Boolean;
    // Busca por instante (início de reprodução e seek).
    function GetMediaAt(const Camera: string; FromMs: Int64; Blocks: Integer;
                        out Chunk: TApiMediaChunk): Boolean;
    // Continuação: devolve o cursor da resposta anterior, sem busca nenhuma.
    function GetMediaNext(const Camera, Cursor: string; Blocks: Integer;
                          out Chunk: TApiMediaChunk): Boolean;
    // Trocável: mudar de câmera pode mudar de servidor, e trocar o OBJETO
    // cliente por baixo da engine deixaria a thread de rede com um ponteiro
    // morto na mão. Trocar só a base é seguro — a requisição em voo já montou
    // a URL dela.
    property BaseUrl: string read GetBaseUrl write SetBaseUrl;
    property LastError: string read FLastError;
    // Status HTTP da última chamada; 0 = nem chegou a haver resposta (rede).
    // Serve para separar "o servidor disse não" (4xx, definitivo) de "não deu
    // para falar com ele" (que merece nova tentativa).
    property LastStatus: Integer read FLastStatus;
  end;

// 'rtsp://host:8554/live/isis' -> 'http://host:8554'. Vazio quando a URL não
// serve (sem host, ou esquema que não é rtsp/http).
function ApiBaseFromCameraUrl(const Url: string): string;
// 'rtsp://host:8554/live/isis' -> 'isis'. O servidor conhece a câmera pelo nome
// da ROTA, que não tem nada a ver com o rótulo que o usuário deu a ela no app
// ("Servidor - frente" é nome de tela; 'frente' é o que o servidor entende).
// Vazio quando a URL não é uma rota /live/ do vmsserver — e aí não há gravação
// para tocar.
function CameraNameFromCameraUrl(const Url: string): string;

implementation

uses
  System.StrUtils;

function ApiBaseFromCameraUrl(const Url: string): string;
var
  S, Authority: string;
  P: Integer;
begin
  Result := '';
  S := Trim(Url);
  P := Pos('://', S);
  if P < 1 then Exit;
  // dvrip:// é conexão direta com a câmera: não há servidor com gravação atrás.
  if not (StartsText('rtsp:', S) or StartsText('http:', S)) then Exit;
  S := Copy(S, P + 3, MaxInt);
  P := Pos('/', S);
  if P > 0 then
    Authority := Copy(S, 1, P - 1)
  else
    Authority := S;
  // credenciais na URL, se houver, não interessam aqui
  P := Pos('@', Authority);
  if P > 0 then
    Authority := Copy(Authority, P + 1, MaxInt);
  if Authority = '' then Exit;
  if Pos(':', Authority) < 1 then
    Authority := Authority + ':8554';
  Result := 'http://' + Authority;
end;

function CameraNameFromCameraUrl(const Url: string): string;
const
  MARK = '/live/';
var
  S: string;
  P: Integer;
begin
  Result := '';
  S := Trim(Url);
  P := Pos(MARK, LowerCase(S));
  if P < 1 then Exit;
  S := Copy(S, P + Length(MARK), MaxInt);
  // corta o que vier depois do nome (query, ou outro segmento)
  P := Pos('?', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  P := Pos('/', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  Result := Trim(S);
end;

{ TVmsApiClient }

constructor TVmsApiClient.Create(const ABaseUrl: string; const ALogger: ILogger);
begin
  inherited Create;
  FBaseLock := TCriticalSection.Create;
  FBaseUrl := ExcludeTrailingPathDelimiter(Trim(ABaseUrl));
  FLogger := ALogger;
  FHttp := THTTPClient.Create;
  // Curtos de propósito: quem espera é o playback, e travar 30 s numa rede ruim
  // é pior do que falhar e tentar de novo.
  FHttp.ConnectionTimeout := 6000;
  FHttp.ResponseTimeout := 15000;
end;

destructor TVmsApiClient.Destroy;
begin
  FHttp.Free;
  FBaseLock.Free;
  inherited;
end;

function TVmsApiClient.GetBaseUrl: string;
begin
  FBaseLock.Enter;
  try
    Result := FBaseUrl;
  finally
    FBaseLock.Leave;
  end;
end;

procedure TVmsApiClient.SetBaseUrl(const Value: string);
begin
  FBaseLock.Enter;
  try
    FBaseUrl := ExcludeTrailingPathDelimiter(Trim(Value));
  finally
    FBaseLock.Leave;
  end;
end;

procedure TVmsApiClient.Log(Level: TLogLevel; const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Log(Level, 'api.client', Msg);
end;

function TVmsApiClient.Get(const PathAndQuery: string; out Body: TBytes;
  Headers: TStrings): Boolean;
var
  Resp: IHTTPResponse;
  Stream: TBytesStream;
  Url: string;
  I: Integer;
begin
  Result := False;
  Body := nil;
  FLastError := '';
  FLastStatus := 0;
  Url := GetBaseUrl + PathAndQuery;
  Stream := TBytesStream.Create;
  try
    try
      Resp := FHttp.Get(Url, Stream);
    except
      on E: Exception do
      begin
        FLastError := E.Message;
        Log(llWarn, Format('%s: %s', [PathAndQuery, E.Message]));
        Exit;
      end;
    end;
    FLastStatus := Resp.StatusCode;
    if Resp.StatusCode <> 200 then
    begin
      // O corpo de erro da API é um JSON com o motivo; sem ele o log só diria
      // o número, e "404" não conta qual câmera o servidor não conhece.
      FLastError := Format('HTTP %d %s', [Resp.StatusCode,
        TEncoding.UTF8.GetString(Copy(Stream.Bytes, 0, Integer(Stream.Size)))]);
      Log(llWarn, Format('%s: %s', [PathAndQuery, FLastError]));
      Exit;
    end;
    // Stream.Bytes pode ter capacidade a mais que o conteúdo: corta no tamanho.
    Body := Copy(Stream.Bytes, 0, Integer(Stream.Size));
    if Headers <> nil then
      for I := 0 to High(Resp.Headers) do
        Headers.Values[Resp.Headers[I].Name] := Resp.Headers[I].Value;
    Result := True;
  finally
    Stream.Free;
  end;
end;

function TVmsApiClient.GetJson(const PathAndQuery: string; out Obj: TJSONObject): Boolean;
var
  Body: TBytes;
  V: TJSONValue;
begin
  Obj := nil;
  Result := False;
  if not Get(PathAndQuery, Body) then Exit;
  V := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Body));
  if not (V is TJSONObject) then
  begin
    V.Free;
    FLastError := 'resposta nao e JSON';
    Exit;
  end;
  Obj := TJSONObject(V);
  Result := True;
end;

function JsonInt(Obj: TJSONObject; const Name: string; Default: Int64 = 0): Int64;
var
  V: TJSONValue;
begin
  Result := Default;
  if Obj = nil then Exit;
  V := Obj.GetValue(Name);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsInt64;
end;

function JsonFloat(Obj: TJSONObject; const Name: string; Default: Double = 0): Double;
var
  V: TJSONValue;
begin
  Result := Default;
  if Obj = nil then Exit;
  V := Obj.GetValue(Name);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsDouble;
end;

function JsonStr(Obj: TJSONObject; const Name: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  if Obj = nil then Exit;
  V := Obj.GetValue(Name);
  if V is TJSONString then
    Result := TJSONString(V).Value;
end;

function JsonBool(Obj: TJSONObject; const Name: string): Boolean;
var
  V: TJSONValue;
begin
  Result := False;
  if Obj = nil then Exit;
  V := Obj.GetValue(Name);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean;
end;

function TVmsApiClient.GetCameras(out Cameras: TArray<TApiCamera>): Boolean;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONObject;
begin
  Cameras := nil;
  Result := GetJson('/api/cameras', Root);
  if not Result then Exit;
  try
    Arr := Root.GetValue('cameras') as TJSONArray;
    if Arr = nil then Exit;
    SetLength(Cameras, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.Items[I] as TJSONObject;
      Cameras[I].Name := JsonStr(Item, 'name');
      Cameras[I].Live := JsonBool(Item, 'live');
      Cameras[I].Files := Integer(JsonInt(Item, 'files'));
      Cameras[I].Bytes := JsonInt(Item, 'bytes');
      Cameras[I].FirstMs := JsonInt(Item, 'firstMs');
      Cameras[I].LastMs := JsonInt(Item, 'lastMs');
    end;
  finally
    Root.Free;
  end;
end;

function TVmsApiClient.GetDays(const Camera: string; out Days: TArray<TApiDay>): Boolean;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONObject;
begin
  Days := nil;
  Result := GetJson('/api/days?camera=' + TNetEncoding.URL.Encode(Camera), Root);
  if not Result then Exit;
  try
    Arr := Root.GetValue('days') as TJSONArray;
    if Arr = nil then Exit;
    SetLength(Days, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.Items[I] as TJSONObject;
      Days[I].Day := JsonStr(Item, 'day');
      Days[I].StartMs := JsonInt(Item, 'startMs');
      Days[I].EndMs := JsonInt(Item, 'endMs');
      Days[I].RecordedMs := JsonInt(Item, 'recordedMs');
      Days[I].Coverage := JsonFloat(Item, 'coverage');
      Days[I].Segments := Integer(JsonInt(Item, 'segments'));
    end;
  finally
    Root.Free;
  end;
end;

function TVmsApiClient.GetSegments(const Camera, Day: string;
  out Segments: TArray<TApiSegment>; out DayStartMs, DayEndMs: Int64): Boolean;
var
  Root: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONObject;
begin
  Segments := nil;
  DayStartMs := 0;
  DayEndMs := 0;
  Result := GetJson(Format('/api/segments?camera=%s&day=%s',
    [TNetEncoding.URL.Encode(Camera), TNetEncoding.URL.Encode(Day)]), Root);
  if not Result then Exit;
  try
    DayStartMs := JsonInt(Root, 'dayStartMs');
    DayEndMs := JsonInt(Root, 'dayEndMs');
    Arr := Root.GetValue('segments') as TJSONArray;
    if Arr = nil then Exit;
    SetLength(Segments, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.Items[I] as TJSONObject;
      Segments[I].StartMs := JsonInt(Item, 'startMs');
      Segments[I].EndMs := JsonInt(Item, 'endMs');
    end;
  finally
    Root.Free;
  end;
end;

function TVmsApiClient.FetchMedia(const Query: string; out Chunk: TApiMediaChunk): Boolean;
var
  Headers: TStringList;
  Body: TBytes;

  function HeaderInt(const Name: string; Default: Int64): Int64;
  var
    S: string;
  begin
    S := Trim(Headers.Values[Name]);
    if (S = '') or (not TryStrToInt64(S, Result)) then
      Result := Default;
  end;

begin
  Chunk := Default(TApiMediaChunk);
  Chunk.NextMs := -1;
  Result := False;
  Headers := TStringList.Create;
  try
    if not Get(Query, Body, Headers) then Exit;
    if Length(Body) = 0 then
    begin
      FLastError := 'resposta de midia vazia';
      Exit;
    end;
    Chunk.Data := Body;
    Chunk.Cursor := Trim(Headers.Values['X-Vms-Cursor']);
    Chunk.BlockCount := Integer(HeaderInt('X-Vms-Block-Count', 0));
    Chunk.StartMs := HeaderInt('X-Vms-Start-Ms', 0);
    Chunk.EndMs := HeaderInt('X-Vms-End-Ms', 0);
    Chunk.NextMs := HeaderInt('X-Vms-Next-Ms', -1);
    Chunk.GapMs := HeaderInt('X-Vms-Gap-Ms', 0);
    Chunk.Discontinuity := HeaderInt('X-Vms-Discontinuity', 0) <> 0;
    Chunk.Keyframe := HeaderInt('X-Vms-Keyframe', 0) <> 0;
    Chunk.Growing := HeaderInt('X-Vms-Growing', 0) <> 0;
    Result := True;
  finally
    Headers.Free;
  end;
end;

function TVmsApiClient.GetMediaAt(const Camera: string; FromMs: Int64; Blocks: Integer;
  out Chunk: TApiMediaChunk): Boolean;
begin
  Result := FetchMedia(Format('/api/media?camera=%s&fromMs=%d&blocks=%d',
    [TNetEncoding.URL.Encode(Camera), FromMs, Blocks]), Chunk);
end;

function TVmsApiClient.GetMediaNext(const Camera, Cursor: string; Blocks: Integer;
  out Chunk: TApiMediaChunk): Boolean;
begin
  if Cursor = '' then
  begin
    FLastError := 'cursor vazio';
    Exit(False);
  end;
  // A câmera vai junto porque o cursor pode ter caducado (retenção apagou o
  // arquivo que ele apontava): aí o servidor resolve pelo instante, dentro dela.
  Result := FetchMedia(Format('/api/media?camera=%s&cursor=%s&blocks=%d',
    [TNetEncoding.URL.Encode(Camera), TNetEncoding.URL.Encode(Cursor), Blocks]), Chunk);
end;

end.
