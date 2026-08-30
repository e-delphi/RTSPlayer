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
//   GET /api/live?camera=X&cursor=…       o ao vivo: a cauda do que se grava
//   GET /api/recordings?camera=X&...      a lista crua, arquivo por arquivo
//   GET /api/index?file=…                 o índice de blocos, cru
//                                         (as duas últimas são diagnóstico)
//   GET /api/events?camera=X&fromMs=…     o que a análise viu naquela janela
//   GET /api/settings                     os parâmetros do servidor
//   POST /api/settings                    grava parâmetros (corpo JSON)
//   GET|POST /api/sql?q=…                 SQL livre no banco (diagnóstico)
//   GET /api/motion/probe?camera=X&…      ensaio do detector, sem gravar nada
//   GET /ui/motion                        a página de sintonia do movimento
//   GET /ui/events                        a faixa de eventos, para o app
//   GET /                                 a mesma casca: entrar no servidor
//                                         pelo endereco nu ja abre a interface
//   GET /favicon.svg  /favicon.ico        o icone da aba
//   GET /ui/login                         a tela de entrada
//   GET /api/auth/status                  se ha senha, e se esta autenticado
//   POST /api/auth/login                  {user,password} -> cookie de sessao
//   POST /api/auth/logout                 encerra a sessao deste cookie
//   POST /api/auth/password               define/troca a senha
//
// TUDO o mais exige credencial quando auth.enabled=1: cookie (navegador) ou
// Basic (o app, que encaminha de dentro do Delphi). Sem senha definida, so o
// proprio computador entra -- e so para definir uma.
//   GET /ui/app                           a casca do app (cameras/dias/play)
//   GET /ui/player                        o player de gravacao em HTML
//   GET /ui/vmsreader.js /ui/player.js    o que a pagina do player carrega
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
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  Vms.Server.LiveHub,
  Vms.Server.IndexCache,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf,
  Vms.Db.Intf,
  Vms.Server.Ui.Html,
  Vms.Server.Events.Html,
  Vms.Server.App.Html,
  Vms.Server.Player.Html,
  Vms.Server.Favicon.Svg,
  Vms.Server.UiFiles,
  Vms.Server.Login.Html,
  Vms.Server.Auth,
  Vms.Server.Player.Js,
  Vms.Server.Reader.Js,
  Vms.Server.Media;

