# Banco de dados do vmsserver — planejamento

Tudo o que hoje é estado espalhado em arquivo passa a viver em tabelas, **menos
o vídeo**. Este documento é o desenho, antes de escrever código.

SQLite 3.53.4, x64, WAL — a DLL já está em `vms/bin`.

---

## 1. O que entra, o que fica de fora

| hoje | vira | por quê |
|---|---|---|
| `_index.json` (inventário das gravações) | tabela `recording` | `/api/days` e `/api/segments` viram agregação em SQL em vez de varrer JSON + disco |
| `<cam>/events/*.vev` | tabela `event` | consulta por janela, rótulo e confiança sem ler o dia inteiro |
| `<cam>/events/progress.txt` | tabela `analysis_progress` | ganha o modelo que produziu o progresso |
| `logs/*.log` | tabela `log` | correlacionar log com evento e gravação numa consulta só |
| `vmsserver.json` (câmeras + ajustes) | `camera`, `camera_endpoint`, `setting` | editável pela API/app, sem mexer em arquivo |
| **`.vms` e `.vms.idx`** | **ficam como estão** | é o vídeo e o índice dele; formato próprio, já resolvido |
| **miniaturas `.jpg`** | ficam em disco, tabela `thumb` só indexa | JPEG é payload binário, não dado estruturado — mesmo critério que exclui o `.vms` |

O DDL completo, com o porquê de cada coluna, está em
[`vms/src/Db/schema-v1.sql`](../vms/src/Db/schema-v1.sql) — é o arquivo que o
`Vms.Db.Schema` vai executar, não uma cópia. `python tools/testschema.py` o roda
no sqlite de verdade: 23 verificações (CHECKs recusando o impossível, cascata,
e as consultas que a API vai fazer).

O **app não ganha SQLite**. Ele fala HTTP com o servidor; o `cameras.json` dele
continua sendo dele. Só o `vmsserver.exe` abre o banco.

---

## 2. Onde o banco mora, e o problema do ovo e da galinha

Com a config dentro do banco, o servidor precisa saber onde o banco está **antes**
de conseguir ler qualquer configuração. Resolução:

```
<pasta do executável>\vmsserver.db      ← padrão, sem precisar de arquivo nenhum
```

O caminho **não é configurável**, e é de propósito: um caminho de banco guardado
na configuração que mora dentro do próprio banco é uma volta que não fecha. Fica
onde sempre dá para achar sem perguntar a ninguém.

Pela mesma razão, o **cache de miniaturas** também tem lugar fixo:

```
<pasta do executável>/cache/<câmera>/thumbs/2026-08-23/1437.jpg
```

Ele saiu de dentro do `storageDir`. São naturezas diferentes: gravação é o dado,
e vai para o disco grande que o usuário escolheu; miniatura é cache descartável,
some sem consequência e é regenerada. Juntas, a pasta de gravações carregava
peso que ninguém precisa mover num backup.

O `vmsserver.json` continua existindo e **não é renomeado**: na primeira subida
o conteúdo dele é importado para as tabelas (marcado em
`db_meta.config_imported_at_ms`) e ele fica como cópia do que havia antes.
Daí em diante, editá-lo não muda mais nada.

> As senhas das câmeras ficam em texto no banco, exatamente como hoje ficam em
> texto no JSON. A troca não piora nem melhora isso; se um dia for para
> proteger, o lugar é aqui e vale para os dois.

---

## 3. O esquema

### Identidade e configuração

