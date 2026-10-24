unit Vms.Db.Schema;

// Deixa o banco na versao que este executavel entende, e nada mais.
//
// A versao mora em `PRAGMA user_version`, dentro do proprio arquivo — nao numa
// tabela. E o unico lugar que se pode consultar ANTES de saber se existe tabela
// alguma, e e transacional junto com o resto.
//
//   0                      arquivo novo (ou vazio): roda o schema inteiro
//   = SCHEMA_VERSION       em dia, nao faz nada
//   < SCHEMA_VERSION       roda os passos que faltam, um por vez
//   > SCHEMA_VERSION       PARA. Ver abaixo.
//
// ## Por que um banco mais novo que o executavel e erro, e nao aviso
//
// Rodar um binario antigo sobre um arquivo novo e o caminho mais curto para
// perder gravacao: ele nao conhece as colunas que existem, escreve pela metade,
// e a versao nova depois le lixo. Melhor recusar subir e dizer o porque — a
// pessoa troca o executavel de volta em trinta segundos, enquanto dado
// corrompido nao volta.

interface

uses
  System.SysUtils,
  System.IOUtils,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  Vms.Db.Intf,
  Vms.Db.Schema.Sql;

// <pasta do executavel>\vmsserver.db
//
// Junto do EXE, e nao junto das gravacoes: o storageDir costuma ser o disco
// grande e lento, e ele e configuracao — estaria dentro do proprio banco que se
// esta tentando abrir.
function DefaultDbPath: string;

// Cria ou atualiza. Levanta EDbError com um texto que explica o que fazer.
// O relogio entra so para carimbar a criacao — mesmo IClock do resto, para o
// carimbo do banco nao discordar do carimbo das gravacoes.
procedure EnsureSchema(const Db: IDbQueue; const Clock: IClock;
                       const Logger: ILogger);

// Uma linha para o log da subida: versao, caminho e tamanho.
function DescribeDb(const Db: IDbQueue): string;

implementation

const
  DB_FILE = 'vmsserver.db';

function DefaultDbPath: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), DB_FILE);
end;

function CurrentVersion(const Db: IDbQueue): Int64;
begin
  // A coluna que o SQLite devolve para este PRAGMA chama-se 'user_version'.
  Result := Db.ReadInt64('PRAGMA user_version', [], 'user_version', 0);
end;

procedure EnsureSchema(const Db: IDbQueue; const Clock: IClock;
  const Logger: ILogger);
var
  Versao: Int64;
  Agora: Int64;
begin
  Versao := CurrentVersion(Db);

  if Versao > SCHEMA_VERSION then
    raise EDbError.CreateFmt(
      'o banco %s esta na versao %d e este vmsserver entende ate a %d. ' +
      'Isto acontece quando se volta para um executavel mais antigo. ' +
      'Use o executavel novo, ou guarde este arquivo e comece outro.',
      [Db.DbPath, Versao, SCHEMA_VERSION]);

  if Versao = SCHEMA_VERSION then
  begin
    // Em dia quanto a TABELAS, o que nao quer dizer em dia quanto a AJUSTES.
    // Uma versao nova do vmsserver pode trazer chaves novas em `setting`, e o
    // banco criado antes dela nao as tem. Como o bloco e INSERT OR IGNORE, ele
    // acrescenta o que falta e nao toca no que o usuario mudou.
    //
    // Sem isto a chave nova nunca existia, e como a gravacao de ajuste e um
    // UPDATE, gravar nela nao dava erro nem gravava nada -- foi o que aconteceu
    // com auth.hash: "senha definida" e nada no banco.
    try
      Db.ExecScript(SettingsSeedSql);
    except
      on E: Exception do
        if Logger <> nil then
          Logger.Warn('db', 'nao consegui semear ajustes novos: ' + E.Message);
    end;
    if Logger <> nil then
      Logger.Info('db', Format('esquema v%d, em dia', [Versao]));
    Exit;
  end;

  if Versao = 0 then
  begin
    if Logger <> nil then
      Logger.Info('db', 'banco novo: criando o esquema v' +
        IntToStr(SCHEMA_VERSION));
    try
      Db.ExecScript(SchemaSql);
    except
      on E: Exception do
        // Falhar no meio deixa o arquivo pela metade. Nao ha o que salvar num
        // banco que nunca chegou a existir, e dizer para apagar e mais honesto
        // do que tentar consertar automaticamente algo que nem se sabe o
        // estado.
        raise EDbError.CreateFmt(
          'nao consegui criar o esquema em %s: %s. O arquivo pode ter ficado ' +
          'pela metade — apague-o e suba de novo.', [Db.DbPath, E.Message]);
    end;

    if Clock <> nil then Agora := Clock.NowUtcMs else Agora := 0;
    Db.Exec('INSERT OR IGNORE INTO db_meta (key, value) VALUES (?, ?)',
            ['created_at_ms', IntToStr(Agora)]);
    Db.Exec('INSERT OR REPLACE INTO db_meta (key, value) VALUES (?, ?)',
            ['schema_version', IntToStr(SCHEMA_VERSION)]);
    Db.Exec('INSERT OR REPLACE INTO db_meta (key, value) VALUES (?, ?)',
            ['exe', ParamStr(0)]);

    if Logger <> nil then
      Logger.Info('db', 'esquema criado');
    Exit;
  end;

  // 0 < Versao < SCHEMA_VERSION: aqui entram os schema-v2.sql, v3... quando
  // existirem. Enquanto so ha a v1, chegar neste ponto significa um arquivo
  // com uma versao que nunca foi publicada.
  raise EDbError.CreateFmt(
    'o banco %s esta na versao %d e nao ha passo de atualizacao dela para a %d.',
    [Db.DbPath, Versao, SCHEMA_VERSION]);
end;

function DescribeDb(const Db: IDbQueue): string;
var
  Bytes: Int64;
  Tabelas: Int64;
begin
  Bytes := 0;
  try
    if TFile.Exists(Db.DbPath) then
      Bytes := TFile.GetSize(Db.DbPath);
  except
    Bytes := 0;
  end;
  Tabelas := Db.ReadInt64(
    'SELECT COUNT(*) AS n FROM sqlite_master WHERE type = ''table''', [], 'n', 0);
  Result := Format('%s | v%d | %d tabelas | %.0f KB',
    [Db.DbPath, SCHEMA_VERSION, Tabelas, Bytes / 1024]);
end;

end.
