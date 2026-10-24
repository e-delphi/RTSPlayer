-- =====================================================================
--  vmsserver — esquema v1
-- =====================================================================
--
--  Este arquivo E o esquema. O Vms.Db.Schema o embute como recurso e o
--  executa inteiro numa transacao quando `PRAGMA user_version` for 0;
--  versoes seguintes entram como schema-v2.sql e assim por diante, nunca
--  editando este. Quem quiser olhar o banco com um cliente de SQLite le
--  este arquivo e sabe o que vai achar.
--
--  CONVENCOES
--    *_ms        instante unix em MILISSEGUNDOS, UTC. Nunca hora local:
--                o dia local so aparece na consulta, com 'localtime'.
--    0 / 1       booleano. SQLite nao tem tipo proprio.
--    id          INTEGER PRIMARY KEY = rowid, chave estavel e barata.
--
--  O QUE NAO ESTA AQUI, de proposito: o video (.vms), o indice de blocos
--  (.vms.idx) e os JPEG das miniaturas. Os tres sao payload binario com
--  formato proprio ja resolvido; o banco guarda o que APONTA para eles.
--
--  Os CHECK nao sao enfeite. Este banco e escrito por sete threads de
--  quatro subsistemas; e a ultima fronteira onde um valor impossivel
--  (score 17, evento que termina antes de comecar, tipo 5) ainda da erro
--  em vez de virar uma tarja errada na linha do tempo do celular.
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- Identidade do arquivo. user_version cuida da migracao; isto aqui e
-- para quando o banco estiver estranho e a pergunta for "que build fez
-- este arquivo, e quando".
-- ---------------------------------------------------------------------
CREATE TABLE db_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- ---------------------------------------------------------------------
-- CAMERA — a identidade. Tudo o mais referencia daqui.
--
-- `name` e a chave de verdade do sistema: e o nome da rota RTSP
-- (/live/<name>), o parametro ?camera= da API e o nome da pasta em
-- disco. COLLATE NOCASE porque a API ja compara com SameText, e duas
-- cameras 'Frente' e 'frente' seriam a mesma pasta.
-- ---------------------------------------------------------------------
CREATE TABLE camera (
  id                     INTEGER PRIMARY KEY,
  name                   TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  enabled                INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  record_audio           INTEGER NOT NULL DEFAULT 1 CHECK (record_audio IN (0,1)),
  filename_pattern       TEXT    NOT NULL DEFAULT '',
  audio_delay_ms         INTEGER NOT NULL DEFAULT 200,
  video_delay_ms         INTEGER NOT NULL DEFAULT 200,
  -- 0 = reconecta para sempre; N > 0 = desiste apos N falhas seguidas
  max_reconnect_attempts INTEGER NOT NULL DEFAULT 0,
  reconnect_initial_ms   INTEGER NOT NULL DEFAULT 2000,
  reconnect_max_ms       INTEGER NOT NULL DEFAULT 30000,
  reconnect_multiplier   REAL    NOT NULL DEFAULT 2.0,
  no_rtp_timeout_ms      INTEGER NOT NULL DEFAULT 10000,
  created_at_ms          INTEGER NOT NULL,
  updated_at_ms          INTEGER NOT NULL,
  CHECK (name <> '')
);

-- ---------------------------------------------------------------------
-- CAMERA_ENDPOINT — os caminhos ate a camera, em ordem de preferencia
-- (a LAN dela, o servidor que a republica, a tailnet). Quem conecta
-- testa qual responde; ver VMS.Net.Probe.
--
-- Tabela filha, e nao colunas, porque o numero de caminhos varia por
-- camera: uma tem so a LAN, outra tem tres.
-- ---------------------------------------------------------------------
CREATE TABLE camera_endpoint (
  id             INTEGER PRIMARY KEY,
  camera_id      INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  ord            INTEGER NOT NULL CHECK (ord >= 0),   -- 0 = o preferido
  label          TEXT    NOT NULL DEFAULT '',         -- rotulo de tela
  url            TEXT    NOT NULL CHECK (url <> ''),
  user_name      TEXT    NOT NULL DEFAULT '',
  password       TEXT    NOT NULL DEFAULT '',
  -- lista em ordem de tentativa, como no json de hoje: 'tcp,udp'
  transports     TEXT    NOT NULL DEFAULT 'tcp,udp',
  uses_tailscale INTEGER NOT NULL DEFAULT 0 CHECK (uses_tailscale IN (0,1)),
  UNIQUE (camera_id, ord)
);

