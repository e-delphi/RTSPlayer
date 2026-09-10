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
//   GET /api/live?camera=X&cursor=…       o ao vivo, direto do anel
//   GET /api/ptz?camera=X&acao=…          move a camera por ONVIF
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
//   GET /ui/ui.css                        a folha comum a todas as paginas
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
  System.SyncObjs,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Ptz,
  VMS.Dvrip.Protocol,
  VMS.Dvrip.Session,
  VMS.Domain.Session,
  VMS.Domain.Clock,
  VMS.App.Clock,
  VMS.Rec.Format,
  VMS.Rec.Writer,
  Vms.Onvif.Client,
  Vms.Server.LiveHub,
  Vms.Server.IndexCache,
  Vms.Thumb.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf,
  Vms.Db.Intf,
  Vms.Server.UiFiles,
  Vms.Server.Auth,
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
  // Quanto o pedido do ao vivo espera por sample novo antes de responder "nada
  // ainda". Segurar a resposta é o que troca uma pergunta a cada meio segundo
  // por uma entrega no instante em que o quadro chega da câmera. Curto o
  // bastante para não prender uma thread do servidor por muito tempo.
  LIVE_ESPERA_MS = 1500;
  // Teto de samples por resposta. Só pega quando o cliente volta depois de uma
  // pausa longa; no ritmo normal vêm um ou dois.
  LIVE_MAX_SAMPLES = 600;
  // A marca que separa o cursor do anel do cursor de arquivo. O cliente devolve
  // o que recebeu sem olhar, e as duas rotas compartilham o mesmo cabeçalho.
  LIVE_CURSOR_TAG = 'L';
  // De quanto em quanto auth.* e relido do banco.
  AUTH_RELEITURA_MS = 5000;
  // De quanto em quanto se confere se as sessoes de comando de PTZ ainda
  // batem com o cadastro. O laco principal chama isso duas vezes por segundo;
  // o trabalho de verdade so acontece nesse ritmo.
  PTZ_CONTROLE_TICK_MS = 15000;
  // Quanto a rota de PTZ espera pela sessao de comando que acabou de mandar
  // abrir. Login nessas cameras ja levou 11 segundos, entao esperar ate o fim
  // prenderia a thread do HTTP por tempo demais; melhor responder "abrindo" e
  // deixar o proximo clique achar a sessao pronta.
  PTZ_CONTROLE_ESPERA_MS = 3000;
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

  // Mantem viva uma sessao DVRIP que existe SO para comandar a camera.
  //
  // Estas cameras aceitam PTZ pela conexao DVRIP autenticada, e ela so existia
  // quando a camera era GRAVADA por DVRIP. Quem grava por RTSP ficava sem PTZ
  // nenhum. Aqui o video continua vindo pelo caminho que funciona melhor e o
  // comando vem por uma conexao propria, que nao pede video e por isso quase
  // nao custa banda.
  //
  // Uma thread por camera, reconectando sozinha: a sessao cai quando a camera
  // reinicia ou a rede pisca, e sem reconexao o PTZ sumiria ate alguem
  // reiniciar o servidor.
  TPtzControleDvrip = class
  strict private
    FThread: TThread;
    FParar: TEvent;
    FConfig: TCameraSessionConfig;
    FLogger: ILogger;
    FTag: string;
  public
    constructor Create(const AConfig: TCameraSessionConfig; const ALogger: ILogger);
    destructor Destroy; override;
    // O endereco que esta sessao serve. Guardado para saber, na conferencia
    // periodica, se o cadastro mudou embaixo dela.
    function Endereco: string;
  end;

  TApiRouter = class
  strict private
    FConfig: TApiConfig;
    FCameras: TArray<string>;
    // Protege a TROCA do vetor acima, nao a leitura dele: o vetor publicado
    // nunca e alterado no lugar, entao quem pegou a referencia pode le-la a
    // vontade depois de soltar o lock.
    FCamerasLock: TCriticalSection;
    // Cameras cuja configuracao mudou e ainda nao foi aplicada. Ver o
    // cabecalho de TomarCamerasPendentes.
    FPendentes: TStringList;
    FHub: TLiveHub;
    // Um cliente ONVIF por camera, guardado: a preparacao custa tres chamadas
    // de rede e o resultado nao muda enquanto a camera for a mesma. O lock e
    // porque cada pedido HTTP vem numa thread do Indy.
    FOnvif: TObjectDictionary<string, TOnvifClient>;
    // O ultimo comando de PTZ por camera. A parada do DVRIP repete o comando
    // que estava andando; sem guardar, nao haveria o que repetir.
    FUltimoPtz: TDictionary<string, string>;
    FOnvifLock: TCriticalSection;
    // Uma sessao de comando por camera cujo campo PTZ e um endereco dvrip://.
    // Ver TPtzControleDvrip.
    FControles: TObjectDictionary<string, TPtzControleDvrip>;
    FControlesLock: TCriticalSection;
    FControlesTickMs: UInt64;
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
    // Chamado depois de gravar um parametro de analise. Quem liga isto e o
    // .dpr, que e onde a API e a analise se encontram -- a API sozinha nao
    // conhece os workers, e nem deve.
    FOnAnalyticsMudou: TProc;
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
    function HandleUiArquivo(const NomeArquivo,
                             TipoConteudo: string): TApiResponse;
    function HandleJs(const NomeArquivo: string): TApiResponse;
    function HandleCss(const NomeArquivo: string): TApiResponse;
    function HandleLive(const Query: string): TApiResponse;
    function HandlePtz(const Query: string): TApiResponse;
    function HandleConfigCamerasGet: TApiResponse;
    function HandleConfigCamerasPost(const Body: TBytes): TApiResponse;
    function HandleProcurarPtz(const Body: TBytes): TApiResponse;
    function CamerasAgora: TArray<string>;
    function HandleCamerasUi: TApiResponse;
    function ClienteOnvif(const Camera: string): TOnvifClient;
    // O que esta gravado no campo PTZ da camera, sem interpretacao.
    function EnderecoPtzDe(const Camera: string): string;
    // A configuracao de uma sessao de comando para esta camera, com o usuario
    // e a senha do endpoint que ja grava. False = nao ha o que abrir.
    function ConfigDeControle(const Camera, Endereco: string;
                              out Cfg: TCameraSessionConfig): Boolean;
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
    // Ligado pelo .dpr: e la que a API e a analise se encontram.
    property OnAnalyticsMudou: TProc read FOnAnalyticsMudou
                                     write FOnAnalyticsMudou;
    // As cameras que mudaram desde a ultima vez, e limpa a lista.
    //
    // Chamada pela thread principal no laco dela. Devolver E limpar numa
    // operacao so e o que evita perder um pedido que chegue entre a leitura e
    // a limpeza. Nomes repetidos entram uma vez so: salvar tres vezes seguidas
    // da um trabalho, nao tres.
    // Abre, fecha e conserta as sessoes de comando de PTZ conforme o cadastro.
    //
    // Chamada pelo laco principal, e barata quando nao ha nada a fazer: so
    // pensa de PTZ_CONTROLE_TICK_MS em PTZ_CONTROLE_TICK_MS. Fica aqui, e nao
    // na composicao, porque quem precisa da sessao e a rota de PTZ -- do mesmo
    // jeito que o cliente ONVIF, que tambem nasce e morre nesta classe.
    procedure ManterControlesPtz;
    function TomarCamerasPendentes: TArray<string>;
    // A lista de cameras que a API reconhece. Trocada quando uma camera nova
    // passa a existir -- sem isto ela gravaria, mas o /api/cameras nao a
    // listaria e o ao vivo dela responderia "camera desconhecida".
    procedure DefinirCameras(const Nomes: TArray<string>);
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

{ TPtzControleDvrip }

constructor TPtzControleDvrip.Create(const AConfig: TCameraSessionConfig;
  const ALogger: ILogger);
