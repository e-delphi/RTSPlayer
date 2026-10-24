unit Vms.Onvif.Client;

// Cliente ONVIF, do tamanho que a PTZ pede.
//
// ONVIF e SOAP sobre HTTP. Nao ha WSDL gerado aqui, nem biblioteca de terceiro:
// as quatro chamadas que a PTZ usa cabem em texto montado a mao, e o que volta
// se le por marcacao. Gerar stub de WSDL para isto traria um megabyte de codigo
// para extrair tres cadeias de caracteres.
//
// A sequencia e sempre a mesma:
//
//   GetSystemDateAndTime  ->  o relogio da camera (SEM credencial)
//   GetCapabilities       ->  onde ficam os servicos de midia e de PTZ
//   GetProfiles           ->  o token do perfil, que a PTZ exige em todo comando
//   ContinuousMove/Stop   ->  o comando em si
//
// As tres primeiras sao caras e nao mudam: ficam guardadas depois da primeira
// vez (ver Preparado).
//
// ## O relogio, que e onde a maioria das integracoes morre
//
// A autenticacao da ONVIF e WS-Security UsernameToken com digest:
//
//   digest = base64(sha1(nonce + created + senha))
//
// `created` e um instante, e a camera RECUSA um token cujo instante esteja longe
// do relogio DELA -- costuma tolerar poucos segundos. Camera com relogio
// adiantado ou atrasado, que e a regra em equipamento sem NTP, entao recusa tudo
// com "sender not authorized", e a mensagem nao diz nada sobre hora. Por isso o
// GetSystemDateAndTime vem antes de qualquer coisa: dele sai a diferenca, e o
// `created` de cada token e carimbado no relogio da CAMERA, e nao no nosso.
//
// ## Nao ha descoberta por multicast aqui
//
// A norma tambem preve WS-Discovery, que e um probe UDP em 239.255.255.250:3702.
// Nao entra: descoberta acha aparelho na mesma rede fisica do servidor, e a
// pergunta que este codigo responde e outra -- "como falo com ESTA camera, que
// ja esta cadastrada". O endereco vem do cadastro; ver EnderecoPadrao.

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.StrUtils,
  System.Hash,
  System.NetEncoding,
  System.Net.HttpClient,
  System.Net.URLClient,
  VMS.Domain.Logging;

type
  // Velocidades normalizadas, -1..1 em pan e tilt, -1..1 em zoom. E a escala da
  // propria norma, entao nao ha conversao: o que se pede e o que vai no XML.
  TOnvifMove = record
    Pan, Tilt, Zoom: Double;
    class function Criar(APan, ATilt, AZoom: Double): TOnvifMove; static;
    function Parado: Boolean;
  end;

  TOnvifPreset = record
    Token: string;
    Nome: string;
  end;

  TOnvifClient = class
  strict private
    FXAddr: string;        // o servico de dispositivo
    FUser, FPass: string;
    FLogger: ILogger;
    FTag: string;

    FPreparado: Boolean;
    FPtzUrl: string;
    FMediaUrl: string;
    FPerfil: string;       // token do perfil de midia
    FDeltaMs: Int64;       // relogio da camera menos o nosso
    FMotivo: string;
    FTempoMs: Integer;
    // A camera respondeu ONVIF, mesmo que sem PTZ. E o que separa "nao ha nada
    // nesta porta" de "ha camera aqui, mas ela nao se move" -- duas respostas
    // diferentes para quem esta procurando.
    FRespondeu: Boolean;
    // Operacoes que ESTA camera recusou uma vez. Nao e cache de resultado: e a
    // memoria de que perguntar de novo so gasta o tempo de espera.
    //
    // Medido na Ayla: Stop e GetPresets fecham a conexao sem resposta HTTP, em
    // 220 ms cada. No solta do botao esses 220 ms saem na frente do movimento
    // de velocidade zero que de fato para a camera, e ela gira sozinha esse
    // tanto depois que o dedo saiu.
    //
    // Vale enquanto este objeto viver -- ate o cadastro da camera mudar ou o
    // servidor reiniciar. Firmware novo volta a ser tentado ali, e nao ha
    // ganho em ser mais esperto que isso.
    FSemStop: Boolean;
    FSemPresets: Boolean;

    function Post(const Url, Corpo: string; out Resposta: string): Boolean;
    function Chamar(const Url, Acao, CorpoInterno: string;
                    out Resposta: string): Boolean;
    function Cabecalho: string;
    function AcertarRelogio: Boolean;
    function LerCapacidades: Boolean;
    function LerPerfil: Boolean;
  public
    // ATempoMs governa cada chamada. O padrao serve para conversar com uma
    // camera conhecida; a procura usa um valor curto, porque la a maioria das
    // portas nao tem ninguem e esperar 8 s por porta somaria mais de um minuto.
    constructor Create(const AXAddr, AUser, APass: string;
                       const ALogger: ILogger; const ATag: string = 'onvif';
                       ATempoMs: Integer = 0);

    // Faz as tres chamadas de preparacao, uma vez. Chamado sozinho pelos
    // comandos; existe em separado para quem quiser testar o cadastro.
    function Preparar: Boolean;
    function MoverContinuo(const M: TOnvifMove): Boolean;
    function Parar: Boolean;
    function LerPresets(out Lista: TArray<TOnvifPreset>): Boolean;
    function IrParaPreset(const Token: string): Boolean;
    // Guarda a posicao de AGORA. Token vazio cria uma posicao nova; token
    // preenchido sobrescreve aquela. TokenSalvo volta com o que a camera
    // usou, que e o unico jeito de saber o nome da recem-criada.
    function GuardarPreset(const Token, Nome: string;
                           out TokenSalvo: string): Boolean;
    function ApagarPreset(const Token: string): Boolean;

    // Por que a ultima chamada falhou. Vale ate a proxima.
    property Motivo: string read FMotivo;
    property TemPtz: Boolean read FPreparado;
    property RespondeOnvif: Boolean read FRespondeu;
    property PtzUrl: string read FPtzUrl;
    property Perfil: string read FPerfil;
  end;

  // Uma porta que respondeu alguma coisa de ONVIF.
  TOnvifAchado = record
    Porta: Integer;
    TemPtz: Boolean;
    Servico: string;   // o endereco do servico de PTZ, quando ha
  end;

