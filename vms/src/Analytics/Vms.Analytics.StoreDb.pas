unit Vms.Analytics.StoreDb;

// Os eventos, agora em tabela. Substitui o TEventFileStore (que fica no
// repositorio, sem uso: reverter e trocar a linha da composicao).
//
// Implementa as MESMAS tres interfaces, entao o analisador, o worker e a rota
// /api/events nao sabem que alguma coisa mudou. Era exatamente para isso que as
// fronteiras existiam.
//
// ## O piso da consulta
//
// Achar o que estava acontecendo numa janela e uma pergunta de SOBREPOSICAO:
// `start_ms <= :to AND end_ms >= :from`. O indice (camera_id, start_ms) resolve
// o teto, mas sozinho nao tem piso — sem um, procurar os eventos das 14h
// obrigaria a considerar qualquer evento aberto desde o comeco do banco.
//
// O piso vem do teto de duracao (analytics.maxEventMs): se nenhum evento passa
// de N ms, entao nenhum que se sobreponha a janela comecou antes de
// `:from - N`. Por isso o MaxEventMs entra no construtor — ele nao e detalhe do
// analisador, e o que torna esta consulta limitada.
//
// ## camera_id por subconsulta
//
// O INSERT resolve o id pelo nome ali mesmo, em vez de manter um cache de
// nomes: e uma linha a menos de estado compartilhado entre threads, e a chave
// estrangeira garante que um nome desconhecido falhe em vez de gravar orfao.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  Vms.Db.Intf,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

type
  TSqliteEventStore = class(TInterfacedObject,
                            IEventStore, IEventSource, IAnalysisProgress)
  strict private
    FDb: IDbQueue;
    FClock: IClock;
    FLogger: ILogger;
    FMaxEventMs: Int64;
  public
    constructor Create(const ADb: IDbQueue; const AClock: IClock;
                       AMaxEventMs: Int64; const ALogger: ILogger);
    { IEventStore }
    procedure Append(const Camera: string; const Ev: TVmsEvent);
    { IEventSource }
    function Query(const Camera: string; FromMs, ToMs: Int64;
                   const NameFilter: string; KindFilter: Integer;
                   MinScore: Single; Limit: Integer): TVmsEventArray;
    function Available: Boolean;
    { IAnalysisProgress }
    function ReadProgress(const Camera, Model: string): Int64;
    procedure WriteProgress(const Camera: string; AnalyzedToMs, Frames,
                            Failures: Int64; const Model: string);
    // Apaga eventos anteriores a KeepFromMs. Chamada pela retencao.
    function PruneOlderThan(KeepFromMs: Int64): Integer;
  end;

implementation

const
  QUERY_DEFAULT_LIMIT = 4000;

  SQL_INSERT =
    'INSERT INTO event (camera_id, start_ms, end_ms, kind, name, score, ' +
    '  obj_count, box_l, box_t, box_r, box_b, created_at_ms) ' +
    'VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

constructor TSqliteEventStore.Create(const ADb: IDbQueue; const AClock: IClock;
  AMaxEventMs: Int64; const ALogger: ILogger);
begin
  inherited Create;
  FDb := ADb;
  FClock := AClock;
  FLogger := ALogger;
  FMaxEventMs := AMaxEventMs;
  // Piso de seguranca: MaxEventMs zerado tiraria o limite da consulta sem
  // avisar, e ela voltaria a crescer com a idade do banco.
  if FMaxEventMs <= 0 then FMaxEventMs := 300000;
end;

function TSqliteEventStore.Available: Boolean;
begin
  Result := (FDb <> nil) and FDb.IsOpen;
end;

procedure TSqliteEventStore.Append(const Camera: string; const Ev: TVmsEvent);
var
  Caixa: TEventBox;
begin
  if not Ev.IsValid then Exit;
  if not Available then Exit;
  Caixa := Ev.Box.Clamped;
  // Post: quem grava evento e a thread de analise, e ela nao pode parar para
  // esperar disco. Falha vai para o log de emergencia da fila.
  FDb.Post(SQL_INSERT, [Camera, Ev.StartMs, Ev.EndMs, Ord(Ev.Kind),
    LowerCase(Ev.Name), Double(Ev.Score), Ev.Count,
    Double(Caixa.L), Double(Caixa.T), Double(Caixa.R), Double(Caixa.B),
    FClock.NowUtcMs]);
end;

function TSqliteEventStore.Query(const Camera: string; FromMs, ToMs: Int64;
  const NameFilter: string; KindFilter: Integer; MinScore: Single;
  Limit: Integer): TVmsEventArray;
var
  Lista: TList<TVmsEvent>;
  Sql, Filtro: string;
  Params: TArray<Variant>;

  procedure AddParam(const V: Variant);
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := V;
  end;

