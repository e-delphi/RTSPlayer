unit Vms.Server.IndexCache;

// O que o servidor sabe sobre as gravações em disco, sem reabrir tudo a cada
// pergunta.
//
// Uma consulta de timeline ("que dias têm gravação da isis?") toca dezenas de
// arquivos. Abrir e reler cada um a cada requisição é o que tornaria a barra do
// app inutilizável — daí este cache, com duas velocidades:
//
//   arquivo fechado  -> resumo e índice saem do rodapé (VIDX), leitura O(1).
//                       O resumo fica em cache; o índice é relido quando pedido,
//                       porque reler o rodapé é barato e guardar 730 KB por
//                       arquivo não é.
//   arquivo em gravação -> não tem rodapé: o índice é varrido UMA vez, fica em
//                       cache, e nas consultas seguintes só os blocos novos são
//                       varridos (SeedIndex + ExtendIndex no leitor).
//
// Nada de handle aberto entre consultas: no Windows um arquivo com handle vivo
// não pode ser apagado, e a varredura de retenção precisa poder apagar.
//
// Threading: um servidor RTSP tem uma thread por conexão. O dicionário é
// protegido por seção crítica, mas a leitura de disco acontece FORA dela — duas
// threads podem ler o mesmo arquivo ao mesmo tempo (desperdício raro), e nenhuma
// segura as outras durante um I/O lento.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Paths,
  VMS.Rec.Reader;

type
  TVmsFileInfo = record
    Path: string;
    Name: string;          // nome base, com extensão
    Camera: string;
    StartMs: Int64;        // primeiro bloco
    EndMs: Int64;          // fim estimado do último bloco
    DurationMs: Int64;
    Bytes: Int64;
    Blocks: Integer;
    Closed: Boolean;       // tem rodapé: a gravação foi encerrada direito
    Indexed: Boolean;      // o índice veio do rodapé, não de varredura
    HasVideo: Boolean;
    VideoCodec: TVideoCodec;
    Width: Word;
    Height: Word;
    HasAudio: Boolean;
    AudioCodec: TAudioCodec;
    SampleRate: Cardinal;
    Channels: Byte;
  end;
  TVmsFileInfoArray = TArray<TVmsFileInfo>;

  TTimeRange = record
    StartMs: Int64;
    EndMs: Int64;
  end;
  TTimeRangeArray = TArray<TTimeRange>;

  TVmsIndexCache = class
  strict private
  type
    TCachedFile = class
      Info: TVmsFileInfo;
      StampSize: Int64;
      StampWrite: TDateTime;
      // só para arquivo em gravação, onde varrer de novo custa caro
      ScannedIndex: TVmsIndex;
      ScannedUpTo: Int64;
    end;
  strict private
    FStorageDir: string;
    FLogger: ILogger;
    FLock: TCriticalSection;
    FFiles: TObjectDictionary<string, TCachedFile>;
    function KeyOf(const Path: string): string;
    function ReadInfo(const Path: string; const PrevIndex: TVmsIndex; PrevUpTo: Int64;
                      out Info: TVmsFileInfo; out NewIndex: TVmsIndex;
                      out NewUpTo: Int64): Boolean;
    procedure Log(Level: TLogLevel; const Msg: string);
  public
    constructor Create(const AStorageDir: string; const ALogger: ILogger);
    destructor Destroy; override;
    // Resumo de um arquivo, do cache ou do disco. False = não é um .vms legível.
    function GetInfo(const Path: string; out Info: TVmsFileInfo): Boolean;
    // Todos os .vms de uma câmera, em ordem de tempo.
    function ListFiles(const Camera: string): TVmsFileInfoArray;
    // Caminho de um arquivo pelo nome. Cada câmera tem sua pasta, então o nome
    // sozinho não basta: sem a câmera, ela é deduzida do prefixo do nome (é o
    // que salva a rota de diagnóstico, que recebe só o arquivo).
    function PathOf(const Camera, Name: string): string;
    // Índice de blocos de um arquivo (para a rota de mídia).
    function GetIndex(const Path: string; out Index: TVmsIndex): Boolean;
    // Some com a entrada (arquivo apagado pela retenção, por exemplo).
    procedure Forget(const Path: string);
    property StorageDir: string read FStorageDir;
  end;

