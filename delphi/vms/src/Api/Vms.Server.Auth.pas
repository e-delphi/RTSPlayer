unit Vms.Server.Auth;

// Quem pode falar com o servidor.
//
// Enquanto o VMS só existia na LAN a resposta era "quem está na LAN". Num
// endereço alcançável de fora isso deixa de valer: as rotas daqui entregam
// vídeo de dentro da casa, e o /api/sql lê a tabela camera_endpoint, onde as
// senhas das câmeras estão em texto claro. Sem porteiro, publicar o endereço é
// publicar as câmeras.
//
// ## O que se guarda
//
// Nunca a senha. Guarda-se `pbkdf2$<iteracoes>$<sal>$<hash>`, com sal por
// instalação, para que ler o banco não devolva a senha -- que costuma ser a
// mesma de outro lugar.
//
// PBKDF2-HMAC-SHA256 e não um SHA direto: hash rápido é hash que se quebra por
// força bruta em GPU. As iterações são o custo que torna isso caro. ITERACOES
// está calibrado para pesar no ataque sem pesar no login, que acontece uma vez
// por sessão.
//
// ## Sessão
//
// O navegador entra uma vez e recebe um cookie; o app manda Basic em toda
// requisição. Os dois caminhos existem porque são clientes diferentes: a página
// tem de sobreviver a um F5 sem pedir senha de novo, e o app -- que encaminha
// de dentro do Delphi -- não tem onde guardar cookie sem inventar um gerenciador
// de sessão só para isso.
//
// O token é de 256 bits e vive só em memória: reiniciar o servidor desloga
// todo mundo, o que é aceitável e evita um arquivo de sessões para vazar.
//
// ## O que este arquivo NÃO faz
//
// Não protege o RTSP. A porta 8554 fala os dois protocolos, e o porteiro aqui
// está no caminho do HTTP. Publicar a porta crua deixa o RTSP aberto; atrás de
// um `tailscale serve`, que só encaminha HTTP, ele não fica exposto.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;

const
  // Custo do PBKDF2. Alto o bastante para um ataque em lote doer, baixo o
  // bastante para o login não travar a tela.
  ITERACOES = 50000;
  // Quanto vale o cookie do navegador antes de pedir senha de novo.
  SESSAO_PADRAO_HORAS = 720;

type
  // Por que uma requisição foi recusada. Muda a resposta: página vai para o
  // login, api leva 401, e "sem senha definida" precisa de um texto próprio --
  // é o estado de instalação nova, e mandar o usuário para um login que ainda
  // não existe seria um beco.
  TAcesso = (acLiberado, acSemCredencial, acCredencialInvalida, acSemSenhaDefinida);

  TAutenticador = class
  strict private
    FLock: TCriticalSection;
    FUsuario: string;
    FHash: string;         // pbkdf2$iter$sal$hash
    FLigado: Boolean;
    FHoras: Integer;
    // token -> quando expira (tick de milissegundos).
    FSessoes: TDictionary<string, UInt64>;
    procedure LimparVencidas;
  public
    constructor Create;
    destructor Destroy; override;

    // Relê o que veio das configurações. Trocar a senha derruba as sessões:
    // trocar senha é justamente o que se faz quando se quer expulsar alguém.
    procedure Configurar(ALigado: Boolean; const AUsuario, AHash: string;
                         AHoras: Integer);

    property Ligado: Boolean read FLigado;
    // Só para preencher o campo de quem já entrou; nunca vai para quem não
    // está autenticado.
    property Usuario: string read FUsuario;
    // Instalação sem senha: só o próprio computador entra, e só para definir uma.
    function SemSenha: Boolean;

    // Confere usuário e senha. Devolve False sem dizer qual dos dois errou --
    // "usuário não existe" é informação que ajuda quem está adivinhando.
    function Confere(const Usuario, Senha: string): Boolean;

    // Abre uma sessão e devolve o token do cookie.
    function AbrirSessao: string;
    function SessaoValida(const Token: string): Boolean;
    procedure FecharSessao(const Token: string);

    // Decide o acesso de uma requisição já com os cabeçalhos em mãos.
    function Avaliar(const Authorization, Cookie: string): TAcesso;
  end;

