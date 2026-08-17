unit VMS.Net.Probe;

// "Ping rápido" e escolha de caminho até a câmera.
//
// A mesma câmera costuma ter mais de um endereço: o IP dela na LAN, o servidor
// local que a republica, e o mesmo servidor pela tailnet. Em vez de cadastrar
// três câmeras iguais, cada câmera tem uma LISTA DE ENDPOINTS em ordem de
// prioridade, e quem vai conectar pergunta antes qual deles responde.
//
// O teste é um TCP connect com timeout curto — não é ICMP, é o próprio serviço
// atendendo. Barato, e responde a pergunta certa: "dá para falar com este
// endereço agora?".
//
// A escolha acontece a CADA tentativa de conexão (ver TCameraSupervisor), não
// uma vez na partida: sair de casa derruba o endereço local, e a reconexão
// seguinte tem que achar o caminho de fora sozinha.

interface

uses
  System.SysUtils,
  System.StrUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Net.Intf,
  VMS.Net.Tcp;

const
  // Curto de propósito: são até N endpoints em série antes de conectar. Uma LAN
  // responde em milissegundos; o que não responde nisso não vale a espera.
  PROBE_TIMEOUT_MS = 700;

// Host e porta de uma URL rtsp:// ou dvrip://, com a porta padrão do esquema
// quando ela não vem escrita.
function HostPortOfUrl(const Url: string; out Host: string; out Port: Word): Boolean;
// Alcança Host:Port? Um TCP connect, sem nada por cima.
function HostReachable(const Host: string; Port: Word; TimeoutMs: Cardinal): Boolean;
function UrlReachable(const Url: string; TimeoutMs: Cardinal = PROBE_TIMEOUT_MS): Boolean;

// Primeiro endpoint que responde, na ordem da lista. Devolve False (e o índice
// -1) quando nenhum responde — aí quem chamou decide o que fazer; o supervisor
// tenta o primeiro assim mesmo, porque errar o palpite é melhor que não tentar.
function SelectEndpoint(const Endpoints: TArray<TCameraEndpoint>;
                        const Logger: ILogger; const Tag: string;
                        TimeoutMs: Cardinal; out Index: Integer): Boolean;

implementation

function HostPortOfUrl(const Url: string; out Host: string; out Port: Word): Boolean;
var
  S, Authority, PortStr: string;
  P: Integer;
  Scheme: string;
begin
  Result := False;
  Host := '';
  Port := 0;
  S := Trim(Url);
  P := Pos('://', S);
  if P < 2 then Exit;
  Scheme := LowerCase(Copy(S, 1, P - 1));
  S := Copy(S, P + 3, MaxInt);

  P := Pos('/', S);
  if P > 0 then
    Authority := Copy(S, 1, P - 1)
  else
    Authority := S;
  // usuário:senha@host — as credenciais não interessam para o teste
  P := Pos('@', Authority);
  if P > 0 then
    Authority := Copy(Authority, P + 1, MaxInt);
  if Authority = '' then Exit;

  P := LastDelimiter(':', Authority);
  // IPv6 entre colchetes tem dois-pontos no meio; sem suporte por ora, e um
  // endereço assim simplesmente não passa no teste em vez de virar lixo.
  if (P > 0) and (Pos(']', Authority) = 0) then
  begin
    Host := Copy(Authority, 1, P - 1);
    PortStr := Copy(Authority, P + 1, MaxInt);
    Port := Word(StrToIntDef(PortStr, 0));
  end
  else
    Host := Authority;

  if Port = 0 then
  begin
    if Scheme = 'dvrip' then
      Port := 34567
    else if Scheme = 'http' then
      Port := 80
    else
      Port := 554;   // rtsp
  end;
  Result := Host <> '';
end;

function HostReachable(const Host: string; Port: Word; TimeoutMs: Cardinal): Boolean;
var
  Sock: ITcpStream;
begin
  Result := False;
  if (Host = '') or (Port = 0) then Exit;
  try
    Sock := TIndyTcpStream.Create;
    try
      Sock.Connect(Host, Port, TimeoutMs);
      Result := Sock.Connected;
    finally
      try Sock.Disconnect; except end;
      Sock := nil;
    end;
  except
    on E: Exception do
      Result := False; // sem rota, recusado, timeout: para nós é tudo "não alcança"
  end;
end;

function UrlReachable(const Url: string; TimeoutMs: Cardinal): Boolean;
var
  Host: string;
  Port: Word;
begin
  Result := HostPortOfUrl(Url, Host, Port) and HostReachable(Host, Port, TimeoutMs);
end;

function SelectEndpoint(const Endpoints: TArray<TCameraEndpoint>;
  const Logger: ILogger; const Tag: string; TimeoutMs: Cardinal;
  out Index: Integer): Boolean;
var
  I: Integer;
  Host: string;
  Port: Word;
begin
  Index := -1;
  Result := False;
  for I := 0 to High(Endpoints) do
  begin
    if Trim(Endpoints[I].Url) = '' then Continue;
    if not HostPortOfUrl(Endpoints[I].Url, Host, Port) then Continue;
    if HostReachable(Host, Port, TimeoutMs) then
    begin
      Index := I;
      if Logger <> nil then
        Logger.Info(Tag, Format('conexao por "%s" (%s:%d responde)',
          [Endpoints[I].Name, Host, Port]));
      Exit(True);
    end;
    if Logger <> nil then
      Logger.Debug(Tag, Format('"%s" (%s:%d) nao respondeu em %d ms',
        [Endpoints[I].Name, Host, Port, TimeoutMs]));
  end;
end;

end.
