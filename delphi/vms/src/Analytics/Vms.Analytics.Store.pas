unit Vms.Analytics.Store;

// Onde os eventos ficam: um arquivo por camera por dia, ao lado das gravacoes.
//
//   <storage>/<camera>/events/2026-08-23.vev
//   <storage>/<camera>/events/progress.txt
//
// Sabe de bytes e de pastas, e de mais nada: nao conhece camera, nem modelo,
// nem HTTP. Implementa as duas pontas — IEventStore para quem escreve (o
// worker) e IEventSource para quem le (a API) — porque as duas falam do mesmo
// arquivo, mas quem depende delas depende de uma so.
//
// ## O formato
//
// Cabecalho de 32 bytes, seguido de registros de 64 bytes, sempre anexados:
//
//   cabecalho                        registro (64 bytes, fixo)
//   +0   'VEV1'         4            +0   startUnixMs        i64
//   +4   versao         u16 = 1      +8   endUnixMs          i64
//   +6   tamanhoReg     u16 = 64     +16  tipo               u8
//   +8   criadoUnixMs   i64          +17  quantidade         u8
//   +16  reservado      12           +18  score * 10000      u16
//   +28  crc32(0..27)   u32          +20  caixa L,T,R,B      4 x u16
//                                    +28  reservado          u32
//                                    +32  rotulo UTF-8       28 (NUL a direita)
//                                    +60  crc32(0..59)       u32
//
// Registro de tamanho fixo, e nao JSON por linha, por tres razoes, em ordem:
//
//   1. Queda de energia no meio de um append deixa um rabo truncado. Com passo
//      fixo mais CRC por registro, o leitor descarta exatamente o que ficou
//      pela metade e aproveita todo o resto — a mesma disciplina do `.vms.idx`.
//   2. Anexar e uma escrita, sem reler nem reescrever o arquivo do dia.
//   3. Um dia cheio de eventos sao alguns milhares de registros, umas centenas
//      de KB. Ler o dia inteiro e filtrar em memoria e mais barato do que
//      qualquer indice que se pudesse construir por cima.
//
// O rotulo cabe em 28 bytes porque e nome de classe de modelo de deteccao
// ('person', 'motorcycle', 'traffic light'): o mais longo do COCO tem 13
// caracteres. Nome maior que isso e truncado na escrita, e nao ha caso real em
// que isso aconteca.
//
// O dia e o LOCAL, igual ao das miniaturas, para quem abrir a pasta entender o
// que esta vendo. Um evento que atravessa a meia-noite e gravado no arquivo do
// dia em que COMECOU; a consulta cobre isso lendo tambem o dia anterior ao
// inicio da janela.

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  VMS.Domain.Logging,
  VMS.Rec.Crc32,
  VMS.Rec.Paths,
  Vms.Analytics.Types,
  Vms.Analytics.Intf;

const
  VEV_MAGIC = 'VEV1';
  VEV_VERSION = 1;
  VEV_HEADER_SIZE = 32;
  VEV_RECORD_SIZE = 64;
  VEV_NAME_OFFSET = 32;
  VEV_NAME_SIZE = 28;
  EVENTS_DIR = 'events';
  // Teto de registros devolvidos numa consulta. Uma janela de um dia inteiro
  // numa camera movimentada pode ter dezenas de milhares; mandar tudo para o
  // celular so faria a tela demorar para abrir.
  QUERY_DEFAULT_LIMIT = 4000;