-- ---------------------------------------------------------------------
-- SETTING — todo o resto da configuracao, com as MESMAS chaves do
-- vmsserver.json de hoje ('block.maxSamples', 'analytics.stepMs').
--
-- Chave/valor, e nao colunas tipadas, porque sao ~25 ajustes
-- heterogeneos de seis secoes: a importacao do json vira um laco,
-- acrescentar um ajuste vira um INSERT em vez de um ALTER TABLE, e os
-- GetJsonInt/Bool/Str que ja existem viram GetSettingInt/Bool/Str com a
-- mesma assinatura.
--
-- Valor sempre TEXT: quem le converte, do mesmo jeito que ja convertia
-- do json. Guardar tipos aqui daria seis colunas nulas por linha.
-- ---------------------------------------------------------------------
CREATE TABLE setting (
  key           TEXT PRIMARY KEY,
  value         TEXT NOT NULL,
  updated_at_ms INTEGER NOT NULL
) WITHOUT ROWID;

-- ---------------------------------------------------------------------
-- RECORDING — o inventario dos .vms. Substitui o _index.json.
--
-- Guarda `name`, nao o caminho completo: o caminho e
-- <storageDir>/<pasta da camera>/<name>, e storageDir e config que pode
-- mudar. Caminho gravado viraria mentira no dia da mudanca.
--
-- stamp_size/stamp_mtime_ms sao o carimbo do arquivo. Mudou o tamanho
-- ou a data, o resumo nao vale mais e a linha e refeita — mesma regra
-- do cache de hoje, agora sobrevivendo ao reinicio.
-- ---------------------------------------------------------------------
CREATE TABLE recording (
  id             INTEGER PRIMARY KEY,
  camera_id      INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  name           TEXT    NOT NULL CHECK (name <> ''),
  start_ms       INTEGER NOT NULL,
  end_ms         INTEGER NOT NULL,
  duration_ms    INTEGER NOT NULL,
  bytes          INTEGER NOT NULL,
  blocks         INTEGER NOT NULL,
  -- tem rodape: a gravacao foi encerrada direito
  closed         INTEGER NOT NULL DEFAULT 0 CHECK (closed IN (0,1)),
  -- tem indice pronto (no rodape, ou no .vms.idx ao lado). 0 = descrever
  -- este arquivo custou uma varredura, e toca-lo vai custar outra.
  indexed        INTEGER NOT NULL DEFAULT 0 CHECK (indexed IN (0,1)),
  has_video      INTEGER NOT NULL DEFAULT 0 CHECK (has_video IN (0,1)),
  video_codec    INTEGER NOT NULL DEFAULT 0,
  width          INTEGER NOT NULL DEFAULT 0,
  height         INTEGER NOT NULL DEFAULT 0,
  has_audio      INTEGER NOT NULL DEFAULT 0 CHECK (has_audio IN (0,1)),
  audio_codec    INTEGER NOT NULL DEFAULT 0,
  sample_rate    INTEGER NOT NULL DEFAULT 0,
  channels       INTEGER NOT NULL DEFAULT 0,
  stamp_size     INTEGER NOT NULL,
  stamp_mtime_ms INTEGER NOT NULL,
  UNIQUE (camera_id, name),
  CHECK (end_ms >= start_ms)
);

-- Cobre as tres consultas que importam: as faixas de um dia, o arquivo
-- que contem um instante, e a varredura da retencao por idade.
CREATE INDEX ix_recording_span ON recording (camera_id, start_ms, end_ms);