```sql
PRAGMA user_version = 1;          -- é o número que a migração consulta

CREATE TABLE camera (
  id                     INTEGER PRIMARY KEY,
  name                   TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  enabled                INTEGER NOT NULL DEFAULT 1,
  record_audio           INTEGER NOT NULL DEFAULT 1,
  filename_pattern       TEXT    NOT NULL DEFAULT '',
  audio_delay_ms         INTEGER NOT NULL DEFAULT 200,
  video_delay_ms         INTEGER NOT NULL DEFAULT 200,
  max_reconnect_attempts INTEGER NOT NULL DEFAULT 0,
  reconnect_initial_ms   INTEGER NOT NULL DEFAULT 2000,
  reconnect_max_ms       INTEGER NOT NULL DEFAULT 30000,
  reconnect_multiplier   REAL    NOT NULL DEFAULT 2.0,
  no_rtp_timeout_ms      INTEGER NOT NULL DEFAULT 10000,
  created_at_ms          INTEGER NOT NULL,
  updated_at_ms          INTEGER NOT NULL
);

-- Uma câmera tem VÁRIOS caminhos até ela (a LAN dela, o servidor que a
-- republica, a tailnet), em ordem de prioridade — ver VMS.Net.Probe. Por isso
-- é tabela filha, e não colunas: o número de caminhos varia por câmera.
CREATE TABLE camera_endpoint (
  id             INTEGER PRIMARY KEY,
  camera_id      INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  ord            INTEGER NOT NULL,          -- 0 = o preferido
  label          TEXT    NOT NULL DEFAULT '',
  url            TEXT    NOT NULL,
  user_name      TEXT    NOT NULL DEFAULT '',
  password       TEXT    NOT NULL DEFAULT '',
  transports     TEXT    NOT NULL DEFAULT 'tcp,udp',
  uses_tailscale INTEGER NOT NULL DEFAULT 0,
  UNIQUE (camera_id, ord)
);

-- Todo o resto da config, com as MESMAS chaves do JSON de hoje.
CREATE TABLE setting (
  key           TEXT PRIMARY KEY,    -- 'analytics.stepMs', 'retention.maxDays'
  value         TEXT NOT NULL,       -- sempre texto; quem lê converte
  updated_at_ms INTEGER NOT NULL
);
```

**Por que `setting` é chave/valor e não colunas tipadas.** São ~25 ajustes
heterogêneos de seis seções (`block`, `retention`, `live`, `api`, `analytics`,
raiz). Com chave/valor: a migração do JSON é um laço, acrescentar um ajuste é um
`INSERT` em vez de um `ALTER TABLE`, e os `GetJsonInt/Bool/Str` que já existem
viram `GetSettingInt/Bool/Str` com a mesma assinatura — o `TVmsServerConfig`
quase não muda de forma.

### Gravações — substitui o `_index.json`

```sql
CREATE TABLE recording (
  id             INTEGER PRIMARY KEY,
  camera_id      INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  name           TEXT    NOT NULL,        -- nome base do .vms
  start_ms       INTEGER NOT NULL,
  end_ms         INTEGER NOT NULL,
  duration_ms    INTEGER NOT NULL,
  bytes          INTEGER NOT NULL,
  blocks         INTEGER NOT NULL,
  closed         INTEGER NOT NULL,        -- tem rodapé
  indexed        INTEGER NOT NULL,        -- índice pronto (rodapé ou .idx)
  has_video      INTEGER NOT NULL,
  video_codec    INTEGER NOT NULL,
  width          INTEGER NOT NULL,
  height         INTEGER NOT NULL,
  has_audio      INTEGER NOT NULL,
  audio_codec    INTEGER NOT NULL,
  sample_rate    INTEGER NOT NULL,
  channels       INTEGER NOT NULL,
  -- carimbo do arquivo. Se tamanho ou mtime mudaram, o resumo não vale mais e
  -- a linha é refeita — a mesma regra do cache de hoje, agora persistida.
  stamp_size     INTEGER NOT NULL,
  stamp_mtime_ms INTEGER NOT NULL,
  UNIQUE (camera_id, name)
);
CREATE INDEX ix_recording_span ON recording (camera_id, start_ms, end_ms);
```

É a tabela que mais paga a mudança. Hoje `/api/days` lê o JSON inteiro, cruza com
um `FindFirst` e agrega em Pascal. Vira:

```sql
SELECT date(start_ms/1000, 'unixepoch', 'localtime') AS dia,
       MIN(start_ms), MAX(end_ms), SUM(duration_ms), COUNT(*)
  FROM recording WHERE camera_id = ?
 GROUP BY dia ORDER BY dia;
```

### Eventos — substitui o `.vev`