const
  API_PREFIX = '/api/';
  // As telas servidas pelo próprio servidor. Não é dado, é interface: fica
  // fora do /api/ para nunca ser confundida com uma rota de consumo.
  UI_PREFIX = '/ui/';
  // Quanto se recua ao abrir o ao vivo. Pouco, porque cada segundo daqui é um
  // segundo de atraso em relação ao que a câmera está vendo; o bastante para a
  // tela não abrir vazia esperando o próximo bloco fechar.
  LIVE_PREROLL_MS = 4000;
  // De quanto em quanto auth.* e relido do banco.
  AUTH_RELEITURA_MS = 5000;
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

  // Uma requisição HTTP já separada do socket.
  //
  // Existe porque o porteiro precisa de cabeçalhos -- Authorization, Cookie --
  // e a assinatura antiga levava só método e URI. Um registro, e não a lista de
  // cabeçalhos do Indy, para o roteador continuar sem saber o que é um socket.
  TApiRequest = record
    Method: string;
    Uri: string;
    Body: TBytes;
    Authorization: string;
    Cookie: string;
    // "https" quando um proxy à frente terminou o TLS (o `tailscale serve` põe
    // X-Forwarded-Proto). É o que decide se o cookie sai com Secure: marcá-lo
    // sempre quebraria o acesso por http na LAN, e nunca marcá-lo deixaria o
    // cookie viajar em claro se alguém publicar a porta sem TLS.
    ForwardedProto: string;
    PeerIP: string;
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
    FAuth: TAutenticador;
    // Quando auth.* foi lido do banco pela ultima vez. Reler de tempos em
    // tempos resolve dois casos sem cerimonia: o banco que ainda nao estava
    // aberto na criacao, e a senha trocada por fora.
    FAuthLido: UInt64;
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
    // O ensaio do detector de movimento. Nil = a rota responde 503.
    FProbe: IMotionProbe;
    FLogger: ILogger;
    function KnownCamera(const Name: string; out Canonical: string): Boolean;
    function IsLive(const Camera: string): Boolean;
    function HandleCameras: TApiResponse;
    function HandleDays(const Query: string): TApiResponse;
    function HandleSegments(const Query: string): TApiResponse;
    function HandleRecordings(const Query: string): TApiResponse;
    function HandleMedia(const Query: string; Live: Boolean): TApiResponse;
    function HandleIndex(const Query: string): TApiResponse;
    function HandleThumb(const Query: string): TApiResponse;
    function HandleEvents(const Query: string): TApiResponse;
    function HandleSql(const Query: string; const Body: TBytes): TApiResponse;
    function HandleSettingsGet: TApiResponse;
    function HandleSettingsPost(const Body: TBytes): TApiResponse;
    function HandleMotionProbe(const Query: string): TApiResponse;
    function HandleMotionUi: TApiResponse;
    function HandleEventsUi: TApiResponse;
    function HandleAppUi: TApiResponse;
    function HandleFavicon: TApiResponse;
    function HandleLoginUi: TApiResponse;
    function HandleAuthStatus(const Req: TApiRequest): TApiResponse;
    function HandleLogin(const Req: TApiRequest): TApiResponse;
    function HandleLogout(const Req: TApiRequest): TApiResponse;
    function HandleAuthSenha(const Req: TApiRequest): TApiResponse;
    // Relê auth.* do banco. Chamada na criação e sempre que algo que possa ter
    // mudado a autenticação for gravado.
    procedure RecarregarAuth;
    // Rota que responde sem credencial: a tela de entrada, o próprio login e o
    // ícone. Curta de propósito -- cada item aqui é uma porta a menos.
    function RotaAberta(const Path: string): Boolean;
    function RespostaDeAcesso(const Req: TApiRequest;
                              Acesso: TAcesso): TApiResponse;
    function HandlePlayerUi: TApiResponse;
    function HandleJs(const NomeArquivo, Codigo: string): TApiResponse;
  public
    // O cache e a fonte de miniaturas vêm de fora, e o roteador não é dono de
    // nenhum dos dois: quem os cria é a composição, que é o único lugar que
    // pode conhecer as implementações concretas.
    constructor Create(const AConfig: TApiConfig; const ACameras: TArray<string>;
                       ACache: TVmsIndexCache; AHub: TLiveHub;
                       const AThumbs: IThumbSource; const AEvents: IEventSource;
                       const ADb: IDbQueue; const AProbe: IMotionProbe;
                       const ALogger: ILogger);
    destructor Destroy; override;
    // Method e Uri como vieram da linha do pedido. Nunca levanta exceção: erro
    // vira resposta.
    // Body só é usado pelo POST /api/sql; as demais rotas ignoram.
    function Handle(const Method, Uri: string;
                    const Body: TBytes = nil): TApiResponse; overload;
    function Handle(const Req: TApiRequest): TApiResponse; overload;
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
  const ADb: IDbQueue; const AProbe: IMotionProbe; const ALogger: ILogger);
begin
  inherited Create;
  FThumbs := AThumbs;
  FEvents := AEvents;
  FDb := ADb;
  FProbe := AProbe;
  FConfig := AConfig;
  if FConfig.MaxBlocksPerRequest <= 0 then
    FConfig.MaxBlocksPerRequest := API_DEFAULT_MAX_BLOCKS;
  FCameras := Copy(ACameras);
  FHub := AHub;
  FLogger := ALogger;
  FCache := ACache;
  FMedia := TMediaBuilder.Create(FCache, FConfig.MaxBlocksPerRequest, ALogger);
  FAuth := TAutenticador.Create;
  RecarregarAuth;
  // Uma pasta `ui` esquecida ao lado do executável mudaria a interface sem
  // nenhum outro sinal. Dizer isso na subida é o sinal.
  if UiDirAtivo and (FLogger <> nil) then
    FLogger.Info('api', 'servindo a interface de ' + UiDir +
                        ' (o que estiver la substitui o embutido)');
end;

destructor TApiRouter.Destroy;
begin
  // O cache não é nosso: quem criou destrói.
  FMedia.Free;
  FAuth.Free;
  inherited;
end;

class function TApiRouter.IsApiPath(const Uri: string): Boolean;
var
  Path, Query: string;
begin
  Result := SplitPathAndQuery(Uri, Path, Query) and
            ((Path = '/') or StartsText(API_PREFIX, Path) or
             StartsText(UI_PREFIX, Path) or
             SameText(Path, '/favicon.svg') or SameText(Path, '/favicon.ico'));
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

// O endereço é do próprio computador? É a saída de emergência da instalação
// nova: sem senha definida ninguém entra de fora, mas quem está na máquina
// precisa poder definir uma.
function EhLoopback(const IP: string): Boolean;
var
  S: string;
begin
  S := Trim(IP);
  Result := (S = '127.0.0.1') or (S = '::1') or (S = '0:0:0:0:0:0:0:1') or
            StartsText('127.', S);
end;

