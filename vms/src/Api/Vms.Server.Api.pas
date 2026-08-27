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
//   GET /api/events?camera=X&fromMs=…     o que a análise viu naquela janela
//   GET|POST /api/sql?q=…                 SQL livre no banco (diagnóstico)
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
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf,
  Vms.Db.Intf,
  Vms.Server.Media;

const
  API_PREFIX = '/api/';
  API_DEFAULT_MAX_BLOCKS = 32;
  // Colagem: dois arquivos separados por menos que isto viram uma faixa só. Uma
  // reconexão de câmera custa centenas de ms; 5 s cobre com folga sem esconder
  // ausência de verdade.
  API_DEFAULT_GAP_MS = 5000;
  MS_PER_DAY = Int64(86400000);
  // Teto de linhas que /api/sql devolve. Sem isto, um `select * from log` num
  // servidor de semanas montaria um JSON de centenas de MB na thread do banco.
  SQL_DEFAULT_LIMIT = 500;
  SQL_MAX_LIMIT = 10000;

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
    // A miniatura entra por uma interface, e não pela implementação: é o que
    // mantém FFmpeg e VCL fora desta camada, que só deveria falar HTTP. Sem
    // decodificador na máquina, a composição liga a fonte nula e a rota
    // responde "não tenho" — o servidor sobe igual.
    FThumbs: IThumbSource;
    // Os eventos entram pela mesma porta que as miniaturas: uma interface, e
    // não a implementação. É o que mantém o onnxruntime fora desta camada, que
    // só deveria falar HTTP. Nil = servidor sem análise, e a rota responde 503.
    FEvents: IEventSource;
    // Só a rota /api/sql usa. Nil = a rota responde 503, e o resto da API não
    // sabe da diferença.
    FDb: IDbQueue;
    FLogger: ILogger;
    function KnownCamera(const Name: string; out Canonical: string): Boolean;
    function IsLive(const Camera: string): Boolean;
    function HandleCameras: TApiResponse;
    function HandleDays(const Query: string): TApiResponse;
    function HandleSegments(const Query: string): TApiResponse;
    function HandleRecordings(const Query: string): TApiResponse;
    function HandleMedia(const Query: string): TApiResponse;
    function HandleIndex(const Query: string): TApiResponse;
    function HandleThumb(const Query: string): TApiResponse;
    function HandleEvents(const Query: string): TApiResponse;
    function HandleSql(const Query: string; const Body: TBytes): TApiResponse;
  public
    // O cache e a fonte de miniaturas vêm de fora, e o roteador não é dono de
    // nenhum dos dois: quem os cria é a composição, que é o único lugar que
    // pode conhecer as implementações concretas.
    constructor Create(const AConfig: TApiConfig; const ACameras: TArray<string>;
                       ACache: TVmsIndexCache; AHub: TLiveHub;
                       const AThumbs: IThumbSource; const AEvents: IEventSource;
                       const ADb: IDbQueue; const ALogger: ILogger);
    destructor Destroy; override;
    // Method e Uri como vieram da linha do pedido. Nunca levanta exceção: erro
    // vira resposta.
    // Body só é usado pelo POST /api/sql; as demais rotas ignoram.
    function Handle(const Method, Uri: string;
                    const Body: TBytes = nil): TApiResponse;
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

constructor TApiRouter.Create(const AConfig: TApiConfig;
  const ACameras: TArray<string>; ACache: TVmsIndexCache; AHub: TLiveHub;
  const AThumbs: IThumbSource; const AEvents: IEventSource;
  const ADb: IDbQueue; const ALogger: ILogger);
begin
  inherited Create;
  FThumbs := AThumbs;
  FEvents := AEvents;
  FDb := ADb;
  FConfig := AConfig;
  if FConfig.MaxBlocksPerRequest <= 0 then
    FConfig.MaxBlocksPerRequest := API_DEFAULT_MAX_BLOCKS;
  FCameras := Copy(ACameras);
  FHub := AHub;
  FLogger := ALogger;
  FCache := ACache;
  FMedia := TMediaBuilder.Create(FCache, FConfig.MaxBlocksPerRequest, ALogger);
end;

destructor TApiRouter.Destroy;
begin
  // O cache não é nosso: quem criou destrói.
  FMedia.Free;
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

function TApiRouter.Handle(const Method, Uri: string;
  const Body: TBytes): TApiResponse;
