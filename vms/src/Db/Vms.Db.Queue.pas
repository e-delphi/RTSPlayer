unit Vms.Db.Queue;

// A fila e a thread dona da conexao. E a UNICA unit do servidor que fala
// FireDAC.
//
// Uma thread abre a TFDConnection e nenhuma linha de SQL roda fora dela. As
// outras submetem trabalho e escolhem se esperam (ver Vms.Db.Intf). Isso torna
// a serializacao uma propriedade da estrutura: nao ha como um chamador pegar a
// conexao, mesmo querendo.
//
// ## Lote
//
// `Post` consecutivos entram numa transacao so, com commit a cada
// BATCH_ITEMS ou BATCH_MS, o que vier primeiro, e tambem quando a fila esvazia.
// E o que faz uma rajada de log de backfill custar um fsync em vez de milhares.
//
// A fila e FIFO ESTRITA. Quem chama Exec/Read espera, no maximo, o lote
// corrente fechar. Deixar leitura furar a fila daria latencia menor e a
// possibilidade de uma consulta nao enxergar um Post ja submetido — troca ruim,
// por um ganho que este volume de escrita nao precisa.
//
// ## Falha de Post nao volta pela fila
//
// Um Post nao tem quem espere por ele. O caminho natural para o erro seria o
// log — mas o log tambem escreve por esta fila, e uma falha do log geraria
// outra escrita de log, e assim por diante. Erro daqui vai para o CONSOLE e
// para um arquivo de emergencia ao lado do executavel, e para por ali.
//
// ## A conexao nasce na thread dela
//
// TFDConnection tem afinidade de thread. Abrir no construtor (na thread de quem
// criou) e usar noutra e a receita para um travamento que so aparece em
// producao. Por isso o Create espera a thread avisar que abriu, e so entao
// volta — falha ao abrir vira excecao no construtor, onde ela e util.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Variants,
  System.IOUtils,
  System.Generics.Collections,
  Data.DB,                 // TField: e o que a IDbRow devolve por baixo
  FireDAC.Comp.Client,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.Def,
  FireDAC.Stan.Option,
  FireDAC.DApt,
  FireDAC.Stan.Async,
  FireDAC.Stan.Param,
  FireDAC.Comp.Script,
  FireDAC.Comp.ScriptCommands,
  // O FireDAC exige um "UI provider" ligado mesmo sem prompt de login; sem
  // isto, a primeira operacao que quisesse mostrar espera levantaria
  // "cannot find the FireDAC UI provider". Em app de console, e este.
  FireDAC.ConsoleUI.Wait,
  Vms.Db.Intf;

