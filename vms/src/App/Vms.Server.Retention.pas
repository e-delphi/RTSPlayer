unit Vms.Server.Retention;

// Limpeza automática das gravações.
//
// Sem isto o disco enche e o servidor para de gravar: medido com três câmeras,
// ~21 GB por dia. É o mínimo para deixar o vmsserver rodando sem babá.
//
// Três limites, todos opcionais (0 = desligado), avaliados a cada varredura e
// sempre apagando o arquivo MAIS ANTIGO primeiro:
//
//   maxDays     idade máxima de um arquivo
//   maxTotalGB  tamanho somado de todos os .vms da pasta
//   minFreeGB   espaço que deve continuar livre no disco
//
// O que a varredura nunca apaga:
//   - arquivo tocado nos últimos GRACE_SECONDS: é a gravação em curso;
//   - arquivo que o sistema não deixa apagar, porque o gravador e as sessões ao
//     vivo mantêm o handle aberto sem compartilhar exclusão. Falha de exclusão
//     não é erro: o arquivo fica para a próxima varredura;
//   - qualquer coisa que não termine em .vms.
//
// Por que o mais antigo primeiro, e não cota por câmera: o disco é um só, e a
// ordem por data é a que alguém consegue prever olhando a pasta. Cota por câmera
// fica para quando fizer falta (uma câmera muito mais movimentada que as outras
// consegue encurtar o histórico das demais).

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  VMS.Domain.Logging;

type
  TRetentionPolicy = record
    MaxDays: Integer;      // 0 = sem limite de idade
    MaxTotalBytes: Int64;  // 0 = sem limite de tamanho
    MinFreeBytes: Int64;   // 0 = não olha espaço livre
    IntervalMs: Integer;   // de quanto em quanto tempo varre
    function Enabled: Boolean;
    function Describe: string;
  end;

  TRetentionResult = record
    Deleted: Integer;
    FreedBytes: Int64;
    KeptFiles: Integer;
    KeptBytes: Int64;
    Locked: Integer;       // não deu para apagar agora (em uso)
    ShortOnSpace: Boolean; // acabaram os candidatos e o mínimo livre não foi atingido
  end;

  TRetentionThread = class(TThread)
  strict private
    FDir: string;
    FPolicy: TRetentionPolicy;
    FLogger: ILogger;
    FStop: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADir: string; const APolicy: TRetentionPolicy;
                       const ALogger: ILogger; AStop: TEvent);
  end;

// Uma passada. Separada da thread para poder rodar na partida do servidor (e
// para ser testável sem esperar intervalo).
function SweepRetention(const Dir: string; const Policy: TRetentionPolicy;
  const Logger: ILogger): TRetentionResult;

// Espaço livre no volume da pasta. 0 = não foi possível descobrir.
function FreeSpaceOf(const Dir: string): Int64;

const
  GIGABYTE = Int64(1024) * 1024 * 1024;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;
{$ENDIF}

const
  TAG = 'retencao';
  // Arquivo tocado agora mesmo é a gravação em curso. Um bloco fecha a cada
  // ~2 s; 60 s dá folga de sobra sem proteger arquivo antigo.
  GRACE_SECONDS = 60;
  MIN_INTERVAL_MS = 10000;

type
  TRecFile = record
    Path: string;
    Size: Int64;
    Written: TDateTime;
    Deleted: Boolean; // saiu do disco nesta passada
    Skip: Boolean;    // não mexer: gravação em curso, ou já falhou nesta passada
  end;

{ TRetentionPolicy }

function TRetentionPolicy.Enabled: Boolean;
begin
  Result := (MaxDays > 0) or (MaxTotalBytes > 0) or (MinFreeBytes > 0);
end;

function TRetentionPolicy.Describe: string;
begin
  if not Enabled then
    Exit('desligada (nada apaga gravacao velha; o disco vai encher)');
  Result := '';
  if MaxDays > 0 then
    Result := Format('%d dia(s)', [MaxDays]);
  if MaxTotalBytes > 0 then
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + Format('max %.1f GB gravados', [MaxTotalBytes / GIGABYTE]);
  end;
  if MinFreeBytes > 0 then
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + Format('min %.1f GB livres', [MinFreeBytes / GIGABYTE]);
  end;
  Result := Result + Format('; varredura a cada %.0f min', [IntervalMs / 60000]);
end;

function FreeSpaceOf(const Dir: string): Int64;
{$IFDEF MSWINDOWS}
var
  FreeAvail, Total, TotalFree: TLargeInteger;
{$ENDIF}
begin
  Result := 0;
  {$IFDEF MSWINDOWS}
  FreeAvail := 0;
  Total := 0;
  TotalFree := 0;
  if GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(Dir)),
                        FreeAvail, Total, @TotalFree) then
    Result := FreeAvail;
  {$ENDIF}
end;

// Lista os .vms com tamanho e data numa varredura só (FindFirst já traz os
// três), do mais antigo para o mais novo — que é a ordem em que se apaga.
function ListRecordings(const Dir: string): TArray<TRecFile>;
var
  SR: TSearchRec;
  Base: string;
  N: Integer;