var
  Path, Query: string;
begin
  try
    if not FConfig.Enabled then
      Exit(TApiResponse.Error(404, 'api desligada'));
    if not SplitPathAndQuery(Uri, Path, Query) then
      Exit(TApiResponse.Error(400, 'uri invalida'));
    // POST existe por uma rota só: SQL longo não cabe confortável numa query
    // string. Todo o resto continua sendo leitura, e recusa POST.
    if SameText(Path, API_PREFIX + 'sql') then
    begin
      if not (SameText(Method, 'GET') or SameText(Method, 'POST')) then
        Exit(TApiResponse.Error(405, 'use GET ou POST'));
      Exit(HandleSql(Query, Body));
    end;
    if not (SameText(Method, 'GET') or SameText(Method, 'HEAD')) then
      Exit(TApiResponse.Error(405, 'so GET e HEAD'));

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
    else if SameText(Path, API_PREFIX + 'thumb') then
      Result := HandleThumb(Query)
    else if SameText(Path, API_PREFIX + 'events') then
      Result := HandleEvents(Query)
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

// O que a análise viu numa janela de tempo.
//
//   GET /api/events?camera=frente&fromMs=…&toMs=…
//                  [&kind=motion|object] [&name=person] [&minScore=0.5]
//                  [&limit=500]
//
// A janela é obrigatória e limitada a uma semana: sem teto, um cliente com um
// erro de fuso pediria "de 1970 até agora" e o servidor leria todos os arquivos
// de evento que existem para montar a resposta.
//
// Entra o evento que SE SOBREPÕE à janela, não só o que começa dentro dela —
// quem abre a barra às 14h quer ver a passagem que começou às 13h58 e ainda
// estava acontecendo. Ver IEventSource.Query.
function TApiRouter.HandleEvents(const Query: string): TApiResponse;
var
  Camera, Nome: string;
  FromMs, ToMs: Int64;
  KindFiltro, Limite, I: Integer;
  MinScore: Double;
  Kind: TEventKind;
  Eventos: TVmsEventArray;
  Root, Item, Caixa: TJSONObject;
  Arr: TJSONArray;
begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));
  if (FEvents = nil) or (not FEvents.Available) then
    Exit(TApiResponse.Error(503, 'servidor sem analise de imagem'));

  FromMs := QueryInt(Query, 'fromMs', 0);
  ToMs := QueryInt(Query, 'toMs', 0);
  if (FromMs <= 0) or (ToMs <= FromMs) then
    Exit(TApiResponse.Error(400, 'informe fromMs e toMs'));
  if (ToMs - FromMs) > (7 * MS_PER_DAY) then
    Exit(TApiResponse.Error(400, 'janela maior que 7 dias'));

  KindFiltro := -1;
  Nome := Trim(QueryValue(Query, 'kind'));
  if Nome <> '' then
  begin
    if not StrToEventKind(Nome, Kind) then
      Exit(TApiResponse.Error(400, 'kind invalido: use motion ou object'));
    KindFiltro := Ord(Kind);
  end;

  Nome := LowerCase(Trim(QueryValue(Query, 'name')));
  MinScore := QueryInt(Query, 'minScorePct', 0) / 100;
  Limite := Integer(QueryInt(Query, 'limit', 0));

  Eventos := FEvents.Query(Camera, FromMs, ToMs, Nome, KindFiltro, MinScore, Limite);

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('tz', UtcOffsetStr);
  Root.AddPair('fromMs', TJSONNumber.Create(FromMs));
  Root.AddPair('toMs', TJSONNumber.Create(ToMs));
  Root.AddPair('count', TJSONNumber.Create(Length(Eventos)));
  Root.AddPair('events', Arr);
  for I := 0 to High(Eventos) do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('startMs', TJSONNumber.Create(Eventos[I].StartMs));
    Item.AddPair('endMs', TJSONNumber.Create(Eventos[I].EndMs));
    Item.AddPair('kind', EventKindToStr(Eventos[I].Kind));
    Item.AddPair('name', Eventos[I].Name);
    Item.AddPair('score', TJSONNumber.Create(Eventos[I].Score));
    Item.AddPair('count', TJSONNumber.Create(Eventos[I].Count));
    // A caixa vai normalizada 0..1: o app desenha sobre um vídeo que pode estar
    // em qualquer resolução, e é ele quem sabe qual.
    Caixa := TJSONObject.Create;
    Caixa.AddPair('l', TJSONNumber.Create(Eventos[I].Box.L));
    Caixa.AddPair('t', TJSONNumber.Create(Eventos[I].Box.T));
    Caixa.AddPair('r', TJSONNumber.Create(Eventos[I].Box.R));
    Caixa.AddPair('b', TJSONNumber.Create(Eventos[I].Box.B));
    Item.AddPair('box', Caixa);
    Arr.AddElement(Item);
  end;
  Result := TApiResponse.FromJson(Root);