// O palpite de endereco a partir da URL de midia da camera: mesma maquina, HTTP,
// caminho padrao da norma. Serve de padrao quando o cadastro nao diz outro --
// acerta na maioria das cameras, e as que fogem disso ganham o endereco escrito
// a mao (ver a chave ptz.<camera>.xaddr).
function EnderecoPadrao(const UrlDeMidia: string): string;

// O endereco do servico, a partir do que o cadastro escreveu.
//
// Aceita as tres formas que uma pessoa escreve: so o host, host com porta, ou a
// URL inteira. Porque a porta NAO se adivinha -- a norma sugere a 80, mas a
// Ayla atende na 5000, e nada na URL de midia dela diz isso. Vazio devolve o
// palpite do EnderecoPadrao, que e o que serve para camera comum.
function EnderecoOnvif(const Escrito, UrlDeMidia: string): string;

// O endereco anunciado, mas no host por onde a camera foi ALCANCADA.
//
// Camera atras de encaminhamento de porta anuncia o IP da rede dela, que daqui
// nao se alcanca: a Ayla responde em 192.168.100.2:5000 e se anuncia como
// 192.168.0.6:5000. Seguir o anuncio ao pe da letra seria falar com uma maquina
// que nao existe deste lado. A porta anunciada e mantida, porque ha camera que
// legitimamente poe um servico em porta propria.
function MesmoHostQue(const Anunciado, Base: string): string;

// Extrai o conteudo do primeiro elemento com este nome local, ignorando prefixo
// de namespace. Publica para o teste alcancar.
function ValorDaTag(const Xml, NomeLocal: string): string;
// O mesmo, mas dentro do primeiro elemento `Dentro`. E o que separa o XAddr do
// PTZ do XAddr da Midia, que tem o mesmo nome local.
function ValorDentroDe(const Xml, Dentro, NomeLocal: string): string;
// base64(sha1(nonce + created + senha)), o digest do UsernameToken.
function DigestDeSenha(const Nonce: TBytes; const Created, Senha: string): string;

// As portas em que estas cameras poem o ONVIF, na ordem em que vale tentar.
//
// A norma nao fixa porta. A 80 e a suposicao de todo mundo, mas destas tres
// cameras nenhuma atende nela: a Ayla atende na 5000. A lista sai do que se
// encontra em camera barata; ela e curta de proposito, porque cada porta
// custa uma espera.
function PortasComunsOnvif: TArray<Integer>;

// Procura o servico ONVIF no host, nas portas acima. Devolve o que respondeu,
// na ordem em que foi encontrado -- a primeira COM PTZ e a que interessa.
function ProcurarOnvif(const Host, Usuario, Senha: string;
                       const Logger: ILogger;
                       TempoMs: Integer = 1500): TArray<TOnvifAchado>;

