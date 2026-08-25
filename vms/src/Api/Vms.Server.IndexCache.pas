unit Vms.Server.IndexCache;

// O que o servidor sabe sobre as gravações em disco, sem reabrir tudo a cada
// pergunta.
//
// Uma consulta de timeline ("que dias têm gravação da isis?") toca dezenas de
// arquivos. Abrir e reler cada um a cada requisição é o que tornaria a barra do
// app inutilizável — daí este cache.
//
// A regra que manda aqui: **descrever um arquivo não monta índice**. Para a
// timeline só interessam começo, fim e tamanho, e isso sai de duas leituras
// curtas (GetInfo). Índice é outra pergunta, feita por outro caminho (GetIndex),
// e só quem vai TOCAR aquele arquivo a faz. Montar índice em todo arquivo só
// para saber onde ele começa era o que fazia a primeira consulta depois de subir
// o servidor demorar — com um arquivo por câmera por hora, são dezenas de
// índices lidos por consulta, cada um proporcional às horas gravadas.
//
//   arquivo fechado     -> rodapé (blocos + duração) e o primeiro bloco.
//   arquivo em gravação -> as pontas do `.vms.idx` ao lado, que fica no máximo
//                          um lote atrás (~30 s). Sem sidecar (ou antes do
//                          primeiro lote), varre — mas aí é um arquivo
//                          recém-aberto, de poucos blocos.
//
// Nada de handle aberto entre consultas: no Windows um arquivo com handle vivo
// não pode ser apagado, e a varredura de retenção precisa poder apagar.
//
// E o cache de memória some quando o servidor reinicia — o que fazia a PRIMEIRA
// consulta de timeline depois de subir abrir centenas de arquivos, um por um.
// Por isso o resumo de cada gravação FECHADA também vai para um `_index.json` na
// pasta da câmera: gravação terminada é imutável, então o resumo dela vale para
// sempre. A conferência é por tamanho + data de escrita, os mesmos carimbos do
// cache de memória; arquivo que não bate é relido, e o em gravação nunca entra
// no json (o resumo dele muda a cada minuto).
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
  System.JSON,
  System.DateUtils,
  System.StrUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Paths,
  VMS.Rec.Reader,
  Vms.Db.Intf;

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
    // Tem índice pronto — no rodapé, se fechado, ou no `.vms.idx` ao lado, se
    // ainda grava. False = descrever este arquivo custou uma varredura, e
    // tocá-lo vai custar outra.
    Indexed: Boolean;
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
      StampWriteMs: Int64;   // unix ms: é o que o json guarda sem perder bit
      // Índice, quando alguém já pediu o deste arquivo. Guardado só para os
      // MAX_CACHED_INDEXES arquivos usados mais recentemente: é ~90 KB por
      // arquivo, e quem toca uma gravação fica no mesmo arquivo por horas.
      Index: TVmsIndex;
      IndexUpTo: Int64;     // primeiro offset ainda não varrido
      IndexStampSize: Int64; // tamanho do arquivo quando o índice foi montado
      LastUsed: Int64;
    end;
  strict private
    FStorageDir: string;
    FLogger: ILogger;
    FLock: TCriticalSection;
    FFiles: TObjectDictionary<string, TCachedFile>;
    FUseTick: Int64;          // relógio de uso, para saber qual índice soltar
    // Câmeras cujo `_index.json` já foi lido nesta execução.
    FDiskLoaded: TDictionary<string, Boolean>;
    // Alguma gravação fechada foi (re)lida do disco desde a última gravação do
    // json? É isso, e não a contagem de arquivos, que diz se vale regravá-lo.
    FDiskDirty: Boolean;
    FDb: IDbQueue;
    function KeyOf(const Path: string): string;
    function ReadInfo(const Path: string; out Info: TVmsFileInfo): Boolean;
    // Como o GetInfo, mas com os carimbos já em mãos. A listagem os obtém de uma
    // varredura só do diretório, em vez de dois stats por arquivo.
    function GetInfoStamped(const Path: string; Size, WrittenMs: Int64;
                            out Info: TVmsFileInfo): Boolean;
    // ---- resumo em disco, por câmera -------------------------------------
    // Carrega o `_index.json` da câmera para o cache de memória, uma vez por
    // execução. Arquivo ausente, ilegível ou de outro formato: começa do zero.
    procedure LoadDiskCache(const Camera: string);
    // Regrava o `_index.json` com o que se sabe das gravações FECHADAS.
    procedure SaveDiskCache(const Camera: string);
  public
    // Tira do inventario as gravacoes cujo arquivo ja nao existe.
    function ForgetMissing(const Camera: string): Integer;
  strict private
    // Solta o índice dos arquivos que não são os MAX_CACHED_INDEXES mais
    // recentes. Chamada sob FLock.
    procedure TrimIndexes;
    procedure Log(Level: TLogLevel; const Msg: string);
  public
    // O banco entra pela interface: este cache nao sabe que existe FireDAC,
    // e continua funcionando com Db nil (so perde a persistencia do resumo).
    constructor Create(const AStorageDir: string; const ADb: IDbQueue;
                       const ALogger: ILogger);
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

  // (O resumo em disco era o `_index.json`; agora é a tabela `recording`.
  //  Ver LoadDiskCache/SaveDiskCache — os nomes ficaram, a persistência mudou.)

  // Quantos índices ficam em memória ao mesmo tempo. Um índice de arquivo de 2 h
  // são ~90 KB; guardar o de todos os arquivos da retenção seriam dezenas de MB
  // para nada, porque quem está tocando uma gravação fica no mesmo arquivo (e no
  // seguinte) por horas.
  MAX_CACHED_INDEXES = 8;