begin
  Result := nil;
  if (Camera = '') or (ToMs <= FromMs) or (not Available) then Exit;
  if Limit <= 0 then Limit := QUERY_DEFAULT_LIMIT;
  Filtro := LowerCase(Trim(NameFilter));

  Sql := 'SELECT e.start_ms, e.end_ms, e.kind, e.name, e.score, e.obj_count, ' +
         '       e.box_l, e.box_t, e.box_r, e.box_b ' +
         '  FROM event e JOIN camera c ON c.id = e.camera_id ' +
         ' WHERE c.name = ? AND e.start_ms >= ? AND e.start_ms <= ? ' +
         '   AND e.end_ms >= ?';
  Params := nil;
  AddParam(Camera);
  AddParam(FromMs - FMaxEventMs);   // o piso; ver o cabecalho
  AddParam(ToMs);
  AddParam(FromMs);
  if KindFilter >= 0 then
  begin
    Sql := Sql + ' AND e.kind = ?';
    AddParam(KindFilter);
  end;
  if Filtro <> '' then
  begin
    Sql := Sql + ' AND e.name = ?';
    AddParam(Filtro);
  end;
  if MinScore > 0 then
  begin
    Sql := Sql + ' AND e.score >= ?';
    AddParam(Double(MinScore));
  end;
  Sql := Sql + ' ORDER BY e.start_ms LIMIT ?';
  AddParam(Limit);

  Lista := TList<TVmsEvent>.Create;
  try
    try
      FDb.Read(Sql, Params,
        procedure(const Row: IDbRow)
        var
          Ev: TVmsEvent;
        begin
          Ev := Default(TVmsEvent);
          Ev.StartMs := Row.AsInt64('start_ms');
          Ev.EndMs := Row.AsInt64('end_ms');
          if Row.AsInt('kind') = Ord(ekObject) then
            Ev.Kind := ekObject
          else
            Ev.Kind := ekMotion;
          Ev.Name := Row.AsString('name');
          Ev.Score := Row.AsFloat('score');
          Ev.Count := Row.AsInt('obj_count');
          Ev.Box := TEventBox.FromLTRB(Row.AsFloat('box_l'), Row.AsFloat('box_t'),
                                       Row.AsFloat('box_r'), Row.AsFloat('box_b'));
          Lista.Add(Ev);
        end);
    except
      on E: Exception do
      begin
        // Consulta que falha vira lista vazia, e nao 500: a tela de eventos
        // dizendo "nenhum evento" e ruim, mas o app inteiro parando e pior.
        if FLogger <> nil then
          FLogger.Warn('events', 'consulta falhou: ' + E.Message);
        Exit;
      end;
    end;
    // Ja vem ordenado do banco.
    Result := Lista.ToArray;
  finally
    Lista.Free;
  end;
end;

function TSqliteEventStore.ReadProgress(const Camera, Model: string): Int64;
var
  Ate: Int64;
  Gravado: string;
  Achou: Boolean;
begin
  Result := 0;
  if not Available then Exit;
  Ate := 0;
  Gravado := '';
  Achou := False;
  try
    FDb.Read(
      'SELECT p.analyzed_to_ms, p.model FROM analysis_progress p ' +
      '  JOIN camera c ON c.id = p.camera_id WHERE c.name = ?', [Camera],
      procedure(const Row: IDbRow)
      begin
        Ate := Row.AsInt64('analyzed_to_ms');
        Gravado := Row.AsString('model');
        Achou := True;
      end);
  except
    on E: Exception do
    begin
      if FLogger <> nil then
        FLogger.Warn('analytics', 'progresso nao pode ser lido: ' + E.Message);
      Exit;
    end;
  end;
  if not Achou then Exit;

  // Modelo diferente do configurado: o que foi visto nao vale mais. Devolver 0
  // faz a analise recomecar, que e o que se quer ao trocar de modelo — e o que
  // antes dependia de alguem lembrar de apagar o progress.txt.
  if not SameText(Trim(Gravado), Trim(Model)) then
  begin
    if FLogger <> nil then
      FLogger.Info('analytics', Format('%s: progresso era do modelo "%s" e agora ' +
        'e "%s"; vai reanalisar', [Camera, Gravado, Model]));
    Exit;
  end;
  Result := Ate;
end;

procedure TSqliteEventStore.WriteProgress(const Camera: string;
  AnalyzedToMs, Frames, Failures: Int64; const Model: string);
begin
  if not Available then Exit;
  FDb.Post(
    'INSERT INTO analysis_progress (camera_id, analyzed_to_ms, frames, ' +
    '    decode_failures, model, updated_at_ms) ' +
    '  VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?) ' +
    '  ON CONFLICT(camera_id) DO UPDATE SET ' +
    '    analyzed_to_ms = excluded.analyzed_to_ms, ' +
    '    frames         = excluded.frames, ' +
    '    decode_failures= excluded.decode_failures, ' +
    '    model          = excluded.model, ' +
    '    updated_at_ms  = excluded.updated_at_ms',
    [Camera, AnalyzedToMs, Frames, Failures, Model, FClock.NowUtcMs]);
end;

function TSqliteEventStore.PruneOlderThan(KeepFromMs: Int64): Integer;
begin
  Result := 0;
  if not Available then Exit;
  try
    // Sincrono: a retencao quer saber quantas linhas sairam para poder relatar.
    Result := FDb.Exec('DELETE FROM event WHERE end_ms < ?', [KeepFromMs]);
  except
    on E: Exception do
      if FLogger <> nil then
        FLogger.Warn('events', 'limpeza falhou: ' + E.Message);
  end;
end;

end.