type
  TDbQueue = class(TInterfacedObject, IDbQueue)
  strict private
  type
    TOpKind = (okPost, okPostScript, okExec, okExecScript, okRead);

    TItem = class
    public
      // `public` escrito, e nao herdado do padrao: sem especificador, a
      // visibilidade depende do estado de {$M}, e OnRow, sendo `reference to
      // procedure`, nao pode ser published.
      Kind: TOpKind;
      Sql: string;
      Params: TArray<Variant>;
      OnRow: TDbRowProc;
      Done: TEvent;          // nil = ninguem espera; o worker libera o item
      Error: string;
      Affected: Integer;
      constructor Create(AKind: TOpKind; const ASql: string;
                         const AParams: array of Variant; Espera: Boolean);
      destructor Destroy; override;
    end;

    // A linha, durante o OnRow. Reusada em todas as linhas do mesmo Read: ela
    // so le o registro corrente do cursor, entao alocar uma por linha seria
    // desperdicio numa consulta de milhares.
    TFdRow = class(TInterfacedObject, IDbRow)
    strict private
      FQuery: TFDQuery;
      function Field(const Name: string): TField;
    public
      constructor Create(AQuery: TFDQuery);
      procedure Invalidate;    // depois do Read: uso posterior falha alto
      function IsNull(const Name: string): Boolean;
      function AsInt64(const Name: string): Int64;
      function AsInt(const Name: string): Integer;
      function AsBool(const Name: string): Boolean;
      function AsFloat(const Name: string): Double;
      function AsString(const Name: string): string;
    end;

    TWorker = class(TThread)
    strict private
      FOwner: TDbQueue;
    protected
      procedure Execute; override;
    public
      constructor Create(AOwner: TDbQueue);
    end;

  strict private
    FDbPath: string;
    FConn: TFDConnection;
    FWorker: TWorker;
    FLock: TCriticalSection;
    FWake: TEvent;
    FReady: TEvent;
    FOpenError: string;
    FStopping: Boolean;
    FQueue: TQueue<TItem>;
    // Cache de comandos preparados por texto de SQL. O log manda o MESMO
    // INSERT milhares de vezes; reparar a cada um jogaria fora o ganho do lote.
    FPrepared: TObjectDictionary<string, TFDQuery>;
    FBatchOpen: Boolean;
    FBatchCount: Integer;
    FBatchSince: UInt64;
    // Escrito pela thread do worker (Drain, CommitBatch) E pelas threads que
    // chamam Post depois do encerramento: incremento atomico, senao a conta
    // sai errada justamente no relatorio que existe para nao mentir.
    FDropped: Integer;
    FEmergencyLock: TCriticalSection;
    procedure Emergency(const Msg: string);
    procedure OpenConnection;
    procedure CloseConnection;
    function TakeQuery(const Sql: string): TFDQuery;
    procedure Bind(Q: TFDQuery; const Params: TArray<Variant>);
    procedure RunItem(Item: TItem);
    procedure RunScript(const Script: string);
    procedure EnsureBatch;
    procedure CommitBatch;
    function Pop(out Item: TItem): Boolean;
    procedure Push(Item: TItem);
    procedure Drain;
    // Enfileira e espera. Devolve o item (que o CHAMADOR libera) para quem
    // precisa do Affected.
    procedure Submit(Item: TItem);
  private
    // `private`, e nao `strict private`, por um motivo so: quem chama isto e a
    // TWorker, uma classe ANINHADA. Delphi so garante o acesso de uma classe
    // aos membros de outra da MESMA UNIT quando eles nao sao `strict` — e o
    // `strict` derruba justamente essa regra. Foi o que quebrou o build com
    // `Terminated`, e nao vale arriscar a mesma familia de erro duas vezes.
    procedure WorkerLoop;
  public
    // Abre o banco (criando a pasta se preciso) e levanta se nao conseguir.
    // Volta so depois de a thread confirmar que a conexao subiu.
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    procedure Stop;
    { IDbQueue }
    procedure Post(const Sql: string; const Params: array of Variant);
    procedure PostScript(const Script: string);
    function Exec(const Sql: string; const Params: array of Variant): Integer;
    procedure ExecScript(const Script: string);
    procedure Read(const Sql: string; const Params: array of Variant;
                   const OnRow: TDbRowProc);
    function ReadInt64(const Sql: string; const Params: array of Variant;
                       const Column: string; Default: Int64 = 0): Int64;
    function IsOpen: Boolean;
    function DbPath: string;
    function Pending: Integer;
    // Quantas escritas foram descartadas por chegarem depois do encerramento.
    property Dropped: Integer read FDropped;
  end;

// Monta a conexao do jeito que este projeto precisa. Exposta porque a receita
// tem armadilha e vale poder conferi-la de fora.
function NewSqliteConnection(const FileName: string): TFDConnection;

implementation

const
  // Teto do lote. 500 linhas de log e o que uma rajada de backfill produz em
  // poucos segundos; 200 ms e o maximo que um Read vai esperar por causa dele.
  BATCH_ITEMS = 500;
  BATCH_MS    = 200;
  // Quanto a thread dorme quando nao ha nada. Curto o bastante para o commit
  // por tempo acontecer na hora, longo o bastante para nao girar a toa.
  IDLE_MS     = 50;
  // Teto do cache de comandos preparados.
  MAX_PREPARED = 32;
  EMERGENCY_FILE = 'vmsserver-db.log';

