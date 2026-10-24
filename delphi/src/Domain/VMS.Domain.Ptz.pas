unit VMS.Domain.Ptz;

// Onde a rota HTTP encontra a sessao viva de uma camera para mandar PTZ.
//
// O problema que isto resolve: o comando tem de sair pela conexao que JA esta
// autenticada -- a mesma que grava. Logar de novo a cada clique custaria uns
// cem milissegundos por toque, e um botao de direcao manda dois comandos, o de
// andar e o de parar. Mas quem atende o HTTP nao conhece o supervisor da
// camera, e o supervisor esta em src/Domain, abaixo do servidor: nao pode
// enxergar para cima.
//
// Entao as duas pontas se encontram aqui, num registro por NOME de camera. Quem
// tem sessao viva se anuncia; quem quer mandar comando procura. Sessao que cai
// se desanuncia, e a procura devolve nil -- que e como a rota sabe dizer "essa
// camera nao esta conectada" em vez de esperar por um socket morto.
//
// Registro de instancia unica, e nao passado por construtor como o resto: a
// alternativa seria enfiar mais uma dependencia em cinco camadas de composicao
// para chegar de um lado ao outro. O preco e conhecido e pequeno, porque o
// conteudo aqui e uma tabela de nomes e nada mais.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

type
  // Uma conversa aberta com o alto-falante da camera.
  //
  // Conexao PROPRIA, e nao a do video: a camera abre um canal duplex e passa a
  // mandar o microfone dela por ali, e isso no meio do fluxo de video seria
  // audio a mais misturado no parser. Quem a abre e a sessao viva, que sabe o
  // endereco e a senha; quem a guarda e o TFalaRegistry, abaixo.
  IFalaSession = interface
    ['{0B7E2D4A-5C61-4F8E-A3B2-9D1C7E6F5A48}']
    // PCM 16 bits little-endian, 8 kHz, mono. Converter e dar o ritmo e com
    // ela: a pagina manda aos pedacos, na hora que o HTTP deixa, e a camera
    // quer um quadro a cada 40 ms. False = a conversa ja acabou.
    function Enviar(const Pcm: TBytes): Boolean;
    // Encerra e espera as threads dela. Chamar duas vezes nao faz mal.
    procedure Fechar;
    // False depois de Fechar, de a conexao cair, ou de ficar calada por
    // alguns segundos -- ela se encerra sozinha para nao prender o
    // alto-falante da camera se a pagina sumir sem dizer tchau.
    function Viva: Boolean;
  end;

  // O que uma sessao capaz de PTZ oferece.
  //
  // Iniciar=False e a PARADA do mesmo comando: o protocolo das cameras DVRIP
  // manda a mesma mensagem para andar e para parar, mudando um campo. Quem
  // chama e responsavel por mandar a parada -- sem ela a camera gira ate o fim
  // do curso.
  IPtzSession = interface
    ['{6E1C4B90-7A3D-4C2E-9F51-2B8D0E4A7C33}']
    function MoverPtz(const Comando: string; Passo, Canal: Integer;
                      Iniciar: Boolean): Boolean;
    // Manda a camera para uma posicao guardada. Sem parada depois: quem vai a
    // um preset para sozinho ao chegar.
    // Comando vazio = ir para o preset, que e o uso comum. Os outros dois
    // valores que o protocolo aceita servem para gravar a posicao atual e para
    // apagar a guardada; o nome vem de cima como texto para esta unit nao
    // precisar conhecer o vocabulario do DVRIP.
    function IrParaPreset(Preset, Canal: Integer;
                          const Comando: string = ''): Boolean;
    // Pede uma secao da configuracao da camera, pelo nome que ela usa. A
    // resposta NAO volta aqui: ela chega pela thread que le o socket e vai
    // para o log, como as outras mensagens de controle. Serve para descobrir
    // o que uma camera especifica sabe fazer, sem capturar rede.
    function PerguntarConfig(const Nome: string): Boolean;
    // Abre a fala: conecta, loga e reserva o alto-falante. Bloqueia ate a
    // camera responder. nil = nao deu, e Motivo diz por que.
    function AbrirFala(out Motivo: string): IFalaSession;
  end;

type
  TPtzRegistry = class
  strict private
    class var FLock: TCriticalSection;
    class var FPor: TDictionary<string, IPtzSession>;
  public
    class constructor Create;
    class destructor Destroy;
    // A sessao se anuncia ao ficar pronta e se apaga ao cair. Anunciar duas
    // vezes o mesmo nome substitui: reconexao troca a sessao, e a antiga ja
    // nao serve.
    class procedure Anunciar(const Camera: string; const Sessao: IPtzSession);
    class procedure Apagar(const Camera: string);
    // nil = nao ha sessao viva capaz de PTZ para esta camera.
    class function Achar(const Camera: string): IPtzSession;
  end;

  // As falas abertas, uma por camera.
  //
  // A pagina manda o audio em varios POSTs seguidos, e abrir uma conexao por
  // POST seria um login a cada 160 ms. A primeira abre e as seguintes acham a
  // mesma aqui.
  //
  // O atendimento da rota mora aqui, e nao em cada servidor, pelo mesmo motivo
  // do ComandoDvripDe: o app e o vmsserver respondem /api/fala, e duas copias
  // seriam duas chances de divergir.
  TFalaRegistry = class
  strict private
    class var FLock: TCriticalSection;
    class var FPor: TDictionary<string, IFalaSession>;
    class function Enviar(const Camera: string; const Pcm: TBytes;
                          out Motivo: string): Boolean;
    class procedure Fechar(const Camera: string);
  public
    class constructor Create;
    class destructor Destroy;
    // /api/fala?camera=X&acao=testar|enviar|fechar. Pcm e o corpo do POST de
    // `enviar`. Devolve o JSON da resposta e o status HTTP.
    class function Atender(const Camera, Acao: string; const Pcm: TBytes;
                           out Status: Integer): string;
  end;