begin
  Result := nil;
  N := 0;
  Base := IncludeTrailingPathDelimiter(Dir);
  if FindFirst(Base + '*.vms', faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      if N >= Length(Result) then
        if Length(Result) = 0 then
          SetLength(Result, 64)
        else
          SetLength(Result, Length(Result) * 2);
      Result[N].Path := Base + SR.Name;
      Result[N].Size := SR.Size;
      Result[N].Written := SR.TimeStamp;
      Result[N].Deleted := False;
      Result[N].Skip := False;
      Inc(N);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  SetLength(Result, N);
  TArray.Sort<TRecFile>(Result, TComparer<TRecFile>.Construct(
    function(const A, B: TRecFile): Integer
    begin
      Result := CompareDateTime(A.Written, B.Written);
    end));
end;

function SweepRetention(const Dir: string; const Policy: TRetentionPolicy;
  const Logger: ILogger): TRetentionResult;
var
  Files: TArray<TRecFile>;
  I: Integer;
  Total, Avail: Int64;
  Cutoff: TDateTime;
  Res: TRetentionResult;

  // True se apagou agora. Mantém Total/Avail em dia para as regras seguintes.
  function Drop(Index: Integer; const Why: string): Boolean;
  begin
    Result := False;
    if Files[Index].Deleted or Files[Index].Skip then Exit;
    try
      TFile.Delete(Files[Index].Path);
    except
      on E: Exception do
      begin
        // aberto pelo gravador ou por uma sessão ao vivo: fica para a próxima
        Files[Index].Skip := True; // não tenta de novo nesta passada
        Inc(Res.Locked);
        if Logger <> nil then
          Logger.Debug(TAG, Format('em uso, nao apaguei %s',
            [ExtractFileName(Files[Index].Path)]));
        Exit;
      end;
    end;
    Files[Index].Deleted := True;
    Inc(Res.Deleted);
    Inc(Res.FreedBytes, Files[Index].Size);
    Dec(Total, Files[Index].Size);
    Inc(Avail, Files[Index].Size);
    if Logger <> nil then
      Logger.Info(TAG, Format('apagado %s (%.1f MB, %s)',
        [ExtractFileName(Files[Index].Path), Files[Index].Size / 1048576, Why]));
    Result := True;
  end;

begin
  FillChar(Res, SizeOf(Res), 0);
  Result := Res;
  if not Policy.Enabled then Exit;

  Files := ListRecordings(Dir);
  if Length(Files) = 0 then Exit;

  Total := 0;
  for I := 0 to High(Files) do
    Inc(Total, Files[I].Size);
  Avail := FreeSpaceOf(Dir);

  // A gravação em curso sai da lista antes de qualquer regra encostar nela.
  Cutoff := IncSecond(Now, -GRACE_SECONDS);
  for I := 0 to High(Files) do
    if CompareDateTime(Files[I].Written, Cutoff) > 0 then
      Files[I].Skip := True;

  if Policy.MaxDays > 0 then
  begin
    Cutoff := IncDay(Now, -Policy.MaxDays);
    for I := 0 to High(Files) do
      if CompareDateTime(Files[I].Written, Cutoff) < 0 then
        Drop(I, Format('mais de %d dia(s)', [Policy.MaxDays]));
  end;

  if Policy.MaxTotalBytes > 0 then
  begin
    I := 0;
    while (Total > Policy.MaxTotalBytes) and (I <= High(Files)) do
    begin
      Drop(I, 'limite de tamanho');
      Inc(I);
    end;
  end;

  // Espaço livre só entra se deu para medir (Avail = 0 significa que não deu).
  if (Policy.MinFreeBytes > 0) and (Avail > 0) then
  begin
    I := 0;
    while (Avail < Policy.MinFreeBytes) and (I <= High(Files)) do
    begin
      Drop(I, 'espaco livre');
      Inc(I);
    end;
    Res.ShortOnSpace := Avail < Policy.MinFreeBytes;
    if (Logger <> nil) and Res.ShortOnSpace then
      Logger.Warn(TAG, Format('livre %.1f GB, abaixo do minimo de %.1f GB, e nao ha' +
        ' mais gravacao antiga para apagar', [Avail / GIGABYTE, Policy.MinFreeBytes / GIGABYTE]));
  end;

  // Ficou no disco tudo que não foi apagado — inclusive o que estava em uso.
  for I := 0 to High(Files) do
    if not Files[I].Deleted then
    begin
      Inc(Res.KeptFiles);
      Inc(Res.KeptBytes, Files[I].Size);
    end;
  Result := Res;
end;

{ TRetentionThread }

constructor TRetentionThread.Create(const ADir: string; const APolicy: TRetentionPolicy;
  const ALogger: ILogger; AStop: TEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDir := ADir;
  FPolicy := APolicy;
  FLogger := ALogger;
  FStop := AStop;
  if FPolicy.IntervalMs < MIN_INTERVAL_MS then
    FPolicy.IntervalMs := MIN_INTERVAL_MS;
end;

procedure TRetentionThread.Execute;
var
  R: TRetentionResult;
  Waited: Integer;
  Extra: string;
begin
  while not Terminated do
  begin
    try
      R := SweepRetention(FDir, FPolicy, FLogger);
      if (FLogger <> nil) and ((R.Deleted > 0) or (R.Locked > 0)) then
      begin
        if R.Locked > 0 then
          Extra := Format(' (%d em uso, ficam para depois)', [R.Locked])
        else
          Extra := '';
        FLogger.Info(TAG, Format('%d apagado(s), %.2f GB liberados; ficaram %d' +
          ' arquivo(s) somando %.2f GB%s',
          [R.Deleted, R.FreedBytes / GIGABYTE, R.KeptFiles, R.KeptBytes / GIGABYTE, Extra]));
      end;
    except
      on E: Exception do
        if FLogger <> nil then
          FLogger.Warn(TAG, 'varredura falhou: ' + E.Message);
    end;
    // Espera fatiada: Ctrl+C não precisa aguardar o intervalo inteiro.
    Waited := 0;
    while (not Terminated) and (Waited < FPolicy.IntervalMs) do
    begin
      if (FStop <> nil) and (FStop.WaitFor(500) = wrSignaled) then Exit;
      Inc(Waited, 500);
    end;
  end;
end;

end.