// So o host de uma URL, sem esquema, sem credencial, sem porta e sem caminho.
function HostDaUrl(const Url: string): string;

implementation

const
  NS_ENV = 'http://www.w3.org/2003/05/soap-envelope';
  NS_DEV = 'http://www.onvif.org/ver10/device/wsdl';
  NS_MEDIA = 'http://www.onvif.org/ver10/media/wsdl';
  NS_PTZ = 'http://www.onvif.org/ver20/ptz/wsdl';
  NS_SCH = 'http://www.onvif.org/ver10/schema';
  NS_WSSE = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
  NS_WSU = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
  TIPO_NONCE = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary';
  TIPO_DIGEST = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest';

  TEMPO_MS = 8000;
  // Por quanto tempo a camera deve seguir se movendo sem receber outra ordem.
  //
  // Sem este campo a camera usa o padrao dela, e nesta familia o padrao e
  // curto: segurar o botao dava um passo so. O valor acompanha o teto da tela,
  // que desiste em 8 s -- os dois lados do mesmo limite. E tambem o freio para
  // o caso de a parada se perder no caminho.
  //
  // Formato da norma (ISO 8601 de duracao): PT8S sao oito segundos.
  DURACAO = 'PT8S';

{ funcoes soltas }

function EnderecoPadrao(const UrlDeMidia: string): string;
var
  S, Host: string;
  P: Integer;
