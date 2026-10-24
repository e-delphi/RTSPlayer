unit Vms.Server.LoggerDb;

// O log em tabela. Substitui o TPerCameraLogger (que fica no repositorio, sem
// uso: reverter e trocar a linha da composicao).
//
// ## Nada e descartado por nivel
//
// Continua valendo o que ja valia: `level` e COLUNA, nunca filtro. Ele entra na
// linha para quem le saber o peso do evento, jamais para o programa escolher se
// registra. Ver VMS.Domain.Logging.
//
// ## O console continua
//
// Servidor de console se olha rodando. Trocar arquivo por tabela nao pode
// custar isso, entao toda linha sai nos dois lugares: no console na hora, e na
// tabela pela fila.
//
// ## Post, e nunca Exec
//
// Quem loga sao as threads de sessao RTSP, que tambem leem RTP. I/O de banco no
// caminho quente faria perder pacote — e pacote perdido e buraco na gravacao.
// Post so enfileira; quem escreve e a thread da fila, em lote.
//
// ## E se a escrita do log falhar?
//
// Nao volta por aqui. A fila manda erro dela para o console e para um arquivo
// de emergencia (ver Vms.Db.Queue), justamente porque avisar pelo log geraria
// outra escrita de log, que poderia falhar de novo.
//
// ## A camera sai do TAG
//
// Os tags ja tem a forma `session.frente`, `analytics.ayla`, `main`. O que vem
// depois do primeiro ponto e o nome da camera; a subconsulta devolve NULL
// quando nao casa com nenhuma, e a coluna aceita NULL de proposito. Assim o log
// de uma camera que ainda nao existe na tabela e gravado do mesmo jeito, so que
// sem o vinculo — perder a linha seria bem pior.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  Vms.Db.Intf;

type
  TSqliteLogger = class(TInterfacedObject, ILogger)
  strict private
    FDb: IDbQueue;
    FClock: IClock;
    FConsole: ILogger;
    function CameraOfTag(const Tag: string): string;
  public
    // AConsole nil = so tabela. Em servico do Windows, sem console, e o que se
    // quer; rodando a mao, nao.
    constructor Create(const ADb: IDbQueue; const AClock: IClock;
                       const AConsole: ILogger);
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
  end;

  // Apaga linhas de log anteriores a KeepFromMs. Chamada pela retencao: sem
  // isto a tabela cresce para sempre, que e o unico jeito de um log em banco
  // ficar pior que um log em arquivo.
  function PruneLog(const Db: IDbQueue; KeepFromMs: Int64): Integer;

implementation

const
  SQL_LOG =
    'INSERT INTO log (at_ms, level, tag, camera_id, message) ' +
    'VALUES (?, ?, ?, (SELECT id FROM camera WHERE name = ?), ?)';

constructor TSqliteLogger.Create(const ADb: IDbQueue; const AClock: IClock;
  const AConsole: ILogger);
begin
  inherited Create;
  FDb := ADb;
  FClock := AClock;
  FConsole := AConsole;
end;

function TSqliteLogger.CameraOfTag(const Tag: string): string;
var
  P: Integer;
begin
  P := Pos('.', Tag);
  if P <= 0 then Exit('');
  Result := Copy(Tag, P + 1, MaxInt);
end;

procedure TSqliteLogger.Log(Level: TLogLevel; const Tag, Msg: string);
begin
  // Console primeiro: se a fila estiver encerrando, a linha ainda aparece.
  if FConsole <> nil then
    FConsole.Log(Level, Tag, Msg);
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  FDb.Post(SQL_LOG, [FClock.NowUtcMs, Ord(Level), Tag, CameraOfTag(Tag), Msg]);
end;

procedure TSqliteLogger.Debug(const Tag, Msg: string);
begin
  Log(llDebug, Tag, Msg);
end;

procedure TSqliteLogger.Info(const Tag, Msg: string);
begin
  Log(llInfo, Tag, Msg);
end;

procedure TSqliteLogger.Warn(const Tag, Msg: string);
begin
  Log(llWarn, Tag, Msg);
end;

procedure TSqliteLogger.Error(const Tag, Msg: string);
begin
  Log(llError, Tag, Msg);
end;

function PruneLog(const Db: IDbQueue; KeepFromMs: Int64): Integer;
begin
  Result := 0;
  if (Db = nil) or (not Db.IsOpen) then Exit;
  try
    Result := Db.Exec('DELETE FROM log WHERE at_ms < ?', [KeepFromMs]);
  except
    // Limpeza que falha nao pode derrubar a varredura de retencao, e reclamar
    // aqui seria escrever no log que se esta tentando limpar.
    Result := 0;
  end;
end;

end.