begin
  inherited Create;
  FConfig := AConfig;
  FLogger := ALogger;
  FTag := 'ptz.' + AConfig.Name;
  FParar := TEvent.Create(nil, True, False, '');
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      Sessao: TDvripSession;
    begin
      while FParar.WaitFor(0) <> wrSignaled do
      begin
        Sessao := TDvripSession.Create(FConfig, FLogger, TSystemClock.Create,
                                       FParar, nil);
        try
          try
            Sessao.RunControl; // volta quando FParar dispara ou a conexao cai
          except
            on E: Exception do
              if FLogger <> nil then
                FLogger.Warn(FTag, 'sessao de comando caiu: ' + E.Message);
          end;
        finally
          Sessao.Free;
        end;
        // Espera antes de tentar de novo, e a espera E o ponto de parada:
        // camera fora do ar faria isto girar sem folga.
        if FParar.WaitFor(5000) = wrSignaled then Break;
      end;
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

destructor TPtzControleDvrip.Destroy;
begin
  FParar.SetEvent;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FThread.Free;
  end;
  FParar.Free;
  inherited;
end;

function TPtzControleDvrip.Endereco: string;
begin
  Result := FConfig.Url;
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
  FCamerasLock := TCriticalSection.Create;
  FPendentes := TStringList.Create;
  FPendentes.Duplicates := dupIgnore;
  FPendentes.Sorted := True;
  FHub := AHub;
  FLogger := ALogger;
  FCache := ACache;
  FMedia := TMediaBuilder.Create(FCache, FConfig.MaxBlocksPerRequest, ALogger);
  FAuth := TAutenticador.Create;
  FOnvif := TObjectDictionary<string, TOnvifClient>.Create([doOwnsValues]);
  FUltimoPtz := TDictionary<string, string>.Create;
  FOnvifLock := TCriticalSection.Create;
  FControles := TObjectDictionary<string, TPtzControleDvrip>.Create([doOwnsValues]);
  FControlesLock := TCriticalSection.Create;
  RecarregarAuth;
  // A interface E a pasta: faltando ela, ou um arquivo dela, não há tela
  // nenhuma. Dizer isso na subida evita descobrir pelo navegador, com uma
  // página em branco e nenhuma pista.
  if FLogger <> nil then
  begin
    if not UiDirAtivo then
      FLogger.Error('api', 'sem a pasta da interface: ' + UiExplicacao +
                           ' -- as telas não vão abrir')
    else if UiFaltando <> '' then
      FLogger.Warn('api', 'faltam na interface (' + UiExplicacao + '): ' +
                          UiFaltando)
    else
      FLogger.Info('api', 'interface em ' + UiExplicacao + ' -- ' + UiCarimbo);
  end;
end;

destructor TApiRouter.Destroy;
begin
  // O cache não é nosso: quem criou destrói.
  FMedia.Free;
  FAuth.Free;
  FOnvif.Free;
  FUltimoPtz.Free;
  FOnvifLock.Free;
  // Antes do lock: cada sessao para a thread dela no destrutor, e a thread
  // ainda pode estar entrando aqui para se desanunciar.
  FControles.Free;
  FControlesLock.Free;
  FPendentes.Free;
  FCamerasLock.Free;
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
// A lista publicada, numa referencia propria.
//
// Copia a REFERENCIA, e nao o conteudo: quem publica sempre monta um vetor
// novo, entao o que este aqui devolveu continua valido e imutavel mesmo depois
// de outra thread trocar o campo. E por isso que o lock so envolve a leitura
// do campo, e nao o laco de quem usa.
function TApiRouter.CamerasAgora: TArray<string>;
begin
  FCamerasLock.Enter;
  try
    Result := FCameras;
  finally
    FCamerasLock.Leave;
  end;
end;

procedure TApiRouter.DefinirCameras(const Nomes: TArray<string>);
begin
  FCamerasLock.Enter;
  try
    FCameras := Copy(Nomes);
  finally
    FCamerasLock.Leave;
  end;
end;

function TApiRouter.TomarCamerasPendentes: TArray<string>;
begin
  Result := nil;
  FCamerasLock.Enter;
  try
    if FPendentes.Count = 0 then Exit;
    Result := FPendentes.ToStringArray;
    FPendentes.Clear;
  finally
    FCamerasLock.Leave;
  end;
end;

function TApiRouter.KnownCamera(const Name: string; out Canonical: string): Boolean;
var
  Lista: TArray<string>;
  I: Integer;
begin
  Canonical := '';
  if Trim(Name) = '' then Exit(False);
  Lista := CamerasAgora;
  for I := 0 to High(Lista) do
    if SameText(Lista[I], Name) then
    begin
      Canonical := Lista[I];
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
  //
  // A folha comum entra pelo mesmo motivo do ícone: a tela de entrada a carrega
  // ANTES de haver sessão, e um 401 aqui a deixaria sem estilo nenhum. Não
  // revela nada -- são cores e medidas, os mesmos bytes para todo mundo.
  Result := SameText(Path, UI_PREFIX + 'login') or
            SameText(Path, UI_PREFIX + 'ui.css') or
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
    if SameText(Path, UI_PREFIX + 'cameras') then
      Exit(HandleCamerasUi);
    // A folha comum a TODAS as páginas: a paleta, a base do documento e os
    // poucos componentes que aparecem em mais de uma tela. Solta pelo mesmo
    // motivo dos scripts -- a cor passa a existir num lugar só, e o navegador
    // guarda uma cópia que serve a todas.
    if SameText(Path, UI_PREFIX + 'ui.css') then
      Exit(HandleCss('ui.css'));
    // Os dois scripts que a página do player carrega. Servidos soltos, e não
    // embutidos nela, porque também servirão às próximas páginas -- e assim o
    // navegador os guarda em cache uma vez só.
    if SameText(Path, UI_PREFIX + 'vmsreader.js') then
      Exit(HandleJs('vmsreader.js'));
    if SameText(Path, UI_PREFIX + 'player.js') then
      Exit(HandleJs('player.js'));
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
    // O cadastro das cameras. Separado do /api/cameras, que e a lista curta que
    // as telas de assistir usam: aqui vem a configuracao inteira, e daqui ela
    // se altera.
    // A procura roda AQUI, e nao no navegador de quem abriu a tela: e esta
    // maquina que vai mandar o comando de PTZ depois.
    if SameText(Path, API_PREFIX + 'config/ptz/procurar') then
    begin
      if not SameText(Method, 'POST') then
        Exit(TApiResponse.Error(405, 'use POST'));
      Exit(HandleProcurarPtz(Body));
    end;
    if SameText(Path, API_PREFIX + 'config/cameras') then
    begin
      if SameText(Method, 'POST') then
        Exit(HandleConfigCamerasPost(Body));
      if not (SameText(Method, 'GET') or SameText(Method, 'HEAD')) then
        Exit(TApiResponse.Error(405, 'use GET ou POST'));
      Exit(HandleConfigCamerasGet);
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
    // Ao vivo sai do anel em memória enquanto a câmera publica, e da cauda do
    // arquivo quando ela não está publicando. Ver HandleLive.
    else if SameText(Path, API_PREFIX + 'live') then
      Result := HandleLive(Query)
    else if SameText(Path, API_PREFIX + 'ptz') then
      Result := HandlePtz(Query)
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
// Uma pagina da pasta `ui`, ou 404 dizendo qual arquivo falta e onde ele era
// esperado.
//
// Nao ha copia embutida para cair: a pasta E a interface. Entao a falta de um
// arquivo tem de aparecer com nome e endereco -- tela em branco sem explicacao
// era o pior desfecho possivel.
function TApiRouter.HandleUiArquivo(const NomeArquivo,
  TipoConteudo: string): TApiResponse;
var
  Texto: string;
