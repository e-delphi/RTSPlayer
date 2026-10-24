unit Vms.Server.Interactions;

// O registro de quem mexeu na camera: PTZ e fala para o alto-falante.
//
// Serve para a linha do tempo pintar os trechos em que alguem interagiu, do
// mesmo jeito que pinta o movimento -- so que em outra cor. Quem olha uma
// gravacao em que a imagem gira sozinha quer saber se foi gente ou a ronda.
//
// ## Um trecho, e nao uma linha por comando
//
// Um aperto de seta da PTZ manda dezenas de comandos (a pagina repete a cada
// ~285 ms), e a fala manda um POST a cada 160 ms. Gravar cada um encheria o
// banco sem dizer nada a mais. Entao os comandos da mesma camera e do mesmo
// tipo se juntam num trecho enquanto chegarem a menos de GAP_MS um do outro;
// passado isso o trecho fecha e vira UMA linha.
//
// O trecho aberto nao esta no banco ainda, mas a consulta o devolve junto: a
// pessoa que acabou de mover a camera ve a faixa na hora, sem esperar ele
// fechar.
//
// ## Tabela propria, e nao a `event`
//
// A `event` e da analise de imagem: o kind dela tem CHECK (0,1), e ela so
// existe para quem consulta quando a analise esta ligada -- a rota /api/events
// responde 503 sem ela. Interacao nao depende de FFmpeg nem de modelo.
//
// A tabela nasce com CREATE IF NOT EXISTS na primeira vez que se precisa dela,
// e nao por um passo de versao do esquema. E seguro porque e ADITIVO: nenhuma
// tabela existente muda, e um executavel antigo sobre este banco so ignora uma
// tabela que nao conhece -- que e justamente o risco que a trava de versao
// existe para impedir, e que aqui nao ocorre.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  Vms.Db.Intf;

const
  INTERACAO_PTZ = 'ptz';
  INTERACAO_FALA = 'fala';

type
  TInteracao = record
    StartMs: Int64;
    EndMs: Int64;
    Kind: string;      // INTERACAO_PTZ ou INTERACAO_FALA
    Detail: string;    // "mover x12, parar x12" -- o que foi feito no trecho
  end;

  TInteracaoArray = TArray<TInteracao>;

  TInteractionLog = class
  strict private
    type
      TAberta = class
        Camera: string;
        Kind: string;
        StartMs: Int64;
        EndMs: Int64;
        Contagem: TDictionary<string, Integer>;
        constructor Create;
        destructor Destroy; override;
        function Detalhe: string;
      end;
    var
      FDb: IDbQueue;
      FClock: IClock;
      FLogger: ILogger;
      FLock: TCriticalSection;
      FAbertas: TObjectDictionary<string, TAberta>;
      FTabelaPronta: Boolean;
    function GarantirTabela: Boolean;
    // Tira da tabela em memoria e grava. Chamar com FLock tomado.
    procedure Fechar(const Chave: string);
  public
    constructor Create(const ADb: IDbQueue; const AClock: IClock;
                       const ALogger: ILogger);
    destructor Destroy; override;
    // Um comando que acabou de sair. Acao entra no detalhe do trecho.
    procedure Registrar(const Camera, Kind, Acao: string);
    // Fecha os trechos sem comando ha mais de GAP_MS. Barata; o laco
    // principal chama a cada meio segundo.
    procedure Varrer;
    // Os trechos que se sobrepoem a janela, os abertos inclusive.
    function Consultar(const Camera: string; FromMs, ToMs: Int64): TInteracaoArray;
  end;

implementation