-- ---------------------------------------------------------------------
-- EVENT — o que a analise viu. Substitui os .vev.
--
-- A caixa vai NORMALIZADA 0..1 sobre largura e altura do quadro, e nao
-- em pixels: o app desenha sobre um video que pode estar em qualquer
-- resolucao, e a mesma camera muda de perfil sem avisar. Em REAL, sem o
-- arredondamento para u16 que o formato binario exigia.
-- ---------------------------------------------------------------------
CREATE TABLE event (
  id            INTEGER PRIMARY KEY,
  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  start_ms      INTEGER NOT NULL,
  end_ms        INTEGER NOT NULL,
  kind          INTEGER NOT NULL CHECK (kind IN (0,1)),  -- 0=movimento 1=objeto
  name          TEXT    NOT NULL CHECK (name <> ''),     -- 'movimento','person'
  score         REAL    NOT NULL CHECK (score >= 0 AND score <= 1),
  obj_count     INTEGER NOT NULL DEFAULT 1 CHECK (obj_count >= 0),
  box_l         REAL    NOT NULL DEFAULT 0,
  box_t         REAL    NOT NULL DEFAULT 0,
  box_r         REAL    NOT NULL DEFAULT 0,
  box_b         REAL    NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL,
  CHECK (end_ms >= start_ms),
  CHECK (box_l >= 0 AND box_t >= 0 AND box_r <= 1 AND box_b <= 1)
);

-- A consulta e por SOBREPOSICAO com a janela:
--   WHERE camera_id=? AND start_ms <= :to AND end_ms >= :from
-- O indice resolve o teto. O piso vem do teto de duracao de evento
-- (analytics.maxEventMs): com ele, `start_ms >= :from - maxEventMs` e
-- verdade, e a varredura para de crescer com a idade do banco.
CREATE INDEX ix_event_window ON event (camera_id, start_ms);
-- Para a aba de filtro da tela de eventos ("so pessoas neste dia").
CREATE INDEX ix_event_name   ON event (camera_id, name, start_ms);

-- ---------------------------------------------------------------------
-- ANALYSIS_PROGRESS — ate onde a analise chegou. Substitui o
-- progress.txt.
--
-- `model` conserta uma pegadinha do arquivo de hoje: trocar o .onnx sem
-- apagar o progresso deixava horas analisadas pelo modelo velho passando
-- por analisadas. Modelo diferente do configurado = o progresso daquela
-- camera nao vale, e a analise recomeca sozinha.
-- ---------------------------------------------------------------------
CREATE TABLE analysis_progress (
  camera_id       INTEGER PRIMARY KEY REFERENCES camera(id) ON DELETE CASCADE,
  analyzed_to_ms  INTEGER NOT NULL,
  frames          INTEGER NOT NULL DEFAULT 0,
  -- quantos quadros nao decodificaram. E o numero que responde se as
  -- mensagens do h264 sao 37 em 1800 ou 40%.
  decode_failures INTEGER NOT NULL DEFAULT 0,
  model           TEXT    NOT NULL DEFAULT '',
  updated_at_ms   INTEGER NOT NULL
);

-- ---------------------------------------------------------------------
-- THUMB — o indice das miniaturas. O JPEG continua em disco, em
-- <storage>/<camera>/thumbs/<yyyy-mm-dd>/HHMM.jpg.
--
-- state=1 ("nao ha imagem para este minuto") e o ganho: hoje isso vive
-- num dicionario em memoria com TTL de 60 s e morre a cada reinicio.
-- Persistido, arrastar a barra sobre trecho sem gravacao para de custar
-- uma decodificacao fracassada por vista, para sempre.
--
-- WITHOUT ROWID: a chave natural (camera, minuto) e a unica forma de
-- acesso, e a linha e pequena — a tabela vira a propria arvore.
-- ---------------------------------------------------------------------
CREATE TABLE thumb (
  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,
  minute_ms     INTEGER NOT NULL,
  state         INTEGER NOT NULL CHECK (state IN (0,1)),  -- 0=tem 1=nao ha
  path          TEXT    NOT NULL DEFAULT '',
  bytes         INTEGER NOT NULL DEFAULT 0,
  width         INTEGER NOT NULL DEFAULT 0,
  height        INTEGER NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (camera_id, minute_ms)
) WITHOUT ROWID;

-- ---------------------------------------------------------------------
-- LOG
--
-- ATENCAO: `level` e COLUNA, nunca FILTRO. Continua valendo que nada e
-- descartado por nivel; ele entra na linha para quem le saber o peso do
-- evento, jamais para o programa escolher se registra. Ver
-- VMS.Domain.Logging.
--
-- Escrita em lote por um escritor so: a thread de sessao RTSP enfileira
-- e segue. I/O de banco nao pode entrar no caminho que tambem le RTP.
-- ---------------------------------------------------------------------
CREATE TABLE log (
  id        INTEGER PRIMARY KEY,
  at_ms     INTEGER NOT NULL,
  level     INTEGER NOT NULL,
  tag       TEXT    NOT NULL,   -- 'main', 'session.frente', 'analytics.ayla'
  -- SET NULL, e nao CASCADE: apagar uma camera nao pode apagar o log que
  -- explica por que ela foi apagada.
  camera_id INTEGER REFERENCES camera(id) ON DELETE SET NULL,
  message   TEXT    NOT NULL
);
CREATE INDEX ix_log_at  ON log (at_ms);          -- retencao e "ultimas linhas"
CREATE INDEX ix_log_tag ON log (tag, at_ms);     -- "o que houve com esta camera"