// Nome de arquivo que pode virar caminho dentro de storageDir. Recusa separador,
// '..' e qualquer coisa fora de [A-Za-z0-9._-]. Vale para o que vem na query E
// para o que vem dentro do cursor — os dois são texto do cliente.
function IsSafeVmsName(const Name: string): Boolean;
// Junta o que se encosta: arquivos separados por menos de GapMs viram uma faixa
// contínua. É o que transforma "37 arquivos porque a câmera reconectou" em "o dia
// inteiro gravado", que é o que a timeline mostra.
function MergeRanges(const Files: TVmsFileInfoArray; GapMs: Int64): TTimeRangeArray;
// Recorta faixas para dentro de [FromMs, ToMs), descartando o que ficar vazio.
function ClipRanges(const Ranges: TTimeRangeArray; FromMs, ToMs: Int64): TTimeRangeArray;

implementation

const
  // Sem rodapé não há duração do último bloco; estes 2 s são o mesmo valor
  // padrão de block.maxDurationMs, e servem só para o fim da faixa não cair
  // exatamente no início do último bloco.
  ASSUMED_LAST_BLOCK_MS = 2000;

{ TVmsIndexCache }

constructor TVmsIndexCache.Create(const AStorageDir: string; const ALogger: ILogger);
begin
  inherited Create;
  FStorageDir := ExcludeTrailingPathDelimiter(ExpandFileName(AStorageDir));
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FFiles := TObjectDictionary<string, TCachedFile>.Create([doOwnsValues]);
end;

destructor TVmsIndexCache.Destroy;
begin
  FFiles.Free;
  FLock.Free;
  inherited;
end;

procedure TVmsIndexCache.Log(Level: TLogLevel; const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Log(Level, 'api.cache', Msg);
end;

function TVmsIndexCache.KeyOf(const Path: string): string;
begin
  Result := LowerCase(Path);
end;

// Lê o que interessa de um arquivo. PrevIndex/PrevUpTo, quando vêm preenchidos,
// evitam revarrer o que já se sabe de um arquivo que ainda cresce.
function TVmsIndexCache.ReadInfo(const Path: string; const PrevIndex: TVmsIndex;
  PrevUpTo: Int64; out Info: TVmsFileInfo; out NewIndex: TVmsIndex;
  out NewUpTo: Int64): Boolean;
var
  Reader: TVmsReader;
  Footer: TVmsFooter;
  Count: Integer;
  Base: string;
  P: Integer;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Path := '';
  Info.Name := '';
  Info.Camera := '';
  NewIndex := nil;
  NewUpTo := 0;

  try
    Reader := TVmsReader.Create(Path);
  except
    on E: Exception do
    begin
      // sendo criado agora, ou sumiu entre o listar e o abrir
      Log(llDebug, Format('nao abriu %s: %s', [ExtractFileName(Path), E.Message]));
      Exit;
    end;
  end;
  try
    Reader.Logger := FLogger;
    if not Reader.ReadHeader then Exit;

    // Com o índice da consulta anterior na mão, só os blocos novos são varridos.
    if (Length(PrevIndex) > 0) and (PrevUpTo > 0) then
      Reader.SeedIndex(PrevIndex, PrevUpTo);
    Reader.EnsureIndex;
    Reader.ExtendIndex;
    Count := Reader.IndexCount;
    if Count = 0 then Exit; // arquivo sem bloco algum: não serve para tocar

    Info.Path := Path;
    Base := ExtractFileName(Path);
    Info.Name := Base;
    // A câmera é a PASTA em que o arquivo está; o prefixo do nome só entra para
    // arquivo solto na raiz (nome de câmera com '_' quebra a leitura por
    // prefixo, a pasta não).
    Info.Camera := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(Path)));
    if SameText(IncludeTrailingPathDelimiter(ExtractFilePath(Path)),
                IncludeTrailingPathDelimiter(FStorageDir)) then
    begin
      Info.Camera := '';
      P := Pos('_', Base);
      if P > 1 then
        Info.Camera := Copy(Base, 1, P - 1);
    end;

    Info.Blocks := Count;
    Info.StartMs := Reader.Index[0].StartUnixMs;
    Info.EndMs := Reader.Index[Count - 1].StartUnixMs + ASSUMED_LAST_BLOCK_MS;
    Info.Indexed := Reader.IndexFromFooter;
    Info.Closed := Reader.ReadFooter(Footer);
    if Info.Closed and (Footer.TotalDurationMs > 0) then
    begin
      // O rodapé mede do header ao último bloco; o fim da faixa é isso mais a
      // duração do último bloco, que ninguém guarda — daí a estimativa.
      Info.EndMs := Reader.Header.CreationUnixMs + Footer.TotalDurationMs + ASSUMED_LAST_BLOCK_MS;
      if Info.EndMs < Info.StartMs then
        Info.EndMs := Info.StartMs;
    end;
    Info.DurationMs := Info.EndMs - Info.StartMs;

    Info.HasVideo := Reader.Header.VideoPresent;
    Info.VideoCodec := Reader.Header.Video.Codec;
    Info.Width := Reader.Header.Video.Width;
    Info.Height := Reader.Header.Video.Height;
    Info.HasAudio := Reader.Header.AudioPresent;
    Info.AudioCodec := Reader.Header.Audio.Codec;
    Info.SampleRate := Reader.Header.Audio.SampleRate;
    Info.Channels := Reader.Header.Audio.Channels;

    try
      Info.Bytes := TFile.GetSize(Path);
    except
      Info.Bytes := 0;
    end;

    // Só vale a pena guardar o índice varrido: o do rodapé se relê num piscar.
    if not Reader.IndexFromFooter then
    begin
      NewIndex := Copy(Reader.Index);
      NewUpTo := Reader.ScannedUpTo;
    end;
    Result := True;
  finally
    Reader.Free;
  end;