begin
  Texto := UiTexto(NomeArquivo);
  if Texto = '' then
    Exit(TApiResponse.Error(404, 'nao achei ' + NomeArquivo + ' em ' + UiDir));
  Result.Status := 200;
  Result.ContentType := TipoConteudo;
  Result.Body := TEncoding.UTF8.GetBytes(Texto);
end;

function TApiRouter.HandleAppUi: TApiResponse;
begin
  Result := HandleUiArquivo('app-ui.html', 'text/html; charset=utf-8');
end;

// O player de gravação em HTML. Toca `.vms` direto, sem conversão aqui: o
// vmsreader.js lê o contêiner e o WebCodecs decodifica os AUs como eles estão
// no arquivo. O formato que já existe continua sendo o protocolo.
function TApiRouter.HandleLoginUi: TApiResponse;
begin
  Result := HandleUiArquivo('login-ui.html', 'text/html; charset=utf-8');
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
  Result := HandleUiArquivo('favicon.svg', 'image/svg+xml');
  if Result.Status <> 200 then Exit;
  // O ícone não muda entre versões do executável; deixar o navegador guardá-lo
  // evita um pedido por aba aberta.
  Result.Extra := TArray<string>.Create('Cache-Control: public, max-age=86400');
end;

function TApiRouter.HandlePlayerUi: TApiResponse;
begin
  Result := HandleUiArquivo('player-ui.html', 'text/html; charset=utf-8');
end;

function TApiRouter.HandleJs(const NomeArquivo: string): TApiResponse;
begin
  Result := HandleUiArquivo(NomeArquivo,
                            'application/javascript; charset=utf-8');
end;

function TApiRouter.HandleCss(const NomeArquivo: string): TApiResponse;
begin
  Result := HandleUiArquivo(NomeArquivo, 'text/css; charset=utf-8');
end;

// A faixa de eventos que o app mostra embaixo do vídeo.
//
// Servida pelo servidor, e não carregada de dentro do app, por um motivo
// prático: assim o `fetch` dela para /api/events e /api/thumb é mesma origem.
// Carregada por LoadFromStrings com base https, ela seria uma página https
// tentando buscar http -- conteúdo misto, que o navegador bloqueia.
function TApiRouter.HandleEventsUi: TApiResponse;
begin
  Result := HandleUiArquivo('events-ui.html', 'text/html; charset=utf-8');
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
  Existe, MexeuNaAnalise: Boolean;
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
  MexeuNaAnalise := False;
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
        if Par.JsonString.Value.StartsWith('analytics.', True) then
          MexeuNaAnalise := True;
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

  // Parametro de analise vale AGORA. Sintonizar e uma conversa -- mexe, olha,
  // mexe de novo --, e se cada tentativa custasse reiniciar o servidor ninguem
  // sintonizaria nada. As threads da analise recebem a configuracao nova e a
  // aplicam no comeco da proxima rodada.
  if (Gravadas > 0) and MexeuNaAnalise and Assigned(FOnAnalyticsMudou) then
  begin
    try
      FOnAnalyticsMudou();
      Root.AddPair('note', 'ja esta valendo');
    except
      on E: Exception do
        Root.AddPair('note', 'gravado, mas nao consegui aplicar agora (' +
                             E.Message + '); vale na proxima subida');
    end;
  end
  else
    Root.AddPair('note', 'gravado');
  Result := TApiResponse.FromJson(Root);
end;

// A página de sintonia do movimento, servida da pasta `ui` como as outras.
function TApiRouter.HandleMotionUi: TApiResponse;
begin
  Result.Status := 200;
  Result.ContentType := 'text/html; charset=utf-8';
  // Sem cache, mas isso já vem de graca: o TTxSession poe Cache-Control:
  // no-store em TODA resposta HTTP, e repetir aqui daria o cabecalho em dobro.
  Result := HandleUiArquivo('motion-ui.html', 'text/html; charset=utf-8');
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
  Limiar, Cena, Grade: Double;
  Delta: Integer;
  GradeMs: Int64;
  GradeCel: TArray<Byte>;
  GradeW, GradeH: Integer;
  GradeCapturadaEmMs: Int64;
  Cels: TJSONArray;
  ObjGrade: TJSONObject;
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
  // Vazios = grade cheia e delta padrao. Cliente antigo nao manda os dois, e
  // nada muda para ele.
  Grade := StrToFloatDef(QueryValue(Query, 'gridScale'), 1.0,
                         TFormatSettings.Invariant);
  if (Grade <= 0) or (Grade > 1) then Grade := 1.0;
  Delta := Integer(QueryInt(Query, 'cellDelta', 0));
  if (Delta < 0) or (Delta > 255) then Delta := 0;

  Comeco := Now;
  // Diagnostico: guarda a grade crua do quadro mais proximo deste instante.
  //
  // Serve para comparar, celula a celula, o que o servidor mede com o que outro
  // lado mede sobre o MESMO video. Sem isso, uma divergencia entre os dois so
  // se discute pelos scores, que sao o resultado da conta e nao a entrada dela.
  GradeMs := QueryInt(Query, 'gradeMs', 0);
  FProbe.GuardarGradeEm(GradeMs);

  Amostras := FProbe.Run(Camera, FromMs, ToMs, StepMs, Limiar, Cena, Grade,
                         Delta, Integer(QueryInt(Query, 'max', 0)));

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('fromMs', TJSONNumber.Create(FromMs));
  Root.AddPair('toMs', TJSONNumber.Create(ToMs));
  Root.AddPair('stepMs', TJSONNumber.Create(StepMs));
  Root.AddPair('threshold', TJSONNumber.Create(Limiar));
  Root.AddPair('sceneThreshold', TJSONNumber.Create(Cena));
  Root.AddPair('gridScale', TJSONNumber.Create(Grade));
  Root.AddPair('cellDelta', TJSONNumber.Create(Delta));

  // A grade pedida, se houve. `cells` vem na ordem da esquerda para a direita,
  // de cima para baixo -- o mesmo laco do detector.
  if (GradeMs > 0) and FProbe.GradeGuardada(GradeCel, GradeW, GradeH,
                                            GradeCapturadaEmMs) then
  begin
    ObjGrade := TJSONObject.Create;
    ObjGrade.AddPair('ms', TJSONNumber.Create(GradeCapturadaEmMs));
    ObjGrade.AddPair('w', TJSONNumber.Create(GradeW));
    ObjGrade.AddPair('h', TJSONNumber.Create(GradeH));
    Cels := TJSONArray.Create;
    for I := 0 to High(GradeCel) do
      Cels.Add(GradeCel[I]);
    ObjGrade.AddPair('cells', Cels);
    Root.AddPair('grid', ObjGrade);
  end;
  Root.AddPair('count', TJSONNumber.Create(Length(Amostras)));
  // Por que o percurso terminou. A pagina so mostra isto quando o trecho
  // analisado saiu menor que o pedido -- e ai e a diferenca entre "a gravacao
  // acaba aqui" e um defeito.
  Root.AddPair('walkEnd', FProbe.MotivoDoFim);
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