{ TVmsIndexCache }

constructor TVmsIndexCache.Create(const AStorageDir: string;
  const ADb: IDbQueue; const ALogger: ILogger);
begin
  inherited Create;
  FStorageDir := ExcludeTrailingPathDelimiter(ExpandFileName(AStorageDir));
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FFiles := TObjectDictionary<string, TCachedFile>.Create([doOwnsValues]);
  FDiskLoaded := TDictionary<string, Boolean>.Create;
  FDiskDirty := False;
  FUseTick := 0;
  FDb := ADb;
end;

destructor TVmsIndexCache.Destroy;
begin
  FDiskLoaded.Free;
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

// O resumo de um arquivo, sem montar índice. Duas leituras curtas no caso
// normal; a varredura só sobra para arquivo aberto agora, antes de o primeiro
// lote do sidecar sair — e aí são poucos blocos.
function TVmsIndexCache.ReadInfo(const Path: string; out Info: TVmsFileInfo): Boolean;
var
  Reader: TVmsReader;
  Footer: TVmsFooter;
  Count: Integer;
  Base: string;
  P: Integer;
  FirstMs, LastMs: Int64;
  HaveRange: Boolean;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Path := '';
  Info.Name := '';
  Info.Camera := '';

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

    Count := 0;
    FirstMs := 0;
    LastMs := 0;
    HaveRange := False;
    Info.Closed := Reader.ReadFooter(Footer);
    // O começo da faixa é o primeiro BLOCO, não o instante de criação do header:
    // entre abrir o arquivo e o primeiro sample passa a janela de espera do
    // áudio, e a timeline mostraria gravação onde não há.
    if Reader.FirstBlockStartMs(FirstMs) then
    begin
      HaveRange := True;
      LastMs := FirstMs;
    end;

    if Info.Closed and HaveRange then
    begin
      // Arquivo fechado: o rodapé já responde tudo. A duração é medida a partir
      // do header, então o fim sai dali — e não do primeiro bloco.
      Count := Integer(Footer.TotalBlocks);
      LastMs := Reader.Header.CreationUnixMs + Footer.TotalDurationMs;
      if LastMs < FirstMs then LastMs := FirstMs;
      Info.Indexed := True;
    end
    else if HaveRange and Reader.SidecarSummary(Count, FirstMs, LastMs) then
      // Arquivo em gravação: as pontas do que o `.vms.idx` já registrou.
      Info.Indexed := True
    else
    begin
      // Sem rodapé e sem sidecar legível: não há como saber onde termina sem
      // olhar bloco a bloco. É o arquivo aberto há menos de um lote — curto, por
      // definição.
      Count := Reader.EnsureIndex;
      Info.Indexed := False;
      if Count > 0 then
      begin
        HaveRange := True;
        FirstMs := Reader.Index[0].StartUnixMs;
        LastMs := Reader.Index[Count - 1].StartUnixMs;
      end;
    end;

    if (not HaveRange) or (Count = 0) then
    begin
      // Some da listagem sem dizer nada era o pior jeito de errar: "minha
      // gravação não aparece no histórico" não tinha por onde ser investigado.
      Log(llDebug, Format('%s fora da lista: %s', [ExtractFileName(Path),
        IfThen(not HaveRange, 'nenhum bloco legivel',
               'contagem de blocos zero')]));
      Exit;
    end;

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
    Info.StartMs := FirstMs;
    // A duração do último bloco ninguém guarda; daí a estimativa no fim.
    Info.EndMs := LastMs + ASSUMED_LAST_BLOCK_MS;
    if Info.EndMs < Info.StartMs then
      Info.EndMs := Info.StartMs;
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
    Result := True;
  finally
    Reader.Free;
  end;