type
  TEventFileStore = class(TInterfacedObject, IEventStore, IEventSource)
  strict private
    FStorageDir: string;
    FLogger: ILogger;
    // Serializa o append. A escrita e de um worker por camera, mas a leitura
    // vem de qualquer conexao HTTP: sem isto, uma consulta poderia pegar meio
    // registro recem-escrito. O CRC pegaria o erro, mas o evento sumiria da
    // resposta sem motivo nenhum.
    FLock: TCriticalSection;
    function DayFile(const Camera: string; Ms: Int64): string;
    function EventsDir(const Camera: string): string;
    function ReadDayFile(const Path: string): TVmsEventArray;
  public
    constructor Create(const AStorageDir: string; const ALogger: ILogger);
    destructor Destroy; override;
    { IEventStore }
    procedure Append(const Camera: string; const Ev: TVmsEvent);
    { IEventSource }
    function Query(const Camera: string; FromMs, ToMs: Int64;
                   const NameFilter: string; KindFilter: Integer;
                   MinScore: Single; Limit: Integer): TVmsEventArray;
    function Available: Boolean;
    // Ate onde a analise ja chegou nesta camera. 0 = nunca rodou.
    function ReadProgress(const Camera: string): Int64;
    procedure WriteProgress(const Camera: string; Ms: Int64);
    // Apaga arquivos de dia anteriores a KeepFromMs. Chamada pela retencao:
    // evento de gravacao que ja foi embora e lixo que ninguem mais remove.
    function PruneOlderThan(const Camera: string; KeepFromMs: Int64): Integer;
  end;

// Expostos para o selftest e para quem precisar montar/ler o formato sem o
// store inteiro (a ferramenta de diagnostico, por exemplo).
function BuildEventHeader(CreatedUnixMs: Int64): TBytes;
function BuildEventRecord(const Ev: TVmsEvent): TBytes;
function ParseEventRecord(const Data: TBytes; Offset: Integer;
                          out Ev: TVmsEvent): Boolean;

implementation

// ------------------------------------------------------------------ montagem

procedure PutU16(var B: TBytes; Offset: Integer; Value: Word);
begin
  B[Offset] := Byte(Value and $FF);
  B[Offset + 1] := Byte(Value shr 8);
end;

procedure PutU32(var B: TBytes; Offset: Integer; Value: Cardinal);
begin
  B[Offset] := Byte(Value and $FF);
  B[Offset + 1] := Byte((Value shr 8) and $FF);
  B[Offset + 2] := Byte((Value shr 16) and $FF);
  B[Offset + 3] := Byte((Value shr 24) and $FF);
end;

procedure PutI64(var B: TBytes; Offset: Integer; Value: Int64);
var
  I: Integer;
begin
  for I := 0 to 7 do
    B[Offset + I] := Byte((UInt64(Value) shr (I * 8)) and $FF);
end;

function GetU16(const B: TBytes; Offset: Integer): Word;
begin
  Result := B[Offset] or (Word(B[Offset + 1]) shl 8);
end;

function GetU32(const B: TBytes; Offset: Integer): Cardinal;
begin
  Result := Cardinal(B[Offset]) or (Cardinal(B[Offset + 1]) shl 8) or
            (Cardinal(B[Offset + 2]) shl 16) or (Cardinal(B[Offset + 3]) shl 24);
end;

function GetI64(const B: TBytes; Offset: Integer): Int64;
var
  I: Integer;
  V: UInt64;
begin
  V := 0;
  for I := 0 to 7 do
    V := V or (UInt64(B[Offset + I]) shl (I * 8));
  Result := Int64(V);
end;

// A caixa normalizada cabe em 4 x u16 sem perda que alguem consiga ver: 1/65535
// de um quadro de 1080p e um centesimo de pixel.
function BoxToU16(V: Single): Word;
begin
  if V <= 0 then Exit(0);
  if V >= 1 then Exit($FFFF);
  Result := Word(Round(V * 65535));
end;

function U16ToBox(V: Word): Single;
begin
  Result := V / 65535;
end;

function BuildEventHeader(CreatedUnixMs: Int64): TBytes;
begin
  SetLength(Result, VEV_HEADER_SIZE);
  FillChar(Result[0], VEV_HEADER_SIZE, 0);
  Result[0] := Ord('V');
  Result[1] := Ord('E');
  Result[2] := Ord('V');
  Result[3] := Ord('1');
  PutU16(Result, 4, VEV_VERSION);
  PutU16(Result, 6, VEV_RECORD_SIZE);
  PutI64(Result, 8, CreatedUnixMs);
  PutU32(Result, 28, Crc32Update(0, Result, 0, 28));
end;