function TApiRouter.RotaAberta(const Path: string): Boolean;
begin
  // Curta de propósito: cada item aqui é uma porta a menos. A tela de entrada,
  // as rotas que a fazem funcionar e o ícone -- que o navegador pede sozinho,
  // antes de qualquer login, e cujo 401 sujaria o console.
  Result := SameText(Path, UI_PREFIX + 'login') or
            SameText(Path, API_PREFIX + 'auth/status') or
            SameText(Path, API_PREFIX + 'auth/login') or
            SameText(Path, '/favicon.svg') or
            SameText(Path, '/favicon.ico');
end;

procedure TApiRouter.RecarregarAuth;
var
  Ligado: Boolean;
  Usuario, Hash: string;
  Horas: Integer;
begin
  FAuthLido := TThread.GetTickCount64;
  if (FDb = nil) or (not FDb.IsOpen) then
  begin
    // Sem banco não dá para saber se há senha. O lado seguro é assumir que há
    // autenticação e que ela ainda não foi configurada: só o próprio
    // computador entra. Assumir "liberado" abriria tudo justamente no momento
    // em que o servidor não sabe o que está fazendo.
    FAuth.Configurar(True, 'admin', '', SESSAO_PADRAO_HORAS);
    Exit;
  end;
  Ligado := True;
  Usuario := 'admin';
  Hash := '';
  Horas := SESSAO_PADRAO_HORAS;
  try
    FDb.Read('SELECT key, value FROM setting WHERE key LIKE ''auth.%''', [],
      procedure(const Row: IDbRow)
      var
        K, V: string;
      begin
        K := Row.AsString('key');
        V := Row.AsString('value');
        if SameText(K, 'auth.enabled') then Ligado := Trim(V) <> '0'
        else if SameText(K, 'auth.user') then Usuario := V
        else if SameText(K, 'auth.hash') then Hash := V
        else if SameText(K, 'auth.sessionHours') then
          Horas := StrToIntDef(Trim(V), SESSAO_PADRAO_HORAS);
      end);
  except
    on E: Exception do
      FLogger.Warn('api', 'nao consegui ler auth.*: ' + E.Message);
  end;
  FAuth.Configurar(Ligado, Usuario, Hash, Horas);
end;

// A recusa, na forma que serve a quem pediu: navegador pedindo tela vai para o
// login; chamada de api leva 401 em json, que a página sabe ler.
function TApiRouter.RespostaDeAcesso(const Req: TApiRequest;
  Acesso: TAcesso): TApiResponse;
var
  Path, Query: string;
  EhTela: Boolean;
begin
  SplitPathAndQuery(Req.Uri, Path, Query);
  EhTela := (Path = '/') or StartsText(UI_PREFIX, Path);

  if Acesso = acSemSenhaDefinida then
  begin
    // Beco: mandar para o login não adianta, porque não há senha para digitar.
    // O texto diz o que fazer, e diz de onde -- é a única informação útil aqui.
    Result := TApiResponse.Error(503,
      'este servidor ainda nao tem senha definida; abra-o no proprio ' +
      'computador (http://localhost:8554) e defina uma em /ui/login');
    Exit;
  end;

  if EhTela then
  begin
    Result.Status := 302;
    Result.ContentType := 'text/plain; charset=utf-8';
    Result.Body := TEncoding.UTF8.GetBytes('entre primeiro');
    Result.Extra := TArray<string>.Create('Location: ' + UI_PREFIX + 'login');
    Exit;
  end;

  // Sem WWW-Authenticate de propósito: o cabeçalho faria o navegador abrir o
  // diálogo dele por cima da página, e quem usa Basic aqui é o app, que já
  // manda a credencial sem precisar ser desafiado.
  Result := TApiResponse.Error(401, 'nao autenticado');
end;

function TApiRouter.Handle(const Method, Uri: string;
  const Body: TBytes): TApiResponse;
var
  Req: TApiRequest;
begin
  Req := Default(TApiRequest);
  Req.Method := Method;
  Req.Uri := Uri;
  Req.Body := Body;
  Result := Handle(Req);
end;

function TApiRouter.Handle(const Req: TApiRequest): TApiResponse;
var
  Path, Query: string;
  Method: string;
  Body: TBytes;
  Acesso: TAcesso;
