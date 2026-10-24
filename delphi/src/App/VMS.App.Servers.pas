unit VMS.App.Servers;

// O cadastro de servidores do aparelho, e a escolha de POR ONDE falar com cada
// um deles.
//
// Um servidor costuma ter mais de um endereço: o da LAN, que só existe em casa,
// e o da tailnet, que existe de qualquer lugar mas exige o Tailscale de pé. São
// o MESMO servidor — mesmas câmeras, mesmas gravações — e por isso viram rotas
// de um cadastro só, e não dois servidores repetidos na lista.
//
// A ordem da escolha é a ordem do cadastro, com uma regra por cima: rota de
// tailnet fica por último. Não é preferência estética — é que a rota da LAN não
// custa VPN nenhuma, e tentar a tailnet primeiro em casa faria o aparelho pedir
// para abrir o Tailscale sem necessidade.
//
//   1. sonda as rotas comuns, na ordem, com um TCP connect curto;
//   2. nenhuma respondeu e há rota de tailnet: chama o EnsureTailnetUp, que
//      abre o app do Tailscale se for preciso (no Android; ver VMS.Net.Tailscale
//      para por que não dá para ligar a VPN sozinho) e espera o túnel;
//   3. ainda nada: devolve a primeira rota mesmo assim. O erro de conexão diz
//      mais ao usuário do que uma tela em branco.
//
// Com UMA rota só não há sondagem nenhuma: não existe escolha a fazer, e sondar
// custaria um connect a cada abertura de tela para nada.
//
// A escolha fica em cache por VALIDADE_MS, senão cada requisição da página --
// e são muitas -- pagaria a sondagem. Quem descobre que a rota morreu é o
// encaminhamento: ele chama Invalidar, e a próxima requisição escolhe de novo.
// É esse par (cache + invalidação no erro) que faz sair de casa no meio de uma
// sessão simplesmente funcionar.
//
// Threading: chamado das threads do Indy, várias ao mesmo tempo. O lock protege
// só a leitura e a escrita do cadastro e do cache; sondagem e espera da VPN
// acontecem FORA dele, porque bloqueiam por segundos.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.JSON,
  VMS.Domain.Logging;

const
  // Quanto uma escolha vale antes de ser conferida de novo.
  VALIDADE_MS = 30000;
  // TCP connect de sondagem. Curto: uma rota de LAN responde em milissegundos
  // ou não está lá; esperar mais só atrasa a queda para a rota seguinte.
  SONDA_MS = 1200;

type
  TRotaServidor = record
    Url: string;
    // Esta rota só existe dentro da tailnet. É o que autoriza abrir o app do
    // Tailscale quando ela for a única saída.
    Tailscale: Boolean;
  end;

  TServidorCadastrado = record
    Nome: string;
    Rotas: TArray<TRotaServidor>;
    // A credencial e do SERVIDOR, e nao da rota: as rotas sao caminhos ate o
    // mesmo lugar, e o mesmo lugar pede a mesma senha.
    Usuario: string;
    Senha: string;
  end;

  TRegistroServidores = class
  strict private
    FLock: TCriticalSection;
    FLogger: ILogger;
    FServidores: TArray<TServidorCadastrado>;
    // Nome -> rota escolhida, e quando foi escolhida.
    FEscolha: TDictionary<string, string>;
    FQuando: TDictionary<string, Cardinal>;
    function AcharServidor(const Nome: string;
                           out Servidor: TServidorCadastrado): Boolean;
    function EmCache(const Nome: string; out Url: string): Boolean;
    procedure Guardar(const Nome, Url: string);
    function Escolher(const Servidor: TServidorCadastrado): string;
  public
    constructor Create(const ALogger: ILogger);
    destructor Destroy; override;

    // Relê o cadastro. Toda escolha em cache cai junto: o endereço pode ter
    // mudado, e continuar falando com o antigo seria pior que sondar de novo.
    procedure Carregar(const Json: string);

    // Por onde falar com este servidor agora. Pode bloquear alguns segundos na
    // primeira vez, e até TAILNET_WAIT_MS se estiver esperando a VPN subir.
    function UrlDe(const Nome: string): string;

    // "Esta rota não respondeu": a próxima chamada escolhe de novo. É o que o
    // encaminhamento chama quando um GET falha.
    procedure Invalidar(const Nome: string);

    // O usuário e a senha deste servidor, se houver. False quando o cadastro
    // não tem credencial -- servidor sem autenticação continua funcionando sem
    // ninguém preencher nada.
    function Credencial(const Nome: string;
                        out Usuario, Senha: string): Boolean;

    // O que o registro tem AGORA, em uma linha. Existe para a falha poder se
    // explicar: "sem servidor configurado" sozinho não distingue cadastro
    // vazio de nome que não bateu, e são causas diferentes.
    function Diagnostico: string;

    // Diagnóstico para a tela de cadastro: sonda TODAS as rotas e diz quais
    // responderam. Não abre o Tailscale -- aqui quem pediu foi o usuário, e a
    // resposta honesta inclui "esta não respondeu".
    function SondarTodas(const Nome: string): TJSONObject;
  end;

