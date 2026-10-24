unit Vms.Db.Intf;

// A fronteira do banco. Uma interface, e o vocabulario minimo de uma linha.
//
// Regra da casa: **so o Vms.Db.Queue toca no FireDAC.** Nada acima daqui
// conhece TFDConnection, TFDQuery ou TFDScript — do mesmo jeito que nada acima
// do Vms.Thumb.FFmpeg conhece AVCodecContext. Sem esta unit, `Vms.Server.Api`
// e o worker de analise passariam a arrastar FireDAC atras de si, e nao daria
// para testa-los com um duble.
//
// ## Uma thread e dona, as outras enfileiram
//
// Existe UMA thread com a conexao aberta, e nenhuma linha de SQL roda fora
// dela. As demais submetem trabalho e escolhem se esperam:
//
//   Post    nao espera. Log, eventos, progresso, indice de miniaturas.
//   Exec    espera, devolve linhas afetadas. Importacao, encerramento.
//   Read    espera, e o OnRow roda NA THREAD DA CONEXAO, uma linha por vez.
//
// Serializar assim e propriedade da estrutura, e nao disciplina que alguem
// precisa lembrar de seguir: nao ha como um chamador pegar a conexao.
//
// ## Por que os parametros sao Variant
//
// `array of const` daria um TVarRec, que aponta para a PILHA de quem chamou.
// Guardar isso numa fila para executar depois e ponteiro pendurado: o Post
// voltaria, a pilha seria reusada, e o parametro chegaria ao banco como lixo.
// Variant copia o valor, e por isso e o unico tipo que atravessa a fila.
//
// ## Por que a linha e IDbRow, e nao TFDQuery
//
// O dataset e preso a conexao, que e da thread dona. Devolve-lo vivo para quem
// chamou seria uma corrida no instante em que a thread dona seguisse para o
// proximo item. O OnRow roda la dentro e copia para registro simples; o que
// atravessa a fronteira sao TVmsEvent, TVmsFileInfo e afins, que ja existem.

interface

uses
  System.SysUtils;

type
  EDbError = class(Exception);

  // Uma linha do resultado, durante o OnRow. Acesso por NOME, e nao por
  // indice: o SQL e a leitura ficam lado a lado no codigo, e nome errado
  // levanta excecao na hora, enquanto indice errado devolveria a coluna do
  // vizinho calado.
  //
  // Vale so dentro do OnRow. Guardar a referencia para depois nao funciona: o
  // que ela le e o cursor, que ja terá andado.
  IDbRow = interface
    ['{7B3F1C48-2E95-4A60-9D71-4C8E0A5B3F62}']
    // Quais colunas vieram. So quem NAO escreveu o SELECT precisa disto — a
    // rota /api/sql, que recebe a consulta pronta de fora. Quem escreve o SQL
    // ja sabe os nomes e usa os acessores por nome, que sao mais legiveis.
    function ColumnCount: Integer;
    function ColumnName(Index: Integer): string;
    function IsNull(const Name: string): Boolean;
    function AsInt64(const Name: string): Int64;
    function AsInt(const Name: string): Integer;
    function AsBool(const Name: string): Boolean;
    function AsFloat(const Name: string): Double;
    function AsString(const Name: string): string;
  end;

  TDbRowProc = reference to procedure(const Row: IDbRow);

  IDbQueue = interface
    ['{2A6D9E13-5F07-4B84-A3C6-1E9B7D0C4A58}']
    // ------------------------------------------------ nao espera
    // Volta assim que o item entra na fila. Quem chama NAO fica sabendo se deu
    // certo — falha vai para o log de emergencia (ver Vms.Db.Queue), nunca de
    // volta para o banco, senao uma falha do log geraria outra escrita de log.
    procedure Post(const Sql: string; const Params: array of Variant);
    procedure PostScript(const Script: string);

    // ------------------------------------------------ espera
    // Levanta EDbError na thread de quem chamou, com a mensagem do banco.
    function Exec(const Sql: string; const Params: array of Variant): Integer;
    // Varios comandos num texto so (o schema-vN.sql). ExecSQL executa UM;
    // quem entende `;`, comentario e PRAGMA e o TFDScript.
    procedure ExecScript(const Script: string);
    // OnRow uma vez por linha, na thread da conexao. Quem chamou fica parado
    // ate a ultima linha.
    procedure Read(const Sql: string; const Params: array of Variant;
                   const OnRow: TDbRowProc);
    // Atalho para `select <coluna> ...` de uma linha so. Column e o nome da
    // coluna no resultado; Default vale quando a consulta nao devolveu nada.
    function ReadInt64(const Sql: string; const Params: array of Variant;
                       const Column: string; Default: Int64 = 0): Int64;

    // ------------------------------------------------ estado
    function IsOpen: Boolean;
    function DbPath: string;
    // Quantos itens ainda nao foram executados. So para o log de encerramento.
    function Pending: Integer;
  end;

implementation

end.