begin
  Method := Req.Method;
  Body := Req.Body;
  try
    if not FConfig.Enabled then
      Exit(TApiResponse.Error(404, 'api desligada'));
    if not SplitPathAndQuery(Req.Uri, Path, Query) then
      Exit(TApiResponse.Error(400, 'uri invalida'));

    if TThread.GetTickCount64 - FAuthLido > AUTH_RELEITURA_MS then
      RecarregarAuth;

    // O porteiro vem ANTES de tudo: o que não passa daqui não chega a tocar em
    // gravação, em banco nem em configuração.
    if not RotaAberta(Path) then
    begin
      Acesso := FAuth.Avaliar(Req.Authorization, Req.Cookie);
      if (Acesso = acSemSenhaDefinida) and EhLoopback(Req.PeerIP) then
        Acesso := acLiberado;
      if Acesso <> acLiberado then
        Exit(RespostaDeAcesso(Req, Acesso));
    end;

    if SameText(Path, UI_PREFIX + 'login') then
      Exit(HandleLoginUi);
    if SameText(Path, API_PREFIX + 'auth/status') then
      Exit(HandleAuthStatus(Req));
    if SameText(Path, API_PREFIX + 'auth/login') then
      Exit(HandleLogin(Req));
    if SameText(Path, API_PREFIX + 'auth/logout') then
      Exit(HandleLogout(Req));
    if SameText(Path, API_PREFIX + 'auth/password') then
      Exit(HandleAuthSenha(Req));
    // A raiz é a interface. Quem digita o endereço do servidor quer a tela, e
    // não um 404 seguido de "agora descubra a sub-rota".
    if (Path = '/') or SameText(Path, UI_PREFIX) then
      Exit(HandleAppUi);
    // O navegador pede /favicon.ico sozinho, sem perguntar. As duas rotas
    // devolvem o mesmo SVG; o <link> das páginas aponta para a .svg, que é a
    // que casa com o tipo declarado.
    if SameText(Path, '/favicon.svg') or SameText(Path, '/favicon.ico') then
      Exit(HandleFavicon);
    // A página de sintonia não mora sob /api/: ela é tela, não dado.
    if SameText(Path, UI_PREFIX + 'motion') then
      Exit(HandleMotionUi);
    if SameText(Path, UI_PREFIX + 'events') then
      Exit(HandleEventsUi);
    if SameText(Path, UI_PREFIX + 'app') then
      Exit(HandleAppUi);
    if SameText(Path, UI_PREFIX + 'player') then
      Exit(HandlePlayerUi);
    // Os dois scripts que a página do player carrega. Servidos soltos, e não
    // embutidos nela, porque também servirão às próximas páginas -- e assim o
    // navegador os guarda em cache uma vez só.
    if SameText(Path, UI_PREFIX + 'vmsreader.js') then
      Exit(HandleJs('vmsreader.js', VmsReaderJs));
    if SameText(Path, UI_PREFIX + 'player.js') then
      Exit(HandleJs('player.js', PlayerJs));
    // POST existe por uma rota só: SQL longo não cabe confortável numa query
    // string. Todo o resto continua sendo leitura, e recusa POST.
    if SameText(Path, API_PREFIX + 'sql') then
    begin
      if not (SameText(Method, 'GET') or SameText(Method, 'POST')) then
        Exit(TApiResponse.Error(405, 'use GET ou POST'));
      Exit(HandleSql(Query, Body));
    end;

    // Os parâmetros do servidor. Existe separado do /api/sql de propósito: a
    // tela de configuração não deveria precisar de uma rota que lê o banco
    // inteiro, e esta dá para proteger sem tirar aquela do ar.
    if SameText(Path, API_PREFIX + 'settings') then
    begin
      if SameText(Method, 'POST') then
        Exit(HandleSettingsPost(Body));
      if not (SameText(Method, 'GET') or SameText(Method, 'HEAD')) then
        Exit(TApiResponse.Error(405, 'use GET ou POST'));
      Exit(HandleSettingsGet);
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
      Result := HandleMedia(Query, False)
    // Ao vivo é a mesma mídia, seguida pela cauda: o servidor grava sem parar,
    // e "agora" é o fim do arquivo aberto. Rota separada só para o cliente não
    // precisar saber onde é o fim — ele manda cursor vazio e recebe o resto.
    else if SameText(Path, API_PREFIX + 'live') then
      Result := HandleMedia(Query, True)
    else if SameText(Path, API_PREFIX + 'recordings') then
      Result := HandleRecordings(Query)
    else if SameText(Path, API_PREFIX + 'index') then
      Result := HandleIndex(Query)
    else if SameText(Path, API_PREFIX + 'thumb') then
      Result := HandleThumb(Query)
    else if SameText(Path, API_PREFIX + 'events') then
      Result := HandleEvents(Query)
    else if SameText(Path, API_PREFIX + 'motion/probe') then
      Result := HandleMotionProbe(Query)
    else
      Result := TApiResponse.Error(404, 'rota desconhecida: ' + Path);
  except
    on E: Exception do
    begin
      if FLogger <> nil then
        FLogger.Error('api', Format('%s %s: %s', [Method, Req.Uri, E.Message]));
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

// A casca do app: câmeras, dias e reprodução numa página só. A mesma que o
// servidor local do aparelho serve -- e por isso ela só usa caminho relativo.
function TApiRouter.HandleAppUi: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'text/html; charset=utf-8';
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto('app-ui.html', AppUiHtml));
end;