// Separa host e porta de uma URL. Porta ausente vem do esquema.
function HostEPortaDe(const Url: string; out Host: string;
                      out Porta: Word): Boolean;

implementation

uses
  System.StrUtils,   // IfThen
  // TailnetReachable: connect, mais a conferencia de que um nome de tailnet
  // resolveu para dentro da tailnet. EnsureTailnetUp: sobe o tunel quando essa
  // for a unica saida.
  VMS.Net.Tailscale;

// ---------------------------------------------------------------------------

function HostEPortaDe(const Url: string; out Host: string;
                      out Porta: Word): Boolean;
var
  S, Autoridade: string;
  P: Integer;
  Seguro: Boolean;
  N: Integer;
begin
  Host := '';
  Porta := 0;
  S := Trim(Url);
  if S = '' then Exit(False);

  Seguro := StartsText('https://', S);
  if Seguro then Delete(S, 1, Length('https://'))
  else if StartsText('http://', S) then Delete(S, 1, Length('http://'));

  // Só a autoridade interessa: o caminho não diz nada sobre a rota.
  P := Pos('/', S);
  if P > 0 then Autoridade := Copy(S, 1, P - 1) else Autoridade := S;
  if Autoridade = '' then Exit(False);

  P := LastDelimiter(':', Autoridade);
  // O ':' de um IPv6 literal não é separador de porta; sem colchetes não dá
  // para saber, então só vale como porta o que vier depois do último ':' e for
  // número. IPv6 nu aqui nunca apareceu, e se aparecer cai no default.
  if (P > 0) and TryStrToInt(Copy(Autoridade, P + 1, MaxInt), N) and
     (N > 0) and (N <= 65535) then
  begin
    Host := Copy(Autoridade, 1, P - 1);
    Porta := Word(N);
  end
  else
  begin
    Host := Autoridade;
    if Seguro then Porta := 443 else Porta := 80;
  end;
  Result := Host <> '';
end;

{ TRegistroServidores }

constructor TRegistroServidores.Create(const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FEscolha := TDictionary<string, string>.Create;
  FQuando := TDictionary<string, Cardinal>.Create;
end;

destructor TRegistroServidores.Destroy;
begin
  FEscolha.Free;
  FQuando.Free;
  FLock.Free;
  inherited;
end;

procedure TRegistroServidores.Carregar(const Json: string);
var
  Valor: TJSONValue;
  Arr, ArrRotas: TJSONArray;
  Item, Rota: TJSONObject;
  Lista: TArray<TServidorCadastrado>;
  Rotas: TArray<TRotaServidor>;
  I, J, N: Integer;
  Url: string;
begin
  Lista := nil;
  Valor := TJSONObject.ParseJSONValue(Json);
  try
    if Valor is TJSONObject then
    begin
      Arr := TJSONObject(Valor).GetValue('servers') as TJSONArray;
      if Arr <> nil then
        for I := 0 to Arr.Count - 1 do
        begin
          if not (Arr.Items[I] is TJSONObject) then Continue;
          Item := TJSONObject(Arr.Items[I]);
          Rotas := nil;
          N := 0;

          ArrRotas := Item.GetValue('routes') as TJSONArray;
          if ArrRotas <> nil then
          begin
            SetLength(Rotas, ArrRotas.Count);
            for J := 0 to ArrRotas.Count - 1 do
            begin
              if not (ArrRotas.Items[J] is TJSONObject) then Continue;
              Rota := TJSONObject(ArrRotas.Items[J]);
              Url := Trim(Rota.GetValue<string>('url', '')).TrimRight(['/']);
              if Url = '' then Continue;
              Rotas[N].Url := Url;
              Rotas[N].Tailscale := Rota.GetValue<Boolean>('tailscale', False);
              Inc(N);
            end;
            SetLength(Rotas, N);
          end;

          // Cadastro de antes das rotas: um `url` solto vira a rota única. Ler
          // os dois formatos é o que deixa uma versão nova subir sem o usuário
          // recadastrar nada.
          if N = 0 then
          begin
            Url := Trim(Item.GetValue<string>('url', '')).TrimRight(['/']);
            if Url <> '' then
            begin
              SetLength(Rotas, 1);
              Rotas[0].Url := Url;
              Rotas[0].Tailscale := Item.GetValue<Boolean>('tailscale', False);
            end;
          end;

          if Length(Rotas) = 0 then
          begin
            // Entrada descartada em silêncio era o pior caso: a tela lista o
            // JSON cru e mostra o servidor, enquanto o registro não tem nada.
            if FLogger <> nil then
              FLogger.Warn('servidores', Format(
                'cadastro "%s" ignorado: nenhuma rota valida',
                [Item.GetValue<string>('name', '(sem nome)')]));
            Continue;
          end;
          SetLength(Lista, Length(Lista) + 1);
          Lista[High(Lista)].Nome := Item.GetValue<string>('name', '');
          Lista[High(Lista)].Rotas := Rotas;
          Lista[High(Lista)].Usuario := Item.GetValue<string>('user', '');
          Lista[High(Lista)].Senha := Item.GetValue<string>('password', '');
        end;
    end;
  finally
    Valor.Free;
  end;

  FLock.Enter;
  try
    FServidores := Lista;
    FEscolha.Clear;
    FQuando.Clear;
  finally
    FLock.Leave;
  end;

  // No log, e nao so em memória: um cadastro que o arquivo tem e o registro não
  // é exatamente o caso difícil de enxergar -- a tela lista o JSON cru e parece
  // certa, enquanto a busca do endereço não acha nada.
  if FLogger <> nil then
    FLogger.Info('servidores', 'cadastro lido: ' + Diagnostico);
end;

function TRegistroServidores.AcharServidor(const Nome: string;
  out Servidor: TServidorCadastrado): Boolean;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FServidores) do
      if SameText(FServidores[I].Nome, Nome) then
      begin
        Servidor := FServidores[I];
        Exit(True);
      end;
  finally
    FLock.Leave;
  end;
  Servidor := Default(TServidorCadastrado);
  Result := False;
