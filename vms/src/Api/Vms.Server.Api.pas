unit Vms.Server.Api;

// As rotas HTTP do servidor, na MESMA porta do RTSP (ver Tx.Server.Listener: o
// desvio é pela versão da linha do pedido, `HTTP/1.1` em vez de `RTSP/1.0`).
//
// O que o app precisa saber para montar a timeline:
//
//   GET /api/cameras                      quem existe, e quem está ao vivo agora
//   GET /api/days?camera=X                que dias têm gravação, e quanto
//   GET /api/segments?camera=X&day=Y      as faixas contínuas daquele dia
//   GET /api/media?camera=X&fromMs=…      a mídia: header .vms + N blocos
//   GET /api/media?camera=X&cursor=…      a continuação, sem busca
//   GET /api/recordings?camera=X&...      a lista crua, arquivo por arquivo
//   GET /api/index?file=…                 o índice de blocos, cru
//                                         (as duas últimas são diagnóstico)
//
// Regra de ouro destas rotas: **o cliente não sabe que existem arquivos**. Ele
// pede instante e recebe faixa; que a câmera tenha gerado 37 .vms naquele dia
// porque reconectou é assunto daqui. Só a rota de diagnóstico fala em arquivo.
//
// Este roteador não conhece socket: recebe método e URI, devolve status, tipo e
// corpo. Quem escreve na conexão é a TTxSession, que tem o lock de escrita —
// senão a resposta HTTP se intercalaria com o RTP interleaved de um PLAY na
// mesma conexão.
//
// Threading: uma instância só, compartilhada por todas as conexões. Não guarda
// estado por requisição; o cache que ele consulta tem lock próprio.

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.TimeSpan,
  System.StrUtils,
  System.JSON,
  System.IOUtils,
  System.NetEncoding,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  Vms.Server.LiveHub,
  Vms.Server.IndexCache,
  Vms.Server.Media;

const
  API_PREFIX = '/api/';
  API_DEFAULT_MAX_BLOCKS = 32;
  // Colagem: dois arquivos separados por menos que isto viram uma faixa só. Uma
  // reconexão de câmera custa centenas de ms; 5 s cobre com folga sem esconder
  // ausência de verdade.
  API_DEFAULT_GAP_MS = 5000;
  MS_PER_DAY = Int64(86400000);

type
  TApiConfig = record
    Enabled: Boolean;
    MaxBlocksPerRequest: Integer;
    function Describe: string;
  end;

  TApiResponse = record
    Status: Integer;
    ContentType: string;
    Body: TBytes;
    // cabeçalhos extras, já no formato "Nome: valor"
    Extra: TArray<string>;
    class function FromJson(Obj: TJSONObject): TApiResponse; static;
    class function Error(AStatus: Integer; const Msg: string): TApiResponse; static;
  end;

  TApiRouter = class
  strict private
    FConfig: TApiConfig;
    FCameras: TArray<string>;
    FHub: TLiveHub;
    FCache: TVmsIndexCache;
    FMedia: TMediaBuilder;
    FLogger: ILogger;
    function KnownCamera(const Name: string; out Canonical: string): Boolean;
    function IsLive(const Camera: string): Boolean;
    function HandleCameras: TApiResponse;
    function HandleDays(const Query: string): TApiResponse;
    function HandleSegments(const Query: string): TApiResponse;
    function HandleRecordings(const Query: string): TApiResponse;
    function HandleMedia(const Query: string): TApiResponse;
    function HandleIndex(const Query: string): TApiResponse;
  public
    constructor Create(const AConfig: TApiConfig; const AStorageDir: string;
                       const ACameras: TArray<string>; AHub: TLiveHub;
                       const ALogger: ILogger);
    destructor Destroy; override;
    // Method e Uri como vieram da linha do pedido. Nunca levanta exceção: erro
    // vira resposta.
    function Handle(const Method, Uri: string): TApiResponse;
    class function IsApiPath(const Uri: string): Boolean; static;
    property Cache: TVmsIndexCache read FCache;
    property Config: TApiConfig read FConfig;
  end;