// ---------------------------------------------------------------- conexao

function NewSqliteConnection(const FileName: string): TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  try
    Result.LoginPrompt := False;
    with TFDPhysSQLiteConnectionDefParams(Result.Params) do
    begin
      DriverID := 'SQLite';
      // ANTES de abrir. Com Database vazio o SQLite abre um banco TEMPORARIO
      // privado e o Open seguinte nao reconecta: o servidor gravaria tudo num
      // arquivo que some ao fechar, sem erro nenhum.
      Database := FileName;
      JournalMode := jmWAL;
      Synchronous := snNormal;
      // Nao lmExclusive: um cliente de SQLite ainda precisa conseguir abrir o
      // arquivo para olhar o que esta la dentro.
      LockingMode := lmNormal;
      SharedCache := False;
      // O esquema depende de ON DELETE CASCADE, e o SQLite vem com a checagem
      // DESLIGADA por padrao. Sem isto, apagar uma camera deixaria eventos e
      // gravacoes orfaos apontando para um id que nao existe mais.
      ForeignKeys := fkOn;
      BusyTimeout := 5000;
    end;
    // O pre-processador do FireDAC interpreta `&`, `!`, `{}` e corta script ao
    // meio. Desligado, o SQL chega ao banco como foi escrito.
    // https://docwiki.embarcadero.com/RADStudio/Sydney/en/Preprocessing_Command_Text_(FireDAC)
    Result.ResourceOptions.MacroCreate := False;
    Result.ResourceOptions.MacroExpand := False;
    Result.ResourceOptions.EscapeExpand := False;
    Result.UpdateOptions.LockWait := True;
    Result.Open;
  except
    Result.Free;
    raise;
  end;
end;

// ------------------------------------------------------------------ TItem

constructor TDbQueue.TItem.Create(AKind: TOpKind; const ASql: string;
  const AParams: array of Variant; Espera: Boolean);
var
  I: Integer;
begin
  inherited Create;
  Kind := AKind;
  Sql := ASql;
  SetLength(Params, Length(AParams));
  for I := 0 to High(AParams) do
    Params[I] := AParams[I];
  if Espera then
    Done := TEvent.Create(nil, True, False, '');
end;

destructor TDbQueue.TItem.Destroy;
begin
  Done.Free;
  inherited;
end;

// ------------------------------------------------------------------ TFdRow

constructor TDbQueue.TFdRow.Create(AQuery: TFDQuery);
begin
  inherited Create;
  FQuery := AQuery;
end;

procedure TDbQueue.TFdRow.Invalidate;
begin
  FQuery := nil;
end;

function TDbQueue.TFdRow.Field(const Name: string): TField;
begin
  // Guardar a IDbRow para usar depois do OnRow e erro de uso, e falha aqui em
  // vez de ler o cursor de outra consulta.
  if FQuery = nil then
    raise EDbError.CreateFmt('linha usada fora do OnRow (coluna "%s")', [Name]);
  Result := FQuery.FindField(Name);
  if Result = nil then
    raise EDbError.CreateFmt('coluna "%s" nao existe no resultado', [Name]);
end;

function TDbQueue.TFdRow.IsNull(const Name: string): Boolean;
begin
  Result := Field(Name).IsNull;
end;

function TDbQueue.TFdRow.AsInt64(const Name: string): Int64;
var
  F: TField;
begin
  F := Field(Name);
  if F.IsNull then Exit(0);
  Result := F.AsLargeInt;
end;

function TDbQueue.TFdRow.AsInt(const Name: string): Integer;
var
  F: TField;
begin
  F := Field(Name);
  if F.IsNull then Exit(0);
  Result := F.AsInteger;
end;