end;

function TRegistroServidores.EmCache(const Nome: string;
  out Url: string): Boolean;
var
  T: Cardinal;
begin
  Result := False;
  Url := '';
  FLock.Enter;
  try
    if not FEscolha.TryGetValue(LowerCase(Nome), Url) then Exit;
    if not FQuando.TryGetValue(LowerCase(Nome), T) then Exit;
    // TThread.GetTickCount64 evita a volta ao zero de 49 dias do GetTickCount.
    Result := (TThread.GetTickCount64 - T) < VALIDADE_MS;
  finally
    FLock.Leave;
  end;
end;

procedure TRegistroServidores.Guardar(const Nome, Url: string);
begin
  FLock.Enter;
  try
    FEscolha.AddOrSetValue(LowerCase(Nome), Url);
    FQuando.AddOrSetValue(LowerCase(Nome), Cardinal(TThread.GetTickCount64));
  finally
    FLock.Leave;
  end;
end;

procedure TRegistroServidores.Invalidar(const Nome: string);
begin
  FLock.Enter;
  try
    FEscolha.Remove(LowerCase(Nome));
    FQuando.Remove(LowerCase(Nome));
  finally
    FLock.Leave;
  end;
end;

function TRegistroServidores.Escolher(
  const Servidor: TServidorCadastrado): string;
var
  I: Integer;
  Host: string;
  Porta: Word;
  IdxTailnet: Integer;
begin
  // Uma rota só: não há o que escolher, e sondar seria puro atraso.
  if Length(Servidor.Rotas) = 1 then
    Exit(Servidor.Rotas[0].Url);

  IdxTailnet := -1;

  // 1. as rotas comuns, na ordem do cadastro.
  for I := 0 to High(Servidor.Rotas) do
  begin
    if Servidor.Rotas[I].Tailscale then
    begin
      if IdxTailnet < 0 then IdxTailnet := I;
      Continue;
    end;
    if not HostEPortaDe(Servidor.Rotas[I].Url, Host, Porta) then Continue;
    if TailnetReachable(Host, Porta, SONDA_MS) then
    begin
      FLogger.Debug('servidores', Format('%s: %s respondeu',
        [Servidor.Nome, Servidor.Rotas[I].Url]));
      Exit(Servidor.Rotas[I].Url);
    end;
  end;

  // 2. sobrou a tailnet. Aqui sim vale abrir o Tailscale: nenhuma outra rota
  //    respondeu, então ou o túnel sobe ou não há caminho nenhum.
  if IdxTailnet >= 0 then
  begin
    if HostEPortaDe(Servidor.Rotas[IdxTailnet].Url, Host, Porta) then
    begin
      FLogger.Info('servidores', Format(
        '%s: so a rota de tailnet resta; garantindo o tunel ate %s:%d',
        [Servidor.Nome, Host, Porta]));
      EnsureTailnetUp(Host, Porta, FLogger);
    end;
    Exit(Servidor.Rotas[IdxTailnet].Url);
  end;

  // 3. nada respondeu e não há tailnet: a primeira, para o erro ser de
  //    conexão -- que diz o que houve -- e não "servidor sem rota".
  if Length(Servidor.Rotas) > 0 then
    Result := Servidor.Rotas[0].Url
  else
    Result := '';
