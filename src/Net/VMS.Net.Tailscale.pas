unit VMS.Net.Tailscale;

// Sobe o túnel do Tailscale antes de conectar numa câmera que só existe dentro
// da tailnet — o caso de assistir pelo 4G, em que a câmera tem IP 100.x e não
// há rota nenhuma até ela sem VPN.
//
// O limite que manda no desenho: o Android NÃO deixa um app ligar a VPN de
// outro app. Não existe API para isso, e não é falta de permissão — é decisão
// de plataforma (só o app dono do VpnService pode subir o túnel, e o usuário
// tem que consentir). Então o máximo que se consegue é trazer o app do
// Tailscale para a frente e esperar; quem liga é o usuário (ou o próprio
// Tailscale, se ele estiver configurado para conectar ao abrir).
//
// Por isso a ordem é: testar primeiro, abrir só se precisar.
//
//   1. tenta alcançar a câmera direto. Se alcança, não abre nada — é o caso de
//      estar em casa, na mesma LAN, ou de o túnel já estar de pé;
//   2. não alcançou: abre o app do Tailscale (uma vez só por janela de tempo,
//      para uma reconexão em laço não ficar jogando o usuário para fora do app);
//   3. fica testando a câmera até alcançar ou estourar o prazo.
//
// O teste é um TCP connect na porta real da câmera (554, 8554, 34567...), e não
// um ICMP: ping exigiria socket raw (root no Android), e conectar na porta que
// vai ser usada de verdade prova a rota E o serviço de uma vez.
//
// Fora do Android é só o passo 1 em laço: no Windows o Tailscale é serviço do
// sistema, não app que se abra por Intent.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Domain.Logging;

const
  // Prazo de espera pela VPN. Generoso de propósito: nesse tempo o usuário pode
  // ter que sair do app, ligar o Tailscale e voltar.
  TAILNET_WAIT_MS = 30000;
  // Quanto esperar por um TCP connect em cada tentativa.
  TAILNET_PROBE_MS = 1500;
  // Intervalo mínimo entre duas aberturas do app do Tailscale.
  TAILNET_LAUNCH_COOLDOWN_MS = 60000;

// True se o host parece ser de uma tailnet: faixa CGNAT 100.64.0.0/10, que é a
// que o Tailscale distribui, ou nome MagicDNS (*.ts.net). Serve para avisar no
// log quando a câmera parece ser da tailnet mas a opção está desligada — não
// liga nada sozinho, para não mudar o comportamento de quem não pediu.
function LooksLikeTailnetHost(const Host: string): Boolean;

// Alcança Host:Port? Um TCP connect, sem nada por cima.
function HostReachable(const Host: string; Port: Word; TimeoutMs: Cardinal): Boolean;

// Garante rota até Host:Port, subindo o Tailscale se for necessário e possível.
// AStop (opcional) aborta a espera na hora em que o usuário para a câmera.
// Retorna False no fim do prazo; quem chamou decide se tenta conectar mesmo
// assim (e normalmente vale tentar: o erro de conexão diz mais que não tentar).
function EnsureTailnetUp(const Host: string; Port: Word; const Logger: ILogger;
  AStop: TEvent = nil; TimeoutMs: Cardinal = TAILNET_WAIT_MS): Boolean;

implementation

uses
  VMS.Net.Intf,
  VMS.Net.Tcp
  {$IFDEF ANDROID}
  , Androidapi.Helpers
  , Androidapi.JNI.JavaTypes
  , Androidapi.JNI.GraphicsContentViewText
  {$ENDIF};

const
  TAG = 'tailscale';
  TAILSCALE_PACKAGE = 'com.tailscale.ipn';

var
  // Última abertura do app, para respeitar o cooldown. Compartilhado entre
  // câmeras: o app do Tailscale é um só.
  GLastLaunchTick: UInt64 = 0;
  GLaunchLock: TCriticalSection = nil;

function LooksLikeTailnetHost(const Host: string): Boolean;
var
  H: string;
  P1, Octet2: Integer;
  Parts: TArray<string>;
begin
  Result := False;
  H := LowerCase(Trim(Host));
  if H = '' then Exit;
  if H.EndsWith('.ts.net') then Exit(True);
  // 100.64.0.0/10 = 100.64.x.x até 100.127.x.x
  if not H.StartsWith('100.') then Exit;
  Parts := H.Split(['.']);
  if Length(Parts) <> 4 then Exit;
  if not TryStrToInt(Parts[1], Octet2) then Exit;
  if (Octet2 < 64) or (Octet2 > 127) then Exit;
  // os dois últimos têm que ser número para não casar com nome tipo "100.abc"
  if not TryStrToInt(Parts[2], P1) then Exit;
  if not TryStrToInt(Parts[3], P1) then Exit;
  Result := True;
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