// pbkdf2$<iteracoes>$<sal hex>$<hash hex>, pronto para gravar nas configurações.
function GerarHashDeSenha(const Senha: string): string;
// Confere uma senha contra um registro desses. False também para registro
// ilegível: o que não dá para conferir não passa.
function SenhaConfere(const Senha, Registro: string): Boolean;

// O valor de um cookie dentro do cabeçalho Cookie inteiro.
function CookieDe(const Cabecalho, Nome: string): string;
// Usuário e senha de um "Basic <base64>"; False para qualquer outro esquema.
function LerBasic(const Authorization: string;
                  out Usuario, Senha: string): Boolean;

const
  COOKIE_SESSAO = 'vmsauth';

implementation

uses
  System.Hash,
  System.NetEncoding,
  System.StrUtils,
  System.DateUtils;

// ---------------------------------------------------------------- utilidades

function BytesParaHex(const B: TBytes): string;
const
  DIG: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for I := 0 to High(B) do
  begin
    Result[1 + I * 2] := DIG[B[I] shr 4];
    Result[2 + I * 2] := DIG[B[I] and $0F];
  end;
end;

function HexParaBytes(const S: string): TBytes;
var
  I, N, V: Integer;
begin
  N := Length(S) div 2;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    // Por uma variavel Integer: o elemento e Byte, e `Integer(Result[I])` seria
    // um typecast -- que nao serve de parametro `out`.
    if not TryStrToInt('$' + Copy(S, 1 + I * 2, 2), V) then Exit(nil);
    Result[I] := Byte(V);
  end;
end;

// Comparação de tempo constante.
//
// Um `=` de string sai no primeiro byte diferente, e o tempo que ele leva conta
// quantos bytes bateram. Com muitas tentativas isso descobre o valor byte a
// byte. Aqui todo o comprimento é sempre percorrido.
function IgualEmTempoConstante(const A, B: string): Boolean;
var
  I, Dif: Integer;
begin
  Dif := Length(A) xor Length(B);
  for I := 1 to Length(A) do
    if I <= Length(B) then
      Dif := Dif or (Ord(A[I]) xor Ord(B[I]))
    else
      Dif := Dif or Ord(A[I]);
  Result := Dif = 0;
end;

// PBKDF2-HMAC-SHA256, um bloco (32 bytes bastam para o que se guarda aqui).
function Pbkdf2Sha256(const Senha: string; const Sal: TBytes;
  Iteracoes: Integer): TBytes;
var
  Chave, Bloco, U: TBytes;
  I, J: Integer;
begin
  Chave := TEncoding.UTF8.GetBytes(Senha);

  // U1 = HMAC(senha, sal || 0x00000001)
  SetLength(U, Length(Sal) + 4);
  if Length(Sal) > 0 then Move(Sal[0], U[0], Length(Sal));
  U[Length(Sal)] := 0;
  U[Length(Sal) + 1] := 0;
  U[Length(Sal) + 2] := 0;
  U[Length(Sal) + 3] := 1;

  U := THashSHA2.GetHMACAsBytes(U, Chave, THashSHA2.TSHA2Version.SHA256);
  Bloco := Copy(U, 0, Length(U));

  for I := 2 to Iteracoes do
  begin
    U := THashSHA2.GetHMACAsBytes(U, Chave, THashSHA2.TSHA2Version.SHA256);
    for J := 0 to High(Bloco) do
      Bloco[J] := Bloco[J] xor U[J];
  end;
  Result := Bloco;
end;

// Bytes imprevisíveis para sal e token.
//
// Não é um CSPRNG do sistema -- a RTL não expõe um portátil aqui. É a mistura
// de vários GUIDs (que no Windows e no Android vêm do gerador do sistema) com o
// relógio e um contador, passada por SHA-256. Serve para sal e para token de
// sessão; não serviria para chave de longo prazo.
var
  GContador: Integer = 0;