// O ao vivo pelo anel de memória, sem passar pelo disco.
//
// Por que existe: /api/live era HandleMedia(Query, True), a mesma leitura da
// gravação seguindo a cauda do arquivo aberto. Só que o arquivo só cresce
// quando um bloco FECHA -- block.maxDurationMs, 2 s -- e a isso somava-se o
// recuo de LIVE_PREROLL_MS na abertura, que fica para sempre porque o player
// ancora o relógio no primeiro quadro exibido. O anel do Vms.Server.LiveHub já
// recebia o sample no mesmo instante que o gravador, mas só a saída RTSP o
// consumia; aqui ele passa a servir também quem assiste pelo HTTP.
//
// O formato do fio não muda: a resposta continua sendo .vms (cabeçalho mais um
// bloco) com X-Vms-Cursor, e o player não sabe de onde os bytes vieram. O que
// muda é a idade deles.
//
// Sem câmera publicando, cai no caminho de arquivo -- que é o que atende câmera
// que não conectou nesta execução, e é o mesmo plano B que o hub já previa.
//
// Sobre o ritmo dos pedidos: cada resposta leva o que houver desde o cursor, e o
// pedido fica segurado até aparecer alguma coisa. Em rede rápida isso dá um
// pedido por quadro; em rede lenta o tempo de ida e volta acumula samples e a
// resposta vem maior. O custo se regula sozinho, e por isso NÃO há janela fixa
// de espera juntando quadros antes de responder: qualquer valor ali atrasaria a
// rede boa para poupar a ruim. O preço é uma thread do Indy segurada por até
// LIVE_ESPERA_MS por espectador parado -- a mesma que ele ocuparia reconectando.
function TApiRouter.HandleLive(const Query: string): TApiResponse;
var
  Camera, CursorTexto: string;
  Stream: TLiveStream;
  Cursor: TLiveCursor;
  Res: TLiveFetch;
  Itens: TArray<TLiveSampleRec>;
  Header: TVmsHeader;
  Bloco: TVmsBlock;
  Cabecalho, Corpo: TBytes;
  Flags: TSampleFlags;
  I, N, Off, Total: Integer;
  Descontinuo: Boolean;
  Partes: TArray<string>;

  function CursorSai: string;
  begin
    Result := LIVE_CURSOR_TAG + IntToStr(Cursor.NextSeq) + '-' +
              IntToStr(Cursor.Epoch) + '-' + IntToStr(Ord(Cursor.WaitKeyframe));
  end;

  // Ninguem publicando. 204 com a marca, e nao o historico: cair para o
  // arquivo mostrava um trecho de minutos atras com a tela dizendo "ao vivo",
  // e nada distinguia um do outro. Quem olha um portao precisa saber que esta
  // vendo o passado.
  function SemAoVivo: TApiResponse;
  begin
    Result := Default(TApiResponse);
    Result.Status := 204;
    Result.ContentType := 'application/x-vms';
    Result.Body := nil;
    Result.Extra := TArray<string>.Create('X-Vms-Live: 0');
  end;

  function NadaNovo: TApiResponse;
  begin
    Result := Default(TApiResponse);
    Result.Status := 204;
    Result.ContentType := 'application/x-vms';
    Result.Body := nil;
    Result.Extra := TArray<string>.Create(
      'X-Vms-Cursor: ' + CursorSai,
      'X-Vms-Growing: 1');
  end;

begin
  Result := Default(TApiResponse);
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));

  Stream := nil;
  if FHub <> nil then Stream := FHub.Find(Camera);
  if (Stream = nil) or (not Stream.IsPublishing) then
    Exit(SemAoVivo);

  CursorTexto := Trim(QueryValue(Query, 'cursor'));
  Descontinuo := False;
  Cursor := Default(TLiveCursor);
  // Cursor de arquivo chegando aqui é cliente que estava no plano B e a câmera
  // voltou. Assinar de novo é o certo: ao vivo quer o agora, e não emendar o
  // passado -- a marca de descontinuidade avisa o player para reancorar.
  if StartsText(LIVE_CURSOR_TAG, CursorTexto) then
  begin
    Partes := SplitString(Copy(CursorTexto, 2, MaxInt), '-');
    if Length(Partes) = 3 then
    begin
      Cursor.NextSeq := StrToInt64Def(Partes[0], 0);
      Cursor.Epoch := StrToIntDef(Partes[1], 0);
      Cursor.WaitKeyframe := Partes[2] <> '0';
      Cursor.Valid := True;
    end;
  end;
  if not Cursor.Valid then
  begin
    Descontinuo := True;
    // Publicando, mas ainda sem vídeo anunciado nesta execução: não é erro e
    // não é fim, e o cliente pergunta de novo.
    if not Stream.Subscribe(Cursor) then Exit(NadaNovo);
  end;

  Res := Stream.Fetch(Cursor, LIVE_ESPERA_MS, Itens);
  if Res in [lfResync, lfFormatChanged] then Descontinuo := True;

  N := Length(Itens);
  if N > LIVE_MAX_SAMPLES then N := LIVE_MAX_SAMPLES;
  if (Res = lfNone) or (N = 0) then Exit(NadaNovo);

  if not Stream.TryGetHeader(Header) then Exit(NadaNovo);

  // Um bloco só, com o que veio. As âncoras saem do primeiro sample de cada
  // trilha: é delas que o leitor data o resto, pelo PTS.
  Bloco := Default(TVmsBlock);
  Total := 0;
  for I := 0 to N - 1 do Inc(Total, Length(Itens[I].Data));
  SetLength(Bloco.Payload, Total);
  SetLength(Bloco.Samples, N);
  Off := 0;
  for I := 0 to N - 1 do
  begin
    if Length(Itens[I].Data) > 0 then
      Move(Itens[I].Data[0], Bloco.Payload[Off], Length(Itens[I].Data));
    // Do anel só volta o bit de keyframe; começo e fim de quadro não são
    // guardados lá. É o bit que o leitor e o percurso usam, e o único que
    // mudaria alguma coisa deste lado.
    Flags := [];
    if Itens[I].Keyframe then Include(Flags, sfKeyframe);
    Bloco.Samples[I].TrackId := Itens[I].TrackId;
    Bloco.Samples[I].FlagsByte := FlagsToByte(Flags);
    Bloco.Samples[I].Pts := Itens[I].Pts;
    Bloco.Samples[I].PayloadOffset := Cardinal(Off);
    Bloco.Samples[I].PayloadSize := Cardinal(Length(Itens[I].Data));
    Inc(Off, Length(Itens[I].Data));
    if (Itens[I].TrackId = 0) and (Bloco.VideoAnchorMs = 0) then
      Bloco.VideoAnchorMs := Stream.ParedeDe(Itens[I].WallMs);
    if (Itens[I].TrackId = 1) and (Bloco.AudioAnchorMs = 0) then
      Bloco.AudioAnchorMs := Stream.ParedeDe(Itens[I].WallMs);
  end;
  Bloco.BlockSeq := Cardinal(Cursor.NextSeq - N);
  Bloco.StartUnixMs := Bloco.VideoAnchorMs;
  if Bloco.StartUnixMs = 0 then Bloco.StartUnixMs := Bloco.AudioAnchorMs;

  Cabecalho := BuildHeaderBytes(Header);
  Corpo := BuildBlockBytes(Bloco);
  SetLength(Result.Body, Length(Cabecalho) + Length(Corpo));
  Move(Cabecalho[0], Result.Body[0], Length(Cabecalho));
  Move(Corpo[0], Result.Body[Length(Cabecalho)], Length(Corpo));

  Result.Status := 200;
  Result.ContentType := 'application/x-vms';
  Result.Extra := TArray<string>.Create(
    'X-Vms-Cursor: ' + CursorSai,
    'X-Vms-Block-Count: 1',
    Format('X-Vms-Start-Ms: %d', [Bloco.StartUnixMs]),
    Format('X-Vms-End-Ms: %d', [Bloco.StartUnixMs]),
    'X-Vms-Next-Ms: -1',
    'X-Vms-Gap-Ms: 0',
    Format('X-Vms-Discontinuity: %d', [Ord(Descontinuo)]),
    Format('X-Vms-Keyframe: %d', [Ord(Itens[0].Keyframe)]),
    'X-Vms-Growing: 1',
    'X-Vms-Thinned: 0');
end;