const
  // Mais que isto sem comando, e a proxima vez e outra interacao. Folgado de
  // proposito: quem move a camera para, olha e move de novo esta fazendo UMA
  // coisa so.
  GAP_MS = 15000;
  // Teto de um trecho. E o que da piso a consulta por sobreposicao -- o mesmo
  // raciocinio do analytics.maxEventMs, ver Vms.Analytics.StoreDb -- e uma
  // faixa de horas na regua nao ajudaria ninguem a achar nada.
  MAX_MS = 300000;

  SQL_TABELA =
    'CREATE TABLE IF NOT EXISTS interaction (' +
    '  id            INTEGER PRIMARY KEY,' +
    '  camera_id     INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,' +
    '  start_ms      INTEGER NOT NULL,' +
    '  end_ms        INTEGER NOT NULL,' +
    '  kind          TEXT    NOT NULL CHECK (kind IN (''ptz'',''fala'')),' +
    '  detail        TEXT    NOT NULL DEFAULT '''',' +
    '  created_at_ms INTEGER NOT NULL,' +
    '  CHECK (end_ms >= start_ms)' +
    ');' + sLineBreak +
    'CREATE INDEX IF NOT EXISTS ix_interaction_window ' +
    '  ON interaction (camera_id, start_ms);';

  SQL_INSERT =
    'INSERT INTO interaction (camera_id, start_ms, end_ms, kind, detail, ' +
    '  created_at_ms) ' +
    'VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?)';

{ TInteractionLog.TAberta }

constructor TInteractionLog.TAberta.Create;
begin
  inherited Create;
  Contagem := TDictionary<string, Integer>.Create;
end;

destructor TInteractionLog.TAberta.Destroy;
begin
  Contagem.Free;
  inherited;
end;

function TInteractionLog.TAberta.Detalhe: string;
var
  Par: TPair<string, Integer>;
begin
  Result := '';
  for Par in Contagem do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + Format('%s x%d', [Par.Key, Par.Value]);
  end;
end;

{ TInteractionLog }

constructor TInteractionLog.Create(const ADb: IDbQueue; const AClock: IClock;
  const ALogger: ILogger);
begin
  inherited Create;
  FDb := ADb;
  FClock := AClock;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FAbertas := TObjectDictionary<string, TAberta>.Create([doOwnsValues]);
end;

destructor TInteractionLog.Destroy;
var
  Chaves: TArray<string>;
  Chave: string;
begin
  // Desligando com alguem no meio de um gesto: o trecho vai para o banco como
  // esta, em vez de sumir.
  FLock.Enter;
  try
    Chaves := FAbertas.Keys.ToArray;
    for Chave in Chaves do
      Fechar(Chave);
  finally
    FLock.Leave;
  end;
  FAbertas.Free;
  FLock.Free;
  inherited;
end;

function TInteractionLog.GarantirTabela: Boolean;
begin
  Result := FTabelaPronta;
  if Result then Exit;
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  try
    FDb.ExecScript(SQL_TABELA);
    FTabelaPronta := True;
    Result := True;
  except
    on E: Exception do
      if FLogger <> nil then
        FLogger.Warn('interacao', 'nao consegui criar a tabela: ' + E.Message);
  end;
end;

procedure TInteractionLog.Fechar(const Chave: string);
var
  A: TInteractionLog.TAberta;
begin
  if not FAbertas.TryGetValue(Chave, A) then Exit;
  if FLogger <> nil then
    FLogger.Info('interacao', Format('%s %s: %d s (%s)',
      [A.Camera, A.Kind, (A.EndMs - A.StartMs) div 1000, A.Detalhe]));
  if GarantirTabela then
    // Post: quem fecha e uma thread do HTTP ou o laco principal, e nenhum dos
    // dois deve esperar disco por causa de um registro.
    FDb.Post(SQL_INSERT, [A.Camera, A.StartMs, A.EndMs, A.Kind, A.Detalhe,
                          FClock.NowUtcMs]);
  FAbertas.Remove(Chave);
end;

procedure TInteractionLog.Registrar(const Camera, Kind, Acao: string);
var
  Chave: string;
  A: TInteractionLog.TAberta;
  Agora: Int64;
  N: Integer;
begin
  if (Trim(Camera) = '') or (Trim(Kind) = '') then Exit;
  Agora := FClock.NowUtcMs;
  Chave := LowerCase(Camera) + #0 + Kind;
  FLock.Enter;
  try
    if FAbertas.TryGetValue(Chave, A) and
       ((Agora - A.EndMs > GAP_MS) or (Agora - A.StartMs > MAX_MS)) then
    begin
      Fechar(Chave);
      A := nil;
    end;
    if A = nil then
    begin
      A := TInteractionLog.TAberta.Create;
      A.Camera := Camera;
      A.Kind := Kind;
      A.StartMs := Agora;
      FAbertas.Add(Chave, A);
    end;
    // Relogio de parede que volte (NTP acertando) nao pode deixar o fim antes
    // do comeco: a tabela recusa, e o trecho se perderia inteiro.
    if Agora > A.EndMs then A.EndMs := Agora;
    if A.EndMs < A.StartMs then A.EndMs := A.StartMs;
    if Acao <> '' then
    begin
      if not A.Contagem.TryGetValue(Acao, N) then N := 0;
      A.Contagem.AddOrSetValue(Acao, N + 1);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TInteractionLog.Varrer;
var
  Agora: Int64;
  Par: TPair<string, TInteractionLog.TAberta>;
  Vencidas: TList<string>;
  Chave: string;
begin
  Agora := FClock.NowUtcMs;
  Vencidas := TList<string>.Create;
  FLock.Enter;
  try
    for Par in FAbertas do
      if Agora - Par.Value.EndMs > GAP_MS then
        Vencidas.Add(Par.Key);
    for Chave in Vencidas do
      Fechar(Chave);
  finally
    FLock.Leave;
    Vencidas.Free;
  end;
end;

function TInteractionLog.Consultar(const Camera: string;
  FromMs, ToMs: Int64): TInteracaoArray;
var
  Lista: TList<TInteracao>;
  It: TInteracao;
  A: TInteractionLog.TAberta;
begin
  Result := nil;
  if (Trim(Camera) = '') or (ToMs <= FromMs) then Exit;
  Lista := TList<TInteracao>.Create;
  try
    if GarantirTabela then
    begin
      try
        FDb.Read(
          'SELECT i.start_ms, i.end_ms, i.kind, i.detail ' +
          '  FROM interaction i JOIN camera c ON c.id = i.camera_id ' +
          ' WHERE c.name = ? AND i.start_ms >= ? AND i.start_ms <= ? ' +
          '   AND i.end_ms >= ? ORDER BY i.start_ms LIMIT 4000',
          [Camera, FromMs - MAX_MS, ToMs, FromMs],
          procedure(const Row: IDbRow)
          var
            R: TInteracao;
          begin
            R.StartMs := Row.AsInt64('start_ms');
            R.EndMs := Row.AsInt64('end_ms');
            R.Kind := Row.AsString('kind');
            R.Detail := Row.AsString('detail');
            Lista.Add(R);
          end);
      except
        on E: Exception do
          // Mesma escolha da consulta de eventos: lista vazia, e nao 500. A
          // regua sem a faixa e ruim; a regua inteira falhando e pior.
          if FLogger <> nil then
            FLogger.Warn('interacao', 'consulta falhou: ' + E.Message);
      end;
    end;

    FLock.Enter;
    try
      for A in FAbertas.Values do
        if SameText(A.Camera, Camera) and (A.StartMs <= ToMs) and
           (A.EndMs >= FromMs) then
        begin
          It.StartMs := A.StartMs;
          It.EndMs := A.EndMs;
          It.Kind := A.Kind;
          It.Detail := A.Detalhe;
          Lista.Add(It);
        end;
    finally
      FLock.Leave;
    end;
    Result := Lista.ToArray;
  finally
    Lista.Free;
  end;
end;

end.