// Helpers de tempo, expostos porque a rota de mídia (fase 3) usa os mesmos.
function UnixMsToLocal(Ms: Int64): TDateTime;
function LocalToUnixMs(const Local: TDateTime): Int64;
function LocalDayOf(Ms: Int64): TDateTime;
function UtcOffsetStr: string;
function QueryValue(const Query, Name: string): string;
function SplitPathAndQuery(const Uri: string; out Path, Query: string): Boolean;

implementation

const
  UNIX_EPOCH_DATE = 25569.0; // 1970-01-01 em TDateTime

{ helpers de tempo }

function UnixMsToLocal(Ms: Int64): TDateTime;
var
  Utc: TDateTime;
begin
  Utc := UNIX_EPOCH_DATE + (Ms / MS_PER_DAY);
  try
    Result := TTimeZone.Local.ToLocalTime(Utc);
  except
    Result := Utc; // fuso indisponível: pelo menos não derruba a consulta
  end;
end;

function LocalToUnixMs(const Local: TDateTime): Int64;
var
  Utc: TDateTime;
begin
  try
    Utc := TTimeZone.Local.ToUniversalTime(Local);
  except
    Utc := Local;
  end;
  Result := Round((Utc - UNIX_EPOCH_DATE) * MS_PER_DAY);
end;

// Meia-noite local do dia em que aquele instante cai.
function LocalDayOf(Ms: Int64): TDateTime;
begin
  Result := DateOf(UnixMsToLocal(Ms));
end;

function UtcOffsetStr: string;
var
  Span: TTimeSpan;
  Total, H, M: Integer;
  Sign: Char;
begin
  try
    Span := TTimeZone.Local.GetUtcOffset(Now);
  except
    Exit('+00:00');
  end;
  Total := Round(Span.TotalMinutes);
  if Total < 0 then
  begin
    Sign := '-';
    Total := -Total;
  end
  else
    Sign := '+';
  H := Total div 60;
  M := Total mod 60;
  Result := Format('%s%.2d:%.2d', [Sign, H, M]);
end;

{ helpers de URI }

function SplitPathAndQuery(const Uri: string; out Path, Query: string): Boolean;
var
  P, SchemeEnd: Integer;
  S: string;
begin
  S := Trim(Uri);
  Query := '';
  Path := '';
  if S = '' then Exit(False);
  // Cliente pode mandar caminho absoluto (RTSP faz isso; HTTP normalmente não).
  SchemeEnd := Pos('://', S);
  if SchemeEnd > 0 then
  begin
    P := PosEx('/', S, SchemeEnd + 3);
    if P > 0 then
      S := Copy(S, P, MaxInt)
    else
      S := '/';
  end;
  P := Pos('?', S);
  if P > 0 then
  begin
    Query := Copy(S, P + 1, MaxInt);
    S := Copy(S, 1, P - 1);
  end;
  Path := S;
  Result := Path <> '';
end;

function QueryValue(const Query, Name: string): string;
var
  Pairs: TArray<string>;
  I, P: Integer;
  K, V: string;
begin
  Result := '';
  if Query = '' then Exit;
  Pairs := Query.Split(['&']);
  for I := 0 to High(Pairs) do
  begin
    P := Pos('=', Pairs[I]);
    if P < 2 then Continue;
    K := Copy(Pairs[I], 1, P - 1);
    if not SameText(K, Name) then Continue;
    V := Copy(Pairs[I], P + 1, MaxInt);
    // Numa query, '+' é espaço — um '+' literal chega como %2B, então trocar
    // antes de decodificar é a ordem certa. Sem isto, câmera com espaço no nome
    // nunca casaria com a lista da config.
    V := StringReplace(V, '+', ' ', [rfReplaceAll]);
    Result := TNetEncoding.URL.Decode(V);
    Exit;
  end;
end;

function QueryInt(const Query, Name: string; Default: Int64): Int64;
var
  S: string;
begin
  S := Trim(QueryValue(Query, Name));
  if S = '' then Exit(Default);
  if not TryStrToInt64(S, Result) then
    Result := Default;
end;

function ParseDay(const S: string; out Day: TDateTime): Boolean;
var
  Y, M, D: Integer;