// Mover a camera, por ONVIF.
//
//   GET /api/ptz?camera=X&acao=mover&pan=-1..1&tilt=-1..1&zoom=-1..1
//   GET /api/ptz?camera=X&acao=parar
//   GET /api/ptz?camera=X&acao=presets
//   GET /api/ptz?camera=X&acao=ir&preset=TOKEN
//   GET /api/ptz?camera=X&acao=testar
//
// O comando vem para CA, e nao do aparelho direto para a camera, pelo mesmo
// motivo de todo o resto: quem enxerga a camera e o servidor. O telefone pode
// estar em outra rede, e frequentemente esta.
//
// `mover` e movimento CONTINUO: a camera anda ate mandarem parar. E o que casa
// com botao que se segura, e e por isso que `parar` existe como comando separado
// -- soltar o botao tem de chegar aqui, senao a camera gira sozinha ate bater no
// fim do curso. Quem chama e responsavel por mandar o parar.
//
// O endereco do servico sai da URL de midia da camera (mesma maquina, HTTP,
// caminho da norma). Camera que atende ONVIF noutra porta ou noutro caminho
// ganha a chave `ptz.<camera>.xaddr` nos parametros do servidor.
function TApiRouter.ClienteOnvif(const Camera: string): TOnvifClient;
var
  Url, Usuario, Senha, XAddr: string;
begin
  Result := nil;
  if (FDb = nil) or (not FDb.IsOpen) then Exit;

  FOnvifLock.Enter;
  try
    if FOnvif.TryGetValue(LowerCase(Camera), Result) then Exit;
  finally
    FOnvifLock.Leave;
  end;

  // A primeira rota da camera: e a que o gravador usa, e a que responde.
  Url := '';
  FDb.Read('SELECT e.url, e.user_name, e.password FROM camera_endpoint e ' +
           'JOIN camera c ON c.id = e.camera_id ' +
           'WHERE c.name = ? ORDER BY e.ord LIMIT 1', [Camera],
    procedure(const Row: IDbRow)
    begin
      Url := Row.AsString('url');
      Usuario := Row.AsString('user_name');
      Senha := Row.AsString('password');
    end);
  if Url = '' then Exit;

  XAddr := '';
  FDb.Read('SELECT value FROM setting WHERE key = ?',
           ['ptz.' + LowerCase(Camera) + '.xaddr'],
    procedure(const Row: IDbRow)
    begin
      XAddr := Trim(Row.AsString('value'));
    end);
  // SO o que a chave disser. Sem palpite de porta 80 quando ela esta vazia:
  // medido, perguntar por uma camera sem ONVIF custava 8 segundos de espera
  // numa porta que nao existe, e a tela pergunta ate sete vezes ao abrir o ao
  // vivo. Camera fixa responde "sem endereco" na hora, que e o que se quer.
  //
  // Quem tem ONVIF na 80 escreve "<ip>" na chave e segue igual; o botao
  // Procurar da tela de cameras preenche isso sozinho.
  if Trim(XAddr) = '' then Exit;
  // dvrip:// no campo nao e endereco de ONVIF: e o pedido de uma sessao de
  // comando, que TPtzControleDvrip abre e a rota acha no registro. Tentar SOAP
  // na porta do DVRIP so gastaria o tempo de espera de uma porta que nunca vai
  // responder isso.
  if StartsText('dvrip://', XAddr) then Exit;
  // EnderecoOnvif aceita as mesmas tres formas que o campo do app: so o host,
  // host com porta, ou a URL inteira.
  XAddr := EnderecoOnvif(XAddr, Url);

  Result := TOnvifClient.Create(XAddr, Usuario, Senha, FLogger,
                                'ptz.' + Camera);
  FOnvifLock.Enter;
  try
    // Outra thread pode ter criado o mesmo enquanto esta falava com o banco: o
    // dicionario e dono, entao o perdedor devolve o que ja estava la.
    if FOnvif.ContainsKey(LowerCase(Camera)) then
    begin
      Result.Free;
      FOnvif.TryGetValue(LowerCase(Camera), Result);
    end
    else
      FOnvif.Add(LowerCase(Camera), Result);
  finally
    FOnvifLock.Leave;
  end;
end;

function TApiRouter.EnderecoPtzDe(const Camera: string): string;
var
  Valor: string;
begin
  Result := '';
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  Valor := '';
  FDb.Read('SELECT value FROM setting WHERE key = ?',
           ['ptz.' + LowerCase(Camera) + '.xaddr'],
    procedure(const Row: IDbRow)
    begin
      Valor := Trim(Row.AsString('value'));
    end);
  Result := Valor;
end;

function TApiRouter.ConfigDeControle(const Camera, Endereco: string;
  out Cfg: TCameraSessionConfig): Boolean;
var
  Usuario, Senha: string;
  Achou: Boolean;
begin
  Result := False;
  Cfg := Default(TCameraSessionConfig);
  if (FDb = nil) or (not FDb.IsOpen) then Exit;

  // Usuario e senha do endpoint que ja grava: e a MESMA camera, e pedir para
  // cadastrar de novo so criaria uma segunda copia da senha para envelhecer.
  Achou := False;
  FDb.Read('SELECT e.user_name, e.password FROM camera_endpoint e ' +
           'JOIN camera c ON c.id = e.camera_id ' +
           'WHERE c.name = ? ORDER BY e.ord LIMIT 1', [Camera],
    procedure(const Row: IDbRow)
    begin
      Usuario := Row.AsString('user_name');
      Senha := Row.AsString('password');
      Achou := True;
    end);
  if not Achou then Exit;

  Cfg.Name := Camera;
  Cfg.Url := Endereco;
  Cfg.User := Usuario;
  Cfg.Password := Senha;
  Cfg.ConnectTimeoutMs := 8000;
  Cfg.RtspTimeoutMs := 8000;
  Cfg.RecordEnabled := False;
  Result := True;
end;

procedure TApiRouter.ManterControlesPtz;
var
  Nomes: TArray<string>;
  Nome, Endereco: string;
  Cfg: TCameraSessionConfig;
  Ctrl: TPtzControleDvrip;
  Sobrando: TArray<string>;
  I: Integer;
begin
  if TThread.GetTickCount64 - FControlesTickMs < PTZ_CONTROLE_TICK_MS then Exit;
  FControlesTickMs := TThread.GetTickCount64;
  if (FDb = nil) or (not FDb.IsOpen) then Exit;

  Nomes := CamerasAgora;
  for Nome in Nomes do
  begin
    Endereco := EnderecoPtzDe(Nome);
    // So dvrip:// abre sessao. Endereco ONVIF continua indo pelo caminho de
    // sempre, e campo vazio nao abre nada.
    if not StartsText('dvrip://', Endereco) then Continue;
    // Camera que ja tem sessao viva nao ganha outra: se ela e GRAVADA por
    // DVRIP, o comando ja anda pela conexao da gravacao, e duas sessoes com o
    // mesmo nome brigariam pelo registro.
    if TPtzRegistry.Achar(Nome) <> nil then Continue;

    FControlesLock.Enter;
    try
      if FControles.TryGetValue(LowerCase(Nome), Ctrl) then
      begin
        // O cadastro mudou de endereco embaixo da sessao: derruba e refaz.
        if SameText(Ctrl.Endereco, Endereco) then Continue;
        FControles.Remove(LowerCase(Nome));
      end;
      if not ConfigDeControle(Nome, Endereco, Cfg) then Continue;
      FControles.Add(LowerCase(Nome),
                     TPtzControleDvrip.Create(Cfg, FLogger));
      if FLogger <> nil then
        FLogger.Info('ptz.' + Nome, 'abrindo sessao de comando em ' + Endereco);
    finally
      FControlesLock.Leave;
    end;
  end;

  // Camera que perdeu o endereco, ou sumiu do cadastro, perde a sessao.
  Sobrando := nil;
  FControlesLock.Enter;
  try
    for Nome in FControles.Keys do
      if not StartsText('dvrip://', EnderecoPtzDe(Nome)) then
      begin
        SetLength(Sobrando, Length(Sobrando) + 1);
        Sobrando[High(Sobrando)] := Nome;
      end;
    for I := 0 to High(Sobrando) do
    begin
      FControles.Remove(Sobrando[I]);
      if FLogger <> nil then
        FLogger.Info('ptz.' + Sobrando[I], 'sessao de comando encerrada');
    end;
  finally
    FControlesLock.Leave;
  end;