-- =====================================================================
--  Padroes. INSERT OR IGNORE: rodar isto de novo NAO sobrescreve o que
--  o usuario ja mudou. As chaves sao as mesmas do vmsserver.json, entao
--  a importacao do arquivo antigo e um laco sobre os pares.
-- =====================================================================
INSERT OR IGNORE INTO setting (key, value, updated_at_ms) VALUES
  ('rtspPort',                     '8554',        0),
  ('bindAddress',                  '',            0),
  ('storageDir',                   'recordings',  0),
  ('logDir',                       'logs',        0),
  ('transportFallbackTimeoutMs',   '5000',        0),
  ('keepAliveMethod',              'get_parameter', 0),
  ('rotateMinutes',                '60',          0),

  ('block.maxSamples',             '256',         0),
  ('block.maxDurationMs',          '2000',        0),
  ('block.maxSizeBytes',           '1048576',     0),

  ('retention.maxDays',            '0',           0),
  ('retention.maxTotalGB',         '0',           0),
  ('retention.minFreeGB',          '20',          0),
  ('retention.intervalMinutes',    '5',           0),
  -- Idade do LOG, separada da idade da gravacao: quem guarda video ate o
  -- disco encher (maxDays 0) ainda quer o log parando de crescer.
  ('retention.logDays',            '7',           0),

  ('live.enabled',                 '1',           0),
  ('live.bufferMs',                '4000',        0),
  ('live.maxBufferMB',             '32',          0),

  ('api.enabled',                  '1',           0),
  -- Autenticacao. Nasce LIGADA e sem senha: nesse estado so o proprio
  -- computador entra, e so para definir uma. Assim uma instalacao nova nunca
  -- fica aberta por esquecimento -- que e o modo classico de publicar um
  -- servidor de cameras na internet sem querer.
  ('auth.enabled',                 '1',           0),
  ('auth.user',                    'admin',       0),
  -- pbkdf2$iteracoes$sal$hash. Vazio = senha ainda nao definida.
  ('auth.hash',                    '',            0),
  ('auth.sessionHours',            '720',         0),
  ('api.maxBlocksPerRequest',      '32',          0),

  ('analytics.enabled',            '0',           0),
  ('analytics.stepMs',             '2000',        0),
  ('analytics.motionThreshold',    '0.006',       0),
  ('analytics.sceneChangeThreshold','0.85',       0),
  -- O lado da grade de decisao, como fracao de 64x36. Mais grossa = cego para
  -- movimento de pouco contraste.
  ('analytics.gridScale',          '1',           0),
  -- Quanto o cinza de uma celula precisa mudar (0..255); 0 = o padrao, 14.
  -- Subir e o que faz ignorar a oscilacao de brilho do ganho automatico.
  ('analytics.cellDelta',          '0',           0),
  ('analytics.mergeGapMs',         '8000',        0),
  -- novo: teto de duracao de um evento. Fecha e comeca outro ao passar
  -- disto. Serve a dois donos — da piso a consulta por janela e impede
  -- uma tarja de quatro horas na barra do tempo.
  ('analytics.maxEventMs',         '300000',      0),
  ('analytics.backfillHours',      '6',           0),
  ('analytics.lagMs',              '30000',       0),
  ('analytics.modelPath',          '',            0),
  ('analytics.onnxDll',            'onnxruntime.dll', 0),
  ('analytics.objectIntervalMs',   '5000',        0),
  -- A rede tambem roda sem movimento, de minuto em minuto: quem entra no
  -- quadro e para de se mexer e absorvido pelo fundo em ~20 s.
  ('analytics.objectIdleIntervalMs','60000',      0),
  ('analytics.objectThreshold',    '0.35',        0),
  -- lista separada por virgula; vazio = todos os rotulos do modelo
  ('analytics.classes',            '',            0);

PRAGMA user_version = 1;