end;

// A data de escrita vai como unix ms para o json não depender do formato de
// data local — o mesmo arquivo tem de valer numa máquina configurada em pt-BR e
// noutra em en-US.
function WriteStampMs(const DT: TDateTime): Int64;
begin
  Result := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(DT), True) * 1000;
end;

// Traz da tabela `recording` o resumo das gravacoes FECHADAS desta camera, uma
// vez por execucao. Substitui a leitura do _index.json; o resto do cache nao
// mudou.
procedure TVmsIndexCache.LoadDiskCache(const Camera: string);
var
  Pasta: string;
begin
  FLock.Enter;
  try
    if FDiskLoaded.ContainsKey(LowerCase(Camera)) then Exit;
    FDiskLoaded.AddOrSetValue(LowerCase(Camera), True);
  finally
    FLock.Leave;
  end;
  if (FDb = nil) or (not FDb.IsOpen) then Exit;

  // A camera do resumo e o nome da PASTA, que e o que o ReadInfo deriva.
  // Guardar o nome cru faria as duas origens discordarem quando o nome tem
  // caractere que o CameraFolderName troca.
  Pasta := ExtractFileName(ExcludeTrailingPathDelimiter(
             CameraDir(FStorageDir, Camera)));

  try
    FDb.Read(
      'SELECT r.name, r.start_ms, r.end_ms, r.bytes, r.blocks, r.has_video, ' +
      '       r.video_codec, r.width, r.height, r.has_audio, r.audio_codec, ' +
      '       r.sample_rate, r.channels, r.stamp_size, r.stamp_mtime_ms ' +
      '  FROM recording r JOIN camera c ON c.id = r.camera_id ' +
      ' WHERE c.name = ? AND r.closed = 1', [Camera],
      procedure(const Row: IDbRow)
      var
        Info: TVmsFileInfo;
        Entry: TCachedFile;
        Nome, Chave: string;
      begin
        Nome := Row.AsString('name');
        // O nome vem do banco, mas ainda vira caminho de arquivo: a mesma
        // checagem que se faz com o que chega pela rede vale aqui.
        if (Nome = '') or (not IsSafeVmsName(Nome)) then Exit;

        FillChar(Info, SizeOf(Info), 0);
        Info.Path := ''; Info.Name := ''; Info.Camera := '';
        Info.Name := Nome;
        Info.Camera := Pasta;
        Info.Path := TPath.Combine(CameraDir(FStorageDir, Camera), Nome);
        Info.StartMs := Row.AsInt64('start_ms');
        Info.EndMs := Row.AsInt64('end_ms');
        Info.DurationMs := Info.EndMs - Info.StartMs;
        Info.Bytes := Row.AsInt64('bytes');
        Info.Blocks := Row.AsInt('blocks');
        Info.Closed := True;      // a consulta ja filtrou
        Info.Indexed := True;
        Info.HasVideo := Row.AsBool('has_video');
        Info.VideoCodec := TVideoCodec(Row.AsInt('video_codec'));
        Info.Width := Row.AsInt('width');
        Info.Height := Row.AsInt('height');
        Info.HasAudio := Row.AsBool('has_audio');
        Info.AudioCodec := TAudioCodec(Row.AsInt('audio_codec'));
        Info.SampleRate := Row.AsInt('sample_rate');
        Info.Channels := Row.AsInt('channels');
        if (Info.StartMs <= 0) or (Info.EndMs <= Info.StartMs) then Exit;

        Chave := KeyOf(Info.Path);
        FLock.Enter;
        try
          if not FFiles.TryGetValue(Chave, Entry) then
          begin
            Entry := TCachedFile.Create;
            FFiles.Add(Chave, Entry);
          end;
          Entry.Info := Info;
          Entry.StampSize := Row.AsInt64('stamp_size');
          Entry.StampWriteMs := Row.AsInt64('stamp_mtime_ms');
        finally
          FLock.Leave;
        end;
      end);
  except
    on E: Exception do
      // Consulta que falha nao pode derrubar a listagem: sem o resumo, releem-se
      // os arquivos, que e o comportamento de quem nunca teve cache.
      Log(llDebug, 'inventario nao pode ser lido do banco: ' + E.Message);
  end;