end;

function TApiRouter.HandlePtz(const Query: string): TApiResponse;
var
  Camera, Acao, Comando: string;
  Passo, Canal: Integer;
  Dir: string;
  Sessao: IPtzSession;
  Cli: TOnvifClient;
  Root: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  Presets: TArray<TOnvifPreset>;
  I: Integer;
  Ok: Boolean;
  Espera: UInt64;

  function Num(const Nome: string): Double;
  var
    S: string;
  begin
    // Em milesimos, e nao decimal na query: assim nao ha ponto nem virgula para
    // o cliente errar, e a conversao de volta e uma divisao.
    S := Trim(QueryValue(Query, Nome));
    if S = '' then Exit(0);
    Result := StrToIntDef(S, 0) / 1000;
  end;

begin
  if not KnownCamera(QueryValue(Query, 'camera'), Camera) then
    Exit(TApiResponse.Error(404, 'camera desconhecida'));

  Acao := LowerCase(Trim(QueryValue(Query, 'acao')));

  // DVRIP primeiro, quando ha sessao viva: o comando sai pela conexao que ja
  // esta autenticada -- a mesma que grava -- e nao custa um login por clique.
  // Estas cameras nao respondem ONVIF (medido: a porta 80 delas recusa
  // conexao), entao para elas este e o unico caminho.
  Sessao := TPtzRegistry.Achar(Camera);
  // Sem sessao viva e com dvrip:// no cadastro: manda abrir uma so de comando
  // e espera um pouco por ela. Quem grava por RTSP cai sempre aqui no primeiro
  // clique depois de subir o servidor.
  if (Sessao = nil) and StartsText('dvrip://', EnderecoPtzDe(Camera)) then
  begin
    FControlesTickMs := 0; // nao espera o proximo tick do laco principal
    ManterControlesPtz;
    Espera := TThread.GetTickCount64 + PTZ_CONTROLE_ESPERA_MS;
    while (Sessao = nil) and (TThread.GetTickCount64 < Espera) do
    begin
      Sleep(100);
      Sessao := TPtzRegistry.Achar(Camera);
    end;
    if Sessao = nil then
      Exit(TApiResponse.Error(503,
        'abrindo a sessao de comando desta camera; tente de novo em instantes'));
  end;
  if Sessao <> nil then
  begin
    Comando := '';
    Passo := 5;
    // Zero serve para camera solta, que e o caso das daqui; o parametro existe
    // porque nem toda camera concorda com isso e descobrir qual e a certa e
    // trabalho de tentativa, nao de leitura.
    Canal := StrToIntDef(Trim(QueryValue(Query, 'canal')), 0);
    if Acao = 'mover' then
    begin
      Comando := ComandoDvripDe(Num('pan'), Num('tilt'), Num('zoom'));
      Passo := PassoDvripDe(Num('pan'), Num('tilt'), Num('zoom'));
      if Comando = '' then
        Exit(TApiResponse.Error(400, 'direcao vazia: informe pan, tilt ou zoom'));
      FUltimoPtz.AddOrSetValue(LowerCase(Camera), Comando);
      Ok := Sessao.MoverPtz(Comando, Passo, Canal, True);
    end
    else if Acao = 'parar' then
    begin
      // A parada repete o comando que estava andando: e a mesma mensagem com
      // outro Preset, e a camera espera reconhecer qual movimento parar. Sem
      // saber o anterior, para pela esquerda -- que e o que a captura mostrou
      // e o que as cameras aceitam como "pare tudo".
      if not FUltimoPtz.TryGetValue(LowerCase(Camera), Comando) then
        Comando := DVRIP_PTZ_ESQUERDA;
      Ok := Sessao.MoverPtz(Comando, Passo, Canal, False);
    end
    else if (Acao = 'foco') or (Acao = 'iris') then
    begin
      // Andam enquanto se segura, como as direcoes: mesma mensagem, so muda o
      // nome do comando. Quem para e o `parar`, que repete o ultimo enviado.
      Dir := LowerCase(Trim(QueryValue(Query, 'dir')));
      if Acao = 'foco' then
      begin
        if Dir = 'perto' then Comando := DVRIP_PTZ_FOCO_PERTO
        else if Dir = 'longe' then Comando := DVRIP_PTZ_FOCO_LONGE;
      end
      else
      begin
        if Dir = 'abrir' then Comando := DVRIP_PTZ_IRIS_ABRE
        else if Dir = 'fechar' then Comando := DVRIP_PTZ_IRIS_FECHA;
      end;
      if Comando = '' then
          Exit(TApiResponse.Error(400, 'informe dir'));
      FUltimoPtz.AddOrSetValue(LowerCase(Camera), Comando);
      Ok := Sessao.MoverPtz(Comando, Passo, Canal, True);
    end
    else if Acao = 'ronda' then
    begin
      // De um disparo so: o proprio nome do comando ja diz comecar ou parar.
      if Trim(QueryValue(Query, 'ligar')) = '0' then Comando := DVRIP_PTZ_RONDA_FIM
      else Comando := DVRIP_PTZ_RONDA_INI;
      Ok := Sessao.MoverPtz(Comando, Passo, Canal, True);
    end
    else if Acao = 'preset' then
    begin
      // Sem parada depois: quem vai a um preset para sozinho ao chegar.
      Passo := StrToIntDef(Trim(QueryValue(Query, 'n')), -1);
      if Passo < 0 then
        Exit(TApiResponse.Error(400, 'informe n, o numero do preset'));
      // Ir e o padrao: e o que se faz o tempo todo. Gravar e apagar existem
      // para a tela poder oferecer "guardar esta posicao" sem outra rota.
      Dir := LowerCase(Trim(QueryValue(Query, 'op')));
      if Dir = 'gravar' then Comando := DVRIP_PTZ_PRESET_POR
      else if Dir = 'apagar' then Comando := DVRIP_PTZ_PRESET_LIMPA
      else Comando := DVRIP_PTZ_PRESET_IR;
      Ok := Sessao.IrParaPreset(Passo, Canal, Comando);
    end
    else if Acao = 'config' then
    begin
      // Diagnostico: pergunta a camera o que ela sabe. A resposta sai no log,
      // com a marca ctrl:, porque quem le o socket e outra thread.
      Comando := Trim(QueryValue(Query, 'nome'));
      if Comando = '' then
        Exit(TApiResponse.Error(400, 'informe nome, a secao da configuracao'));
      Ok := Sessao.PerguntarConfig(Comando);
    end
    else if Acao = 'testar' then
      Ok := True
    else
      Exit(TApiResponse.Error(400, Acao + ' nao existe no DVRIP: use mover, ' +
                                   'parar, foco, iris, ronda, preset, config ou testar'));

    Root := TJSONObject.Create;
    Root.AddPair('camera', Camera);
    Root.AddPair('acao', Acao);
    Root.AddPair('via', 'dvrip');
    Root.AddPair('ok', TJSONBool.Create(Ok));
    if Comando <> '' then Root.AddPair('comando', Comando);
    if not Ok then Root.AddPair('motivo', 'nao consegui escrever na sessao');
    Exit(TApiResponse.FromJson(Root));
  end;

  Cli := ClienteOnvif(Camera);
  if Cli = nil then
    Exit(TApiResponse.Error(503,
      'camera sem sessao DVRIP viva e sem cadastro utilizavel para ONVIF'));
  Presets := nil;
  if Acao = 'parar' then
    Ok := Cli.Parar
  else if Acao = 'mover' then
    Ok := Cli.MoverContinuo(TOnvifMove.Criar(Num('pan'), Num('tilt'), Num('zoom')))
  else if (Acao = 'ir') or (Acao = 'preset') then
    // Dois nomes para a mesma coisa: `ir` e o que esta rota ja aceitava, e
    // `preset` e o que a tela manda, igual ao DVRIP. O valor vem em `preset`
    // ou em `n`, o que estiver preenchido.
    Ok := Cli.IrParaPreset(Trim(QueryValue(Query, 'preset')) +
                           Trim(QueryValue(Query, 'n')))
  else if Acao = 'presets' then
    Ok := Cli.LerPresets(Presets)
  else if Acao = 'testar' then
    Ok := Cli.Preparar
  else
    Exit(TApiResponse.Error(400, 'acao invalida: use mover, parar, presets, ' +
                                 'ir ou testar'));

  Root := TJSONObject.Create;
  Root.AddPair('camera', Camera);
  Root.AddPair('acao', Acao);
  Root.AddPair('via', 'onvif');
  Root.AddPair('ok', TJSONBool.Create(Ok));
  // O motivo vai junto MESMO quando deu certo estar vazio: e ele que diz se a
  // camera nao tem PTZ, se recusou a senha ou se nem respondeu, e sem ele a
  // tela so teria "nao funcionou".
  if not Ok then Root.AddPair('motivo', Cli.Motivo);
  if Acao = 'testar' then
  begin
    Root.AddPair('ptz', TJSONBool.Create(Cli.TemPtz));
    Root.AddPair('servico', Cli.PtzUrl);
    Root.AddPair('perfil', Cli.Perfil);
  end;
  if Acao = 'presets' then
  begin
    Arr := TJSONArray.Create;
    Root.AddPair('presets', Arr);
    for I := 0 to High(Presets) do
    begin
      Item := TJSONObject.Create;
      Item.AddPair('token', Presets[I].Token);
      Item.AddPair('nome', Presets[I].Nome);
      Arr.AddElement(Item);
    end;
  end;
  Result := TApiResponse.FromJson(Root);