begin
  // 'YYYY-MM-DD', e só isso: aceitar formato local traria ambiguidade de fuso
  // e de separador que não vale a pena.
  Result := False;
  if Length(S) <> 10 then Exit;
  if (S[5] <> '-') or (S[8] <> '-') then Exit;
  if not TryStrToInt(Copy(S, 1, 4), Y) then Exit;
  if not TryStrToInt(Copy(S, 6, 2), M) then Exit;
  if not TryStrToInt(Copy(S, 9, 2), D) then Exit;
  Result := TryEncodeDate(Y, M, D, Day);
end;

function DayStr(const Day: TDateTime): string;
begin
  Result := FormatDateTime('yyyy-mm-dd', Day);
end;

{ TApiConfig }

function TApiConfig.Describe: string;
begin
  if not Enabled then
    Exit('desligada');
  Result := Format('ligada, ate %d blocos por pedido', [MaxBlocksPerRequest]);
end;

{ TApiResponse }

class function TApiResponse.FromJson(Obj: TJSONObject): TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'application/json; charset=utf-8';
  Result.Extra := nil;
  try
    Result.Body := TEncoding.UTF8.GetBytes(Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

class function TApiResponse.Error(AStatus: Integer; const Msg: string): TApiResponse;
var
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  Obj.AddPair('error', Msg);
  Result := FromJson(Obj);
  Result.Status := AStatus;
end;

{ TApiRouter }

constructor TApiRouter.Create(const AConfig: TApiConfig; const AStorageDir: string;
  const ACameras: TArray<string>; AHub: TLiveHub; const ALogger: ILogger);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.MaxBlocksPerRequest <= 0 then
    FConfig.MaxBlocksPerRequest := API_DEFAULT_MAX_BLOCKS;
  FCameras := Copy(ACameras);
  FHub := AHub;
  FLogger := ALogger;
  FCache := TVmsIndexCache.Create(AStorageDir, ALogger);
  FMedia := TMediaBuilder.Create(FCache, FConfig.MaxBlocksPerRequest, ALogger);
end;

destructor TApiRouter.Destroy;
begin
  FMedia.Free;
  FCache.Free;
  inherited;
end;

class function TApiRouter.IsApiPath(const Uri: string): Boolean;
var
  Path, Query: string;
begin
  Result := SplitPathAndQuery(Uri, Path, Query) and StartsText(API_PREFIX, Path);
end;

// O nome da câmera vem do cliente e vira parte de um caminho de arquivo. Aceitar
// só o que está configurado resolve a travessia de diretório pela raiz: nada que
// o cliente escreva chega ao sistema de arquivos.
function TApiRouter.KnownCamera(const Name: string; out Canonical: string): Boolean;
var
  I: Integer;
begin
  Canonical := '';
  if Trim(Name) = '' then Exit(False);
  for I := 0 to High(FCameras) do
    if SameText(FCameras[I], Name) then
    begin
      Canonical := FCameras[I];
      Exit(True);
    end;
  Result := False;
end;

function TApiRouter.IsLive(const Camera: string): Boolean;
var
  Stream: TLiveStream;
begin
  Result := False;
  if FHub = nil then Exit;
  Stream := FHub.Find(Camera);
  Result := (Stream <> nil) and Stream.IsPublishing;
end;

function TApiRouter.Handle(const Method, Uri: string): TApiResponse;
var
  Path, Query: string;
begin
  try
    if not FConfig.Enabled then
      Exit(TApiResponse.Error(404, 'api desligada'));
    if not (SameText(Method, 'GET') or SameText(Method, 'HEAD')) then
      Exit(TApiResponse.Error(405, 'so GET e HEAD'));
    if not SplitPathAndQuery(Uri, Path, Query) then
      Exit(TApiResponse.Error(400, 'uri invalida'));

    if SameText(Path, API_PREFIX + 'cameras') then
      Result := HandleCameras
    else if SameText(Path, API_PREFIX + 'days') then
      Result := HandleDays(Query)
    else if SameText(Path, API_PREFIX + 'segments') then
      Result := HandleSegments(Query)
    else if SameText(Path, API_PREFIX + 'media') then
      Result := HandleMedia(Query)
    else if SameText(Path, API_PREFIX + 'recordings') then
      Result := HandleRecordings(Query)
    else if SameText(Path, API_PREFIX + 'index') then
      Result := HandleIndex(Query)
    else
      Result := TApiResponse.Error(404, 'rota desconhecida: ' + Path);
  except
    on E: Exception do
    begin
      if FLogger <> nil then
        FLogger.Error('api', Format('%s %s: %s', [Method, Uri, E.Message]));
      Result := TApiResponse.Error(500, E.Message);
    end;
  end;
end;

function TApiRouter.HandleCameras: TApiResponse;
var
  Root, Item: TJSONObject;
  Arr: TJSONArray;
  I, J: Integer;
  Files: TVmsFileInfoArray;
  Bytes: Int64;
begin
  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('tz', UtcOffsetStr);
  Root.AddPair('cameras', Arr);
  for I := 0 to High(FCameras) do
  begin
    Files := FCache.ListFiles(FCameras[I]);
    Item := TJSONObject.Create;
    Item.AddPair('name', FCameras[I]);
    Item.AddPair('live', TJSONBool.Create(IsLive(FCameras[I])));
    Item.AddPair('files', TJSONNumber.Create(Length(Files)));
    Bytes := 0;
    for J := 0 to High(Files) do
      Inc(Bytes, Files[J].Bytes);
    Item.AddPair('bytes', TJSONNumber.Create(Bytes));
    if Length(Files) > 0 then
    begin
      Item.AddPair('firstMs', TJSONNumber.Create(Files[0].StartMs));
      Item.AddPair('lastMs', TJSONNumber.Create(Files[High(Files)].EndMs));
    end;
    Arr.AddElement(Item);
  end;
  Result := TApiResponse.FromJson(Root);
end;

function TApiRouter.HandleDays(const Query: string): TApiResponse;
var
  Camera: string;
  Files: TVmsFileInfoArray;
  Exact, Glued, DayExact, DayGlued: TTimeRangeArray;
  Root, Item: TJSONObject;
  Arr: TJSONArray;
  Day, LastDay: TDateTime;
  DayStartMs, DayEndMs, Recorded, GapMs: Int64;
  I: Integer;
begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));

  GapMs := QueryInt(Query, 'gapMs', API_DEFAULT_GAP_MS);
  if GapMs < 0 then GapMs := 0;

  Files := FCache.ListFiles(Camera);
  // Duas contas diferentes de propósito. Quanto foi gravado se mede SEM folga:
  // encostar não é preencher. Quantas faixas o dia tem se conta COM a folga da
  // colagem, senão este número não bateria com o que o /api/segments desenha —
  // cada reconexão de câmera viraria uma faixa a mais.
  Exact := MergeRanges(Files, 0);
  Glued := MergeRanges(Files, GapMs);

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('tz', UtcOffsetStr);
  Root.AddPair('days', Arr);

  if Length(Exact) > 0 then
  begin
    Day := LocalDayOf(Exact[0].StartMs);
    LastDay := LocalDayOf(Exact[High(Exact)].EndMs);
    while Day <= LastDay do
    begin
      DayStartMs := LocalToUnixMs(Day);
      DayEndMs := LocalToUnixMs(Day + 1);
      DayExact := ClipRanges(Exact, DayStartMs, DayEndMs);
      if Length(DayExact) > 0 then
      begin
        DayGlued := ClipRanges(Glued, DayStartMs, DayEndMs);
        Recorded := 0;
        for I := 0 to High(DayExact) do
          Inc(Recorded, DayExact[I].EndMs - DayExact[I].StartMs);
        Item := TJSONObject.Create;
        Item.AddPair('day', DayStr(Day));
        Item.AddPair('startMs', TJSONNumber.Create(DayExact[0].StartMs));
        Item.AddPair('endMs', TJSONNumber.Create(DayExact[High(DayExact)].EndMs));
        Item.AddPair('recordedMs', TJSONNumber.Create(Recorded));
        // Fração do dia com gravação. O dia de hoje ainda não acabou, então o
        // valor sobe ao longo do dia — é assim mesmo: a barra mostra o que já
        // existe, não uma previsão.
        Item.AddPair('coverage', TJSONNumber.Create(Recorded / MS_PER_DAY));
        Item.AddPair('segments', TJSONNumber.Create(Length(DayGlued)));
        Arr.AddElement(Item);
      end;
      Day := Day + 1;
    end;
  end;
  Result := TApiResponse.FromJson(Root);