function BytesAleatorios(N: Integer): TBytes;
var
  Fonte: string;
  G: TGUID;
  I: Integer;
  Dig: TBytes;
begin
  Fonte := '';
  for I := 1 to 4 do
  begin
    if CreateGUID(G) = 0 then
      Fonte := Fonte + GUIDToString(G);
  end;
  Fonte := Fonte + IntToStr(TThread.GetTickCount64) +
           FloatToStr(Now) + IntToStr(TInterlocked.Increment(GContador));
  // GetHashString + hex, e nao GetHashBytes: a versao de string existe desde
  // sempre e o custo aqui e irrelevante -- isto roda uma vez por token.
  Dig := HexParaBytes(THashSHA2.GetHashString(Fonte,
                        THashSHA2.TSHA2Version.SHA256));
  if N <= Length(Dig) then
    Result := Copy(Dig, 0, N)
  else
    Result := Dig;
end;

// ------------------------------------------------------------------- senha

function GerarHashDeSenha(const Senha: string): string;
var
  Sal: TBytes;
begin
  Sal := BytesAleatorios(16);
  Result := Format('pbkdf2$%d$%s$%s',
    [ITERACOES, BytesParaHex(Sal),
     BytesParaHex(Pbkdf2Sha256(Senha, Sal, ITERACOES))]);
end;

function SenhaConfere(const Senha, Registro: string): Boolean;
var
  Partes: TArray<string>;
  Iter: Integer;
  Sal: TBytes;
begin
  Result := False;
  if Trim(Registro) = '' then Exit;
  Partes := Registro.Split(['$']);
  if Length(Partes) <> 4 then Exit;
  if not SameText(Partes[0], 'pbkdf2') then Exit;
  if not TryStrToInt(Partes[1], Iter) then Exit;
  if (Iter <= 0) or (Iter > 5000000) then Exit;
  Sal := HexParaBytes(Partes[2]);
  if Length(Sal) = 0 then Exit;
  Result := IgualEmTempoConstante(
    BytesParaHex(Pbkdf2Sha256(Senha, Sal, Iter)), LowerCase(Partes[3]));
end;

// --------------------------------------------------------------- cabeçalhos

function CookieDe(const Cabecalho, Nome: string): string;
var
  Partes: TArray<string>;
  I, P: Integer;
  Item, Chave: string;
begin
  Result := '';
  Partes := Cabecalho.Split([';']);
  for I := 0 to High(Partes) do
  begin
    Item := Trim(Partes[I]);
    P := Pos('=', Item);
    if P < 2 then Continue;
    Chave := Copy(Item, 1, P - 1);
    if SameText(Chave, Nome) then
      Exit(Copy(Item, P + 1, MaxInt));
  end;
end;

function LerBasic(const Authorization: string;
  out Usuario, Senha: string): Boolean;
var
  S, Claro: string;
  P: Integer;
begin
  Usuario := '';
  Senha := '';
  Result := False;
  S := Trim(Authorization);
  if not StartsText('Basic ', S) then Exit;
  Delete(S, 1, Length('Basic '));
  try
    Claro := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(Trim(S)));
  except
    Exit(False);
  end;
  P := Pos(':', Claro);
  if P < 1 then Exit;
  Usuario := Copy(Claro, 1, P - 1);
  Senha := Copy(Claro, P + 1, MaxInt);
  Result := True;
end;

{ TAutenticador }

constructor TAutenticador.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSessoes := TDictionary<string, UInt64>.Create;
  FHoras := SESSAO_PADRAO_HORAS;
end;

destructor TAutenticador.Destroy;
begin
  FSessoes.Free;
  FLock.Free;
  inherited;
end;

procedure TAutenticador.Configurar(ALigado: Boolean;
  const AUsuario, AHash: string; AHoras: Integer);