end;

// Em que porta esta camera atende ONVIF, vista DESTE servidor.
//
// POST, e nao GET com query: leva a senha da camera, e senha em URL fica no
// historico e em qualquer registro de acesso pelo caminho.
function TApiRouter.HandleProcurarPtz(const Body: TBytes): TApiResponse;
var
  Texto, Host: string;
  Valor: TJSONValue;
  Obj, Root, Item: TJSONObject;
  Arr: TJSONArray;
  Achados: TArray<TOnvifAchado>;
  I: Integer;
  Melhor: string;
begin
  Texto := TEncoding.UTF8.GetString(Body);
  if Trim(Texto) = '' then
    Exit(TApiResponse.Error(400, 'corpo vazio'));
  Valor := TJSONObject.ParseJSONValue(Texto);
  if not (Valor is TJSONObject) then
  begin
    Valor.Free;
    Exit(TApiResponse.Error(400, 'mande {url, user, password}'));
  end;
  try
    Obj := TJSONObject(Valor);
    Host := HostDaUrl(Obj.GetValue<string>('url', ''));
    if Host = '' then
      Exit(TApiResponse.Error(400, 'a url nao tem host'));
    Achados := ProcurarOnvif(Host, Obj.GetValue<string>('user', ''),
                             Obj.GetValue<string>('password', ''), FLogger);
  finally
    Valor.Free;
  end;

  Melhor := '';
  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('host', Host);
  Root.AddPair('achados', Arr);
  for I := 0 to High(Achados) do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('porta', TJSONNumber.Create(Achados[I].Porta));
    Item.AddPair('ptz', TJSONBool.Create(Achados[I].TemPtz));
    Arr.AddElement(Item);
    if Achados[I].TemPtz and (Melhor = '') then
      Melhor := Host + ':' + IntToStr(Achados[I].Porta);
  end;
  // Vazio nao e erro: e camera que nao fala ONVIF, ou que fala e nao se move.
  Root.AddPair('melhor', Melhor);
  Result := TApiResponse.FromJson(Root);
end;

function TApiRouter.HandleCamerasUi: TApiResponse;
begin
  Result := HandleUiArquivo('cameras-ui.html', 'text/html; charset=utf-8');
end;

// O cadastro inteiro das cameras deste servidor.
//
// SEM as senhas. Elas nao voltam nem mascaradas com o tamanho certo: a tela nao
// precisa delas para nada, e o que nao sai daqui nao vaza pelo cache do
// navegador, pelo historico nem por uma captura de tela. No lugar vai um
// `temSenha`, que e o que a tela precisa mostrar -- e, na hora de gravar, campo
// de senha vazio quer dizer "mantenha a que ja esta la".
function TApiRouter.HandleConfigCamerasGet: TApiResponse;
var
  Root: TJSONObject;
  Arr, Eps: TJSONArray;
  Cam: TJSONObject;
  Ids: TList<Int64>;
  I: Integer;
  Xaddr: string;
begin
  if (FDb = nil) or (not FDb.IsOpen) then
    Exit(TApiResponse.Error(503, 'banco indisponivel'));

  Root := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Root.AddPair('cameras', Arr);
  Ids := TList<Int64>.Create;
  try
    FDb.Read('SELECT id, name, enabled, record_audio FROM camera ' +
             'ORDER BY name COLLATE NOCASE', [],
      procedure(const Row: IDbRow)
      var
        O: TJSONObject;
      begin
        O := TJSONObject.Create;
        O.AddPair('id', TJSONNumber.Create(Row.AsInt64('id')));
        O.AddPair('name', Row.AsString('name'));
        O.AddPair('enabled', TJSONBool.Create(Row.AsBool('enabled')));
        O.AddPair('recordAudio', TJSONBool.Create(Row.AsBool('record_audio')));
        Arr.AddElement(O);
        Ids.Add(Row.AsInt64('id'));
      end);

    for I := 0 to Ids.Count - 1 do
    begin
      Cam := Arr.Items[I] as TJSONObject;
      Eps := TJSONArray.Create;
      Cam.AddPair('endpoints', Eps);
      FDb.Read('SELECT ord, label, url, user_name, password, transports, ' +
               '  uses_tailscale FROM camera_endpoint WHERE camera_id = ? ' +
               'ORDER BY ord', [Ids[I]],
        procedure(const Row: IDbRow)
        var
          E: TJSONObject;
        begin
          E := TJSONObject.Create;
          E.AddPair('label', Row.AsString('label'));
          E.AddPair('url', Row.AsString('url'));
          E.AddPair('user', Row.AsString('user_name'));
          // A senha NAO vai; so o fato de existir uma.
          E.AddPair('temSenha', TJSONBool.Create(Row.AsString('password') <> ''));
          E.AddPair('transport', Row.AsString('transports'));
          E.AddPair('tailscale', TJSONBool.Create(Row.AsBool('uses_tailscale')));
          Eps.AddElement(E);
        end);

      Xaddr := '';
      FDb.Read('SELECT value FROM setting WHERE key = ?',
               ['ptz.' + LowerCase(Cam.GetValue<string>('name', '')) + '.xaddr'],
        procedure(const Row: IDbRow)
        begin
          Xaddr := Row.AsString('value');
        end);
      Cam.AddPair('ptz', Xaddr);
    end;
  finally
    Ids.Free;
  end;
  Result := TApiResponse.FromJson(Root);
end;