end;

// Grava na tabela `recording` o que se sabe das gravacoes FECHADAS. Substitui a
// reescrita do _index.json.
//
// Uma linha por arquivo, por Post (assincrono): quem chama isto e a varredura
// da listagem, e ela nao pode parar para esperar disco. O ON CONFLICT deixa
// reexecutar sem duplicar.
procedure TVmsIndexCache.SaveDiskCache(const Camera: string);
var
  Pair: TPair<string, TCachedFile>;
  Pasta: string;
  Copias: TArray<TCachedFile>;
  Carimbos: TArray<TPair<Int64, Int64>>;
  N, I: Integer;
begin
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  Pasta := ExtractFileName(ExcludeTrailingPathDelimiter(
             CameraDir(FStorageDir, Camera)));

  // Copia sob o lock e grava fora dele: manter a secao critica presa durante
  // dezenas de Post seguraria toda a API, que tambem consulta este cache.
  SetLength(Copias, 0);
  SetLength(Carimbos, 0);
  FLock.Enter;
  try
    N := 0;
    SetLength(Copias, FFiles.Count);
    SetLength(Carimbos, FFiles.Count);
    for Pair in FFiles do
    begin
      // So gravacao fechada: a que ainda grava muda de resumo a cada minuto.
      if not Pair.Value.Info.Closed then Continue;
      if not SameText(Pair.Value.Info.Camera, Pasta) then Continue;
      if Pair.Value.StampSize <= 0 then Continue;
      Copias[N] := Pair.Value;
      Carimbos[N] := TPair<Int64, Int64>.Create(Pair.Value.StampSize,
                                                Pair.Value.StampWriteMs);
      Inc(N);
    end;
    SetLength(Copias, N);
    SetLength(Carimbos, N);
  finally
    FLock.Leave;
  end;

  for I := 0 to High(Copias) do
  begin
    // Apagada pela retencao: nao entra. A linha velha sai na limpeza abaixo.
    if not TFile.Exists(Copias[I].Info.Path) then Continue;
    FDb.Post(
      'INSERT INTO recording (camera_id, name, start_ms, end_ms, duration_ms, ' +
      '    bytes, blocks, closed, indexed, has_video, video_codec, width, ' +
      '    height, has_audio, audio_codec, sample_rate, channels, ' +
      '    stamp_size, stamp_mtime_ms) ' +
      '  VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?, ?, 1, 1, ' +
      '          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' +
      '  ON CONFLICT(camera_id, name) DO UPDATE SET ' +
      '    start_ms = excluded.start_ms, end_ms = excluded.end_ms, ' +
      '    duration_ms = excluded.duration_ms, bytes = excluded.bytes, ' +
      '    blocks = excluded.blocks, closed = 1, indexed = 1, ' +
      '    has_video = excluded.has_video, video_codec = excluded.video_codec, ' +
      '    width = excluded.width, height = excluded.height, ' +
      '    has_audio = excluded.has_audio, audio_codec = excluded.audio_codec, ' +
      '    sample_rate = excluded.sample_rate, channels = excluded.channels, ' +
      '    stamp_size = excluded.stamp_size, ' +
      '    stamp_mtime_ms = excluded.stamp_mtime_ms',
      [Camera, Copias[I].Info.Name, Copias[I].Info.StartMs, Copias[I].Info.EndMs,
       Copias[I].Info.DurationMs, Copias[I].Info.Bytes, Copias[I].Info.Blocks,
       Copias[I].Info.HasVideo, Ord(Copias[I].Info.VideoCodec),
       Copias[I].Info.Width, Copias[I].Info.Height,
       Copias[I].Info.HasAudio, Ord(Copias[I].Info.AudioCodec),
       Int64(Copias[I].Info.SampleRate), Copias[I].Info.Channels,
       Carimbos[I].Key, Carimbos[I].Value]);
  end;
end;

// Tira do inventario as linhas cujo .vms nao existe mais. Chamada pela
// retencao, depois de apagar os arquivos.
function TVmsIndexCache.ForgetMissing(const Camera: string): Integer;
var
  Sumidos: TArray<string>;
  I: Integer;