```sql
CREATE TABLE event (
  id            INTEGER PRIMARY KEY,
  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  start_ms      INTEGER NOT NULL,
  end_ms        INTEGER NOT NULL,
  kind          INTEGER NOT NULL,          -- 0 = movimento, 1 = objeto
  name          TEXT    NOT NULL,          -- 'movimento', 'person', 'car'
  score         REAL    NOT NULL,
  obj_count     INTEGER NOT NULL DEFAULT 1,
  box_l         REAL    NOT NULL DEFAULT 0,
  box_t         REAL    NOT NULL DEFAULT 0,
  box_r         REAL    NOT NULL DEFAULT 0,
  box_b         REAL    NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL
);
CREATE INDEX ix_event_window ON event (camera_id, start_ms);
CREATE INDEX ix_event_name   ON event (camera_id, name, start_ms);
```

A caixa continua **normalizada 0..1** — pelo mesmo motivo de antes, e agora em
`REAL`, sem o arredondamento para `u16` que o formato binário exigia.

**Um ajuste de projeto que caiu deste desenho.** A consulta é por sobreposição
(`start_ms <= :to AND end_ms >= :from`). Um índice em `start_ms` resolve o teto,
mas não o piso: sem um limite de duração, achar os eventos das 14h obriga a
considerar qualquer evento aberto desde sempre. Hoje um evento só fecha depois de
`mergeGapMs` sem avistamento — numa rua movimentada, `movimento` poderia ficar
aberto por horas.

Então entra um teto: **evento que passa de `maxEventMs` (5 min) fecha e começa
outro.** Isso conserta as duas coisas de uma vez — a consulta ganha piso
(`start_ms >= :from - maxEventMs`) e a barra do tempo para de mostrar uma tarja
de quatro horas que não diz nada. É mudança no `TFrameAnalyzer`, não no banco.

### Progresso da análise — substitui o `progress.txt`

```sql
CREATE TABLE analysis_progress (
  camera_id       INTEGER PRIMARY KEY REFERENCES camera(id) ON DELETE CASCADE,
  analyzed_to_ms  INTEGER NOT NULL,
  frames          INTEGER NOT NULL DEFAULT 0,
  decode_failures INTEGER NOT NULL DEFAULT 0,
  model           TEXT    NOT NULL DEFAULT '',
  updated_at_ms   INTEGER NOT NULL
);
```

`model` é novo e resolve uma pegadinha do arquivo de hoje: trocar o `.onnx` sem
apagar o progresso deixava seis horas analisadas pelo modelo velho passando por
analisadas. Agora, `model` diferente do configurado = o progresso daquela câmera
não vale, e a análise recomeça sozinha.

`decode_failures` persiste a contagem que hoje só vai para o log — é o número que
responde se aquelas mensagens do h264 são 37 em 1800 ou 40%.

### Miniaturas — o arquivo fica, o índice entra

```sql
CREATE TABLE thumb (
  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  minute_ms     INTEGER NOT NULL,
  state         INTEGER NOT NULL,     -- 0 = tem imagem, 1 = não há para este minuto
  path          TEXT    NOT NULL DEFAULT '',
  bytes         INTEGER NOT NULL DEFAULT 0,
  width         INTEGER NOT NULL DEFAULT 0,
  height        INTEGER NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (camera_id, minute_ms)
) WITHOUT ROWID;
```

`state = 1` é o ganho: hoje o "este minuto não tem imagem" mora num dicionário em
memória com TTL de 60 s e **morre a cada reinício**. Persistido, arrastar a barra
sobre um trecho sem gravação para de custar uma tentativa de decodificação por
vista, para sempre.

### Log

```sql
CREATE TABLE log (
  id        INTEGER PRIMARY KEY,
  at_ms     INTEGER NOT NULL,
  level     INTEGER NOT NULL,
  tag       TEXT    NOT NULL,        -- 'main', 'session.frente', 'analytics.ayla'
  camera_id INTEGER REFERENCES camera(id) ON DELETE SET NULL,
  message   TEXT    NOT NULL
);
CREATE INDEX ix_log_at  ON log (at_ms);
CREATE INDEX ix_log_tag ON log (tag, at_ms);
```