end;

function TApiRouter.HandleSegments(const Query: string): TApiResponse;
var
  Camera, DayText: string;
  Day: TDateTime;
  Files: TVmsFileInfoArray;
  Ranges: TTimeRangeArray;
  Root, Item: TJSONObject;
  Arr: TJSONArray;
  GapMs, DayStartMs, DayEndMs: Int64;
  I: Integer;
begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));

  DayText := Trim(QueryValue(Query, 'day'));
  if DayText = '' then
    Day := DateOf(Now)
  else if not ParseDay(DayText, Day) then
    Exit(TApiResponse.Error(400, 'day precisa ser YYYY-MM-DD'));

  GapMs := QueryInt(Query, 'gapMs', API_DEFAULT_GAP_MS);
  if GapMs < 0 then GapMs := 0;

  DayStartMs := LocalToUnixMs(Day);
  DayEndMs := LocalToUnixMs(Day + 1);

  Files := FCache.ListFiles(Camera);
  Ranges := ClipRanges(MergeRanges(Files, GapMs), DayStartMs, DayEndMs);

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('day', DayStr(Day));
  Root.AddPair('tz', UtcOffsetStr);
  Root.AddPair('dayStartMs', TJSONNumber.Create(DayStartMs));
  Root.AddPair('dayEndMs', TJSONNumber.Create(DayEndMs));
  Root.AddPair('gapMs', TJSONNumber.Create(GapMs));
  Root.AddPair('segments', Arr);
  for I := 0 to High(Ranges) do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('startMs', TJSONNumber.Create(Ranges[I].StartMs));
    Item.AddPair('endMs', TJSONNumber.Create(Ranges[I].EndMs));
    Arr.AddElement(Item);
  end;
  Result := TApiResponse.FromJson(Root);