// Cria ou altera UMA camera.
//
// O nome nao se altera depois de criado, e a recusa e proposital: ele e o nome
// da pasta em disco, o da rota RTSP e o parametro ?camera= de tudo. Renomear
// aqui separaria a camera das gravacoes dela, que continuariam na pasta antiga.
//
// Nao ha apagar. Apagar a linha da camera leva junto, por cascata, o inventario
// das gravacoes, os eventos e as miniaturas dela -- o historico inteiro, sendo
// que os .vms continuariam ocupando disco sem ninguem que os indexe. Quem quer
// parar uma camera desmarca "habilitada": a gravacao para e o passado continua
// aberto para consulta.
function TApiRouter.HandleConfigCamerasPost(const Body: TBytes): TApiResponse;
var
  Texto, Nome, NomeAtual, Ptz: string;
  Valor: TJSONValue;
  Obj, Root, EpObj: TJSONObject;
  Eps: TJSONArray;
  Id: Int64;
  I, Ord_: Integer;
  Agora: Int64;
  Antigas: TDictionary<Integer, string>;
  Senha, Url: string;
  Ligada, ComAudio: Boolean;
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

  Antigas := TDictionary<Integer, string>.Create;
  try
    Obj := TJSONObject(Valor);
    Nome := Trim(Obj.GetValue<string>('name', ''));
    Id := Obj.GetValue<Int64>('id', 0);
    Ligada := Obj.GetValue<Boolean>('enabled', True);
    ComAudio := Obj.GetValue<Boolean>('recordAudio', True);
    Ptz := Trim(Obj.GetValue<string>('ptz', ''));

    if Nome = '' then
      Exit(TApiResponse.Error(400, 'a camera precisa de um nome'));
    // O nome vira pasta em disco: o que nao serve num caminho nao serve aqui.
    if (Pos('/', Nome) > 0) or (Pos('\', Nome) > 0) or (Pos(':', Nome) > 0) or
       (Pos('..', Nome) > 0) then
      Exit(TApiResponse.Error(400,
        'o nome vira pasta em disco: sem / \ : nem ..'));

    if not (Obj.GetValue('endpoints') is TJSONArray) then
      Exit(TApiResponse.Error(400, 'informe ao menos um endereco em endpoints'));
    Eps := Obj.GetValue('endpoints') as TJSONArray;
    if Eps.Count = 0 then
      Exit(TApiResponse.Error(400, 'informe ao menos um endereco em endpoints'));
    for I := 0 to Eps.Count - 1 do
    begin
      if not (Eps.Items[I] is TJSONObject) then
        Exit(TApiResponse.Error(400, 'endpoint invalido'));
      if Trim((Eps.Items[I] as TJSONObject).GetValue<string>('url', '')) = '' then
        Exit(TApiResponse.Error(400, 'endereco sem url'));
    end;

    Agora := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), True) * 1000;

    if Id > 0 then
    begin
      NomeAtual := '';
      FDb.Read('SELECT name FROM camera WHERE id = ?', [Id],
        procedure(const Row: IDbRow)
        begin
          NomeAtual := Row.AsString('name');
        end);
      if NomeAtual = '' then
        Exit(TApiResponse.Error(404, 'nao ha camera com este id'));
      if not SameText(NomeAtual, Nome) then
        Exit(TApiResponse.Error(400,
          'o nome e a pasta em disco e a rota da camera: renomear a separaria ' +
          'das gravacoes dela. Crie outra camera.'));
      // So o que esta tela edita. As outras colunas (atrasos, reconexao) ficam
      // como estao: sobrescreve-las com padroes apagaria ajuste feito a mao.
      FDb.Exec('UPDATE camera SET enabled = ?, record_audio = ?, ' +
               '  updated_at_ms = ? WHERE id = ?',
               [Ord(Ligada), Ord(ComAudio), Agora, Id]);
    end
    else
    begin
      if FDb.ReadInt64('SELECT COUNT(*) AS n FROM camera WHERE name = ?',
                       [Nome], 'n', 0) > 0 then
        Exit(TApiResponse.Error(409, 'ja existe uma camera com este nome'));
      FDb.Exec('INSERT INTO camera (name, enabled, record_audio, ' +
               '  created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)',
               [Nome, Ord(Ligada), Ord(ComAudio), Agora, Agora]);
      Id := FDb.ReadInt64('SELECT id AS n FROM camera WHERE name = ?',
                          [Nome], 'n', 0);
      if Id <= 0 then
        Exit(TApiResponse.Error(500, 'gravei a camera e nao a encontrei'));
    end;

    // As senhas que ja estao la, por posicao. Campo vazio na tela quer dizer
    // "mantenha": a tela nunca recebeu a senha, entao ela nao teria como
    // devolve-la, e sem isto salvar qualquer outro campo apagaria a senha.
    FDb.Read('SELECT ord, password FROM camera_endpoint WHERE camera_id = ?',
             [Id],
      procedure(const Row: IDbRow)
      begin
        Antigas.AddOrSetValue(Row.AsInt('ord'), Row.AsString('password'));
      end);

    // Apaga e regrava: e a unica forma simples de refletir a remocao de um
    // caminho, e a lista tem tres itens no maximo.
    FDb.Exec('DELETE FROM camera_endpoint WHERE camera_id = ?', [Id]);
    for I := 0 to Eps.Count - 1 do
    begin
      EpObj := Eps.Items[I] as TJSONObject;
      Ord_ := I;
      Url := Trim(EpObj.GetValue<string>('url', ''));
      Senha := EpObj.GetValue<string>('password', '');
      if Senha = '' then
        if not Antigas.TryGetValue(Ord_, Senha) then Senha := '';
      FDb.Exec('INSERT INTO camera_endpoint (camera_id, ord, label, url, ' +
               '  user_name, password, transports, uses_tailscale) ' +
               'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
               [Id, Ord_, EpObj.GetValue<string>('label', ''), Url,
                EpObj.GetValue<string>('user', ''), Senha,
                EpObj.GetValue<string>('transport', 'tcp,udp'),
                Ord(EpObj.GetValue<Boolean>('tailscale', False))]);
    end;

    // O endereco do PTZ mora em `setting`, e nao numa coluna da camera,
    // porque e o mesmo lugar de onde o /api/ptz ja o le hoje. Vale para as
    // duas formas: host de ONVIF ou dvrip://host:porta.
    if Ptz <> '' then
      FDb.Exec('INSERT INTO setting (key, value, updated_at_ms) ' +
               'VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET ' +
               '  value = excluded.value, updated_at_ms = excluded.updated_at_ms',
               ['ptz.' + LowerCase(Nome) + '.xaddr', Ptz, Agora])
    else
      FDb.Exec('DELETE FROM setting WHERE key = ?',
               ['ptz.' + LowerCase(Nome) + '.xaddr']);

    // O pedido para a thread principal. Ver TomarCamerasPendentes.
    FCamerasLock.Enter;
    try
      FPendentes.Add(Nome);
    finally
      FCamerasLock.Leave;
    end;

    if FLogger <> nil then
      FLogger.Info('api', Format('cadastro da camera %s gravado (%d enderecos)',
                                 [Nome, Eps.Count]));

    Root := TJSONObject.Create;
    Root.AddPair('id', TJSONNumber.Create(Id));
    Root.AddPair('name', Nome);
    // A captura tambem passa a valer, so que nao neste instante: quem a troca
    // e a thread principal, na proxima volta do laco dela. Segundos, nao a
    // proxima subida do servidor.
    Root.AddPair('aplicando', TJSONBool.Create(True));
    Result := TApiResponse.FromJson(Root);
  finally
    Antigas.Free;
    Valor.Free;
  end;
end;

function TApiRouter.HandleCameras: TApiResponse;
var
  Lista: TArray<string>;
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
  // Numa referencia propria: outra thread pode publicar uma lista nova no meio
  // deste laco, e ler o campo a cada volta daria metade de uma e metade da
  // outra. Ver CamerasAgora.
  Lista := CamerasAgora;
  for I := 0 to High(Lista) do
  begin
    Files := FCache.ListFiles(Lista[I]);
    Item := TJSONObject.Create;
    Item.AddPair('name', Lista[I]);
    Item.AddPair('live', TJSONBool.Create(IsLive(Lista[I])));
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