end;

function TVmsIndexCache.GetInfo(const Path: string; out Info: TVmsFileInfo): Boolean;
var
  Key: string;
  Entry: TCachedFile;
  Size: Int64;
  Written: TDateTime;
  PrevIndex: TVmsIndex;
  PrevUpTo: Int64;
  NewIndex: TVmsIndex;
  NewUpTo: Int64;
  Fresh: TVmsFileInfo;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Path := '';
  Info.Name := '';
  Info.Camera := '';
  if not FileExists(Path) then
  begin
    Forget(Path);
    Exit;
  end;

  try
    Size := TFile.GetSize(Path);
    Written := TFile.GetLastWriteTime(Path);
  except
    Exit;
  end;

  Key := KeyOf(Path);
  PrevIndex := nil;
  PrevUpTo := 0;
  FLock.Enter;
  try
    if FFiles.TryGetValue(Key, Entry) then
    begin
      // Nada mudou desde a última vez: o resumo em cache vale.
      if (Entry.StampSize = Size) and (Entry.StampWrite = Written) then
      begin
        Info := Entry.Info;
        Exit(True);
      end;
      // Cresceu: aproveita o índice já varrido e continua dali.
      if Size > Entry.StampSize then
      begin
        PrevIndex := Entry.ScannedIndex;
        PrevUpTo := Entry.ScannedUpTo;
      end;
    end;
  finally
    FLock.Leave;
  end;

  // Fora do lock: I/O não pode segurar as outras conexões.
  if not ReadInfo(Path, PrevIndex, PrevUpTo, Fresh, NewIndex, NewUpTo) then Exit;

  FLock.Enter;
  try
    if not FFiles.TryGetValue(Key, Entry) then
    begin
      Entry := TCachedFile.Create;
      FFiles.Add(Key, Entry);
    end;
    Entry.Info := Fresh;
    Entry.StampSize := Size;
    Entry.StampWrite := Written;
    Entry.ScannedIndex := NewIndex;
    Entry.ScannedUpTo := NewUpTo;
  finally
    FLock.Leave;
  end;

  Info := Fresh;
  Result := True;
end;

function TVmsIndexCache.GetIndex(const Path: string; out Index: TVmsIndex): Boolean;
var
  Info: TVmsFileInfo;
  Key: string;
  Entry: TCachedFile;
  Reader: TVmsReader;
begin
  Index := nil;
  // Passa pelo GetInfo primeiro: é ele que revalida o cache e estende o índice
  // do arquivo que ainda cresce.
  if not GetInfo(Path, Info) then Exit(False);

  Key := KeyOf(Path);
  FLock.Enter;
  try
    if FFiles.TryGetValue(Key, Entry) and (Length(Entry.ScannedIndex) > 0) then
    begin
      Index := Entry.ScannedIndex;
      Exit(True);
    end;
  finally
    FLock.Leave;
  end;

  // Arquivo fechado: o índice está no rodapé, e reler custa uma leitura.
  try
    Reader := TVmsReader.Create(Path);
  except
    Exit(False);
  end;
  try
    if not Reader.ReadHeader then Exit(False);
    if Reader.EnsureIndex = 0 then Exit(False);
    Index := Copy(Reader.Index);
    Result := True;
  finally
    Reader.Free;
  end;