implementation

uses
  System.JSON;

class constructor TPtzRegistry.Create;
begin
  FLock := TCriticalSection.Create;
  FPor := TDictionary<string, IPtzSession>.Create;
end;

class destructor TPtzRegistry.Destroy;
begin
  FPor.Free;
  FLock.Free;
end;

class procedure TPtzRegistry.Anunciar(const Camera: string;
  const Sessao: IPtzSession);
begin
  if Trim(Camera) = '' then Exit;
  FLock.Enter;
  try
    FPor.AddOrSetValue(LowerCase(Trim(Camera)), Sessao);
  finally
    FLock.Leave;
  end;
end;

class procedure TPtzRegistry.Apagar(const Camera: string);
begin
  FLock.Enter;
  try
    FPor.Remove(LowerCase(Trim(Camera)));
  finally
    FLock.Leave;
  end;
end;

class function TPtzRegistry.Achar(const Camera: string): IPtzSession;
begin
  Result := nil;
  FLock.Enter;
  try
    FPor.TryGetValue(LowerCase(Trim(Camera)), Result);
  finally
    FLock.Leave;
  end;
end;

{ TFalaRegistry }

class constructor TFalaRegistry.Create;
begin
  FLock := TCriticalSection.Create;
  FPor := TDictionary<string, IFalaSession>.Create;
end;

class destructor TFalaRegistry.Destroy;
begin
  // Com fala aberta, a tabela fica sem liberar, de proposito. Liberar solta a
  // ultima referencia, e a fala fecha o socket dela -- mas esta unit nao usa o
  // Indy, entao nada garante que ele ainda nao foi finalizado a esta altura.
  // O processo esta acabando e o sistema fecha o socket de qualquer jeito.
  if FPor.Count = 0 then
  begin
    FPor.Free;
    FLock.Free;
  end;
end;

class function TFalaRegistry.Enviar(const Camera: string; const Pcm: TBytes;
  out Motivo: string): Boolean;
var
  Chave: string;
  Fala: IFalaSession;
  Sessao: IPtzSession;
  Tentativa: Integer;
begin
  Result := False;
  Motivo := '';
  Chave := LowerCase(Trim(Camera));
  // Duas voltas: a fala pode se encerrar por silencio entre o achar e o
  // enviar, e ai a segunda volta abre outra em vez de devolver erro por uma
  // corrida que a pagina nao tem como entender.
  for Tentativa := 1 to 2 do
  begin
    // A trava fica presa durante a abertura, que conecta e loga. De proposito:
    // dois POSTs chegando juntos no comeco abririam duas conversas, e a
    // camera so tem um alto-falante. O preco e que uma camera lenta para
    // responder segura a primeira fala das outras -- raro, e so no comeco.
    FLock.Enter;
    try
      if FPor.TryGetValue(Chave, Fala) and not Fala.Viva then
      begin
        FPor.Remove(Chave);
        Fala := nil;
      end;
      if Fala = nil then
      begin
        Sessao := TPtzRegistry.Achar(Camera);
        if Sessao = nil then
        begin
          Motivo := 'sem sessao DVRIP viva para ' + Camera;
          Exit;
        end;
        Fala := Sessao.AbrirFala(Motivo);
        if Fala = nil then Exit;
        FPor.Add(Chave, Fala);
      end;
    finally
      FLock.Leave;
    end;
    if Fala.Enviar(Pcm) then Exit(True);
    Fala := nil;
  end;
  Motivo := 'a conversa com a camera caiu';
end;

class procedure TFalaRegistry.Fechar(const Camera: string);
var
  Fala: IFalaSession;
begin
  Fala := nil;
  FLock.Enter;
  try
    if FPor.TryGetValue(LowerCase(Trim(Camera)), Fala) then
      FPor.Remove(LowerCase(Trim(Camera)));
  finally
    FLock.Leave;
  end;
  // Fora da trava: fechar espera as threads da fala, e isso nao pode segurar
  // quem esta falando com outra camera.
  if Fala <> nil then
    Fala.Fechar;
end;

class function TFalaRegistry.Atender(const Camera, Acao: string;
  const Pcm: TBytes; out Status: Integer): string;
var
  Ok: Boolean;
  Motivo: string;
  Obj: TJSONObject;
begin
  Status := 200;
  Motivo := '';
  if Acao = 'testar' then
  begin
    // So diz se ha por onde tentar. Se a camera tem alto-falante, so o Claim
    // responde -- e ele prende o alto-falante, entao nao e coisa de sondar.
    Ok := TPtzRegistry.Achar(Camera) <> nil;
    if not Ok then Motivo := 'sem sessao DVRIP viva para ' + Camera;
  end
  else if Acao = 'enviar' then
  begin
    if Length(Pcm) = 0 then
    begin
      Status := 400;
      Motivo := 'corpo vazio: mande PCM 16 bits, 8 kHz, mono';
      Ok := False;
    end
    else
      Ok := Enviar(Camera, Pcm, Motivo);
  end
  else if Acao = 'fechar' then
  begin
    Fechar(Camera);
    Ok := True;
  end
  else
  begin
    Status := 400;
    Motivo := Acao + ' nao existe: use testar, enviar ou fechar';
    Ok := False;
  end;

  Obj := TJSONObject.Create;
  try
    Obj.AddPair('camera', Camera);
    Obj.AddPair('acao', Acao);
    Obj.AddPair('via', 'dvrip');
    Obj.AddPair('ok', TJSONBool.Create(Ok));
    if Motivo <> '' then Obj.AddPair('motivo', Motivo);
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

end.
