unit Vms.Db.Schema.Sql;

// GERADO por tools/gen_schema_pas.py — NAO EDITE ESTA UNIT.
//
// A fonte e vms/src/Db/schema-v1.sql. Mexeu la, rode o gerador de novo:
//
//     python tools/gen_schema_pas.py
//
// Os comentarios do .sql nao vem para ca (ver o cabecalho do gerador); o porque
// de cada coluna esta no arquivo, que e onde se vai ler. Os comandos sao
// identicos, e o tools/testschema.py confere que os dois produzem o mesmo banco.

interface

const
  // O que este script deixa em PRAGMA user_version.
  SCHEMA_VERSION = 1;

// O script inteiro, para o TFDScript executar de uma vez.
function SchemaSql: string;

// So o bloco de padroes do `setting`. E INSERT OR IGNORE: rodar de novo nao
// mexe no que o usuario ja mudou, e acrescenta o que a versao nova trouxe.
function SettingsSeedSql: string;

implementation

uses
  System.SysUtils,
  System.Classes;

const
  LINHAS: array[0..186] of string = (
    'PRAGMA foreign_keys = ON;',
    '',
    'CREATE TABLE db_meta (',
    '  key   TEXT PRIMARY KEY,',
    '  value TEXT NOT NULL',
    ');',
    '',
    'CREATE TABLE camera (',
    '  id                     INTEGER PRIMARY KEY,',
    '  name                   TEXT    NOT NULL UNIQUE COLLATE NOCASE,',
    '  enabled                INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),',
    '  record_audio           INTEGER NOT NULL DEFAULT 1 CHECK (record_audio IN (0,1)),',
    '  filename_pattern       TEXT    NOT NULL DEFAULT '''',',
    '  audio_delay_ms         INTEGER NOT NULL DEFAULT 200,',
    '  video_delay_ms         INTEGER NOT NULL DEFAULT 200,',
    '',
    '  max_reconnect_attempts INTEGER NOT NULL DEFAULT 0,',
    '  reconnect_initial_ms   INTEGER NOT NULL DEFAULT 2000,',
    '  reconnect_max_ms       INTEGER NOT NULL DEFAULT 30000,',
    '  reconnect_multiplier   REAL    NOT NULL DEFAULT 2.0,',
    '  no_rtp_timeout_ms      INTEGER NOT NULL DEFAULT 10000,',
    '  created_at_ms          INTEGER NOT NULL,',
    '  updated_at_ms          INTEGER NOT NULL,',
    '  CHECK (name <> '''')',
    ');',
    '',
    'CREATE TABLE camera_endpoint (',
    '  id             INTEGER PRIMARY KEY,',
    '  camera_id      INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,',
    '  ord            INTEGER NOT NULL CHECK (ord >= 0),',
    '  label          TEXT    NOT NULL DEFAULT '''',',
    '  url            TEXT    NOT NULL CHECK (url <> ''''),',
    '  user_name      TEXT    NOT NULL DEFAULT '''',',
    '  password       TEXT    NOT NULL DEFAULT '''',',
    '',
    '  transports     TEXT    NOT NULL DEFAULT ''tcp,udp'',',
    '  uses_tailscale INTEGER NOT NULL DEFAULT 0 CHECK (uses_tailscale IN (0,1)),',
    '  UNIQUE (camera_id, ord)',
    ');',
    '',
    'CREATE TABLE setting (',
    '  key           TEXT PRIMARY KEY,',
    '  value         TEXT NOT NULL,',
    '  updated_at_ms INTEGER NOT NULL',
    ') WITHOUT ROWID;',
    '',
    'CREATE TABLE recording (',
    '  id             INTEGER PRIMARY KEY,',
    '  camera_id      INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,',
    '  name           TEXT    NOT NULL CHECK (name <> ''''),',
    '  start_ms       INTEGER NOT NULL,',
    '  end_ms         INTEGER NOT NULL,',
    '  duration_ms    INTEGER NOT NULL,',
    '  bytes          INTEGER NOT NULL,',
    '  blocks         INTEGER NOT NULL,',
    '',
    '  closed         INTEGER NOT NULL DEFAULT 0 CHECK (closed IN (0,1)),',
    '',
    '  indexed        INTEGER NOT NULL DEFAULT 0 CHECK (indexed IN (0,1)),',
    '  has_video      INTEGER NOT NULL DEFAULT 0 CHECK (has_video IN (0,1)),',
    '  video_codec    INTEGER NOT NULL DEFAULT 0,',
    '  width          INTEGER NOT NULL DEFAULT 0,',
    '  height         INTEGER NOT NULL DEFAULT 0,',
    '  has_audio      INTEGER NOT NULL DEFAULT 0 CHECK (has_audio IN (0,1)),',
    '  audio_codec    INTEGER NOT NULL DEFAULT 0,',
    '  sample_rate    INTEGER NOT NULL DEFAULT 0,',
    '  channels       INTEGER NOT NULL DEFAULT 0,',
    '  stamp_size     INTEGER NOT NULL,',
    '  stamp_mtime_ms INTEGER NOT NULL,',
    '  UNIQUE (camera_id, name),',
    '  CHECK (end_ms >= start_ms)',
    ');',
    '',
    'CREATE INDEX ix_recording_span ON recording (camera_id, start_ms, end_ms);',
    '',
    'CREATE TABLE event (',
    '  id            INTEGER PRIMARY KEY,',
    '  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,',
    '  start_ms      INTEGER NOT NULL,',
    '  end_ms        INTEGER NOT NULL,',
    '  kind          INTEGER NOT NULL CHECK (kind IN (0,1)),',
    '  name          TEXT    NOT NULL CHECK (name <> ''''),',
    '  score         REAL    NOT NULL CHECK (score >= 0 AND score <= 1),',
    '  obj_count     INTEGER NOT NULL DEFAULT 1 CHECK (obj_count >= 0),',
    '  box_l         REAL    NOT NULL DEFAULT 0,',
    '  box_t         REAL    NOT NULL DEFAULT 0,',
    '  box_r         REAL    NOT NULL DEFAULT 0,',
    '  box_b         REAL    NOT NULL DEFAULT 0,',
    '  created_at_ms INTEGER NOT NULL,',
    '  CHECK (end_ms >= start_ms),',
    '  CHECK (box_l >= 0 AND box_t >= 0 AND box_r <= 1 AND box_b <= 1)',
    ');',
    '',
    'CREATE INDEX ix_event_window ON event (camera_id, start_ms);',
    '',
    'CREATE INDEX ix_event_name   ON event (camera_id, name, start_ms);',
    '',
    'CREATE TABLE analysis_progress (',
    '  camera_id       INTEGER PRIMARY KEY REFERENCES camera(id) ON DELETE CASCADE,',
    '  analyzed_to_ms  INTEGER NOT NULL,',
    '  frames          INTEGER NOT NULL DEFAULT 0,',
    '',
    '  decode_failures INTEGER NOT NULL DEFAULT 0,',
    '  model           TEXT    NOT NULL DEFAULT '''',',
    '  updated_at_ms   INTEGER NOT NULL',
    ');',
    '',
    'CREATE TABLE thumb (',
    '  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,',
    '  minute_ms     INTEGER NOT NULL,',
    '  state         INTEGER NOT NULL CHECK (state IN (0,1)),',
    '  path          TEXT    NOT NULL DEFAULT '''',',
    '  bytes         INTEGER NOT NULL DEFAULT 0,',
    '  width         INTEGER NOT NULL DEFAULT 0,',
    '  height        INTEGER NOT NULL DEFAULT 0,',
    '  created_at_ms INTEGER NOT NULL,',
    '  PRIMARY KEY (camera_id, minute_ms)',
    ') WITHOUT ROWID;',
    '',
    'CREATE TABLE log (',
    '  id        INTEGER PRIMARY KEY,',
    '  at_ms     INTEGER NOT NULL,',
    '  level     INTEGER NOT NULL,',
    '  tag       TEXT    NOT NULL,',
    '',
    '  camera_id INTEGER REFERENCES camera(id) ON DELETE SET NULL,',
    '  message   TEXT    NOT NULL',
    ');',
    'CREATE INDEX ix_log_at  ON log (at_ms);',
    'CREATE INDEX ix_log_tag ON log (tag, at_ms);',
    '',
    'INSERT OR IGNORE INTO setting (key, value, updated_at_ms) VALUES',
    '  (''rtspPort'',                     ''8554'',        0),',
    '  (''bindAddress'',                  '''',            0),',
    '  (''storageDir'',                   ''recordings'',  0),',
    '  (''logDir'',                       ''logs'',        0),',
    '  (''transportFallbackTimeoutMs'',   ''5000'',        0),',
    '  (''keepAliveMethod'',              ''get_parameter'', 0),',
    '  (''rotateMinutes'',                ''60'',          0),',
    '',
    '  (''block.maxSamples'',             ''256'',         0),',
    '  (''block.maxDurationMs'',          ''2000'',        0),',
    '  (''block.maxSizeBytes'',           ''1048576'',     0),',
    '',
    '  (''retention.maxDays'',            ''0'',           0),',
    '  (''retention.maxTotalGB'',         ''0'',           0),',
    '  (''retention.minFreeGB'',          ''20'',          0),',
    '  (''retention.intervalMinutes'',    ''5'',           0),',
    '',
    '  (''retention.logDays'',            ''7'',           0),',
    '',
    '  (''live.enabled'',                 ''1'',           0),',
    '  (''live.bufferMs'',                ''4000'',        0),',
    '  (''live.maxBufferMB'',             ''32'',          0),',
    '',
    '  (''api.enabled'',                  ''1'',           0),',
    '',
    '  (''auth.enabled'',                 ''1'',           0),',
    '  (''auth.user'',                    ''admin'',       0),',
    '',
    '  (''auth.hash'',                    '''',            0),',
    '  (''auth.sessionHours'',            ''720'',         0),',
    '  (''api.maxBlocksPerRequest'',      ''32'',          0),',
    '',
    '  (''analytics.enabled'',            ''0'',           0),',
    '  (''analytics.stepMs'',             ''2000'',        0),',
    '  (''analytics.motionThreshold'',    ''0.006'',       0),',
    '  (''analytics.sceneChangeThreshold'',''0.85'',       0),',
    '',
    '  (''analytics.gridScale'',          ''1'',           0),',
    '',
    '  (''analytics.cellDelta'',          ''0'',           0),',
    '  (''analytics.mergeGapMs'',         ''8000'',        0),',
    '',
    '  (''analytics.maxEventMs'',         ''300000'',      0),',
    '  (''analytics.backfillHours'',      ''6'',           0),',
    '  (''analytics.lagMs'',              ''30000'',       0),',
    '  (''analytics.modelPath'',          '''',            0),',
    '  (''analytics.onnxDll'',            ''onnxruntime.dll'', 0),',
    '  (''analytics.objectIntervalMs'',   ''5000'',        0),',
    '',
    '  (''analytics.objectIdleIntervalMs'',''60000'',      0),',
    '  (''analytics.objectThreshold'',    ''0.35'',        0),',
    '',
    '  (''analytics.classes'',            '''',            0);',
    '',
    'PRAGMA user_version = 1;'
  );

function Junta(De, Ate: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := De to Ate do
    begin
      SB.Append(LINHAS[I]);
      SB.Append(sLineBreak);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function SchemaSql: string;
begin
  Result := Junta(Low(LINHAS), High(LINHAS));
end;

function SettingsSeedSql: string;
begin
  Result := Junta(131, 184);
end;

end.