end;

// SQL livre no banco. Existe para olhar o que está sendo gravado sem precisar
// parar o servidor e abrir o arquivo num cliente de SQLite — e, quando fizer
// falta, corrigir uma linha na mão.
//
//   GET  /api/sql?q=select%20count(*)%20from%20event
//   POST /api/sql            (o corpo é o SQL; use quando ele for longo)
//
// **Não há autenticação.** Quem alcança esta porta lê qualquer tabela — o que
// inclui `camera_endpoint.password`, que guarda as senhas das câmeras em texto
// — e pode alterar ou apagar o que quiser. Limite a porta com `bindAddress`, ou
// desligue a API, se a máquina não estiver numa rede de confiança. O aviso na
// subida diz o mesmo.
//
// A distinção leitura x escrita sai da PRIMEIRA palavra. `select`, `pragma`,
// `explain` e `with` vão por Read (devolvem linhas); qualquer outra coisa vai
// por Exec (devolve quantas linhas mudaram). Não é análise de SQL — é só o que
// basta para escolher o caminho, e um erro de classificação vira erro do banco,
// não corrupção.
//
// Os valores saem todos como TEXTO, e null continua null. É deliberado: um
// console de diagnóstico ganha mais em não ter surpresa de formatação de float
// do que em tipos ricos no JSON.
function TApiRouter.HandleSql(const Query: string; const Body: TBytes): TApiResponse;
var
  Sql, Primeira: string;
  Limite, Lidas: Integer;
  Truncou, Leitura: Boolean;
  Root, Erro: TJSONObject;
  Colunas, Linhas: TJSONArray;
  Afetadas: Integer;
  Comeco: TDateTime;
begin
  if (FDb = nil) or (not FDb.IsOpen) then
    Exit(TApiResponse.Error(503, 'servidor sem banco aberto'));

  // O corpo tem prioridade: quem manda POST mandou por caber melhor lá.
  Sql := '';
  if Length(Body) > 0 then
    Sql := TEncoding.UTF8.GetString(Body);
  if Trim(Sql) = '' then
    Sql := QueryValue(Query, 'q');
  Sql := Trim(Sql);
  if Sql = '' then
    Exit(TApiResponse.Error(400, 'informe o sql em q= ou no corpo'));

  Limite := Integer(QueryInt(Query, 'limit', SQL_DEFAULT_LIMIT));
  if Limite <= 0 then Limite := SQL_DEFAULT_LIMIT;
  if Limite > SQL_MAX_LIMIT then Limite := SQL_MAX_LIMIT;

  Primeira := LowerCase(Copy(TrimLeft(Sql), 1, 7));
  Leitura := StartsText('select', Primeira) or StartsText('pragma', Primeira) or
             StartsText('explain', Primeira) or StartsText('with', Primeira);

  if FLogger <> nil then
    FLogger.Info('api.sql', Sql);

  Root := TJSONObject.Create;
  try
    Root.AddPair('sql', Sql);
    Comeco := Now;
    try
      if Leitura then
      begin
        Colunas := TJSONArray.Create;
        Linhas := TJSONArray.Create;
        Root.AddPair('kind', 'read');
        Root.AddPair('columns', Colunas);
        Root.AddPair('rows', Linhas);
        Lidas := 0;
        Truncou := False;
        FDb.Read(Sql, [],
          procedure(const Row: IDbRow)
          var
            Linha: TJSONArray;
            I: Integer;
          begin
            // Os nomes das colunas saem da primeira linha: é a única em que se
            // tem certeza de que o cursor está posicionado.
            if Lidas = 0 then
              for I := 0 to Row.ColumnCount - 1 do
                Colunas.Add(Row.ColumnName(I));
            Inc(Lidas);
            // Passou do teto: continua consumindo o cursor (interromper no meio
            // deixaria a consulta pela metade na thread do banco), mas para de
            // montar JSON.
            if Lidas > Limite then
            begin
              Truncou := True;
              Exit;
            end;
            Linha := TJSONArray.Create;
            for I := 0 to Row.ColumnCount - 1 do
              if Row.IsNull(Row.ColumnName(I)) then
                Linha.AddElement(TJSONNull.Create)
              else
                Linha.Add(Row.AsString(Row.ColumnName(I)));
            Linhas.AddElement(Linha);
          end);
        Root.AddPair('count', TJSONNumber.Create(Linhas.Count));
        Root.AddPair('scanned', TJSONNumber.Create(Lidas));
        Root.AddPair('truncated', TJSONBool.Create(Truncou));
        if Truncou then
          Root.AddPair('hint', Format('use limit= (max %d) ou refine o sql',
            [SQL_MAX_LIMIT]));
      end
      else
      begin
        Afetadas := FDb.Exec(Sql, []);
        Root.AddPair('kind', 'write');
        Root.AddPair('affected', TJSONNumber.Create(Afetadas));
      end;
    except
      on E: Exception do
      begin
        // O erro do banco volta inteiro: quem escreveu o SQL é quem precisa
        // lê-lo, e esconder a mensagem tornaria a rota inútil.
        Root.Free;
        Erro := TJSONObject.Create;
        Erro.AddPair('error', E.Message);
        Erro.AddPair('sql', Sql);
        Result := TApiResponse.FromJson(Erro);
        Result.Status := 400;
        Exit;
      end;
    end;
    // Sem Round: MilliSecondsBetween ja devolve Int64, e Round quer ponto
    // flutuante. TJSONNumber tem sobrecarga para Int64.
    Root.AddPair('elapsedMs',
      TJSONNumber.Create(MilliSecondsBetween(Now, Comeco)));
    Result := TApiResponse.FromJson(Root);
  except
    Root.Free;
    raise;
  end;
