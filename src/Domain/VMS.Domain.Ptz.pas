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

implementation

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

end.