// O player de gravação em HTML. Toca `.vms` direto, sem conversão aqui: o
// vmsreader.js lê o contêiner e o WebCodecs decodifica os AUs como eles estão
// no arquivo. O formato que já existe continua sendo o protocolo.
function TApiRouter.HandleLoginUi: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'text/html; charset=utf-8';
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto('login-ui.html', LoginUiHtml));
end;

function TApiRouter.HandleAuthStatus(const Req: TApiRequest): TApiResponse;
var
  Root: TJSONObject;
  Autenticado: Boolean;
begin
  Root := TJSONObject.Create;
  Root.AddPair('enabled', TJSONBool.Create(FAuth.Ligado));
  // "ainda nao ha senha": e o que faz a tela de entrada virar tela de definir
  // senha, em vez de pedir uma que nao existe.
  Root.AddPair('needsSetup', TJSONBool.Create(FAuth.Ligado and FAuth.SemSenha));
  Root.AddPair('local', TJSONBool.Create(EhLoopback(Req.PeerIP)));
  Autenticado := (not FAuth.Ligado) or
                 (FAuth.Avaliar(Req.Authorization, Req.Cookie) = acLiberado);
  Root.AddPair('authenticated', TJSONBool.Create(Autenticado));
  // O nome do usuário só para quem já entrou. É pouca coisa, mas é metade do
  // par que se está tentando adivinhar: não se entrega de graça na rota que
  // responde sem credencial.
  if Autenticado then
    Root.AddPair('user', FAuth.Usuario);
  Result := TApiResponse.FromJson(Root);
end;

// Le {user, password} do corpo. Devolve False para corpo que nao seja objeto.
function LerCredencial(const Body: TBytes; out Usuario, Senha: string): Boolean;
var
  Valor: TJSONValue;
begin
  Usuario := '';
  Senha := '';
  Result := False;
  Valor := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Body));
  try
    if not (Valor is TJSONObject) then Exit;
    Usuario := TJSONObject(Valor).GetValue<string>('user', '');
    Senha := TJSONObject(Valor).GetValue<string>('password', '');
    Result := True;
  finally
    Valor.Free;
  end;
end;

function TApiRouter.HandleLogin(const Req: TApiRequest): TApiResponse;
var
  Usuario, Senha, Token, Cookie: string;
  Root: TJSONObject;
begin
  if not SameText(Req.Method, 'POST') then
    Exit(TApiResponse.Error(405, 'use POST'));
  if not LerCredencial(Req.Body, Usuario, Senha) then
    Exit(TApiResponse.Error(400, 'esperava {user, password}'));
  if FAuth.SemSenha then
    Exit(TApiResponse.Error(409, 'defina uma senha primeiro'));
  if not FAuth.Confere(Usuario, Senha) then
  begin
    // Uma mensagem só para os dois casos: dizer "usuário não existe" entregaria
    // metade da resposta a quem está adivinhando.
    FLogger.Warn('auth', 'login recusado de ' + Req.PeerIP);
    Exit(TApiResponse.Error(401, 'usuario ou senha invalidos'));
  end;

  Token := FAuth.AbrirSessao;
  FLogger.Info('auth', 'login aceito de ' + Req.PeerIP);

  // HttpOnly: script nenhum precisa ler este cookie, e não poder lê-lo tira o
  // valor de um XSS. SameSite=Strict: o cookie não vai junto em requisição
  // vinda de outro site, que é o que impede CSRF nas rotas de escrita.
  Cookie := Format('Set-Cookie: %s=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d',
    [COOKIE_SESSAO, Token, SESSAO_PADRAO_HORAS * 3600]);
  if SameText(Trim(Req.ForwardedProto), 'https') then
    Cookie := Cookie + '; Secure';

  Root := TJSONObject.Create;
  Root.AddPair('ok', TJSONBool.Create(True));
  Result := TApiResponse.FromJson(Root);
  Result.Extra := TArray<string>.Create(Cookie);
end;

function TApiRouter.HandleLogout(const Req: TApiRequest): TApiResponse;
var
  Root: TJSONObject;
begin
  FAuth.FecharSessao(CookieDe(Req.Cookie, COOKIE_SESSAO));
  Root := TJSONObject.Create;
  Root.AddPair('ok', TJSONBool.Create(True));
  Result := TApiResponse.FromJson(Root);
  Result.Extra := TArray<string>.Create(
    Format('Set-Cookie: %s=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0',
           [COOKIE_SESSAO]));
end;

function TApiRouter.HandleAuthSenha(const Req: TApiRequest): TApiResponse;
var
  Usuario, Senha, Hash: string;
  Agora: Int64;
  Root: TJSONObject;