> **`level` é coluna, não filtro.** Continua valendo o que já vale: nada é
> descartado por nível. Ele entra na linha para quem lê saber o peso do evento,
> nunca para o programa escolher se registra. Ver `VMS.Domain.Logging`.

O console continua imprimindo ao vivo — é como se olha um servidor rodando, e não
se perde isso por causa de uma tabela.

---

## 4. Acesso: uma thread dona, as outras na fila

**Uma thread abre a conexão FireDAC e é a única que toca nela.** As demais
submetem trabalho a uma fila, e escolhem se esperam ou não. Nenhuma linha de SQL
roda fora dessa thread — é o que torna a serialização uma propriedade da
estrutura, e não uma disciplina que alguém precisa lembrar de seguir.

```
 supervisores  workers de análise  sessões RTSP  API  retenção
      │              │                  │        │       │
      └──────────────┴────────┬─────────┴────────┴───────┘
                              ▼
                    fila (FIFO, com lock)
                              │
                              ▼
                  TDbThread  ── dona da TFDConnection
                              │
                              ▼
                       vmsserver.db (WAL)
```

### As três formas de submeter

| forma | espera? | quem usa |
|---|---|---|
| `Post(sql, params)` | não | log, eventos, progresso, índice de miniaturas |
| `Exec(sql, params): Integer` | sim, devolve linhas afetadas | importação da config, encerramento |
| `Read(sql, params, OnRow)` | sim | a API, toda consulta |

```pascal
IDbQueue = interface
  ['{...}']
  // Volta assim que o item entra na fila. O chamador não sabe (nem espera
  // saber) se deu certo — falha vai para o log de emergência, ver abaixo.
  procedure Post(const Sql: string; const Params: array of Variant);
  procedure PostScript(const Script: string);

  // Espera a fila chegar neste item e executa. Levanta a exceção do banco
  // na thread de quem chamou.
  function  Exec(const Sql: string; const Params: array of Variant): Integer;
  function  ExecScript(const Script: string): Boolean;

  // OnRow roda NA THREAD DA CONEXÃO, uma vez por linha; quem chamou fica
  // bloqueado até acabar. Ver a nota sobre TFDQuery logo abaixo.
  procedure Read(const Sql: string; const Params: array of Variant;
                 const OnRow: TProc<TFDQuery>);
end;
```

### Três detalhes que não são estilo, são correção

**`array of Variant`, não `array of const`.** Um `TVarRec` aponta para a pilha de
quem chamou. Guardá-lo numa fila para executar depois é ponteiro pendurado — o
`Post` voltaria, a pilha seria reusada, e o parâmetro chegaria ao banco como
lixo. `Variant` copia o valor.

**O `TFDQuery` não atravessa a fronteira.** Ele é preso à conexão, que é da
thread dona. Devolver um dataset vivo para quem chamou seria uma corrida no
instante em que a thread dona seguisse para o próximo item. Por isso o `OnRow`
roda lá dentro e copia para registros simples; o que atravessa são `TVmsEvent`,
`TVmsFileInfo` e afins, que já existem.

**O erro de um `Post` não pode voltar pela fila.** Se uma inserção falhar (um
`CHECK` recusando o impossível), o caminho natural seria registrar — mas o log
também escreve por esta fila, e uma falha do log geraria outra escrita de log.
Falhas da própria fila vão para o **console e para um arquivo de emergência**,
nunca de volta para o banco.

### Lote

`Post` consecutivos entram numa transação só, com commit a cada **500 itens ou
200 ms**, o que vier primeiro. É o que faz o log de uma rajada de backfill custar
um fsync em vez de milhares.

A fila é **FIFO estrita**: quem chamou `Read` espera, no máximo, o lote corrente
fechar. Deixar leitura furar a fila daria latência menor e a possibilidade de uma
consulta não enxergar um `Post` que já tinha sido submetido — troca ruim, por um
ganho que este volume de escrita não precisa.

### A conexão