end;

function TApiRouter.HandleMedia(const Query: string): TApiResponse;
var
  Req: TMediaRequest;
  Frag: TMediaFragment;
  Camera, FileName, CursorText: string;
begin
  Req := Default(TMediaRequest);

  FileName := Trim(QueryValue(Query, 'file'));
  if FileName <> '' then
  begin
    // Modo diagnóstico. Não é o caminho do app, e por isso não exige câmera —
    // mas o nome passa pelo mesmo filtro, senão viraria leitura de disco livre.
    if not IsSafeVmsName(FileName) then
      Exit(TApiResponse.Error(400, 'nome de arquivo invalido'));
    Req.FileName := FileName;
  end
  else
  begin
    if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
      Exit(TApiResponse.Error(404, 'camera desconhecida'));
    Req.Camera := Camera;
  end;

  CursorText := Trim(QueryValue(Query, 'cursor'));
  if CursorText <> '' then
    if not TMediaCursor.Decode(CursorText, Req.Cursor) then
      Exit(TApiResponse.Error(400, 'cursor invalido'));

  if Trim(QueryValue(Query, 'fromMs')) <> '' then
  begin
    Req.FromMs := QueryInt(Query, 'fromMs', 0);
    Req.HasFromMs := True;
  end;
  if Trim(QueryValue(Query, 'fromBlock')) <> '' then
  begin
    Req.FromBlock := Integer(QueryInt(Query, 'fromBlock', 0));
    Req.HasFromBlock := True;
  end;
  Req.Blocks := Integer(QueryInt(Query, 'blocks', MEDIA_DEFAULT_BLOCKS));

  Frag := FMedia.Fetch(Req);
  if not Frag.Ok then
    Exit(TApiResponse.Error(Frag.Status, Frag.Error));

  Result.Status := 200;
  Result.ContentType := 'application/x-vms';
  Result.Body := Frag.Data;
  Result.Extra := TArray<string>.Create(
    'X-Vms-Cursor: ' + Frag.Cursor,
    Format('X-Vms-Block-Count: %d', [Frag.BlockCount]),
    Format('X-Vms-Start-Ms: %d', [Frag.StartMs]),
    Format('X-Vms-End-Ms: %d', [Frag.EndMs]),
    Format('X-Vms-Next-Ms: %d', [Frag.NextMs]),
    Format('X-Vms-Gap-Ms: %d', [Frag.GapMs]),
    Format('X-Vms-Discontinuity: %d', [Ord(Frag.Discontinuity)]),
    Format('X-Vms-Keyframe: %d', [Ord(Frag.Keyframe)]),
    Format('X-Vms-Growing: %d', [Ord(Frag.Growing)]));