{$IFDEF ANDROID}
// Traz o app do Tailscale para a frente. Não liga a VPN — só o app dono do
// VpnService pode fazer isso. False = app não instalado.
function LaunchTailscaleApp(const Logger: ILogger): Boolean;
var
  Intent: JIntent;
  PM: JPackageManager;
begin
  Result := False;
  try
    if TAndroidHelper.Context = nil then Exit;
    PM := TAndroidHelper.Context.getPackageManager;
    if PM = nil then Exit;
    Intent := PM.getLaunchIntentForPackage(StringToJString(TAILSCALE_PACKAGE));
    if Intent = nil then
    begin
      if Logger <> nil then
        Logger.Warn(TAG, 'o app do Tailscale nao esta instalado neste aparelho');
      Exit;
    end;
    // NEW_TASK: startActivity fora da UI thread só é legal com esta flag.
    Intent.addFlags(TJIntent.JavaClass.FLAG_ACTIVITY_NEW_TASK);
    TAndroidHelper.Context.startActivity(Intent);
    Result := True;
  except
    on E: Exception do
      if Logger <> nil then
        Logger.Warn(TAG, 'falha ao abrir o Tailscale: ' + E.Message);
  end;
end;
{$ELSE}
function LaunchTailscaleApp(const Logger: ILogger): Boolean;
begin
  // No Windows/desktop o Tailscale é serviço do sistema: não há app para abrir,
  // e subir a VPN daqui não é papel deste programa. Só resta esperar.
  Result := False;
end;
{$ENDIF}

// Abre o app respeitando o cooldown. True se abriu agora.
function TryLaunchOnce(const Logger: ILogger): Boolean;
var
  Now_: UInt64;
begin
  Result := False;
  if GLaunchLock = nil then Exit;
  GLaunchLock.Enter;
  try
    Now_ := TThread.GetTickCount64;
    if (GLastLaunchTick <> 0) and (Now_ - GLastLaunchTick < TAILNET_LAUNCH_COOLDOWN_MS) then
    begin
      if Logger <> nil then
        Logger.Info(TAG, 'Tailscale ja foi aberto ha pouco; so aguardando o tunel');
      Exit;
    end;
    GLastLaunchTick := Now_;
  finally
    GLaunchLock.Leave;
  end;
  Result := LaunchTailscaleApp(Logger);
end;

function EnsureTailnetUp(const Host: string; Port: Word; const Logger: ILogger;
  AStop: TEvent; TimeoutMs: Cardinal): Boolean;
var
  Deadline: UInt64;
  Launched: Boolean;
  Attempts: Integer;

  function Stopped: Boolean;
  begin
    Result := (AStop <> nil) and (AStop.WaitFor(0) = wrSignaled);
  end;

begin
  // 1) Já alcança? Então não há VPN a subir — nem para abrir app, nem para
  //    esperar. É o caminho normal de quem está na mesma rede da câmera.
  if HostReachable(Host, Port, TAILNET_PROBE_MS) then
  begin
    if Logger <> nil then
      Logger.Debug(TAG, Format('%s:%d ja responde; sem VPN a subir', [Host, Port]));
    Exit(True);
  end;
  if Stopped then Exit(False);

  // 2) Não alcança: pede o túnel.
  if Logger <> nil then
    Logger.Info(TAG, Format('%s:%d nao responde; pedindo o tunel do Tailscale', [Host, Port]));
  Launched := TryLaunchOnce(Logger);
  if Logger <> nil then
    if Launched then
      Logger.Info(TAG, 'app do Tailscale aberto; ligue a VPN e volte para o app')
    else
      Logger.Info(TAG, Format('aguardando o tunel por ate %d s', [TimeoutMs div 1000]));

  // 3) Espera a rota aparecer.
  Deadline := TThread.GetTickCount64 + TimeoutMs;
  Attempts := 0;
  while TThread.GetTickCount64 < Deadline do
  begin
    if Stopped then Exit(False);
    Inc(Attempts);
    if HostReachable(Host, Port, TAILNET_PROBE_MS) then
    begin
      if Logger <> nil then
        Logger.Info(TAG, Format('tunel de pe: %s:%d respondeu na tentativa %d',
          [Host, Port, Attempts]));
      Exit(True);
    end;
    if (AStop <> nil) then
    begin
      if AStop.WaitFor(500) = wrSignaled then Exit(False);
    end
    else
      TThread.Sleep(500);
  end;

  if Logger <> nil then
    Logger.Warn(TAG, Format('%s:%d continua sem resposta depois de %d s;' +
      ' o Tailscale esta conectado neste aparelho?', [Host, Port, TimeoutMs div 1000]));
  Result := False;
end;

initialization
  GLaunchLock := TCriticalSection.Create;

finalization
  GLaunchLock.Free;

end.