begin
  if not SameText(Req.Method, 'POST') then
    Exit(TApiResponse.Error(405, 'use POST'));
  if (FDb = nil) or (not FDb.IsOpen) then
    Exit(TApiResponse.Error(503, 'banco indisponivel'));
  if not LerCredencial(Req.Body, Usuario, Senha) then
    Exit(TApiResponse.Error(400, 'esperava {user, password}'));
  // Oito é pouco para uma senha boa e muito para um engano de digitação. O
  // limite existe para não deixar passar "1234" num endereço público.
  if Length(Senha) < 8 then
    Exit(TApiResponse.Error(400, 'a senha precisa de ao menos 8 caracteres'));
  // Usuário em branco MANTÉM o que já está lá. Quem está só trocando a senha
  // não deveria precisar redigitar o usuário -- e se redigitasse errado, ou
  // deixasse vazio, trocaria o usuário sem querer e ficaria de fora.
  if Trim(Usuario) = '' then Usuario := FAuth.Usuario;
  if Trim(Usuario) = '' then Usuario := 'admin';

  Hash := GerarHashDeSenha(Senha);
  Agora := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), True) * 1000;
  try
    // INSERT OR IGNORE antes do UPDATE.
    //
    // UPDATE em linha que nao existe nao e erro: afeta zero linhas e devolve
    // sucesso. Num banco criado antes destas chaves existirem, definir a senha
    // respondia "ok" e nao gravava nada -- e a tela de entrada continuava
    // pedindo para definir uma senha, para sempre.
    FDb.Exec('INSERT OR IGNORE INTO setting (key, value, updated_at_ms) ' +
             'VALUES (?, ?, ?)', ['auth.user', 'admin', Agora]);
    FDb.Exec('INSERT OR IGNORE INTO setting (key, value, updated_at_ms) ' +
             'VALUES (?, ?, ?)', ['auth.hash', '', Agora]);
    FDb.Exec('UPDATE setting SET value = ?, updated_at_ms = ? WHERE key = ?',
             [Trim(Usuario), Agora, 'auth.user']);
    FDb.Exec('UPDATE setting SET value = ?, updated_at_ms = ? WHERE key = ?',
             [Hash, Agora, 'auth.hash']);
  except
    on E: Exception do
      Exit(TApiResponse.Error(500, E.Message));
  end;
  // Recarregar aqui e nao esperar a releitura periodica: quem acabou de definir
  // a senha vai entrar em seguida, e o Configurar tambem derruba as sessoes
  // antigas -- que e o efeito esperado de trocar uma senha.
  RecarregarAuth;
  FLogger.Info('auth', 'senha definida por ' + Req.PeerIP);

  Root := TJSONObject.Create;
  Root.AddPair('ok', TJSONBool.Create(True));
  Root.AddPair('user', Trim(Usuario));
  Result := TApiResponse.FromJson(Root);
end;

function TApiRouter.HandleFavicon: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'image/svg+xml';
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto('favicon.svg', FaviconSvg));
  // O ícone não muda entre versões do executável; deixar o navegador guardá-lo
  // evita um pedido por aba aberta.
  Result.Extra := TArray<string>.Create('Cache-Control: public, max-age=86400');
end;

function TApiRouter.HandlePlayerUi: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'text/html; charset=utf-8';
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto('player-ui.html', PlayerUiHtml));
end;

function TApiRouter.HandleJs(const NomeArquivo, Codigo: string): TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'application/javascript; charset=utf-8';
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto(NomeArquivo, Codigo));
end;

// A faixa de eventos que o app mostra embaixo do vídeo.
//
// Servida pelo servidor, e não carregada de dentro do app, por um motivo
// prático: assim o `fetch` dela para /api/events e /api/thumb é mesma origem.
// Carregada por LoadFromStrings com base https, ela seria uma página https
// tentando buscar http -- conteúdo misto, que o navegador bloqueia.
function TApiRouter.HandleEventsUi: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'text/html; charset=utf-8';
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto('events-ui.html', EventsUiHtml));
end;

// Todos os parâmetros, em ordem. São poucas dezenas de linhas, então não há
// paginação: a tela mostra tudo e filtra do lado dela.
function TApiRouter.HandleSettingsGet: TApiResponse;
var
  Root: TJSONObject;
  Arr: TJSONArray;
