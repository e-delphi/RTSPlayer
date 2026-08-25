unit Vms.Thumb.IndexDb;

// O indice das miniaturas, na tabela `thumb`. O JPEG continua em disco, em
// <pasta do executavel>/cache/<camera>/thumbs/<dia>/HHMM.jpg — imagem e payload
// binario, nao dado estruturado, pelo mesmo criterio que deixa o `.vms` fora do
// banco.
//
// ## O que a tabela compra
//
// A linha com state=1 quer dizer "olhei este minuto e nao havia imagem". Hoje
// isso vive num dicionario em memoria com TTL de 60 s e MORRE a cada reinicio:
// arrastar a barra sobre um trecho sem gravacao custa, de novo, uma tentativa
// de decodificacao por minuto por vista. Persistido, custa uma vez na vida.
//
// ## Por que so o passado vira ausencia definitiva
//
// Um minuto recente pode nao ter imagem simplesmente porque a gravacao ainda
// nao chegou nele — o arquivo esta sendo escrito neste instante. Marcar esse
// minuto como "nao ha" seria uma mentira que nunca mais se corrige.
//
// So se registra ausencia de minuto mais velho que MIN_IDADE_AUSENCIA_MS. Para
// tras disso, se nao ha keyframe, nao vai passar a haver.
//
// ## Escrita sempre por Post
//
// Quem gera miniatura e uma requisicao HTTP esperando resposta. Ela nao pode
// parar para esperar disco de banco: o indice e otimizacao, e otimizacao que
// atrasa o caminho principal e defeito.

interface

uses
  System.SysUtils,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  Vms.Db.Intf,
  Vms.Thumb.Intf;

type
  TSqliteThumbIndex = class(TInterfacedObject, IThumbIndex)
  strict private
    FDb: IDbQueue;
    FClock: IClock;
    FLogger: ILogger;
  public
    constructor Create(const ADb: IDbQueue; const AClock: IClock;
                       const ALogger: ILogger);
    { IThumbIndex }
    procedure NoteHit(const Camera: string; MinuteMs: Int64;
                      const Path: string; Bytes, W, H: Integer);
    procedure NoteMissing(const Camera: string; MinuteMs: Int64);
    function KnownMissing(const Camera: string; MinuteMs: Int64): Boolean;
  end;

// Tira do indice os minutos anteriores a KeepFromMs. Chamada pela retencao,
// junto com a poda dos JPEG.
function PruneThumbIndex(const Db: IDbQueue; KeepFromMs: Int64): Integer;

implementation

const
  // Um minuto mais novo que isto ainda pode ganhar gravacao. Ver o cabecalho.
  MIN_IDADE_AUSENCIA_MS = Int64(120000);

constructor TSqliteThumbIndex.Create(const ADb: IDbQueue; const AClock: IClock;
  const ALogger: ILogger);
begin
  inherited Create;
  FDb := ADb;
  FClock := AClock;
  FLogger := ALogger;
end;

procedure TSqliteThumbIndex.NoteHit(const Camera: string; MinuteMs: Int64;
  const Path: string; Bytes, W, H: Integer);
begin
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  FDb.Post(
    'INSERT INTO thumb (camera_id, minute_ms, state, path, bytes, width, ' +
    '    height, created_at_ms) ' +
    '  VALUES ((SELECT id FROM camera WHERE name = ?), ?, 0, ?, ?, ?, ?, ?) ' +
    '  ON CONFLICT(camera_id, minute_ms) DO UPDATE SET ' +
    '    state = 0, path = excluded.path, bytes = excluded.bytes, ' +
    '    width = excluded.width, height = excluded.height, ' +
    '    created_at_ms = excluded.created_at_ms',
    [Camera, MinuteMs, Path, Bytes, W, H, FClock.NowUtcMs]);
end;

procedure TSqliteThumbIndex.NoteMissing(const Camera: string; MinuteMs: Int64);
begin
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  // Recente demais para virar ausencia definitiva: a gravacao ainda pode
  // chegar. O dicionario em memoria do TThumbService cobre o curto prazo.
  if (FClock.NowUtcMs - MinuteMs) < MIN_IDADE_AUSENCIA_MS then Exit;
  FDb.Post(
    'INSERT INTO thumb (camera_id, minute_ms, state, created_at_ms) ' +
    '  VALUES ((SELECT id FROM camera WHERE name = ?), ?, 1, ?) ' +
    '  ON CONFLICT(camera_id, minute_ms) DO UPDATE SET ' +
    '    state = 1, created_at_ms = excluded.created_at_ms',
    [Camera, MinuteMs, FClock.NowUtcMs]);
end;

function TSqliteThumbIndex.KnownMissing(const Camera: string;
  MinuteMs: Int64): Boolean;
begin
  Result := False;
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  try
    Result := FDb.ReadInt64(
      'SELECT t.state AS s FROM thumb t JOIN camera c ON c.id = t.camera_id ' +
      ' WHERE c.name = ? AND t.minute_ms = ?', [Camera, MinuteMs], 's', 0) = 1;
  except
    on E: Exception do
    begin
      // Consulta que falha nao pode impedir de tentar gerar: no pior caso
      // gasta-se uma decodificacao a mais.
      if FLogger <> nil then
        FLogger.Debug('thumb', 'indice nao pode ser consultado: ' + E.Message);
      Result := False;
    end;
  end;
end;

function PruneThumbIndex(const Db: IDbQueue; KeepFromMs: Int64): Integer;
begin
  Result := 0;
  if (Db = nil) or (not Db.IsOpen) then Exit;
  try
    Result := Db.Exec('DELETE FROM thumb WHERE minute_ms < ?', [KeepFromMs]);
  except
    Result := 0;
  end;
end;

end.