function BuildEventRecord(const Ev: TVmsEvent): TBytes;
var
  NameBytes: TBytes;
  N: Integer;
  Box: TEventBox;
  Score: Integer;
begin
  SetLength(Result, VEV_RECORD_SIZE);
  FillChar(Result[0], VEV_RECORD_SIZE, 0);
  PutI64(Result, 0, Ev.StartMs);
  PutI64(Result, 8, Ev.EndMs);
  Result[16] := Byte(Ord(Ev.Kind));
  if Ev.Count > 255 then Result[17] := 255 else
  if Ev.Count < 0 then Result[17] := 0 else Result[17] := Byte(Ev.Count);
  Score := Round(Ev.Score * 10000);
  if Score < 0 then Score := 0;
  if Score > 10000 then Score := 10000;
  PutU16(Result, 18, Word(Score));
  Box := Ev.Box.Clamped;
  PutU16(Result, 20, BoxToU16(Box.L));
  PutU16(Result, 22, BoxToU16(Box.T));
  PutU16(Result, 24, BoxToU16(Box.R));
  PutU16(Result, 26, BoxToU16(Box.B));

  NameBytes := TEncoding.UTF8.GetBytes(Ev.Name);
  N := Length(NameBytes);
  if N > VEV_NAME_SIZE then N := VEV_NAME_SIZE;
  if N > 0 then
    Move(NameBytes[0], Result[VEV_NAME_OFFSET], N);

  PutU32(Result, 60, Crc32Update(0, Result, 0, 60));
end;

function ParseEventRecord(const Data: TBytes; Offset: Integer;
  out Ev: TVmsEvent): Boolean;
var
  Reg: TBytes;
  N: Integer;
begin
  Result := False;
  Ev := Default(TVmsEvent);
  if Offset + VEV_RECORD_SIZE > Length(Data) then Exit;
  SetLength(Reg, VEV_RECORD_SIZE);
  Move(Data[Offset], Reg[0], VEV_RECORD_SIZE);
  if GetU32(Reg, 60) <> Crc32Update(0, Reg, 0, 60) then Exit;

  Ev.StartMs := GetI64(Reg, 0);
  Ev.EndMs := GetI64(Reg, 8);
  if Reg[16] = Byte(Ord(ekObject)) then Ev.Kind := ekObject else Ev.Kind := ekMotion;
  Ev.Count := Reg[17];
  Ev.Score := GetU16(Reg, 18) / 10000;
  Ev.Box := TEventBox.FromLTRB(U16ToBox(GetU16(Reg, 20)), U16ToBox(GetU16(Reg, 22)),
                               U16ToBox(GetU16(Reg, 24)), U16ToBox(GetU16(Reg, 26)));

  // O rotulo vai NUL-preenchido a direita; o comprimento e ate o primeiro zero.
  N := 0;
  while (N < VEV_NAME_SIZE) and (Reg[VEV_NAME_OFFSET + N] <> 0) do Inc(N);
  if N > 0 then
    Ev.Name := TEncoding.UTF8.GetString(Reg, VEV_NAME_OFFSET, N)
  else
    Ev.Name := '';
  Result := Ev.IsValid;
end;

// -------------------------------------------------------------------- store

constructor TEventFileStore.Create(const AStorageDir: string;
  const ALogger: ILogger);
begin
  inherited Create;
  FStorageDir := AStorageDir;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
end;

destructor TEventFileStore.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TEventFileStore.Available: Boolean;
begin
  Result := True;
end;

function TEventFileStore.EventsDir(const Camera: string): string;
begin
  Result := TPath.Combine(CameraDir(FStorageDir, Camera), EVENTS_DIR);
end;

function TEventFileStore.DayFile(const Camera: string; Ms: Int64): string;
var
  DT: TDateTime;
begin
  DT := TTimeZone.Local.ToLocalTime(UnixToDateTime(Ms div 1000, True));
  Result := TPath.Combine(EventsDir(Camera),
                          FormatDateTime('yyyy-mm-dd', DT) + '.vev');
end;

procedure TEventFileStore.Append(const Camera: string; const Ev: TVmsEvent);
var
  Path, Dir: string;
  Stream: TFileStream;
  Header, Reg: TBytes;
  Novo: Boolean;