var
  Mudou: Boolean;
begin
  FLock.Enter;
  try
    Mudou := (FHash <> AHash) or not SameText(FUsuario, AUsuario);
    FLigado := ALigado;
    FUsuario := Trim(AUsuario);
    if FUsuario = '' then FUsuario := 'admin';
    FHash := Trim(AHash);
    if AHoras > 0 then FHoras := AHoras;
    // Senha nova invalida o que já estava aberto: é o que faz trocar a senha
    // servir para tirar alguém de dentro.
    if Mudou then FSessoes.Clear;
  finally
    FLock.Leave;
  end;
end;

function TAutenticador.SemSenha: Boolean;
begin
  FLock.Enter;
  try
    Result := Trim(FHash) = '';
  finally
    FLock.Leave;
  end;
end;

function TAutenticador.Confere(const Usuario, Senha: string): Boolean;
var
  U, H: string;
begin
  FLock.Enter;
  try
    U := FUsuario;
    H := FHash;
  finally
    FLock.Leave;
  end;
  if H = '' then Exit(False);
  // O PBKDF2 roda mesmo com o usuário errado: sair antes faria o tempo de
  // resposta dizer se aquele usuário existe.
  Result := SenhaConfere(Senha, H) and IgualEmTempoConstante(LowerCase(Usuario),
                                                             LowerCase(U));
end;

procedure TAutenticador.LimparVencidas;
var
  Agora: UInt64;
  Par: TPair<string, UInt64>;
  Mortas: TArray<string>;
  N: Integer;
begin
  Agora := TThread.GetTickCount64;
  SetLength(Mortas, FSessoes.Count);
  N := 0;
  for Par in FSessoes do
    if Par.Value <= Agora then
    begin
      Mortas[N] := Par.Key;
      Inc(N);
    end;
  while N > 0 do
  begin
    Dec(N);
    FSessoes.Remove(Mortas[N]);
  end;
end;

function TAutenticador.AbrirSessao: string;
var
  Token: string;
begin
  Token := BytesParaHex(BytesAleatorios(32));
  FLock.Enter;
  try
    LimparVencidas;
    FSessoes.AddOrSetValue(Token,
      TThread.GetTickCount64 + UInt64(FHoras) * 3600 * 1000);
  finally
    FLock.Leave;
  end;
  Result := Token;
end;

function TAutenticador.SessaoValida(const Token: string): Boolean;
var
  Ate: UInt64;
begin
  Result := False;
  if Trim(Token) = '' then Exit;
  FLock.Enter;
  try
    if not FSessoes.TryGetValue(Token, Ate) then Exit;
    Result := Ate > TThread.GetTickCount64;
    if not Result then FSessoes.Remove(Token);
  finally
    FLock.Leave;
  end;
end;

procedure TAutenticador.FecharSessao(const Token: string);
begin
  FLock.Enter;
  try
    FSessoes.Remove(Token);
  finally
    FLock.Leave;
  end;
end;

function TAutenticador.Avaliar(const Authorization, Cookie: string): TAcesso;
var
  Usuario, Senha, Token: string;
begin
  if not FLigado then Exit(acLiberado);
  if SemSenha then Exit(acSemSenhaDefinida);

  // Cookie primeiro: é o caminho do navegador, e o mais barato -- uma busca no
  // dicionário contra os 50 mil rounds do PBKDF2.
  Token := CookieDe(Cookie, COOKIE_SESSAO);
  if Token <> '' then
  begin
    if SessaoValida(Token) then Exit(acLiberado);
    Exit(acCredencialInvalida);
  end;

  // Basic: o caminho do app, que encaminha de dentro do Delphi e não tem por
  // que manter sessão.
  if Trim(Authorization) <> '' then
  begin
    if LerBasic(Authorization, Usuario, Senha) and Confere(Usuario, Senha) then
      Exit(acLiberado);
    Exit(acCredencialInvalida);
  end;

  Result := acSemCredencial;
end;

end.