begin
  Result := '';
  S := Trim(UrlDeMidia);
  P := Pos('://', S);
  if P > 0 then Delete(S, 1, P + 2);
  // Credencial embutida na URL nao faz parte do host.
  P := Pos('@', S);
  if P > 0 then Delete(S, 1, P);
  P := Pos('/', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  // A porta da midia nao serve ao ONVIF: 554 e do RTSP, 34567 e do DVRIP. O
  // servico de dispositivo mora no HTTP da camera, que e onde a norma o poe.
  P := Pos(':', S);
  if P > 0 then Host := Copy(S, 1, P - 1) else Host := S;
  if Host = '' then Exit;
  Result := 'http://' + Host + '/onvif/device_service';
end;

function HostDaUrl(const Url: string): string;
var
  S: string;
  P: Integer;
begin
  S := Trim(Url);
  P := Pos('://', S);
  if P > 0 then Delete(S, 1, P + 2);
  P := Pos('@', S);
  if P > 0 then Delete(S, 1, P);
  P := Pos('/', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  P := Pos(':', S);
  if P > 0 then S := Copy(S, 1, P - 1);
  Result := S;
end;

function PortasComunsOnvif: TArray<Integer>;
begin
  Result := [80, 8000, 8080, 5000, 8899, 2020, 88, 8090, 8081, 10080];
end;

function ProcurarOnvif(const Host, Usuario, Senha: string;
  const Logger: ILogger; TempoMs: Integer): TArray<TOnvifAchado>;
var
  Portas: TArray<Integer>;
  I: Integer;
  Cli: TOnvifClient;
  Achado: TOnvifAchado;
begin
  Result := nil;
  if Trim(Host) = '' then Exit;
  Portas := PortasComunsOnvif;
  for I := 0 to High(Portas) do
  begin
    Cli := TOnvifClient.Create('http://' + Host + ':' + IntToStr(Portas[I]) +
                               '/onvif/device_service',
                               Usuario, Senha, nil, 'onvif.procura', TempoMs);
    try
      // Preparar devolve False tambem para camera fixa; e por isso que a
      // resposta olha o RespondeOnvif, e nao so o resultado.
      Achado.TemPtz := Cli.Preparar;
      if not Cli.RespondeOnvif then Continue;
      Achado.Porta := Portas[I];
      Achado.Servico := Cli.PtzUrl;
      Result := Result + [Achado];
      if Logger <> nil then
        Logger.Info('onvif.procura',
                    Format('%s:%d responde ONVIF%s',
                           [Host, Portas[I],
                            IfThen(Achado.TemPtz, ' e tem PTZ', ' sem PTZ')]));
      // Achou uma com PTZ: nao ha por que continuar esperando as outras.
      if Achado.TemPtz then Exit;
    finally
      Cli.Free;
    end;
  end;
end;

function EnderecoOnvif(const Escrito, UrlDeMidia: string): string;
var
  S: string;
begin
  S := Trim(Escrito);
  if S = '' then Exit(EnderecoPadrao(UrlDeMidia));
  if (Pos('://', S) = 0) then S := 'http://' + S;
  // Sem caminho, entra o da norma. Nesta familia de firmware o caminho e
  // ignorado de todo jeito -- ela roteia pela acao do SOAP --, mas camera que
  // segue a norma precisa dele.
  if Pos('/', Copy(S, Pos('://', S) + 3, MaxInt)) = 0 then
    S := S + '/onvif/device_service';
  Result := S;
end;

function MesmoHostQue(const Anunciado, Base: string): string;
var
  A, B, HostBase, Autoridade, Resto: string;
  P: Integer;
begin
  Result := Anunciado;
  A := Trim(Anunciado);
  B := Trim(Base);
  if (A = '') or (B = '') then Exit;

  // O host da base, sem esquema, sem porta e sem caminho.
  P := Pos('://', B);
  if P > 0 then Delete(B, 1, P + 2);
  P := Pos('/', B);
  if P > 0 then B := Copy(B, 1, P - 1);
  P := Pos(':', B);
  if P > 0 then HostBase := Copy(B, 1, P - 1) else HostBase := B;
  if HostBase = '' then Exit;

  // A autoridade do anunciado, para trocar so o host e guardar a porta.
  P := Pos('://', A);
  if P = 0 then Exit;
  Resto := Copy(A, P + 3, MaxInt);
  P := Pos('/', Resto);
  if P > 0 then
  begin
    Autoridade := Copy(Resto, 1, P - 1);
    Resto := Copy(Resto, P, MaxInt);
  end
  else
  begin
    Autoridade := Resto;
    Resto := '';
  end;
  P := Pos(':', Autoridade);
  if P > 0 then Autoridade := HostBase + Copy(Autoridade, P, MaxInt)
  else Autoridade := HostBase;
  Result := 'http://' + Autoridade + Resto;
end;

// Acha a abertura do proximo elemento cujo nome LOCAL bata, a partir de De.
// Devolve 0 se nao houver. Sai por AposNome a posicao logo depois do nome, que e
// onde comecam os atributos.
//
// Comparar so a parte local, depois do ultimo ':', dispensa saber qual prefixo a
// camera escolheu -- e elas escolhem: tt, tds, trt, ou nenhum. E comparar o nome
// INTEIRO, e nao por substring, e o que separa Profile de Profiles.
function AcharAbertura(const Xml, NomeLocal: string; De: Integer;
  out AposNome: Integer): Integer;
var
  I, P, C: Integer;
  Nome: string;
begin
  Result := 0;
  AposNome := 0;
  I := De;
  while True do
  begin
    I := PosEx('<', Xml, I);
    if I = 0 then Exit;
    Inc(I);
    // Fechamento, declaracao ou comentario nao sao abertura.
    if (I > Length(Xml)) or CharInSet(Xml[I], ['/', '?', '!']) then Continue;
    P := I;
    while (P <= Length(Xml)) and
          not CharInSet(Xml[P], ['>', ' ', '/', #9, #10, #13]) do Inc(P);
    Nome := Copy(Xml, I, P - I);
    C := LastDelimiter(':', Nome);
    if C > 0 then Nome := Copy(Nome, C + 1, MaxInt);
    if SameText(Nome, NomeLocal) then
    begin
      AposNome := P;
      Exit(I - 1);
    end;
    I := P;
  end;
end;

function ValorDaTag(const Xml, NomeLocal: string): string;
var
  I, Apos, Ini, Fim: Integer;
begin
  Result := '';
  I := 1;
  while True do
  begin
    if AcharAbertura(Xml, NomeLocal, I, Apos) = 0 then Exit;
    Ini := PosEx('>', Xml, Apos);
    if Ini = 0 then Exit;
    // `<Tag/>` nao tem conteudo: segue procurando outra ocorrencia.
    if (Ini > 1) and (Xml[Ini - 1] = '/') then
    begin
      I := Ini;
      Continue;
    end;
    Fim := PosEx('</', Xml, Ini);
    if Fim = 0 then Exit;
    Exit(Trim(Copy(Xml, Ini + 1, Fim - Ini - 1)));
  end;
end;

// O fechamento de um elemento com este nome local, a partir de De. Mesma regra
// de comparacao da abertura: so a parte depois do ultimo ':'.
function AcharFechamento(const Xml, NomeLocal: string; De: Integer): Integer;
var
  I, P, C: Integer;
  Nome: string;
begin
  Result := 0;
  I := De;
  while True do
  begin
    I := PosEx('</', Xml, I);
    if I = 0 then Exit;
    P := I + 2;
    while (P <= Length(Xml)) and
          not CharInSet(Xml[P], ['>', ' ', #9, #10, #13]) do Inc(P);
    Nome := Copy(Xml, I + 2, P - I - 2);
    C := LastDelimiter(':', Nome);
    if C > 0 then Nome := Copy(Nome, C + 1, MaxInt);
    if SameText(Nome, NomeLocal) then Exit(I);
    I := P;
  end;
end;

function ValorDentroDe(const Xml, Dentro, NomeLocal: string): string;
var
  Abre, Apos, Fecha: Integer;
begin
  Result := '';
  Abre := AcharAbertura(Xml, Dentro, 1, Apos);
  if Abre = 0 then Exit;
  Fecha := AcharFechamento(Xml, Dentro, Apos);
  if Fecha = 0 then Fecha := Length(Xml);
  Result := ValorDaTag(Copy(Xml, Abre, Fecha - Abre), NomeLocal);
end;

function DigestDeSenha(const Nonce: TBytes; const Created, Senha: string): string;
var
  Buf, Bytes: TBytes;
  N: Integer;
  Sha: THashSHA1;
begin
  Buf := TEncoding.UTF8.GetBytes(Created + Senha);
  N := Length(Nonce);
  SetLength(Bytes, N + Length(Buf));
  // O nonce entra nos BYTES CRUS, e nao no base64 dele. E o engano classico da
  // ONVIF, e ele nao aparece: o digest sai com cara perfeita e a camera so
  // responde "sender not authorized".
  if N > 0 then Move(Nonce[0], Bytes[0], N);
  if Length(Buf) > 0 then Move(Buf[0], Bytes[N], Length(Buf));
  // Pela instancia, e nao pelo GetHashBytes de classe: aquele so recebe string,
  // e converter estes bytes para string passaria pela codificacao e mudaria o
  // conteudo.
  Sha := THashSHA1.Create;
  Sha.Update(Bytes);
  Result := TNetEncoding.Base64.EncodeBytesToString(Sha.HashAsBytes);
end;

function EscaparXml(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ TOnvifMove }

class function TOnvifMove.Criar(APan, ATilt, AZoom: Double): TOnvifMove;

  function Preso(V: Double): Double;
  begin
    if V < -1 then Exit(-1);
    if V > 1 then Exit(1);
    Result := V;
  end;

begin
  Result.Pan := Preso(APan);
  Result.Tilt := Preso(ATilt);
  Result.Zoom := Preso(AZoom);
end;

function TOnvifMove.Parado: Boolean;
begin
  Result := (Abs(Pan) < 0.001) and (Abs(Tilt) < 0.001) and (Abs(Zoom) < 0.001);
end;

{ TOnvifClient }

constructor TOnvifClient.Create(const AXAddr, AUser, APass: string;
  const ALogger: ILogger; const ATag: string; ATempoMs: Integer);
begin
  inherited Create;
  FXAddr := Trim(AXAddr);
  FUser := AUser;
  FPass := APass;
  FLogger := ALogger;
  FTag := ATag;
  if ATempoMs > 0 then FTempoMs := ATempoMs else FTempoMs := TEMPO_MS;
end;

// O cabecalho de seguranca, refeito a cada chamada.
//
// Nonce novo e created novo por chamada: camera que guarda nonces usados recusa
// repeticao, e e assim que ela evita que um token capturado sirva duas vezes.
function TOnvifClient.Cabecalho: string;
var
  Nonce: TBytes;
  I: Integer;
  Created: string;
begin
  if FUser = '' then Exit('');
  SetLength(Nonce, 16);
  for I := 0 to High(Nonce) do Nonce[I] := Byte(Random(256));
  // No relogio da camera, e nao no nosso. Ver o cabecalho desta unit.
  Created := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"."zzz"Z"',
                            IncMilliSecond(TTimeZone.Local.ToUniversalTime(Now),
                                           FDeltaMs));
  Result :=
    '<s:Header><wsse:Security s:mustUnderstand="1" xmlns:wsse="' + NS_WSSE +
    '" xmlns:wsu="' + NS_WSU + '"><wsse:UsernameToken>' +
    '<wsse:Username>' + EscaparXml(FUser) + '</wsse:Username>' +
    '<wsse:Password Type="' + TIPO_DIGEST + '">' +
    DigestDeSenha(Nonce, Created, FPass) + '</wsse:Password>' +
    '<wsse:Nonce EncodingType="' + TIPO_NONCE + '">' +
    TNetEncoding.Base64.EncodeBytesToString(Nonce) + '</wsse:Nonce>' +
    '<wsu:Created>' + Created + '</wsu:Created>' +
    '</wsse:UsernameToken></wsse:Security></s:Header>';
end;

function TOnvifClient.Post(const Url, Corpo: string;
  out Resposta: string): Boolean;
var
  Http: THTTPClient;
  Fluxo: TStringStream;
  R: IHTTPResponse;
begin
  Result := False;
  Resposta := '';
  Http := THTTPClient.Create;
  Fluxo := TStringStream.Create(Corpo, TEncoding.UTF8);
  try
    Http.ConnectionTimeout := FTempoMs;
    Http.ResponseTimeout := FTempoMs;
    try
      // O tipo vai como cabecalho, e nao por propriedade do cliente: e SOAP 1.2
      // que se declara aqui, e camera que so fala 1.1 responde 415 -- o motivo
      // entao aparece no log em vez de virar "nao respondeu".
      R := Http.Post(Url, Fluxo, nil,
        [TNetHeader.Create('Content-Type',
                           'application/soap+xml; charset=utf-8')]);
    except
      on E: Exception do
      begin
        FMotivo := 'nao consegui falar com ' + Url + ': ' + E.Message;
        Exit;
      end;
    end;
    Resposta := R.ContentAsString(TEncoding.UTF8);
    Result := R.StatusCode = 200;
    if not Result then
      // O texto do Fault diz mais que o codigo: "sender not authorized" e senha
      // ou relogio, "action not supported" e camera sem aquele servico.
      FMotivo := Format('%s respondeu %d: %s',
                        [Url, R.StatusCode, ValorDaTag(Resposta, 'Text')]);
  finally
    Fluxo.Free;
    Http.Free;
  end;
end;

function TOnvifClient.Chamar(const Url, Acao, CorpoInterno: string;
  out Resposta: string): Boolean;
begin
  Result := Post(Url,
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<s:Envelope xmlns:s="' + NS_ENV + '">' + Cabecalho +
    '<s:Body>' + CorpoInterno + '</s:Body></s:Envelope>', Resposta);
  if not Result and (FLogger <> nil) then
    FLogger.Warn(FTag, Acao + ': ' + FMotivo);
end;

// GetSystemDateAndTime nao leva credencial, por norma. E o que permite acertar o
// relogio ANTES de existir um token para ser recusado.
function TOnvifClient.AcertarRelogio: Boolean;
var
  Resp, Utc: string;
  A, M, D, H, N, Sg: Integer;
  Cam: TDateTime;
begin
  FDeltaMs := 0;
  Result := Post(FXAddr,
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<s:Envelope xmlns:s="' + NS_ENV + '"><s:Body>' +
    '<GetSystemDateAndTime xmlns="' + NS_DEV + '"/>' +
    '</s:Body></s:Envelope>', Resp);
  if not Result then Exit;
  Utc := ValorDentroDe(Resp, 'UTCDateTime', 'Date');
  A := StrToIntDef(ValorDaTag(Utc, 'Year'), 0);
  M := StrToIntDef(ValorDaTag(Utc, 'Month'), 0);
  D := StrToIntDef(ValorDaTag(Utc, 'Day'), 0);
  Utc := ValorDentroDe(Resp, 'UTCDateTime', 'Time');
  H := StrToIntDef(ValorDaTag(Utc, 'Hour'), 0);
  N := StrToIntDef(ValorDaTag(Utc, 'Minute'), 0);
  Sg := StrToIntDef(ValorDaTag(Utc, 'Second'), 0);
  if (A < 2000) or (M < 1) or (M > 12) or (D < 1) or (D > 31) then
  begin
    // Camera que nao diz a hora: segue com a nossa. Se ela reclamar do token, o
    // motivo vai aparecer na chamada seguinte.
    if FLogger <> nil then
      FLogger.Info(FTag, 'camera nao informou a hora; usando a daqui');
    Exit(True);
  end;
  Cam := EncodeDateTime(A, M, D, H, N, Sg, 0);
  FDeltaMs := MilliSecondsBetween(Cam, TTimeZone.Local.ToUniversalTime(Now));
  if Cam < TTimeZone.Local.ToUniversalTime(Now) then FDeltaMs := -FDeltaMs;
  if (FLogger <> nil) and (Abs(FDeltaMs) > 2000) then
    FLogger.Info(FTag, Format('relogio da camera %d s de diferenca; ' +
                              'os tokens vao pela hora dela', [FDeltaMs div 1000]));
end;

function TOnvifClient.LerCapacidades: Boolean;
var
  Resp: string;
begin
  Result := Chamar(FXAddr, 'GetCapabilities',
    '<GetCapabilities xmlns="' + NS_DEV + '">' +
    '<Category>All</Category></GetCapabilities>', Resp);
  // Respondeu = ha ONVIF nesta porta. Vale mesmo que falte PTZ depois.
  FRespondeu := Result;
  if not Result then Exit;
  // Pelo host por onde ela foi alcancada, e nao pelo que ela diz de si. Ver
  // MesmoHostQue.
  FPtzUrl := MesmoHostQue(ValorDentroDe(Resp, 'PTZ', 'XAddr'), FXAddr);
  FMediaUrl := MesmoHostQue(ValorDentroDe(Resp, 'Media', 'XAddr'), FXAddr);
  if FMediaUrl = '' then
  begin
    FMotivo := 'a camera nao anunciou o servico de midia';
    Exit(False);
  end;
  if FPtzUrl = '' then
  begin
    // Nao e erro de comunicacao: e camera fixa. Quem chamou precisa distinguir
    // isso de "falhou", senao o botao de PTZ fica prometendo o que nao existe.
    FMotivo := 'esta camera nao tem PTZ';
    Exit(False);
  end;
end;

function TOnvifClient.LerPerfil: Boolean;
var
  Resp: string;
  I, Fim: Integer;
begin
  Result := Chamar(FMediaUrl, 'GetProfiles',
    '<GetProfiles xmlns="' + NS_MEDIA + '"/>', Resp);
  if not Result then Exit;
  // O token vem como ATRIBUTO do Profiles, e nao como elemento: `token="..."`.
  I := Pos('token="', Resp);
  if I = 0 then
  begin
    FMotivo := 'nenhum perfil de midia na resposta';
    Exit(False);
  end;
  Inc(I, Length('token="'));
  Fim := PosEx('"', Resp, I);
  FPerfil := Copy(Resp, I, Fim - I);
  Result := FPerfil <> '';
  if not Result then FMotivo := 'perfil de midia sem token';
end;

function TOnvifClient.Preparar: Boolean;
begin
  if FPreparado then Exit(True);
  FMotivo := '';
  if FXAddr = '' then
  begin
    FMotivo := 'sem endereco do servico ONVIF';
    Exit(False);
  end;
  // O relogio e um ACERTO, nao um requisito. A Ayla nao responde
  // GetSystemDateAndTime, e enquanto isso era o primeiro `and` da linha ela
  // reprovava inteira -- inclusive o movimento, que ela sabe fazer. Sem o
  // acerto o token vai pela hora daqui; se a camera recusar por causa disso, o
  // motivo aparece na chamada seguinte, que e onde ele ajuda.
  AcertarRelogio;
  Result := LerCapacidades and LerPerfil;
  FPreparado := Result;
end;

function TOnvifClient.MoverContinuo(const M: TOnvifMove): Boolean;
var
  Resp: string;
  Fmt: TFormatSettings;
begin
  if not Preparar then Exit(False);
  if M.Parado then Exit(Parar);
  // Ponto decimal, sempre: com a virgula do portugues a camera le 0 e nao mexe.
  Fmt := TFormatSettings.Invariant;
  Result := Chamar(FPtzUrl, 'ContinuousMove',
    '<ContinuousMove xmlns="' + NS_PTZ + '">' +
    '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken><Velocity>' +
    Format('<PanTilt x="%.3f" y="%.3f" xmlns="%s"/>',
           [M.Pan, M.Tilt, NS_SCH], Fmt) +
    Format('<Zoom x="%.3f" xmlns="%s"/>', [M.Zoom, NS_SCH], Fmt) +
    '</Velocity><Timeout>' + DURACAO + '</Timeout>' +
    '</ContinuousMove>', Resp);
end;

function TOnvifClient.Parar: Boolean;
var
  Resp: string;
begin
  if not Preparar then Exit(False);
  // Os dois eixos de uma vez: parar so o PanTilt deixa o zoom correndo, e quem
  // soltou o botao espera que TUDO pare.
  if not FSemStop then
  begin
    Result := Chamar(FPtzUrl, 'Stop',
      '<Stop xmlns="' + NS_PTZ + '">' +
      '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken>' +
      '<PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>', Resp);
    if Result then Exit;
    // Falhou uma vez, nao se pergunta mais: ver FSemStop.
    FSemStop := True;
    if FLogger <> nil then
      FLogger.Info(FTag, 'Stop nao respondeu; daqui em diante paro com ' +
                         'velocidade zero direto');
  end;

  // Camera que nao implementa Stop existe, e cala em vez de recusar. A Ayla e
  // uma: Stop nao devolve nada, e ela para com um movimento de velocidade
  // zero. Aqui, e nao em MoverContinuo, porque MoverContinuo manda velocidade
  // zero para CA -- fazer o contrario fecharia um ciclo entre os dois.
  Result := Chamar(FPtzUrl, 'ContinuousMove',
    '<ContinuousMove xmlns="' + NS_PTZ + '">' +
    '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken><Velocity>' +
    '<PanTilt x="0.000" y="0.000" xmlns="' + NS_SCH + '"/>' +
    '<Zoom x="0.000" xmlns="' + NS_SCH + '"/>' +
    // Sem Timeout: velocidade zero E o fim do movimento, e por um instante.
    '</Velocity></ContinuousMove>', Resp);
end;

function TOnvifClient.GuardarPreset(const Token, Nome: string;
  out TokenSalvo: string): Boolean;
var
  Resp, Corpo: string;
begin
  TokenSalvo := '';
  if not Preparar then Exit(False);
  Corpo := '<SetPreset xmlns="' + NS_PTZ + '">' +
           '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken>';
  // O nome vem antes do token na ordem do esquema, e ha firmware que so le
  // nessa ordem.
  if Trim(Nome) <> '' then
    Corpo := Corpo + '<PresetName>' + EscaparXml(Nome) + '</PresetName>';
  if Trim(Token) <> '' then
    Corpo := Corpo + '<PresetToken>' + EscaparXml(Token) + '</PresetToken>';
  Result := Chamar(FPtzUrl, 'SetPreset', Corpo + '</SetPreset>', Resp);
  if not Result then Exit;
  // Sobrescrita devolve o mesmo token; criacao devolve um novo. Camera que
  // nao devolve nada nao e erro: o token que mandamos continua valendo.
  TokenSalvo := Trim(ValorDaTag(Resp, 'PresetToken'));
  if TokenSalvo = '' then TokenSalvo := Trim(Token);
end;

function TOnvifClient.ApagarPreset(const Token: string): Boolean;
var
  Resp: string;
begin
  if not Preparar then Exit(False);
  if Trim(Token) = '' then
  begin
    FMotivo := 'sem o token da posicao a apagar';
    Exit(False);
  end;
  Result := Chamar(FPtzUrl, 'RemovePreset',
    '<RemovePreset xmlns="' + NS_PTZ + '">' +
    '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken>' +
    '<PresetToken>' + EscaparXml(Token) + '</PresetToken></RemovePreset>',
    Resp);
  // Lista guardada em memoria nao existe aqui: quem lista pergunta de novo a
  // cada abertura, entao apagar nao deixa rastro para limpar.
end;

function TOnvifClient.LerPresets(out Lista: TArray<TOnvifPreset>): Boolean;
var
  Resp, Bloco: string;
  I, Fim, N: Integer;
begin
  Lista := nil;
  if not Preparar then Exit(False);
  // Camera que nao lista presets nao passa a listar. A tela pergunta a cada
  // abertura do ao vivo, e sem esta guarda o log ganhava uma linha de erro por
  // abertura, dias a fio, por uma resposta que nunca vem. Ver FSemPresets.
  if FSemPresets then Exit(False);
  Result := Chamar(FPtzUrl, 'GetPresets',
    '<GetPresets xmlns="' + NS_PTZ + '">' +
    '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken></GetPresets>', Resp);
  if not Result then
  begin
    FSemPresets := True;
    Exit;
  end;
  N := 0;
  I := 1;
  while True do
  begin
    I := PosEx('token="', Resp, I);
    if I = 0 then Break;
    Inc(I, Length('token="'));
    Fim := PosEx('"', Resp, I);
    if Fim = 0 then Break;
    SetLength(Lista, N + 1);
    Lista[N].Token := Copy(Resp, I, Fim - I);
    // O nome vem num filho `Name` logo depois; se nao vier, o token serve de
    // rotulo -- lista de presets sem rotulo nenhum seria pior.
    Bloco := Copy(Resp, Fim, 400);
    Lista[N].Nome := ValorDaTag(Bloco, 'Name');
    if Lista[N].Nome = '' then Lista[N].Nome := Lista[N].Token;
    Inc(N);
    I := Fim;
  end;
end;

function TOnvifClient.IrParaPreset(const Token: string): Boolean;
var
  Resp: string;
begin
  if not Preparar then Exit(False);
  Result := Chamar(FPtzUrl, 'GotoPreset',
    '<GotoPreset xmlns="' + NS_PTZ + '">' +
    '<ProfileToken>' + EscaparXml(FPerfil) + '</ProfileToken>' +
    '<PresetToken>' + EscaparXml(Token) + '</PresetToken></GotoPreset>', Resp);
end;

initialization
  Randomize;

end.
