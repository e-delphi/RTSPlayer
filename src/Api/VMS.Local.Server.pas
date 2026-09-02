unit VMS.Local.Server;

// O servidor HTTP que roda DENTRO do app, só para o próprio app.
//
// É a fundação da interface em HTML: o WebView aponta para
// `http://127.0.0.1:<porta>/` e tudo que a página precisa chega por aqui.
//
// ## Por que um servidor, e não uma ponte
//
// O canal que o FMX oferece entre página e nativo é a navegação
// (`OnShouldStartLoadWithRequest`), e ele serve para comando — "vá para este
// instante" —, não para dados. Miniatura, fragmento de vídeo, lista longa: nada
// disso passa por URL. Um servidor local resolve quatro coisas de uma vez:
//
//   * **Contexto seguro.** `127.0.0.1` é origem confiável para o Chromium, e é
//     isso que deixa o WebCodecs disponível dentro do app.
//   * **Mesma origem.** Sem CORS, sem conteúdo misto.
//   * **Binário e streaming.** Range, fragmentos, imagens — o que HTTP faz bem.
//   * **Uma interface só.** A página fala a MESMA `/api/*` do vmsserver. O
//     mesmo HTML serve o app (contra este servidor) e o navegador remoto
//     (contra o vmsserver). É esse o ganho que justifica o resto.
//
// ## O que ele serve, e o que ele repassa
//
// O app não tem banco de eventos nem gravação em disco — isso é do vmsserver.
// Então este servidor **encaminha** o que não é dele (`/api/events`,
// `/api/thumb`, `/api/media`...) para o servidor configurado, e responde
// diretamente só o que ele mesmo sabe.
//
// A página nunca precisa saber de onde veio cada coisa. É o ponto: um único
// endereço, e o Delphi por baixo decide se a resposta sai da memória, do
// aparelho ou da rede.
//
// ## Segurança
//
// Escuta SÓ em 127.0.0.1. Nada fora do aparelho alcança esta porta — nem outro
// aplicativo em outro celular da mesma rede. Por isso não há autenticação: o
// alcance já é o limite.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Net.HttpClient,
  System.Net.URLClient,   // TNameValuePair, do cabecalho encaminhado
  System.NetEncoding,     // Base64 do Authorization: Basic
  System.NetConsts,
  IdContext,
  IdCustomHTTPServer,
  IdHTTPServer,
  IdSocketHandle,
  VMS.Domain.Logging;