begin
  if not Ev.IsValid then Exit;
  Path := DayFile(Camera, Ev.StartMs);
  Reg := BuildEventRecord(Ev);
  FLock.Enter;
  try
    try
      Dir := EventsDir(Camera);
      if not TDirectory.Exists(Dir) then
        TDirectory.CreateDirectory(Dir);
      Novo := not TFile.Exists(Path);
      if Novo then
        Stream := TFileStream.Create(Path, fmCreate or fmShareDenyNone)
      else
        Stream := TFileStream.Create(Path, fmOpenReadWrite or fmShareDenyNone);
      try
        if Novo then
        begin
          Header := BuildEventHeader(Ev.StartMs);
          Stream.WriteBuffer(Header[0], Length(Header));
        end
        else
          Stream.Seek(Int64(0), soEnd);
        Stream.WriteBuffer(Reg[0], Length(Reg));
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
        if FLogger <> nil then
          FLogger.Warn('events', Format('%s: nao deu para gravar o evento: %s',
            [Camera, E.Message]));
    end;
  finally
    FLock.Leave;
  end;
end;

// Le um arquivo de dia inteiro, descartando o que nao fecha. Rabo truncado
// (queda no meio de um append) e sobra de tamanho que nao e multiplo do
// registro simplesmente nao entram — o resto do dia continua valendo.
function TEventFileStore.ReadDayFile(const Path: string): TVmsEventArray;
var
  Data: TBytes;
  Total, Offset, Usados: Integer;
  Ev: TVmsEvent;
begin
  Result := nil;
  if not TFile.Exists(Path) then Exit;
  FLock.Enter;
  try
    try
      Data := TFile.ReadAllBytes(Path);
    except
      Exit;
    end;
  finally
    FLock.Leave;
  end;
  if Length(Data) < VEV_HEADER_SIZE then Exit;
  if (Data[0] <> Ord('V')) or (Data[1] <> Ord('E')) or
     (Data[2] <> Ord('V')) or (Data[3] <> Ord('1')) then Exit;
  if GetU32(Data, 28) <> Crc32Update(0, Data, 0, 28) then Exit;
  if GetU16(Data, 6) <> VEV_RECORD_SIZE then Exit;

  Total := (Length(Data) - VEV_HEADER_SIZE) div VEV_RECORD_SIZE;
  if Total <= 0 then Exit;
  SetLength(Result, Total);
  Usados := 0;
  Offset := VEV_HEADER_SIZE;
  while Offset + VEV_RECORD_SIZE <= Length(Data) do
  begin
    if ParseEventRecord(Data, Offset, Ev) then
    begin
      Result[Usados] := Ev;
      Inc(Usados);
    end;
    Inc(Offset, VEV_RECORD_SIZE);
  end;
  SetLength(Result, Usados);
end;

function TEventFileStore.Query(const Camera: string; FromMs, ToMs: Int64;
  const NameFilter: string; KindFilter: Integer; MinScore: Single;
  Limit: Integer): TVmsEventArray;
var
  Dia, Fim: TDateTime;
  Path, Filtro: string;
  DoDia: TVmsEventArray;
  Lista: TList<TVmsEvent>;
  I: Integer;
  Ev: TVmsEvent;