function TDbQueue.TFdRow.AsBool(const Name: string): Boolean;
var
  F: TField;
begin
  F := Field(Name);
  // 0/1, porque SQLite nao tem booleano proprio e o esquema grava inteiro.
  Result := (not F.IsNull) and (F.AsInteger <> 0);
end;

function TDbQueue.TFdRow.AsFloat(const Name: string): Double;
var
  F: TField;
begin
  F := Field(Name);
  if F.IsNull then Exit(0);
  Result := F.AsFloat;
end;

function TDbQueue.TFdRow.AsString(const Name: string): string;
var
  F: TField;
begin
  F := Field(Name);
  if F.IsNull then Exit('');
  Result := F.AsString;
end;

// ----------------------------------------------------------------- TWorker

constructor TDbQueue.TWorker.Create(AOwner: TDbQueue);
begin
  // Campos primeiro, `inherited Create(False)` por ultimo, e SEM chamar Start:
  // quem inicia e o TThread.AfterConstruction (ver TApiThumbProvider.TFetcher,
  // mesma armadilha, mesmo motivo).
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDbQueue.TWorker.Execute;
begin
  NameThreadForDebugging('vms.db');
  FOwner.WorkerLoop;
end;

// ---------------------------------------------------------------- TDbQueue

constructor TDbQueue.Create(const ADbPath: string);
begin
  inherited Create;
  FDbPath := ADbPath;
  FLock := TCriticalSection.Create;
  FEmergencyLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FReady := TEvent.Create(nil, True, False, '');
  FQueue := TQueue<TItem>.Create;
  FPrepared := TObjectDictionary<string, TFDQuery>.Create([doOwnsValues]);
  FWorker := TWorker.Create(Self);
  // A conexao abre NA THREAD dela; aqui so se espera o veredito.
  FReady.WaitFor(INFINITE);
  if FOpenError <> '' then
  begin
    Stop;
    raise EDbError.CreateFmt('nao consegui abrir %s: %s', [FDbPath, FOpenError]);
  end;
end;

destructor TDbQueue.Destroy;
begin
  Stop;
  FPrepared.Free;
  FQueue.Free;
  FReady.Free;
  FWake.Free;
  FEmergencyLock.Free;
  FLock.Free;
  inherited;
end;

procedure TDbQueue.Stop;
begin
  FLock.Enter;
  try
    if FStopping then Exit;
    FStopping := True;
  finally
    FLock.Leave;
  end;
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FWake.SetEvent;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

// O log da propria fila. NUNCA passa pelo banco: ver o cabecalho.
procedure TDbQueue.Emergency(const Msg: string);
var
  Linha, Arquivo: string;