begin
  Result := 0;
  if (FDb = nil) or (not FDb.IsOpen) then Exit;
  SetLength(Sumidos, 0);
  try
    FDb.Read(
      'SELECT r.name FROM recording r JOIN camera c ON c.id = r.camera_id ' +
      ' WHERE c.name = ?', [Camera],
      procedure(const Row: IDbRow)
      begin
        SetLength(Sumidos, Length(Sumidos) + 1);
        Sumidos[High(Sumidos)] := Row.AsString('name');
      end);
    for I := 0 to High(Sumidos) do
      if not TFile.Exists(TPath.Combine(CameraDir(FStorageDir, Camera), Sumidos[I])) then
      begin
        FDb.Post('DELETE FROM recording WHERE name = ? AND camera_id = ' +
                 '(SELECT id FROM camera WHERE name = ?)', [Sumidos[I], Camera]);
        Inc(Result);
      end;
  except
    on E: Exception do
      Log(llDebug, 'limpeza do inventario falhou: ' + E.Message);
  end;
end;

function TVmsIndexCache.GetInfo(const Path: string; out Info: TVmsFileInfo): Boolean;
var
  Size: Int64;
  Written: TDateTime;
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
  Result := GetInfoStamped(Path, Size, WriteStampMs(Written), Info);
end;

function TVmsIndexCache.GetInfoStamped(const Path: string; Size, WrittenMs: Int64;
  out Info: TVmsFileInfo): Boolean;
var
  Key: string;
  Entry: TCachedFile;
  Fresh: TVmsFileInfo;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Path := '';
  Info.Name := '';
  Info.Camera := '';

  Key := KeyOf(Path);
  FLock.Enter;
  try
    if FFiles.TryGetValue(Key, Entry) then
    begin
      // Nada mudou desde a última vez: o resumo em cache vale. Vale também para
      // o que veio do json — lá o carimbo é o mesmo par tamanho + data.
      if (Entry.StampSize = Size) and (Entry.StampWriteMs = WrittenMs) then
      begin
        Info := Entry.Info;
        Exit(True);
      end;
    end;
  finally
    FLock.Leave;
  end;

  // Fora do lock: I/O não pode segurar as outras conexões.
  if not ReadInfo(Path, Fresh) then Exit;

  FLock.Enter;
  try
    if not FFiles.TryGetValue(Key, Entry) then
    begin
      Entry := TCachedFile.Create;
      FFiles.Add(Key, Entry);
    end;
    Entry.Info := Fresh;
    Entry.StampSize := Size;
    Entry.StampWriteMs := WrittenMs;
    // Gravação fechada tem resumo imutável: vale guardar em disco. A que ainda
    // grava, não — ela mudaria o json a cada consulta.
    if Fresh.Closed then FDiskDirty := True;
  finally
    FLock.Leave;
  end;

  Info := Fresh;
  Result := True;
end;

// O índice de blocos de um arquivo — a pergunta cara, feita só por quem vai
// tocar. Fica em cache para os poucos arquivos em uso; o arquivo que ainda
// cresce continua de onde parou (SeedIndex + ExtendIndex), sem revarrer.
function TVmsIndexCache.GetIndex(const Path: string; out Index: TVmsIndex): Boolean;
var
  Info: TVmsFileInfo;
  Key: string;
  Entry: TCachedFile;
  Reader: TVmsReader;
  Size: Int64;
  PrevIndex: TVmsIndex;
  PrevUpTo, NewUpTo: Int64;