end;

// Diagnóstico: as entradas do índice, cruas, no mesmo layout do chunk VIDX
// (offset 8 + startUnixMs 8 + flags 1). Serve para conferir contra o arquivo.
function TApiRouter.HandleIndex(const Query: string): TApiResponse;
var
  FileName: string;
  Index: TVmsIndex;
  Data: TBytes;
  I, O: Integer;
  U: UInt64;
  K: Integer;
begin
  FileName := Trim(QueryValue(Query, 'file'));
  if not IsSafeVmsName(FileName) then
    Exit(TApiResponse.Error(400, 'nome de arquivo invalido'));
  // camera é opcional: sem ela o cache deduz a pasta pelo prefixo do nome.
  if not FCache.GetIndex(FCache.PathOf(Trim(QueryValue(Query, 'camera')), FileName), Index) then
    Exit(TApiResponse.Error(404, 'arquivo sem indice legivel'));

  SetLength(Data, Length(Index) * VMS_INDEX_ENTRY_SIZE);
  O := 0;
  for I := 0 to High(Index) do
  begin
    U := UInt64(Index[I].Offset);
    for K := 0 to 7 do
    begin
      Data[O + K] := Byte(U and $FF);
      U := U shr 8;
    end;
    Inc(O, 8);
    U := UInt64(Index[I].StartUnixMs);
    for K := 0 to 7 do
    begin
      Data[O + K] := Byte(U and $FF);
      U := U shr 8;
    end;
    Inc(O, 8);
    Data[O] := Index[I].Flags;
    Inc(O);
  end;

  Result.Status := 200;
  Result.ContentType := 'application/octet-stream';
  Result.Body := Data;
  Result.Extra := TArray<string>.Create(
    Format('X-Vms-Block-Count: %d', [Length(Index)]));
end;

function TApiRouter.HandleRecordings(const Query: string): TApiResponse;
var
  Camera: string;
  Files: TVmsFileInfoArray;
  Root, Item, Track: TJSONObject;
  Arr: TJSONArray;
  FromMs, ToMs: Int64;
  I: Integer;
begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));

  FromMs := QueryInt(Query, 'fromMs', Low(Int64));
  ToMs := QueryInt(Query, 'toMs', High(Int64));

  Files := FCache.ListFiles(Camera);
  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('tz', UtcOffsetStr);
  Root.AddPair('files', Arr);
  for I := 0 to High(Files) do
  begin
    if Files[I].EndMs <= FromMs then Continue;
    if Files[I].StartMs >= ToMs then Continue;
    Item := TJSONObject.Create;
    Item.AddPair('file', Files[I].Name);
    Item.AddPair('startMs', TJSONNumber.Create(Files[I].StartMs));
    Item.AddPair('endMs', TJSONNumber.Create(Files[I].EndMs));
    Item.AddPair('durationMs', TJSONNumber.Create(Files[I].DurationMs));
    Item.AddPair('bytes', TJSONNumber.Create(Files[I].Bytes));
    Item.AddPair('blocks', TJSONNumber.Create(Files[I].Blocks));
    Item.AddPair('closed', TJSONBool.Create(Files[I].Closed));
    Item.AddPair('indexed', TJSONBool.Create(Files[I].Indexed));
    if Files[I].HasVideo then
    begin
      Track := TJSONObject.Create;
      Track.AddPair('codec', VideoCodecToStr(Files[I].VideoCodec));
      Track.AddPair('width', TJSONNumber.Create(Files[I].Width));
      Track.AddPair('height', TJSONNumber.Create(Files[I].Height));
      Item.AddPair('video', Track);
    end;
    if Files[I].HasAudio then
    begin
      Track := TJSONObject.Create;
      Track.AddPair('codec', AudioCodecToStr(Files[I].AudioCodec));
      Track.AddPair('rate', TJSONNumber.Create(Files[I].SampleRate));
      Track.AddPair('channels', TJSONNumber.Create(Files[I].Channels));
      Item.AddPair('audio', Track);
    end;
    Arr.AddElement(Item);
  end;
  Result := TApiResponse.FromJson(Root);
end;

end.