```pascal
uses
  System.SysUtils, System.Classes, System.DateUtils,
  FireDAC.Comp.Client, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.Def, FireDAC.DApt, FireDAC.Stan.Async,
  FireDAC.Comp.Script, FireDAC.Comp.ScriptCommands;   // TFDScript, p/ o schema

function NewConnection(const FileName: string): TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  try
    Result.LoginPrompt := False;
    with TFDPhysSQLiteConnectionDefParams(Result.Params) do
    begin
      DriverID    := 'SQLite';
      Database    := FileName;   // ANTES de abrir — ver a nota
      JournalMode := jmWAL;
      Synchronous := snNormal;
      LockingMode := lmNormal;   // não lmExclusive: um cliente de SQLite
                                 // ainda precisa conseguir abrir o arquivo
      SharedCache := False;
      ForeignKeys := fkOn;       // o esquema depende de ON DELETE CASCADE
      BusyTimeout := 5000;
    end;
    // O pré-processador do FireDAC come `&`, `!`, `{}` e `:` do texto do
    // comando e corta script ao meio. Desligado, o SQL chega como está.
    // https://docwiki.embarcadero.com/RADStudio/Sydney/en/Preprocessing_Command_Text_(FireDAC)
    Result.ResourceOptions.MacroCreate  := False;
    Result.ResourceOptions.MacroExpand  := False;
    Result.ResourceOptions.EscapeExpand := False;
    Result.UpdateOptions.LockWait := True;
    Result.Open;
  except
    Result.Free;
    raise;
  end;
end;
```

> **Uma correção na receita.** No trecho original o `Connected := True` vinha
> **antes** de `Params.Values['Database']`. Com o parâmetro ainda vazio, o SQLite
> abre um banco temporário privado, e o `Open` seguinte não reconecta — o
> servidor gravaria tudo num arquivo que some ao fechar, sem erro nenhum.
> `Database` tem de estar preenchido antes de abrir.

> **A `sqlite3.dll` não vai ser usada.** Conferi a instalação: em `win64` só
> existem `FireDAC.Phys.SQLiteWrapper.Stat` e `.FDEStat`, os dois estáticos, e
> nenhum DCU do FireDAC menciona `sqlite3.dll`. O SQLite entra compilado dentro
> do `vmsserver.exe`. Isso é bom — um arquivo a menos para acompanhar o
> executável — e o esquema não usa nada recente (o mais novo é `WITHOUT ROWID`,
> de 2013). A DLL pode sair da pasta de deploy.

### Scripts

`schema-v1.sql` tem vários comandos, e `ExecSQL` executa **um**. Quem roda o
arquivo é o `TFDScript`, que entende `;`, comentários e `PRAGMA` — daí
`PostScript`/`ExecScript` serem operações próprias da fila, e não um laço de
`Exec` que teria de fatiar o SQL na mão (e erraria no primeiro `;` dentro de uma
string).

### Encerramento

Drena a fila, fecha o lote aberto, `PRAGMA optimize`, fecha a conexão. `Post`
depois disso é descartado e contado — o número aparece no encerramento, porque
"perdi 12 escritas ao fechar" é o tipo de coisa que não pode ser silenciosa.

---

## 5. As units, e por que a troca é barata

```
vms/src/Db/
  Vms.Db.Intf.pas       IDbQueue — a única coisa que o resto do servidor enxerga
  Vms.Db.Queue.pas      a fila e a TDbThread, dona da TFDConnection
  Vms.Db.Schema.pas     abre, confere user_version, roda o schema-vN.sql
  Vms.Db.Migrate.pas    importa o vmsserver.json antigo na primeira subida
  schema-v1.sql         o esquema (embutido como recurso)
```

Não há binding de FFI: o FireDAC é o driver. Some com ele o risco que estava
listado aqui — assinatura errada de função C virando corrupção silenciosa num
projeto que não compila por linha de comando.

Cada subsistema ganha **outra implementação da interface que ele já tem** — as
interfaces não mudam:

| interface (já existe) | hoje | passa a ser |
|---|---|---|
| `IEventStore` / `IEventSource` | `TEventFileStore` | `TSqliteEventStore` |
| `IThumbSource` (cache interno) | `TThumbDiskCache` | `TThumbDiskCache` + `IThumbIndex` |
| `ILogger` | `TPerCameraLogger` | `TSqliteLogger` (+ console) |