begin
  Index := nil;
  Result := False;
  // Passa pelo GetInfo primeiro: é ele que revalida o cache e diz se o arquivo
  // ainda está lá.
  if not GetInfo(Path, Info) then Exit;
  // O tamanho de agora, não o que o resumo trouxe: é ele que diz se o índice em
  // cache ainda descreve o arquivo inteiro.
  try
    Size := TFile.GetSize(Path);
  except
    Exit;
  end;
  if Size <= 0 then Exit;

  Key := KeyOf(Path);
  PrevIndex := nil;
  PrevUpTo := 0;
  FLock.Enter;
  try
    if FFiles.TryGetValue(Key, Entry) and (Length(Entry.Index) > 0) then
    begin
      Inc(FUseTick);
      Entry.LastUsed := FUseTick;
      // Do mesmo tamanho de quando foi montado: nada mudou, serve como está.
      if Entry.IndexStampSize = Size then
      begin
        Index := Entry.Index;
        Exit(True);
      end;
      // Cresceu: continua dali em vez de refazer.
      if (Size > Entry.IndexStampSize) and (Entry.IndexUpTo > 0) then
      begin
        PrevIndex := Entry.Index;
        PrevUpTo := Entry.IndexUpTo;
      end;
    end;
  finally
    FLock.Leave;
  end;

  // Fora do lock: I/O não segura as outras conexões.
  try
    Reader := TVmsReader.Create(Path);
  except
    Exit;
  end;
  try
    if not Reader.ReadHeader then Exit;
    if (Length(PrevIndex) > 0) and (PrevUpTo > 0) then
      Reader.SeedIndex(PrevIndex, PrevUpTo);
    Reader.EnsureIndex;
    Reader.ExtendIndex;
    if Reader.IndexCount = 0 then Exit;
    Index := Copy(Reader.Index);
    NewUpTo := Reader.ScannedUpTo;
  finally
    Reader.Free;
  end;

  FLock.Enter;
  try
    if FFiles.TryGetValue(Key, Entry) then
    begin
      Inc(FUseTick);
      Entry.Index := Index;
      Entry.IndexUpTo := NewUpTo;
      Entry.IndexStampSize := Size;
      Entry.LastUsed := FUseTick;
      TrimIndexes;
    end;
  finally
    FLock.Leave;
  end;
  Result := True;
end;

procedure TVmsIndexCache.TrimIndexes;
var
  Pair: TPair<string, TCachedFile>;
  Held: TList<TCachedFile>;
  I: Integer;
begin
  Held := TList<TCachedFile>.Create;
  try
    for Pair in FFiles do
      if Length(Pair.Value.Index) > 0 then
        Held.Add(Pair.Value);
    if Held.Count <= MAX_CACHED_INDEXES then Exit;
    Held.Sort(TComparer<TCachedFile>.Construct(
      function(const A, B: TCachedFile): Integer
      begin
        // mais recente primeiro
        if A.LastUsed > B.LastUsed then Result := -1
        else if A.LastUsed < B.LastUsed then Result := 1
        else Result := 0;
      end));
    for I := MAX_CACHED_INDEXES to Held.Count - 1 do
    begin
      Held[I].Index := nil;
      Held[I].IndexUpTo := 0;
      Held[I].IndexStampSize := 0;
    end;
  finally
    Held.Free;
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
  SR: TSearchRec;
  Count: Integer;
  Info: TVmsFileInfo;
  Tmp: TVmsFileInfoArray;
  Dir, Base: string;
  Sujo: Boolean;
begin
  Result := nil;
  if Camera = '' then Exit;
  // Tudo que está na pasta da câmera é dela — não há mais o que filtrar.
  Dir := CameraDir(FStorageDir, Camera);
  if not DirectoryExists(Dir) then Exit;
  // Resumo em disco da execução anterior: sem ele, a primeira consulta depois de
  // subir o servidor abriria cada gravação da pasta, uma por uma.
  LoadDiskCache(Camera);

  Base := IncludeTrailingPathDelimiter(Dir);
  Count := 0;
  SetLength(Tmp, 64);
  // FindFirst traz nome, tamanho e data numa varredura só. Com TDirectory.GetFiles
  // eram dois stats por arquivo depois, e com centenas de gravações isso pesa
  // mais que ler os poucos arquivos novos.
  if FindFirst(Base + '*.vms', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      // O filtro do sistema casa por nome curto também; conferir a extensão é o
      // que garante que um `.vms.idx` nunca entre na lista como se fosse gravação.
      if not SameText(ExtractFileExt(SR.Name), '.vms') then Continue;
      if not GetInfoStamped(Base + SR.Name, SR.Size,
                            WriteStampMs(SR.TimeStamp), Info) then Continue;
      if Count >= Length(Tmp) then SetLength(Tmp, Length(Tmp) * 2);
      Tmp[Count] := Info;
      Inc(Count);
    until FindNext(SR) <> 0;
  finally
    System.SysUtils.FindClose(SR);
  end;
  SetLength(Tmp, Count);
  // Gravação fechada nova (ou mudada) entrou no cache: regrava o json para a
  // próxima subida já achar tudo pronto.
  FLock.Enter;
  try
    Sujo := FDiskDirty;
    FDiskDirty := False;
  finally
    FLock.Leave;
  end;
  if Sujo then SaveDiskCache(Camera);

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