type
  // De onde o servidor tira a lista de câmeras. Um método, para o servidor não
  // precisar conhecer a configuração do app nem o formulário.
  TCameraListFunc = function: TArray<string> of object;

  // O cadastro, nos dois sentidos, em JSON -- o MESMO texto que o app grava em
  // disco e que a exportação manda para outro aparelho (ver CamerasToJson).
  // Trocar texto, e não registro, mantém o servidor sem saber o que é uma
  // câmera: ele só transporta.
  TConfigLerFunc = function: string of object;
  TConfigGravarFunc = function(const Json: string): string of object;

  // O ao vivo de uma camera, em bytes .vms. Cursor 0 abre a sessao; o servidor
  // devolve o proximo cursor. Resultado False = ainda nao ha o que entregar, e
  // nao erro: camera conectando tambem cai aqui.
  TLiveLerFunc = function(const Camera: string; Cursor: Cardinal;
                          out Dados: TBytes;
                          out ProxCursor: Cardinal): Boolean of object;

  // O cadastro de SERVIDORES, tambem em JSON, tambem do aparelho. Um cliente
  // pode falar com varios servidores; qual deles vale numa requisicao vem no
  // parametro `server` dela, e nao de um estado global -- assim duas abas
  // olhando servidores diferentes nao se atrapalham.
  TServidoresLerFunc = function: string of object;
  TServidoresGravarFunc = function(const Json: string): string of object;
  // Traduz o nome de um servidor cadastrado no http://host:porta dele. Vazio =
  // nao existe, e a rota responde 404 em vez de encaminhar para lugar nenhum.
  TServidorUrlFunc = function(const Nome: string): string of object;
  // "esta rota nao respondeu": quem cadastra escolhe outra da proxima vez.
  TServidorFalhouProc = procedure(const Nome: string) of object;
  // Sonda todas as rotas de um servidor e devolve o json do resultado.
  TSondarServidorFunc = function(const Nome: string): string of object;
  // Uma linha sobre o que o cadastro tem, para a falha de encaminhamento poder
  // dizer por que nao achou o servidor.
  TServidorDiagFunc = function: string of object;
  // "o voltar chegou na pagina ja na raiz": e para o app fechar.
  TSairProc = procedure of object;

  // Decodificacao nativa, para o que o WebView nao da conta (ver
  // VMS.App.Decodificacao). Devolve quantos samples ficaram pendentes, ou -1
  // quando o fragmento nao serviu.
  TDecodeAlimentarFunc = function(const Camera: string;
                                  const Dados: TBytes): Integer of object;
  // O proximo quadro, ja em JPEG, com o instante de parede dele.
  TDecodeQuadroFunc = function(const Camera: string; out Jpeg: TBytes;
                               out Ms: Int64): Boolean of object;
  TDecodeReiniciarProc = procedure(const Camera: string) of object;
  // A credencial cadastrada para um servidor, quando ele pede uma.
  TServidorCredFunc = function(const Nome: string;
                               out Usuario, Senha: string): Boolean of object;

  TLocalServer = class
  strict private
    FHttp: TIdHTTPServer;
    FLogger: ILogger;
    FPorta: Integer;
    FUpstream: string;      // http://host:porta do vmsserver, ou vazio
    FOnCameras: TCameraListFunc;
    FOnLerConfig: TConfigLerFunc;
    FOnGravarConfig: TConfigGravarFunc;
    FOnLive: TLiveLerFunc;
    FOnLerServidores: TServidoresLerFunc;
    FOnGravarServidores: TServidoresGravarFunc;
    FOnServidorUrl: TServidorUrlFunc;
    FOnServidorFalhou: TServidorFalhouProc;
    FOnSondarServidor: TSondarServidorFunc;
    FOnServidorCredencial: TServidorCredFunc;
    FOnServidorDiag: TServidorDiagFunc;
    FOnSair: TSairProc;
    FOnDecodeAlimentar: TDecodeAlimentarFunc;
    FOnDecodeQuadro: TDecodeQuadroFunc;
    FOnDecodeReiniciar: TDecodeReiniciarProc;
    FLock: TCriticalSection;
    procedure Comando(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
                      AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirDaPasta(AResponseInfo: TIdHTTPResponseInfo;
                            const NomeArquivo, TipoConteudo: string);
    procedure ServirPagina(AResponseInfo: TIdHTTPResponseInfo;
                           const NomeArquivo: string);
    procedure ServirIcone(AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirJs(AResponseInfo: TIdHTTPResponseInfo;
                       const NomeArquivo: string);
    procedure ServirCameras(AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirConfig(AResponseInfo: TIdHTTPResponseInfo);
    procedure GravarConfig(ARequestInfo: TIdHTTPRequestInfo;
                           AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirLive(ARequestInfo: TIdHTTPRequestInfo;
                         AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirServidores(AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirSonda(ARequestInfo: TIdHTTPRequestInfo;
                          AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirSair(AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirDecodeAlimentar(ARequestInfo: TIdHTTPRequestInfo;
                                    AResponseInfo: TIdHTTPResponseInfo);
    procedure ServirDecodeQuadro(ARequestInfo: TIdHTTPRequestInfo;
                                 AResponseInfo: TIdHTTPResponseInfo);
    procedure GravarServidores(ARequestInfo: TIdHTTPRequestInfo;
                               AResponseInfo: TIdHTTPResponseInfo);
    function UpstreamDaRequisicao(ARequestInfo: TIdHTTPRequestInfo): string;
    procedure Encaminhar(ARequestInfo: TIdHTTPRequestInfo;
                         AResponseInfo: TIdHTTPResponseInfo);
    procedure ResponderErro(AResponseInfo: TIdHTTPResponseInfo;
                            Codigo: Integer; const Msg: string);
  public
    constructor Create(const ALogger: ILogger);
    destructor Destroy; override;
    // Sobe numa porta livre a partir de PortaBase. Devolve False e registra no
    // log se nenhuma serviu — o app continua funcionando sem a interface web.
    function Start(PortaBase: Integer = 8899): Boolean;
    procedure Stop;
    // Para onde encaminhar o que este servidor não responde. Pode mudar em
    // tempo de execução: o app descobre o servidor depois de conectar.
    procedure SetUpstream(const ABase: string);
    // A raiz que o WebView deve abrir. Vazia enquanto não subiu.
    function BaseUrl: string;
    function Ativo: Boolean;
    property OnCameras: TCameraListFunc read FOnCameras write FOnCameras;
    // O cadastro do aparelho. Sem estes dois, /api/app/cameras responde 503 e a
    // página esconde o cadastro -- o servidor não inventa configuração.
    property OnLerConfig: TConfigLerFunc read FOnLerConfig write FOnLerConfig;
    property OnGravarConfig: TConfigGravarFunc read FOnGravarConfig
                                               write FOnGravarConfig;
    // O ao vivo. Sem isto /api/live responde 503 e a pagina esconde o botao.
    property OnLive: TLiveLerFunc read FOnLive write FOnLive;
    // O cadastro de servidores. Sem eles a tela de servidores fica vazia e o
    // cliente so serve as cameras do proprio aparelho.
    property OnLerServidores: TServidoresLerFunc read FOnLerServidores
                                                 write FOnLerServidores;
    property OnGravarServidores: TServidoresGravarFunc read FOnGravarServidores
                                                       write FOnGravarServidores;
    property OnServidorUrl: TServidorUrlFunc read FOnServidorUrl
                                             write FOnServidorUrl;
    property OnServidorFalhou: TServidorFalhouProc read FOnServidorFalhou
                                                   write FOnServidorFalhou;
    property OnSondarServidor: TSondarServidorFunc read FOnSondarServidor
                                                   write FOnSondarServidor;
    property OnServidorCredencial: TServidorCredFunc read FOnServidorCredencial
                                                     write FOnServidorCredencial;
    // Como a pagina pede para o app fechar. Ver ServirSair.
    property OnSair: TSairProc read FOnSair write FOnSair;
    // A decodificacao nativa. Sem elas, /api/decode responde 503 e a pagina
    // sabe que este caminho nao existe aqui.
    property OnDecodeAlimentar: TDecodeAlimentarFunc read FOnDecodeAlimentar
                                                     write FOnDecodeAlimentar;
    property OnDecodeQuadro: TDecodeQuadroFunc read FOnDecodeQuadro
                                               write FOnDecodeQuadro;
    property OnDecodeReiniciar: TDecodeReiniciarProc read FOnDecodeReiniciar
                                                     write FOnDecodeReiniciar;
    property OnServidorDiag: TServidorDiagFunc read FOnServidorDiag
                                               write FOnServidorDiag;
  end;

implementation

uses
  // A MESMA leitura de arquivo que o vmsserver usa: uma pasta, dois
  // hospedeiros, e as mesmas páginas para os dois.
  Vms.Server.UiFiles,
  IdURI;

const
  // Quantas portas tentar a partir da base. Outro app pode estar na primeira, e
  // desistir na primeira tentativa deixaria o usuário sem interface por nada.
  TENTATIVAS = 12;
  // Teto do que se encaminha de uma vez. Miniatura e JSON cabem folgado; é uma
  // trava contra pedido absurdo, não um limite de projeto.
  MAX_ENCAMINHADO = 8 * 1024 * 1024;

// O parametro vindo da QUERY, e nao do corpo.
//
// Num POST o Indy pode preencher Params a partir do CORPO, quando ele parece um
// formulario -- e ai o `camera=` da URL simplesmente some. As rotas de
// decodificacao levam o fragmento no corpo e o nome na URL, entao aqui a query
// e lida direto, sem depender de como o corpo foi interpretado.
function ParamDaQuery(ARequestInfo: TIdHTTPRequestInfo;
  const Nome: string): string;
var
  Partes: TStringList;
begin
  Partes := TStringList.Create;
  try
    Partes.Delimiter := '&';
    Partes.StrictDelimiter := True;
    Partes.DelimitedText := ARequestInfo.QueryParams;
    Result := TIdURI.URLDecode(Partes.Values[Nome]);
  finally
    Partes.Free;
  end;
end;

constructor TLocalServer.Create(const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
end;

destructor TLocalServer.Destroy;
begin
  Stop;
  FLock.Free;
  inherited;
end;

function TLocalServer.Ativo: Boolean;
begin
  Result := (FHttp <> nil) and FHttp.Active;
end;

function TLocalServer.BaseUrl: string;
begin
  if Ativo then
    Result := Format('http://127.0.0.1:%d', [FPorta])
  else
    Result := '';
end;

procedure TLocalServer.SetUpstream(const ABase: string);
begin
  FLock.Enter;
  try
    FUpstream := ABase.TrimRight(['/']);
  finally
    FLock.Leave;
  end;
end;

function TLocalServer.Start(PortaBase: Integer): Boolean;
var
  I: Integer;
  Bind: TIdSocketHandle;
begin
  Result := Ativo;
  if Result then Exit;

  for I := 0 to TENTATIVAS - 1 do
  begin
    FPorta := PortaBase + I;
    FHttp := TIdHTTPServer.Create(nil);
    try
      FHttp.Bindings.Clear;
      Bind := FHttp.Bindings.Add;
      // SÓ o loopback. Ver a nota de segurança no cabeçalho: é o alcance que
      // faz as vezes de autenticação.
      Bind.IP := '127.0.0.1';
      Bind.Port := FPorta;
      FHttp.OnCommandGet := Comando;
      FHttp.KeepAlive := True;
      FHttp.Active := True;
      FLogger.Info('local', Format('interface local em %s', [BaseUrl]));
      // A interface pode vir de tres lugares (ver Vms.Server.UiFiles). Dizer
      // qual na subida evita a confusao de editar um arquivo e nao entender
      // por que a tela mudou -- ou por que nao mudou.
      if not UiDirAtivo then
        FLogger.Error('local', 'sem a pasta da interface: ' + UiExplicacao +
                               ' -- as telas nao vao abrir')
      else if UiFaltando <> '' then
        FLogger.Warn('local', 'faltam na interface (' + UiExplicacao + '): ' +
                              UiFaltando)
      else
        FLogger.Info('local', 'interface em ' + UiExplicacao);
      Exit(True);
    except
      on E: Exception do
      begin
        // Porta ocupada é o caso comum, e não é erro: tenta a próxima.
        FreeAndNil(FHttp);
        if I = TENTATIVAS - 1 then
          FLogger.Warn('local', Format(
            'nao consegui abrir porta entre %d e %d: %s',
            [PortaBase, PortaBase + TENTATIVAS - 1, E.Message]));
      end;
    end;
  end;
  Result := False;
end;

procedure TLocalServer.Stop;
begin
  if FHttp = nil then Exit;
  try
    FHttp.Active := False;
  except
    // Parar não pode derrubar o encerramento do app.
  end;
  FreeAndNil(FHttp);
end;

procedure TLocalServer.ResponderErro(AResponseInfo: TIdHTTPResponseInfo;
  Codigo: Integer; const Msg: string);
var
  Obj: TJSONObject;
begin
  AResponseInfo.ResponseNo := Codigo;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.CharSet := 'utf-8';
  // Pelo TJSONObject, e nao concatenando: mensagem de excecao pode trazer aspas
  // e barras, que quebrariam o JSON montado a mao.
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('error', Msg);
    AResponseInfo.ContentText := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

// Um arquivo da pasta `ui`, ou 404 dizendo qual falta e onde era esperado.
//
// Não há cópia embutida para cair: a pasta É a interface. Uma tela em branco
// sem explicação seria o pior desfecho, ainda mais no aparelho, onde não se
// olha a pasta com o dedo.
procedure TLocalServer.ServirDaPasta(AResponseInfo: TIdHTTPResponseInfo;
  const NomeArquivo, TipoConteudo: string);
var
  Texto: string;
begin
  Texto := UiTexto(NomeArquivo);
  if Texto = '' then
  begin
    ResponderErro(AResponseInfo, 404,
                  'nao achei ' + NomeArquivo + ' em ' + UiDir);
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := TipoConteudo;
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentText := Texto;
  // Versão velha presa no WebView seria confusão pura: o arquivo pode ter
  // mudado desde o último pedido.
  AResponseInfo.CacheControl := 'no-store';
end;

procedure TLocalServer.ServirPagina(AResponseInfo: TIdHTTPResponseInfo;
  const NomeArquivo: string);
begin
  ServirDaPasta(AResponseInfo, NomeArquivo, 'text/html; charset=utf-8');
end;

// O cadastro deste aparelho, como texto JSON. Não passa pelo vmsserver: são as
// câmeras que ESTE app conhece, guardadas no arquivo dele.
procedure TLocalServer.ServirConfig(AResponseInfo: TIdHTTPResponseInfo);
begin
  if not Assigned(FOnLerConfig) then
  begin
    ResponderErro(AResponseInfo, 503, 'cadastro indisponivel');
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentText := FOnLerConfig();
  AResponseInfo.CacheControl := 'no-store';
end;

// Substitui o cadastro inteiro. Lista completa, e não operações por câmera:
// a página já tem a lista na mão, e um POST só evita ter de inventar
// identidade estável para câmera que o usuário pode renomear.
//
// Devolve o erro de validação do app quando há um, para a página mostrar o
// motivo em vez de um 400 mudo.
procedure TLocalServer.GravarConfig(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Corpo, Erro: string;
  Leitor: TStreamReader;
begin
  if not Assigned(FOnGravarConfig) then
  begin
    ResponderErro(AResponseInfo, 503, 'cadastro indisponivel');
    Exit;
  end;

  Corpo := '';
  if ARequestInfo.PostStream <> nil then
  begin
    ARequestInfo.PostStream.Position := 0;
    Leitor := TStreamReader.Create(ARequestInfo.PostStream, TEncoding.UTF8);
    try
      Corpo := Leitor.ReadToEnd;
    finally
      Leitor.Free;
    end;
  end
  else
    Corpo := ARequestInfo.UnparsedParams;

  if Trim(Corpo) = '' then
  begin
    ResponderErro(AResponseInfo, 400, 'corpo vazio');
    Exit;
  end;

  // A gravação mexe na configuração e reconecta câmera: quem faz isso é o
  // formulário, na thread dele. Esta aqui é uma thread do Indy.
  Erro := FOnGravarConfig(Corpo);
  if Erro <> '' then
  begin
    ResponderErro(AResponseInfo, 400, Erro);
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.ContentText := '{"ok":true}';
end;

// Base64 numa linha só.
//
// O TNetEncoding.Base64 quebra a saída a cada 76 colunas, que é o certo para
// corpo MIME e o errado para cabeçalho: uma senha longa viraria duas linhas e o
// cabeçalho sairia partido ao meio.
function Base64Simples(const S: string): string;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(S));
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
end;

procedure TLocalServer.ServirSonda(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Nome: string;
begin
  if not Assigned(FOnSondarServidor) then
  begin
    ResponderErro(AResponseInfo, 503, 'sem cadastro de servidores');
    Exit;
  end;
  Nome := Trim(ARequestInfo.Params.Values['server']);
  if Nome = '' then
  begin
    ResponderErro(AResponseInfo, 400, 'informe o servidor');
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentText := FOnSondarServidor(Nome);
  AResponseInfo.CacheControl := 'no-store';
end;

// O voltar chegou na pagina e ela ja estava na raiz: nao ha para onde voltar
// dentro dela, entao quem sai e o app.
//
// Por HTTP, e nao por navegacao. O caminho antigo era navegar o WebView para um
// esquema inventado (vmsapp://sair) e interceptar: so que o FMX nunca cancela a
// navegacao -- shouldOverrideUrlLoading devolve False fixo, em
// FMX.WebBrowser.Android -- entao o WebView REALMENTE tentava abrir aquilo,
// falhava com ERR_UNKNOWN_URL_SCHEME e pintava a pagina de erro dele: branca,
// com a URL escrita. Era isso que aparecia por um instante quando o app fechava.
//
// Quem responde nao pode fechar o app aqui dentro: isto roda numa thread do
// Indy, e encerrar o formulario derruba o proprio servidor que esta
// respondendo. Por isso o evento so agenda (ver Inicio.SairPelaPagina).
procedure TLocalServer.ServirSair(AResponseInfo: TIdHTTPResponseInfo);
begin
  if not Assigned(FOnSair) then
  begin
    ResponderErro(AResponseInfo, 503, 'sem quem feche');
    Exit;
  end;
  FOnSair();
  AResponseInfo.ResponseNo := 204;
  AResponseInfo.ContentText := '';
end;

// A pagina entrega um fragmento .vms para o lado nativo decodificar.
//
// POST com o corpo em bytes -- o MESMO que /api/media devolveu para ela. Nao se
// pede aqui de novo ao servidor: o download ja aconteceu, e repeti-lo dobraria o
// trafego e duplicaria a logica de cursor que a pagina ja tem.
procedure TLocalServer.ServirDecodeAlimentar(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Camera: string;
  Dados: TBytes;
  Pend: Integer;
begin
  if not Assigned(FOnDecodeAlimentar) then
  begin
    ResponderErro(AResponseInfo, 503, 'sem decodificacao nativa aqui');
    Exit;
  end;
  Camera := ParamDaQuery(ARequestInfo, 'camera');
  if Trim(Camera) = '' then
  begin
    ResponderErro(AResponseInfo, 400, 'informe camera');
    Exit;
  end;
  if SameText(ParamDaQuery(ARequestInfo, 'reset'), '1') and
     Assigned(FOnDecodeReiniciar) then
    FOnDecodeReiniciar(Camera);

  Dados := nil;
  if ARequestInfo.PostStream <> nil then
  begin
    ARequestInfo.PostStream.Position := 0;
    SetLength(Dados, ARequestInfo.PostStream.Size);
    if Length(Dados) > 0 then
      ARequestInfo.PostStream.ReadBuffer(Dados[0], Length(Dados));
  end;

  Pend := FOnDecodeAlimentar(Camera, Dados);
  if Pend < 0 then
  begin
    ResponderErro(AResponseInfo, 415, 'fragmento ilegivel');
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.ContentText := Format('{"pendentes":%d}', [Pend]);
end;

// O proximo quadro decodificado, em JPEG.
//
// Um de cada vez, e nao "o mais recente": quem tem o relogio da reproducao e a
// pagina. Ver o cabecalho de VMS.App.Decodificacao.
procedure TLocalServer.ServirDecodeQuadro(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Camera: string;
  Jpeg: TBytes;
  Ms: Int64;
  Fluxo: TMemoryStream;
begin
  if not Assigned(FOnDecodeQuadro) then
  begin
    ResponderErro(AResponseInfo, 503, 'sem decodificacao nativa aqui');
    Exit;
  end;
  Camera := ParamDaQuery(ARequestInfo, 'camera');
  if Trim(Camera) = '' then
  begin
    ResponderErro(AResponseInfo, 400, 'informe camera');
    Exit;
  end;
  if not FOnDecodeQuadro(Camera, Jpeg, Ms) then
  begin
    // 204: nao ha quadro AGORA. Nao e erro -- a pagina volta a pedir depois de
    // mandar mais um fragmento.
    AResponseInfo.ResponseNo := 204;
    AResponseInfo.ContentText := '';
    Exit;
  end;
  Fluxo := TMemoryStream.Create;
  Fluxo.WriteBuffer(Jpeg[0], Length(Jpeg));
  Fluxo.Position := 0;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'image/jpeg';
  AResponseInfo.CustomHeaders.AddValue('X-Vms-Frame-Ms', IntToStr(Ms));
  AResponseInfo.ContentStream := Fluxo;   // o Indy libera
end;

procedure TLocalServer.ServirServidores(AResponseInfo: TIdHTTPResponseInfo);
begin
  if not Assigned(FOnLerServidores) then
  begin
    ResponderErro(AResponseInfo, 503, 'cadastro indisponivel');
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentText := FOnLerServidores();
  AResponseInfo.CacheControl := 'no-store';
end;

procedure TLocalServer.GravarServidores(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Corpo, Erro: string;
  Leitor: TStreamReader;
begin
  if not Assigned(FOnGravarServidores) then
  begin
    ResponderErro(AResponseInfo, 503, 'cadastro indisponivel');
    Exit;
  end;
  Corpo := '';
  if ARequestInfo.PostStream <> nil then
  begin
    ARequestInfo.PostStream.Position := 0;
    Leitor := TStreamReader.Create(ARequestInfo.PostStream, TEncoding.UTF8);
    try
      Corpo := Leitor.ReadToEnd;
    finally
      Leitor.Free;
    end;
  end
  else
    Corpo := ARequestInfo.UnparsedParams;

  if Trim(Corpo) = '' then
  begin
    ResponderErro(AResponseInfo, 400, 'corpo vazio');
    Exit;
  end;
  Erro := FOnGravarServidores(Corpo);
  if Erro <> '' then
  begin
    ResponderErro(AResponseInfo, 400, Erro);
    Exit;
  end;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.ContentText := '{"ok":true}';
end;

// Para onde encaminhar ESTA requisicao.
//
// O parametro `server` manda: com ele, vale o servidor cadastrado com aquele
// nome; sem ele, vale o upstream corrente (o que a reproducao configurou). Ter
// os dois caminhos e o que permite a mesma pagina falar com varios servidores
// sem inventar um estado global de "servidor atual" no lado do Delphi.
function TLocalServer.UpstreamDaRequisicao(
  ARequestInfo: TIdHTTPRequestInfo): string;
var
  Nome: string;
begin
  Nome := Trim(ARequestInfo.Params.Values['server']);
  if (Nome <> '') and Assigned(FOnServidorUrl) then
    Exit(FOnServidorUrl(Nome).TrimRight(['/']));

  FLock.Enter;
  try
    Result := FUpstream;
  finally
    FLock.Leave;
  end;
end;

// O ao vivo da camera, no MESMO formato .vms da gravacao -- cabecalho mais
// blocos. O player em HTML nao distingue: muda so a rota que respondeu, e o
// cursor, que aqui e um numero de bloco em vez do cursor opaco do /api/media.
//
// Nao bloqueia esperando midia. Sem nada novo, responde 204 e a pagina volta a
// perguntar; segurar a thread do Indy num long poll gastaria uma conexao por
// espectador para economizar uma ida de rede.
procedure TLocalServer.ServirLive(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Camera: string;
  Cursor, Prox: Cardinal;
  Dados: TBytes;
  Fluxo: TMemoryStream;
begin
  if not Assigned(FOnLive) then
  begin
    ResponderErro(AResponseInfo, 503, 'ao vivo indisponivel');
    Exit;
  end;

  Camera := ARequestInfo.Params.Values['camera'];
  if Trim(Camera) = '' then
  begin
    ResponderErro(AResponseInfo, 400, 'informe camera');
    Exit;
  end;
  Cursor := Cardinal(StrToInt64Def(ARequestInfo.Params.Values['cursor'], 0));

  if not FOnLive(Camera, Cursor, Dados, Prox) then
  begin
    // 204: nada novo AINDA. O cursor volta mesmo assim, porque ele pode ter
    // sido reposicionado (o leitor ficou para tras e o anel ja descartou).
    AResponseInfo.ResponseNo := 204;
    AResponseInfo.CustomHeaders.AddValue('X-Vms-Cursor', UIntToStr(Prox));
    AResponseInfo.ContentText := '';
    Exit;
  end;

  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'application/x-vms';
  AResponseInfo.CustomHeaders.AddValue('X-Vms-Cursor', UIntToStr(Prox));
  AResponseInfo.CacheControl := 'no-store';
  Fluxo := TMemoryStream.Create;
  if Length(Dados) > 0 then
    Fluxo.WriteBuffer(Dados[0], Length(Dados));
  Fluxo.Position := 0;
  AResponseInfo.ContentStream := Fluxo;   // o Indy libera depois de enviar
end;

procedure TLocalServer.ServirJs(AResponseInfo: TIdHTTPResponseInfo;
  const NomeArquivo: string);
begin
  ServirDaPasta(AResponseInfo, NomeArquivo,
                'application/javascript; charset=utf-8');
end;

procedure TLocalServer.ServirIcone(AResponseInfo: TIdHTTPResponseInfo);
begin
  ServirDaPasta(AResponseInfo, 'favicon.svg', 'image/svg+xml');
  // O ícone não muda entre versões; deixar o navegador guardá-lo evita um
  // pedido por aba aberta.
  if AResponseInfo.ResponseNo = 200 then
    AResponseInfo.CacheControl := 'public, max-age=86400';
end;

procedure TLocalServer.ServirCameras(AResponseInfo: TIdHTTPResponseInfo);
var
  Root: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  Nomes: TArray<string>;
  I: Integer;
begin
  Nomes := nil;
  if Assigned(FOnCameras) then
    Nomes := FOnCameras();

  Root := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    Root.AddPair('cameras', Arr);
    for I := 0 to High(Nomes) do
    begin
      Item := TJSONObject.Create;
      Item.AddPair('name', Nomes[I]);
      Arr.AddElement(Item);
    end;
    AResponseInfo.ResponseNo := 200;
    AResponseInfo.ContentType := 'application/json; charset=utf-8';
    AResponseInfo.CharSet := 'utf-8';
    AResponseInfo.ContentText := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

// O que não é nosso vai para o vmsserver. A página não sabe que isto acontece,
// e é justamente esse o objetivo: um endereço só, e o Delphi decide a origem.
procedure TLocalServer.Encaminhar(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Base, Url, Nome, Usuario, Senha, Erro, Rota: string;
  Cli: THTTPClient;
  Resp: IHTTPResponse;
  Buf, Envio: TMemoryStream;
  Par: TNameValuePair;
  Cabecalhos: TNetHeaders;
begin
  Rota := ARequestInfo.Document;
  Base := UpstreamDaRequisicao(ARequestInfo);
  if Base = '' then
  begin
    // Com o nome pedido e o que o cadastro tem, a mensagem separa as tres
    // causas que antes ficavam iguais: pedido sem `server`, cadastro vazio, e
    // nome que nao bateu com nenhum cadastrado.
    Nome := Trim(ARequestInfo.Params.Values['server']);
    if Nome = '' then
      Erro := 'a requisicao nao disse a qual servidor se refere'
    else
      Erro := Format('nao achei o servidor "%s"', [Nome]);
    if Assigned(FOnServidorDiag) then
      Erro := Erro + '; ' + FOnServidorDiag();
    FLogger.Warn('local', Rota + ': ' + Erro);
    ResponderErro(AResponseInfo, 503, Erro);
    Exit;
  end;

  Url := Base + ARequestInfo.URI;
  if ARequestInfo.QueryParams <> '' then
    Url := Url + '?' + ARequestInfo.QueryParams;

  Buf := TMemoryStream.Create;
  Envio := nil;
  Cli := THTTPClient.Create;
  try
    Cli.ConnectionTimeout := 8000;
    Cli.ResponseTimeout := 30000;

    // Basic direto, sem esperar o 401.
    //
    // O servidor agora pede credencial, e o app não é navegador: não tem cookie
    // nem sessão para manter. Mandar a autorização em toda requisição custa uns
    // bytes e evita o par 401+repetição em cada uma delas -- e são muitas, cada
    // fragmento de vídeo é uma.
    Cabecalhos := nil;
    Nome := Trim(ARequestInfo.Params.Values['server']);
    if (Nome <> '') and Assigned(FOnServidorCredencial) and
       FOnServidorCredencial(Nome, Usuario, Senha) then
      Cabecalhos := [TNetHeader.Create('Authorization',
                                       'Basic ' + Base64Simples(Usuario + ':' + Senha))];

    try
      // POST vai adiante com o corpo. É por ele que a tela de parâmetros grava
      // no servidor: encaminhar só GET faria a leitura funcionar e a escrita
      // sumir sem dizer por quê.
      if SameText(ARequestInfo.Command, 'POST') then
      begin
        Envio := TMemoryStream.Create;
        if ARequestInfo.PostStream <> nil then
        begin
          ARequestInfo.PostStream.Position := 0;
          Envio.CopyFrom(ARequestInfo.PostStream, 0);
          Envio.Position := 0;
        end;
        Cli.ContentType := ARequestInfo.ContentType;
        Resp := Cli.Post(Url, Envio, Buf, Cabecalhos);
      end
      else
        Resp := Cli.Get(Url, Buf, Cabecalhos);
    except
      on E: Exception do
      begin
        // Nao foi erro DO servidor: foi nao chegar nele. A rota escolhida pode
        // ter deixado de existir (o aparelho saiu de casa), entao avisa para a
        // proxima requisicao escolher de novo -- e ai a rota de tailnet entra.
        if Assigned(FOnServidorFalhou) then
          FOnServidorFalhou(Trim(ARequestInfo.Params.Values['server']));
        ResponderErro(AResponseInfo, 502, E.Message);
        Exit;
      end;
    end;

    if Buf.Size > MAX_ENCAMINHADO then
    begin
      ResponderErro(AResponseInfo, 502, 'resposta grande demais');
      Exit;
    end;

    AResponseInfo.ResponseNo := Resp.StatusCode;
    AResponseInfo.ContentType := Resp.HeaderValue['Content-Type'];

    // Os X-Vms-* voltam JUNTO. E neles que vem o cursor de continuacao, o
    // instante do proximo fragmento e a marca de descontinuidade -- sem eles a
    // pagina recebe o video e nao tem como pedir o pedaco seguinte.
    //
    // Copiar so o Content-Type foi o primeiro jeito, e estava errado: o
    // encaminhamento tem de ser transparente para o que a pagina precisa ler.
    for Par in Resp.Headers do
      if Par.Name.StartsWith('X-Vms-', True) then
        AResponseInfo.CustomHeaders.AddValue(Par.Name, Par.Value);

    Buf.Position := 0;
    // O stream passa a ser do AResponseInfo, que o libera depois de enviar.
    AResponseInfo.ContentStream := Buf;
    Buf := nil;
  finally
    Buf.Free;
    Envio.Free;
    Cli.Free;
  end;
end;

// Uma thread por conexão, cortesia do Indy: NADA aqui pode tocar a interface.
// O que precisa chegar à UI passa pelos eventos do app, nunca daqui direto.
procedure TLocalServer.Comando(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Caminho: string;
begin
  Caminho := LowerCase(ARequestInfo.Document);

  // no-store em TUDO, antes de rotear.
  //
  // Só as páginas diziam isso; as respostas de /api/ saíam sem cabeçalho de
  // cache nenhum, e aí o WebView decide por conta própria -- e decidiu guardar.
  // Um 503 antigo de "sem servidor configurado" ficou preso no cache dele e
  // passou a ser repetido SEM tocar no servidor: a tela mostrava o erro, o log
  // do Delphi não registrava nada, e limpar o cadastro não adiantava porque a
  // requisição nunca chegava aqui.
  //
  // Nada daqui é cacheável por natureza: é estado que muda (câmeras ao vivo,
  // gravação crescendo, cadastro editável). Quem tem exceção -- o ícone --
  // sobrescreve depois, porque isto roda antes do roteamento.
  AResponseInfo.CacheControl := 'no-store';

  // Uma linha por requisição, em Debug.
  //
  // A ausência dela é informação: foi olhando um log vazio, com a tela
  // mostrando erro, que ficou claro que a resposta vinha do cache do WebView e
  // não do servidor. Sem este registro não dava para distinguir "respondi isso"
  // de "nem me perguntaram".
  FLogger.Debug('local', ARequestInfo.Command + ' ' + ARequestInfo.URI);

  try
    // A raiz e a casca do app: e ela que o WebView abre.
    if (Caminho = '/') or (Caminho = '/ui/app') then
      ServirPagina(AResponseInfo, 'app-ui.html')
    else if Caminho = '/ui/events' then
      ServirPagina(AResponseInfo, 'events-ui.html')
    // A sintonia do movimento. A página é a mesma do vmsserver, e o ensaio dela
    // (/api/motion/probe) é encaminhado para lá: quem tem gravacao e detector e
    // o servidor, nao o aparelho.
    else if Caminho = '/ui/motion' then
      ServirPagina(AResponseInfo, 'motion-ui.html')
    else if Caminho = '/ui/player' then
      ServirPagina(AResponseInfo, 'player-ui.html')
    else if Caminho = '/ui/vmsreader.js' then
      ServirJs(AResponseInfo, 'vmsreader.js')
    else if Caminho = '/ui/player.js' then
      ServirJs(AResponseInfo, 'player.js')
    // O icone da aba. As duas rotas devolvem o mesmo SVG: o <link> da pagina
    // pede a .svg, e a .ico e a que o navegador busca por conta propria.
    else if (Caminho = '/favicon.svg') or (Caminho = '/favicon.ico') then
      ServirIcone(AResponseInfo)
    // COM escopo, a lista e do servidor e tem de ser encaminhada; sem escopo,
    // sao as cameras deste aparelho. Responder sempre daqui fazia "entrar num
    // servidor" mostrar as cameras do celular -- o que passou despercebido
    // porque os nomes coincidiam.
    else if (Caminho = '/api/cameras') and
            (Trim(ARequestInfo.Params.Values['server']) = '') then
      ServirCameras(AResponseInfo)
    // A sondagem das rotas de um servidor: e o que a tela de cadastro mostra
    // para dizer qual endereco responde DAQUI, agora.
    else if Caminho = '/api/app/route' then
      ServirSonda(ARequestInfo, AResponseInfo)
    else if Caminho = '/api/app/sair' then
      ServirSair(AResponseInfo)
    // O caminho de quem nao consegue decodificar na pagina: ela manda o
    // fragmento e pede quadro por quadro, ja em JPEG.
    else if Caminho = '/api/decode' then
      ServirDecodeAlimentar(ARequestInfo, AResponseInfo)
    else if Caminho = '/api/frame' then
      ServirDecodeQuadro(ARequestInfo, AResponseInfo)
    else if Caminho = '/api/app/servers' then
    begin
      if SameText(ARequestInfo.Command, 'POST') then
        GravarServidores(ARequestInfo, AResponseInfo)
      else
        ServirServidores(AResponseInfo);
    end
    // Mesmo caso do /api/cameras: o anel deste aparelho só sabe das câmeras
    // deste aparelho. Dentro de um servidor o ao vivo é o dele -- lá o /api/live
    // segue a cauda do que está sendo gravado -- e responder daqui devolveria
    // vídeo de outra câmera, ou vídeo nenhum.
    else if (Caminho = '/api/live') and
            (Trim(ARequestInfo.Params.Values['server']) = '') then
      ServirLive(ARequestInfo, AResponseInfo)
    else if Caminho = '/api/app/cameras' then
    begin
      if SameText(ARequestInfo.Command, 'POST') then
        GravarConfig(ARequestInfo, AResponseInfo)
      else
        ServirConfig(AResponseInfo);
    end
    else if Caminho.StartsWith('/api/') then
      Encaminhar(ARequestInfo, AResponseInfo)
    else
      ResponderErro(AResponseInfo, 404, 'nao existe aqui');
  except
    on E: Exception do
    begin
      // Exceção que escape daqui derruba a thread do Indy calada, e o WebView
      // fica esperando para sempre. Melhor um 500 legível.
      FLogger.Warn('local', Format('%s: %s', [Caminho, E.Message]));
      ResponderErro(AResponseInfo, 500, E.Message);
    end;
  end;
end;

end.