begin
  Linha := Format('%s  %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), Msg]);
  FEmergencyLock.Enter;
  try
    try
      Writeln(ErrOutput, '[db] ' + Linha);
    except
      // console redirecionado ou fechado: nao ha o que fazer, e nao pode subir
    end;
    try
      Arquivo := TPath.Combine(ExtractFilePath(ParamStr(0)), EMERGENCY_FILE);
      TFile.AppendAllText(Arquivo, Linha + sLineBreak, TEncoding.UTF8);
    except
      // sem permissao, disco cheio: idem
    end;
  finally
    FEmergencyLock.Leave;
  end;
end;

procedure TDbQueue.OpenConnection;
var
  Dir: string;
begin
  try
    Dir := ExtractFilePath(FDbPath);
    if (Dir <> '') and (not TDirectory.Exists(Dir)) then
      TDirectory.CreateDirectory(Dir);
    FConn := NewSqliteConnection(FDbPath);
    FOpenError := '';
  except
    on E: Exception do
    begin
      FConn := nil;
      FOpenError := E.ClassName + ': ' + E.Message;
    end;
  end;
  FReady.SetEvent;
end;

procedure TDbQueue.CloseConnection;
begin
  if FConn = nil then Exit;
  try
    // Deixa o SQLite atualizar as estatisticas antes de fechar; e barato e faz
    // a proxima subida planejar melhor as consultas.
    if FConn.Connected then
      FConn.ExecSQL('PRAGMA optimize');
  except
    on E: Exception do Emergency('PRAGMA optimize: ' + E.Message);
  end;
  // Os comandos preparados sao filhos da conexao: soltam antes dela.
  FPrepared.Clear;
  try
    FConn.Free;
  except
    on E: Exception do Emergency('fechar: ' + E.Message);
  end;
  FConn := nil;
end;

function TDbQueue.TakeQuery(const Sql: string): TFDQuery;
begin
  if FPrepared.TryGetValue(Sql, Result) then Exit;
  // Sem politica de idade: os SQL desta aplicacao sao um punhado fixo, e o
  // teto existe so para o caso de alguem gerar texto variavel por engano.
  if FPrepared.Count >= MAX_PREPARED then
    FPrepared.Clear;
  Result := TFDQuery.Create(nil);
  Result.Connection := FConn;
  Result.ResourceOptions.MacroCreate := False;
  Result.ResourceOptions.MacroExpand := False;
  Result.ResourceOptions.EscapeExpand := False;
  Result.SQL.Text := Sql;
  FPrepared.Add(Sql, Result);
end;

procedure TDbQueue.Bind(Q: TFDQuery; const Params: TArray<Variant>);
var
  I: Integer;
begin
  if Q.Params.Count <> Length(Params) then
    raise EDbError.CreateFmt('%d parametros para um comando que espera %d',
      [Length(Params), Q.Params.Count]);
  for I := 0 to High(Params) do
    if VarIsNull(Params[I]) or VarIsEmpty(Params[I]) then
      Q.Params[I].Clear
    else
      Q.Params[I].Value := Params[I];
end;

procedure TDbQueue.RunScript(const Script: string);
var
  S: TFDScript;
begin
  // TFDScript, e nao um laco de ExecSQL: ExecSQL executa UM comando, e fatiar
  // o texto por `;` na mao erraria no primeiro `;` dentro de uma string.
  S := TFDScript.Create(nil);
  try
    S.Connection := FConn;
    S.ScriptOptions.CommandSeparator := ';';
    S.ScriptOptions.BreakOnError := True;
    S.SQLScripts.Clear;
    S.SQLScripts.Add.SQL.Text := Script;
    // O resultado do ValidateAll importa: seguir para o ExecuteAll com um
    // script que nao passou daria o erro no meio da execucao, com metade dos
    // comandos ja aplicados, em vez de antes de tocar no banco.
    if not S.ValidateAll then
      raise EDbError.Create('o script nao passou na validacao do FireDAC');
    S.ExecuteAll;
  finally
    S.Free;
  end;
end;

procedure TDbQueue.RunItem(Item: TItem);
var
  Q: TFDQuery;
  Row: TFdRow;
  Iface: IDbRow;
begin
  case Item.Kind of
    okPost, okExec:
      begin
        Q := TakeQuery(Item.Sql);
        Bind(Q, Item.Params);
        Q.ExecSQL;
        Item.Affected := Q.RowsAffected;
      end;

    okPostScript, okExecScript:
      RunScript(Item.Sql);

    okRead:
      begin
        Q := TakeQuery(Item.Sql);
        Bind(Q, Item.Params);
        Q.Open;
        try
          Row := TFdRow.Create(Q);
          Iface := Row;              // a contagem de referencia passa a mandar
          try
            while not Q.Eof do
            begin
              if Assigned(Item.OnRow) then
                Item.OnRow(Iface);
              Q.Next;
            end;
          finally
            // Se o OnRow guardou a referencia, o proximo uso levanta em vez de
            // ler o cursor de outra consulta.
            Row.Invalidate;
            Iface := nil;
          end;
        finally
          Q.Close;
        end;
      end;
  end;
end;

procedure TDbQueue.EnsureBatch;
begin
  if FBatchOpen then Exit;
  FConn.StartTransaction;
  FBatchOpen := True;
  FBatchCount := 0;
  FBatchSince := TThread.GetTickCount64;
end;

procedure TDbQueue.CommitBatch;
begin
  if not FBatchOpen then Exit;
  FBatchOpen := False;
  try
    FConn.Commit;
  except
    on E: Exception do
    begin
      // Commit que falha (disco cheio) leva o lote inteiro. Dizer QUANTAS
      // linhas se perderam e o minimo — sem isso o buraco no log seria mudo.
      Emergency(Format('commit de %d escrita(s) falhou: %s. As linhas do lote ' +
        'foram perdidas.', [FBatchCount, E.Message]));
      try FConn.Rollback; except end;
      TInterlocked.Add(FDropped, FBatchCount);
    end;
  end;
  FBatchCount := 0;
end;

procedure TDbQueue.Push(Item: TItem);
begin
  FLock.Enter;
  try
    FQueue.Enqueue(Item);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TDbQueue.Pop(out Item: TItem): Boolean;
begin
  Item := nil;
  FLock.Enter;
  try
    if FQueue.Count > 0 then
      Item := FQueue.Dequeue;
  finally
    FLock.Leave;
  end;
  Result := Item <> nil;
end;

// O que sobrou quando o servidor esta fechando. Quem espera e liberado com
// erro; quem nao espera e contado, porque "perdi 12 escritas ao fechar" nao
// pode ser silencioso.
procedure TDbQueue.Drain;
var
  Item: TItem;
begin
  while Pop(Item) do
  begin
    if Item.Done <> nil then
    begin
      Item.Error := 'a fila do banco foi encerrada';
      Item.Done.SetEvent;         // quem espera libera o item
    end
    else
    begin
      TInterlocked.Increment(FDropped);
      Item.Free;
    end;
  end;
end;

procedure TDbQueue.WorkerLoop;
var
  Item: TItem;
  Espera: Boolean;
begin
  OpenConnection;
  if FConn = nil then Exit;       // o construtor ja vai levantar
  try
   try
    while True do
    begin
      if not Pop(Item) then
      begin
        // Fila vazia: fecha o lote agora. Commitar so por tempo deixaria a
        // escrita invisivel para a proxima consulta sem motivo nenhum.
        CommitBatch;
        // FStopping, e nao Terminated: este metodo e do TDbQueue, nao do
        // TThread — Terminated e protegido e declarado noutra unit, entao nem
        // por FWorker.Terminated daria. E FStopping diz a mesma coisa, e e o
        // mesmo sinalizador que faz Post e Submit recusarem trabalho novo.
        // Ler sem o lock e de proposito: no pior caso gasta-se mais uma volta,
        // e o Stop ainda acorda a thread pelo FWake logo em seguida.
        if FStopping then Break;
        FWake.WaitFor(IDLE_MS);
        Continue;
      end;

      Espera := Item.Done <> nil;
      try
        if Espera then
          // FIFO e visibilidade: o que veio antes ja esta gravado quando esta
          // leitura (ou escrita sincrona) roda.
          CommitBatch
        else
          EnsureBatch;

        try
          RunItem(Item);
        except
          on E: Exception do
            if Espera then
              Item.Error := E.Message
            else
              // Ninguem para avisar. Uma linha recusada nao envenena a
              // transacao no SQLite, entao o lote segue com as boas.
              Emergency(Format('%s | %s', [E.Message, Item.Sql]));
        end;

        if not Espera then
        begin
          Inc(FBatchCount);
          if (FBatchCount >= BATCH_ITEMS) or
             ((TThread.GetTickCount64 - FBatchSince) >= BATCH_MS) then
            CommitBatch;
        end;
      finally
        if Espera then
          Item.Done.SetEvent      // quem espera e dono do item, e o libera
        else
          Item.Free;
      end;
    end;
   except
     on E: Exception do
       // O laco nunca deveria cair aqui. Se cair, o `finally` abaixo ainda
       // libera quem espera — sem isso, uma excecao inesperada penduraria
       // todas as threads paradas no WaitFor, para sempre.
       Emergency('laco da fila morreu: ' + E.ClassName + ': ' + E.Message);
   end;
  finally
    CommitBatch;
    Drain;
    CloseConnection;
  end;
end;

// Enfileira e espera. O item volta com Error/Affected preenchidos; liberar e de
// quem chamou (por isso este metodo nao libera nada no caminho normal).
procedure TDbQueue.Submit(Item: TItem);
var
  Encerrando: Boolean;
begin
  FLock.Enter;
  try
    Encerrando := FStopping;
    if not Encerrando then
      FQueue.Enqueue(Item);
  finally
    FLock.Leave;
  end;
  // Recusa FORA do lock: levantar com o lock na mao deixaria a secao critica
  // presa se alguem um dia capturasse esta excecao mais acima.
  if Encerrando then
  begin
    Item.Free;
    raise EDbError.Create('a fila do banco esta encerrando');
  end;
  FWake.SetEvent;
  Item.Done.WaitFor(INFINITE);
end;

{ IDbQueue }

procedure TDbQueue.Post(const Sql: string; const Params: array of Variant);
var
  Item: TItem;
begin
  FLock.Enter;
  try
    if FStopping then
    begin
      Inc(FDropped);
      Exit;
    end;
  finally
    FLock.Leave;
  end;
  Item := TItem.Create(okPost, Sql, Params, False);
  Push(Item);
end;

procedure TDbQueue.PostScript(const Script: string);
var
  Item: TItem;
begin
  FLock.Enter;
  try
    if FStopping then
    begin
      Inc(FDropped);
      Exit;
    end;
  finally
    FLock.Leave;
  end;
  Item := TItem.Create(okPostScript, Script, [], False);
  Push(Item);
end;

function TDbQueue.Exec(const Sql: string; const Params: array of Variant): Integer;
var
  Item: TItem;
begin
  Item := TItem.Create(okExec, Sql, Params, True);
  try
    Submit(Item);
    if Item.Error <> '' then
      raise EDbError.CreateFmt('%s | %s', [Item.Error, Sql]);
    Result := Item.Affected;
  finally
    Item.Free;
  end;
end;

procedure TDbQueue.ExecScript(const Script: string);
var
  Item: TItem;
begin
  Item := TItem.Create(okExecScript, Script, [], True);
  try
    Submit(Item);
    if Item.Error <> '' then
      raise EDbError.Create(Item.Error);
  finally
    Item.Free;
  end;
end;

procedure TDbQueue.Read(const Sql: string; const Params: array of Variant;
  const OnRow: TDbRowProc);
var
  Item: TItem;
begin
  Item := TItem.Create(okRead, Sql, Params, True);
  try
    Item.OnRow := OnRow;
    Submit(Item);
    if Item.Error <> '' then
      raise EDbError.CreateFmt('%s | %s', [Item.Error, Sql]);
  finally
    Item.Free;
  end;
end;

function TDbQueue.ReadInt64(const Sql: string; const Params: array of Variant;
  const Column: string; Default: Int64): Int64;
var
  Achou: Boolean;
  Valor: Int64;
begin
  Achou := False;
  Valor := Default;
  Read(Sql, Params,
    procedure(const Row: IDbRow)
    begin
      if Achou then Exit;         // so a primeira linha interessa
      Valor := Row.AsInt64(Column);
      Achou := True;
    end);
  Result := Valor;
end;

function TDbQueue.IsOpen: Boolean;
begin
  Result := (FConn <> nil) and (not FStopping);
end;

function TDbQueue.DbPath: string;
begin
  Result := FDbPath;
end;

function TDbQueue.Pending: Integer;
begin
  FLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

end.