end;

// A miniatura do instante pedido. O cliente manda o instante que quer mostrar;
// a resposta diz, no X-Vms-Thumb-Ms, o minuto que a imagem realmente representa
// — é por ele que o app sabe que já tem aquela imagem e não pede de novo.
function TApiRouter.HandleThumb(const Query: string): TApiResponse;
var
  Camera: string;
  Ms, ActualMs: Int64;
  Data: TBytes;
begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));
  if Trim(QueryValue(Query, 'ms')) = '' then
    Exit(TApiResponse.Error(400, 'informe ms'));
  Ms := QueryInt(Query, 'ms', 0);
  if Ms <= 0 then
    Exit(TApiResponse.Error(400, 'ms invalido'));

  if (FThumbs = nil) or (not FThumbs.Available) then
    Exit(TApiResponse.Error(503, 'servidor sem gerador de miniaturas'));
  if not FThumbs.Get(Camera, Ms, Data, ActualMs) then
    Exit(TApiResponse.Error(404, 'sem imagem para este instante'));

  Result.Status := 200;
  Result.ContentType := FThumbs.ContentType;
  Result.Body := Data;
  Result.Extra := TArray<string>.Create(
    Format('X-Vms-Thumb-Ms: %d', [ActualMs]),
    // Miniatura de minuto passado não muda nunca mais: deixa o cliente e
    // qualquer proxy no caminho guardarem à vontade.
    'Cache-Control: max-age=86400');
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
  // Duas capacidades do SERVIDOR, e não da câmera: o app usa para não oferecer
  // uma tela de eventos que nunca teria conteúdo, nem pedir miniatura a quem
  // não sabe gerar. Cliente antigo simplesmente ignora os dois campos.
  Root.AddPair('events', TJSONBool.Create((FEvents <> nil) and FEvents.Available));
  Root.AddPair('thumbs', TJSONBool.Create((FThumbs <> nil) and FThumbs.Available));
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
  // Varredura: um quadro a cada stepMs de mídia, só keyframe e sem áudio. É o
  // cliente que decide o valor, porque é ele que sabe a velocidade e quantos
  // quadros por segundo vai conseguir mostrar.
  Req.StepMs := QueryInt(Query, 'stepMs', 0);
  if Req.StepMs < 0 then Req.StepMs := 0;

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
    Format('X-Vms-Growing: %d', [Ord(Frag.Growing)]),
    Format('X-Vms-Thinned: %d', [Ord(Frag.Thinned)]));
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