begin
  Result := nil;
  if (Camera = '') or (ToMs <= FromMs) then Exit;
  if Limit <= 0 then Limit := QUERY_DEFAULT_LIMIT;
  Filtro := LowerCase(Trim(NameFilter));

  Lista := TList<TVmsEvent>.Create;
  try
    // Um dia para tras do inicio da janela: evento que comecou 23h58 e terminou
    // 00h03 esta no arquivo de ONTEM, e quem pediu a janela da meia-noite
    // precisa ve-lo.
    Dia := DateOf(TTimeZone.Local.ToLocalTime(UnixToDateTime(FromMs div 1000, True))) - 1;
    Fim := DateOf(TTimeZone.Local.ToLocalTime(UnixToDateTime(ToMs div 1000, True)));
    while Dia <= Fim do
    begin
      Path := TPath.Combine(EventsDir(Camera),
                            FormatDateTime('yyyy-mm-dd', Dia) + '.vev');
      DoDia := ReadDayFile(Path);
      for I := 0 to High(DoDia) do
      begin
        Ev := DoDia[I];
        // Sobreposicao, nao continencia: o que interessa e o que estava
        // acontecendo na janela (ver IEventSource.Query).
        if Ev.EndMs < FromMs then Continue;
        if Ev.StartMs > ToMs then Continue;
        if (KindFilter >= 0) and (Ord(Ev.Kind) <> KindFilter) then Continue;
        if (Filtro <> '') and (LowerCase(Ev.Name) <> Filtro) then Continue;
        if Ev.Score < MinScore then Continue;
        Lista.Add(Ev);
        if Lista.Count >= Limit then Break;
      end;
      if Lista.Count >= Limit then Break;
      Dia := Dia + 1;
    end;

    Result := Lista.ToArray;
  finally
    Lista.Free;
  end;

  // Os arquivos ja saem em ordem de escrita, que e crescente, mas dois tipos de
  // evento fechados em ordens diferentes podem se cruzar. Ordenar aqui e o que
  // permite o app so desenhar.
  TArray.Sort<TVmsEvent>(Result, TComparer<TVmsEvent>.Construct(
    function(const A, B: TVmsEvent): Integer
    begin
      if A.StartMs < B.StartMs then Result := -1
      else if A.StartMs > B.StartMs then Result := 1
      else Result := 0;
    end));
end;

// ---------------------------------------------------------------- progresso

// Texto puro, um numero. Apagar o arquivo e a forma de mandar reanalisar tudo,
// e isso e deliberado: e a operacao que alguem vai querer fazer no dia em que
// trocar o modelo ou baixar o limiar.
procedure TEventFileStore.WriteProgress(const Camera: string; Ms: Int64);
var
  Dir, Path: string;
begin
  try
    Dir := EventsDir(Camera);
    if not TDirectory.Exists(Dir) then
      TDirectory.CreateDirectory(Dir);
    Path := TPath.Combine(Dir, 'progress.txt');
    TFile.WriteAllText(Path, IntToStr(Ms), TEncoding.ASCII);
  except
    // Progresso e otimizacao: perde-lo custa reanalisar, nao perder evento.
  end;
end;

function TEventFileStore.ReadProgress(const Camera: string): Int64;
var
  Path: string;
begin
  Result := 0;
  Path := TPath.Combine(EventsDir(Camera), 'progress.txt');
  try
    if TFile.Exists(Path) then
      Result := StrToInt64Def(Trim(TFile.ReadAllText(Path, TEncoding.ASCII)), 0);
  except
    Result := 0;
  end;
end;

function TEventFileStore.PruneOlderThan(const Camera: string;
  KeepFromMs: Int64): Integer;
var
  Root, Name: string;
  Arquivos: TArray<string>;
  I: Integer;
  Limite, Dia: TDateTime;
begin
  Result := 0;
  Root := EventsDir(Camera);
  if not TDirectory.Exists(Root) then Exit;
  Limite := DateOf(TTimeZone.Local.ToLocalTime(
              UnixToDateTime(KeepFromMs div 1000, True)));
  try
    Arquivos := TDirectory.GetFiles(Root, '*.vev');
  except
    Exit;
  end;
  for I := 0 to High(Arquivos) do
  begin
    Name := ChangeFileExt(ExtractFileName(Arquivos[I]), '');
    // So apaga o que o proprio store criou e cujo nome ele entende.
    if Length(Name) <> 10 then Continue;
    if not TryEncodeDate(StrToIntDef(Copy(Name, 1, 4), 0),
                         StrToIntDef(Copy(Name, 6, 2), 0),
                         StrToIntDef(Copy(Name, 9, 2), 0), Dia) then Continue;
    if Dia >= Limite then Continue;
    try
      TFile.Delete(Arquivos[I]);
      Inc(Result);
    except
      // em uso, ou sem permissao: fica para a proxima varredura
    end;
  end;
end;

end.