end;

function TRegistroServidores.Credencial(const Nome: string;
  out Usuario, Senha: string): Boolean;
var
  Servidor: TServidorCadastrado;
begin
  Usuario := '';
  Senha := '';
  Result := AcharServidor(Nome, Servidor) and (Trim(Servidor.Usuario) <> '');
  if Result then
  begin
    Usuario := Servidor.Usuario;
    Senha := Servidor.Senha;
  end;
end;

function TRegistroServidores.Diagnostico: string;
var
  I: Integer;
  Nomes: string;
begin
  FLock.Enter;
  try
    if Length(FServidores) = 0 then
      Exit('nenhum servidor no cadastro em memoria');
    Nomes := '';
    for I := 0 to High(FServidores) do
    begin
      if Nomes <> '' then Nomes := Nomes + ', ';
      Nomes := Nomes + FServidores[I].Nome + ' (' +
               IntToStr(Length(FServidores[I].Rotas)) + ' rota' +
               IfThen(Length(FServidores[I].Rotas) = 1, '', 's') + ')';
    end;
    Result := Format('%d no cadastro: %s', [Length(FServidores), Nomes]);
  finally
    FLock.Leave;
  end;
end;

function TRegistroServidores.UrlDe(const Nome: string): string;
var
  Servidor: TServidorCadastrado;
begin
  Result := '';
  if Trim(Nome) = '' then Exit;
  if EmCache(Nome, Result) then Exit;
  if not AcharServidor(Nome, Servidor) then
  begin
    if FLogger <> nil then
      FLogger.Warn('servidores', Format('pediram "%s"; %s', [Nome, Diagnostico]));
    Exit('');
  end;
  Result := Escolher(Servidor);
  if Result <> '' then
  begin
    Guardar(Nome, Result);
    if FLogger <> nil then
      FLogger.Debug('servidores', Format('%s -> %s', [Nome, Result]));
  end
  else if FLogger <> nil then
    FLogger.Warn('servidores', Format(
      '%s esta cadastrado mas nao sobrou endereco: %d rota(s)',
      [Nome, Length(Servidor.Rotas)]));
end;

function TRegistroServidores.SondarTodas(const Nome: string): TJSONObject;
var
  Servidor: TServidorCadastrado;
  Arr: TJSONArray;
  Item: TJSONObject;
  I: Integer;
  Host, Escolhida: string;
  Porta: Word;
  T0: Cardinal;
  Ok: Boolean;
begin
  Result := TJSONObject.Create;
  Result.AddPair('server', Nome);
  Arr := TJSONArray.Create;
  Result.AddPair('routes', Arr);

  if not AcharServidor(Nome, Servidor) then
  begin
    Result.AddPair('error', 'servidor nao cadastrado');
    Exit;
  end;

  for I := 0 to High(Servidor.Rotas) do
  begin
    Item := TJSONObject.Create;
    Item.AddPair('url', Servidor.Rotas[I].Url);
    Item.AddPair('tailscale', TJSONBool.Create(Servidor.Rotas[I].Tailscale));
    Ok := False;
    T0 := Cardinal(TThread.GetTickCount64);
    if HostEPortaDe(Servidor.Rotas[I].Url, Host, Porta) then
      // TailnetReachable, e nao HostReachable: para um nome .ts.net o connect
      // sozinho responde "sim" contra a pagina de NXDOMAIN da operadora, e a
      // tela diria que a rota do Tailscale esta de pe quando nao esta.
      Ok := TailnetReachable(Host, Porta, SONDA_MS)
    else
      Item.AddPair('error', 'endereco invalido');
    Item.AddPair('ok', TJSONBool.Create(Ok));
    Item.AddPair('ms', TJSONNumber.Create(
      Int64(Cardinal(TThread.GetTickCount64) - T0)));
    Arr.AddElement(Item);
  end;

  // Qual seria usada agora. Sem sondar de novo e sem abrir o Tailscale: é só o
  // que já está em cache, ou a primeira que respondeu nesta sondagem.
  if not EmCache(Nome, Escolhida) then
  begin
    Escolhida := '';
    for I := 0 to Arr.Count - 1 do
      if (Arr.Items[I] as TJSONObject).GetValue<Boolean>('ok', False) then
      begin
        Escolhida := (Arr.Items[I] as TJSONObject).GetValue<string>('url', '');
        Break;
      end;
  end;
  Result.AddPair('chosen', Escolhida);
end;

end.