end;

procedure TVmsIndexCache.Forget(const Path: string);
begin
  FLock.Enter;
  try
    FFiles.Remove(KeyOf(Path));
  finally
    FLock.Leave;
  end;
end;

function TVmsIndexCache.PathOf(const Camera, Name: string): string;
var
  Cam: string;
  P: Integer;
begin
  Cam := Camera;
  if Cam = '' then
  begin
    P := Pos('_', Name);
    if P > 1 then Cam := Copy(Name, 1, P - 1);
  end;
  if Cam = '' then
    Exit(TPath.Combine(FStorageDir, Name));
  Result := TPath.Combine(CameraDir(FStorageDir, Cam), Name);
  // Arquivo antigo, de quando tudo morava na raiz: continua achável.
  if (not FileExists(Result)) and FileExists(TPath.Combine(FStorageDir, Name)) then
    Result := TPath.Combine(FStorageDir, Name);
end;

function TVmsIndexCache.ListFiles(const Camera: string): TVmsFileInfoArray;
var
  Paths: TArray<string>;
  I, Count: Integer;
  Info: TVmsFileInfo;
  Tmp: TVmsFileInfoArray;
  Dir: string;
begin
  Result := nil;
  if Camera = '' then Exit;
  // Tudo que está na pasta da câmera é dela — não há mais o que filtrar.
  Dir := CameraDir(FStorageDir, Camera);
  if not DirectoryExists(Dir) then Exit;
  try
    Paths := TDirectory.GetFiles(Dir, '*.vms');
  except
    Exit;
  end;

  SetLength(Tmp, Length(Paths));
  Count := 0;
  for I := 0 to High(Paths) do
    if GetInfo(Paths[I], Info) then
    begin
      Tmp[Count] := Info;
      Inc(Count);
    end;
  SetLength(Tmp, Count);

  TArray.Sort<TVmsFileInfo>(Tmp, TComparer<TVmsFileInfo>.Construct(
    function(const A, B: TVmsFileInfo): Integer
    begin
      if A.StartMs < B.StartMs then Result := -1
      else if A.StartMs > B.StartMs then Result := 1
      else Result := 0;
    end));
  Result := Tmp;
end;

function IsSafeVmsName(const Name: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := False;
  if (Length(Name) < 5) or (Length(Name) > 255) then Exit;
  if not SameText(ExtractFileExt(Name), '.vms') then Exit;
  if Pos('..', Name) > 0 then Exit;
  for I := 1 to Length(Name) do
  begin
    C := Name[I];
    if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-']) then Continue;
    Exit;
  end;
  Result := True;
end;

function MergeRanges(const Files: TVmsFileInfoArray; GapMs: Int64): TTimeRangeArray;
var
  I, Count: Integer;
  Tmp: TTimeRangeArray;
begin
  Result := nil;
  if Length(Files) = 0 then Exit;
  SetLength(Tmp, Length(Files));
  Count := 0;
  for I := 0 to High(Files) do
  begin
    if Files[I].EndMs <= Files[I].StartMs then Continue;
    // Chega colado (ou sobreposto) no anterior: estica em vez de abrir faixa.
    if (Count > 0) and (Files[I].StartMs - Tmp[Count - 1].EndMs <= GapMs) then
    begin
      if Files[I].EndMs > Tmp[Count - 1].EndMs then
        Tmp[Count - 1].EndMs := Files[I].EndMs;
      Continue;
    end;
    Tmp[Count].StartMs := Files[I].StartMs;
    Tmp[Count].EndMs := Files[I].EndMs;
    Inc(Count);
  end;
  Result := Copy(Tmp, 0, Count);
end;

function ClipRanges(const Ranges: TTimeRangeArray; FromMs, ToMs: Int64): TTimeRangeArray;
var
  I, Count: Integer;
  Tmp: TTimeRangeArray;
  S, E: Int64;
begin
  Result := nil;
  SetLength(Tmp, Length(Ranges));
  Count := 0;
  for I := 0 to High(Ranges) do
  begin
    S := Ranges[I].StartMs;
    E := Ranges[I].EndMs;
    if S < FromMs then S := FromMs;
    if E > ToMs then E := ToMs;
    if E <= S then Continue;
    Tmp[Count].StartMs := S;
    Tmp[Count].EndMs := E;
    Inc(Count);
  end;
  Result := Copy(Tmp, 0, Count);
end;

end.