begin
  if (FDb = nil) or (not FDb.IsOpen) then
    Exit(TApiResponse.Error(503, 'banco indisponivel'));

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('settings', Arr);
  try
    FDb.Read('SELECT key, value FROM setting ORDER BY key', [],
      procedure(const Row: IDbRow)
      var
        Item: TJSONObject;
      begin
        // O hash da senha nao vai para a tela. Nao e segredo -- e um hash --
        // mas mostra-lo so serviria para alguem tentar quebra-lo offline, e
        // edita-lo a mao so serviria para travar a entrada.
        if SameText(Row.AsString('key'), 'auth.hash') then Exit;
        Item := TJSONObject.Create;
        Item.AddPair('key', Row.AsString('key'));
        Item.AddPair('value', Row.AsString('value'));
        Arr.AddElement(Item);
      end);
  except
    on E: Exception do
    begin
      Root.Free;
      Exit(TApiResponse.Error(500, E.Message));
    end;
  end;
  Result := TApiResponse.FromJson(Root);
end;

// Grava os parâmetros que vierem no corpo: {"analytics.motionThreshold":"0.008"}.
//
// Só chaves que JÁ EXISTEM são aceitas. Sem isso, um erro de digitação criaria
// uma chave nova que ninguém lê, e a tela mostraria um parâmetro que não faz
// nada -- pior do que recusar.
function TApiRouter.HandleSettingsPost(const Body: TBytes): TApiResponse;
var
  Texto: string;
  Valor: TJSONValue;
  Obj, Root: TJSONObject;
  Par: TJSONPair;
  I, Gravadas: Integer;
  Agora: Int64;
  Recusadas: TJSONArray;
  Existe: Boolean;
begin
  if (FDb = nil) or (not FDb.IsOpen) then
    Exit(TApiResponse.Error(503, 'banco indisponivel'));

  Texto := TEncoding.UTF8.GetString(Body);
  if Trim(Texto) = '' then
    Exit(TApiResponse.Error(400, 'corpo vazio'));

  Valor := TJSONObject.ParseJSONValue(Texto);
  if not (Valor is TJSONObject) then
  begin
    Valor.Free;
    Exit(TApiResponse.Error(400, 'esperava um objeto JSON'));
  end;

  Obj := TJSONObject(Valor);
  Root := TJSONObject.Create;
  Recusadas := TJSONArray.Create;
  Gravadas := 0;
  Agora := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), True) * 1000;
  try
    try
      for I := 0 to Obj.Count - 1 do
      begin
        Par := Obj.Pairs[I];
        // A senha se troca pela rota propria, que sabe gerar o hash. Deixar
        // gravar aqui abriria o caminho de por texto claro no lugar do hash --
        // e ai a comparacao nunca mais bateria, trancando o servidor.
        if SameText(Par.JsonString.Value, 'auth.hash') then
        begin
          Recusadas.Add(Par.JsonString.Value);
          Continue;
        end;
        Existe := False;
        FDb.Read('SELECT 1 AS achou FROM setting WHERE key = ?',
          [Par.JsonString.Value],
          procedure(const Row: IDbRow)
          begin
            Existe := True;
          end);
        if not Existe then
        begin
          Recusadas.Add(Par.JsonString.Value);
          Continue;
        end;
        FDb.Exec('UPDATE setting SET value = ?, updated_at_ms = ? WHERE key = ?',
          [Par.JsonValue.Value, Agora, Par.JsonString.Value]);
        Inc(Gravadas);
      end;
    except
      on E: Exception do
      begin
        Root.Free;
        Recusadas.Free;
        Exit(TApiResponse.Error(500, E.Message));
      end;
    end;
  finally
    Obj.Free;
  end;

  Root.AddPair('saved', TJSONNumber.Create(Gravadas));
  Root.AddPair('unknown', Recusadas);
  // A análise lê a configuração na subida: dizer isso evita o usuário achar
  // que mexeu no limiar e nada mudou.
  Root.AddPair('note', 'vale na proxima subida do servidor');
  Result := TApiResponse.FromJson(Root);
end;

// A página de sintonia do movimento. Vem embutida no executável (ver
// Vms.Server.Ui.Html), então não há arquivo solto para faltar.
function TApiRouter.HandleMotionUi: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'text/html; charset=utf-8';
  // Sem cache, mas isso já vem de graca: o TTxSession poe Cache-Control:
  // no-store em TODA resposta HTTP, e repetir aqui daria o cabecalho em dobro.
  Result.Body := TEncoding.UTF8.GetBytes(UiTexto('motion-ui.html', MotionUiHtml));
end;

// O ENSAIO: reprocessa um trecho real com os parâmetros do pedido e devolve o
// score de CADA quadro. Não grava nada.
//
//   GET /api/motion/probe?camera=frente&fromMs=…&toMs=…
//                        [&stepMs=2000] [&threshold=0.006] [&sceneThreshold=0.85]
//
// É a peça que faltava para sintonizar: o banco só guarda o PICO dos eventos
// que passaram do limiar, então de lá não dá para distinguir "nada se moveu" de
// "o limiar comeu". Aqui os dois casos são visíveis.
function TApiRouter.HandleMotionProbe(const Query: string): TApiResponse;
var
  Camera: string;
  FromMs, ToMs, StepMs: Int64;
  Limiar, Cena: Double;
  Amostras: TMotionSamples;
  Root, Item, Caixa: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Comeco: TDateTime;
begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));
  if (FProbe = nil) or (not FProbe.Available) then
    Exit(TApiResponse.Error(503, 'servidor sem como decodificar video'));

  FromMs := QueryInt(Query, 'fromMs', 0);
  ToMs := QueryInt(Query, 'toMs', 0);
  if (FromMs <= 0) or (ToMs <= FromMs) then
    Exit(TApiResponse.Error(400, 'informe fromMs e toMs'));

  StepMs := QueryInt(Query, 'stepMs', 2000);
  // Os limiares vêm como fração; QueryInt não serve. Vazio = o padrão do
  // detector, que é o que a página mostra ao abrir.
  Limiar := StrToFloatDef(QueryValue(Query, 'threshold'), 0.006,
                          TFormatSettings.Invariant);
  Cena := StrToFloatDef(QueryValue(Query, 'sceneThreshold'), 0.85,
                        TFormatSettings.Invariant);

  Comeco := Now;
  Amostras := FProbe.Run(Camera, FromMs, ToMs, StepMs, Limiar, Cena,
                         Integer(QueryInt(Query, 'max', 0)));

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('fromMs', TJSONNumber.Create(FromMs));
  Root.AddPair('toMs', TJSONNumber.Create(ToMs));
  Root.AddPair('stepMs', TJSONNumber.Create(StepMs));
  Root.AddPair('threshold', TJSONNumber.Create(Limiar));
  Root.AddPair('sceneThreshold', TJSONNumber.Create(Cena));
  Root.AddPair('count', TJSONNumber.Create(Length(Amostras)));
  Root.AddPair('elapsedMs', TJSONNumber.Create(MilliSecondsBetween(Now, Comeco)));
  Root.AddPair('samples', Arr);
  for I := 0 to High(Amostras) do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('ms', TJSONNumber.Create(Amostras[I].Ms));
    Item.AddPair('score', TJSONNumber.Create(Amostras[I].Score));
    Item.AddPair('moved', TJSONBool.Create(Amostras[I].Moved));
    Item.AddPair('sceneChanged', TJSONBool.Create(Amostras[I].SceneChanged));
    if not Amostras[I].Box.IsEmpty then
    begin
      Caixa := TJSONObject.Create;
      Caixa.AddPair('l', TJSONNumber.Create(Amostras[I].Box.L));
      Caixa.AddPair('t', TJSONNumber.Create(Amostras[I].Box.T));
      Caixa.AddPair('r', TJSONNumber.Create(Amostras[I].Box.R));
      Caixa.AddPair('b', TJSONNumber.Create(Amostras[I].Box.B));
      Item.AddPair('box', Caixa);
    end;
    Arr.AddElement(Item);
  end;
  Result := TApiResponse.FromJson(Root);
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

function TApiRouter.HandleMedia(const Query: string; Live: Boolean): TApiResponse;
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
  // O cliente abre o ao vivo com cursor=0, que é como o anel do app diz "do
  // começo". Aqui não há anel: 0 quer dizer "sem cursor", e a cauda resolve.
  if Live and (CursorText = '0') then CursorText := '';
  if CursorText <> '' then
    if not TMediaCursor.Decode(CursorText, Req.Cursor) then
      Exit(TApiResponse.Error(400, 'cursor invalido'));

  if Trim(QueryValue(Query, 'fromMs')) <> '' then
  begin
    Req.FromMs := QueryInt(Query, 'fromMs', 0);
    Req.HasFromMs := True;
  end
  else if Live and (CursorText = '') then
  begin
    // Abrir o ao vivo é entrar pelo fim. O recuo dá o que tocar enquanto o
    // primeiro pedido de continuação não volta; o keyframe atrás dele o
    // /api/media já busca sozinho.
    Req.FromMs := LocalToUnixMs(Now) - LIVE_PREROLL_MS;
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

  // 204 com o cursor de volta: nada novo ainda. Corpo vazio é a resposta certa,
  // e o cursor tem de voltar junto, senão quem segue o ao vivo perde o fio e
  // recomeça do zero a cada pergunta.
  if Frag.Empty then
  begin
    Result.Status := 204;
    Result.ContentType := 'application/x-vms';
    Result.Body := nil;
    Result.Extra := TArray<string>.Create(
      'X-Vms-Cursor: ' + Frag.Cursor,
      Format('X-Vms-Growing: %d', [Ord(Frag.Growing)]));
    Exit;
  end;

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