O analisador, o worker, a rota `/api/events` e a barra do app **não são tocados**:
eles falam com `IEventStore`/`IEventSource`, e trocar a implementação é uma linha
no `BuildAnalytics`. É exatamente o que essas fronteiras existiam para comprar.

Os dois que exigem cirurgia de verdade:

- **`Vms.Server.IndexCache`** — hoje é cache em memória + `_index.json` + LRU.
  Com a tabela, o cache em memória de *resumos* some (a consulta é rápida); o LRU
  de **índices de bloco** continua, porque aquilo é o `.vms` e não entra no banco.
- **`Vms.Server.Config`** — deixa de parsear JSON e passa a ler `setting` e
  `camera`. É onde mora a importação do formato antigo.

---

## 6. Migração e retenção

**Na primeira subida**, dentro de uma transação só: cria o esquema, importa o
`vmsserver.json` (câmeras, endpoints, ajustes), varre `<storage>/*/` e popula
`recording`, importa os `.vev` e os `progress.txt` que existirem, indexa as
miniaturas já geradas. Deu errado no meio, nada foi gravado e o servidor sobe com
o JSON como antes.

**Retenção** passa a ter as duas pontas na mesma transação: apagar um `.vms`
apaga a linha em `recording`; `ON DELETE CASCADE` leva junto o que pende da
câmera. Mais `DELETE FROM log WHERE at_ms < ?` e `DELETE FROM event WHERE end_ms
< ?`, que hoje são varreduras de diretório.

`PRAGMA optimize` no encerramento; `VACUUM` só quando pedido à mão — sem blobs, o
banco não incha.

---

## 7. Verificação

O Python já tem `sqlite3` embutido, então o `tools/selftest.py` passa a **executar
o DDL de verdade** e conferir os contratos sobre o banco real: unicidade de
`(camera_id, name)`, o cascade apagando os filhos, a consulta de sobreposição
achando o evento que começou antes da janela, a agregação de `/api/days` batendo
com a soma dos arquivos. É verificação melhor do que a de hoje, que modela o
formato binário por fora.

---

## 8. Ordem de implementação

1. ~~`Vms.Db.Intf` + `Vms.Db.Queue` + `Vms.Db.Schema` — abrir, criar, migrar.~~
   **Feito.** O servidor cria `vmsserver.db`, migra por `user_version` e loga
   `Banco: <caminho> | v1 | 9 tabelas | N KB`. Ninguém lê nem escreve nele
   ainda. O `schema-v1.sql` vira `Vms.Db.Schema.Sql.pas` por
   `tools/gen_schema_pas.py`, e `tools/testschema.py` recusa passar se os dois
   divergirem.
2. `TSqliteEventStore` — o mais isolado, e o que valida a fila de escrita.
3. `recording` + `Vms.Server.IndexCache`.
4. `TSqliteLogger` com fila em lote.
5. Config (`setting`, `camera`, `camera_endpoint`) + importação do JSON.
6. Índice de miniaturas.
7. Teto de duração de evento no `TFrameAnalyzer`.

Cada passo compila e roda sozinho; nenhum exige o seguinte.

## 9. Riscos

- **Não há compilador aqui** (ver `no-cli-build`). O que dá para verificar é o
  esquema, e ele é verificado de verdade (`tools/testschema.py`, no sqlite do
  Python). O que **não** dá para verificar é a fila: ordem, lote e encerramento
  só aparecem rodando. É a parte que merece um teste manual na primeira subida.
- **FIFO estrita põe a leitura atrás do lote.** Com 200 ms de teto, uma consulta
  da API espera no máximo isso. Se algum dia incomodar, o conserto é diminuir o
  teto do lote — não deixar a leitura furar a fila.
- **Config no banco** tira a edição à mão. Enquanto não houver rota de escrita na
  API, mexer numa senha vai exigir um cliente de SQLite. Vale decidir cedo se a
  fase 5 já entrega `POST /api/cameras`.
- **Log em tabela** perde a legibilidade de "abrir o .log no editor". O console ao
  vivo continua, mas a leitura post-mortem passa a exigir consulta.
