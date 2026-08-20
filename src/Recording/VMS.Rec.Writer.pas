unit VMS.Rec.Writer;

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Rec.Format,
  VMS.Rec.Crc32;

type
  IRecordingWriter = interface
    ['{3F1A0F62-0B2D-4D0F-9B5C-CC4F2A3E8E60}']
    procedure WriteHeader(const Header: TVmsHeader);
    procedure WriteBlock(const Block: TVmsBlock);
    procedure Close(WriteFooter: Boolean);
    function HeaderWritten: Boolean;
    function BlocksWritten: Cardinal;
    function BytesWritten: Int64;
    function FilePath: string;
    // A região de índice viva encheu: quem grava deve rodar de arquivo. Ver
    // VMS.Rec.Format — é o tamanho da região que define o do segmento.
    function IndexRegionFull: Boolean;
    // Quase cheia: ainda cabe esperar o próximo keyframe antes de rodar, para o
    // arquivo novo começar por onde o decodificador consegue entrar.
    function IndexRegionNearlyFull: Boolean;
  end;

  TFileRecordingWriter = class(TInterfacedObject, IRecordingWriter)
  strict private
    FFilePath: string;
    FStream: TFileStream;
    FHeaderDone: Boolean;
    FBlocks: Cardinal;
    FBytes: Int64;
    FFirstUnixMs: Int64;
    FLastUnixMs: Int64;
    FLastBlockOffset: UInt64;
    // índice acumulado em memória e despejado no Close; 17 bytes por bloco, ou
    // ~30 KB por hora de gravação
    FIndex: TVmsIndex;
    FIndexCount: Integer;
    FIndexOverflow: Boolean;
    // Região de índice viva: reservada no WriteHeader, atualizada no lugar a
    // cada REGION_COMMIT_EVERY blocos.
    FRegionOffset: Int64;
    FRegionBytes: Integer;
    FRegionCapacity: Integer;
    FRegionOk: Boolean;       // False = não deu para escrever; grava sem índice vivo
    FCommittedCount: Integer; // entradas já commitadas na região
    FCommitCrc: Cardinal;     // crc corrente das entradas commitadas
    FCommitGen: Cardinal;
    FCommitSlot: Integer;     // próximo slot a escrever (alterna 0/1)
    procedure NoteBlockInIndex(const Block: TVmsBlock; Offset: UInt64);
    procedure ReserveIndexRegion;
    procedure CommitIndexRegion;
    function WriteIndexChunk: UInt64;
    procedure FlushDisk;
  public
    // AIndexRegionBytes decide de quanto em quanto tempo a gravação roda de
    // arquivo: cabe uma entrada por bloco, e região cheia é o gatilho.
    constructor Create(const AFilePath: string;
                       AIndexRegionBytes: Integer = VMS_REGION_DEFAULT_BYTES);
    destructor Destroy; override;
    procedure WriteHeader(const Header: TVmsHeader);
    procedure WriteBlock(const Block: TVmsBlock);
    procedure Close(WriteFooter: Boolean);
    function HeaderWritten: Boolean;
    function BlocksWritten: Cardinal;
    function BytesWritten: Int64;
    function FilePath: string;
    function IndexRegionFull: Boolean;
    function IndexRegionNearlyFull: Boolean;
  end;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;
{$ENDIF}

const
  // Válvula de segurança: acima disto o índice é abandonado e o arquivo fecha
  // sem ele (quem precisar varre). São ~23 dias de gravação com blocos de 2 s —
  // se chegou lá, alguma coisa está errada e é melhor não segurar 17 MB de RAM.
  MAX_INDEX_ENTRIES = 1000000;

  // De quantos em quantos blocos a região é atualizada. Cada commit são ~280
  // bytes e dois seeks; 16 blocos são ~32 s, e o que ficar de fora do último
  // commit o leitor recupera varrendo a cauda, em uma dúzia de leituras.
  REGION_COMMIT_EVERY = 16;

procedure WriteU16ToBytes(var Buf: TBytes; var Offset: Integer; V: Word);
begin
  Buf[Offset]     := Byte(V and $FF);
  Buf[Offset + 1] := Byte((V shr 8) and $FF);
  Inc(Offset, 2);
end;

procedure WriteU32ToBytes(var Buf: TBytes; var Offset: Integer; V: Cardinal);
begin
  Buf[Offset]     := Byte(V and $FF);
  Buf[Offset + 1] := Byte((V shr 8) and $FF);
  Buf[Offset + 2] := Byte((V shr 16) and $FF);
  Buf[Offset + 3] := Byte((V shr 24) and $FF);
  Inc(Offset, 4);
end;

procedure WriteI64ToBytes(var Buf: TBytes; var Offset: Integer; V: Int64);
var
  U: UInt64;
  K: Integer;
begin
  U := UInt64(V);
  for K := 0 to 7 do
  begin
    Buf[Offset + K] := Byte(U and $FF);
    U := U shr 8;
  end;
  Inc(Offset, 8);
end;

procedure WriteU64ToBytes(var Buf: TBytes; var Offset: Integer; V: UInt64);
var
  U: UInt64;
  K: Integer;
begin
  U := V;
  for K := 0 to 7 do
  begin
    Buf[Offset + K] := Byte(U and $FF);
    U := U shr 8;
  end;
  Inc(Offset, 8);
end;

{ TFileRecordingWriter }

constructor TFileRecordingWriter.Create(const AFilePath: string;
  AIndexRegionBytes: Integer);
var
  Dir: string;
begin
  inherited Create;
  FFilePath := AFilePath;
  FRegionBytes := NormalizeRegionBytes(AIndexRegionBytes);
  FRegionCapacity := RegionCapacity(FRegionBytes);
  Dir := ExtractFilePath(AFilePath);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);
  FStream := TFileStream.Create(AFilePath, fmCreate or fmShareDenyWrite);
  FHeaderDone := False;
  FBlocks := 0;
  FBytes := 0;
  FFirstUnixMs := 0;
  FLastUnixMs := 0;
  FLastBlockOffset := 0;
  FIndexCount := 0;
  FIndexOverflow := False;
  FRegionOffset := 0;
  FRegionOk := False;
  FCommittedCount := 0;
  FCommitCrc := 0;
  FCommitGen := 0;
  FCommitSlot := 0;
end;

destructor TFileRecordingWriter.Destroy;
begin
  if FStream <> nil then
  begin
    try
      FStream.Free;
    except
    end;
    FStream := nil;
  end;
  inherited;
end;

procedure TFileRecordingWriter.WriteHeader(const Header: TVmsHeader);
var
  UriBytes, Buf: TBytes;
  Size, Offset: Integer;
  Crc: Cardinal;
begin
  if FHeaderDone then
    raise EVmsIoError.Create('Header already written');

  UriBytes := TEncoding.UTF8.GetBytes(Header.SourceUri);
  if Length(UriBytes) > 65535 then
    SetLength(UriBytes, 65535);

  Size :=
    4 +              // magic
    2 +              // version
    4 +              // header size
    8 +              // creation unix ms
    2 + Length(UriBytes) +
    1 + 1 + 4 + 2 + 2 + 4 + Length(Header.Video.Extradata) +
    1 + 1 + 4 + 1 + 1 + 4 + 4 + Length(Header.Audio.Extradata) +
    4;               // crc32

  SetLength(Buf, Size);
  Offset := 0;

  Move(VMS_MAGIC_FILE[0], Buf[Offset], 4); Inc(Offset, 4);
  WriteU16ToBytes(Buf, Offset, VMS_FORMAT_VERSION);
  WriteU32ToBytes(Buf, Offset, Cardinal(Size));
  WriteI64ToBytes(Buf, Offset, Header.CreationUnixMs);
  WriteU16ToBytes(Buf, Offset, Word(Length(UriBytes)));
  if Length(UriBytes) > 0 then
  begin
    Move(UriBytes[0], Buf[Offset], Length(UriBytes));
    Inc(Offset, Length(UriBytes));
  end;

  if Header.VideoPresent then
    Buf[Offset] := 1
  else
    Buf[Offset] := 0;
  Inc(Offset);
  Buf[Offset] := Byte(Header.Video.Codec); Inc(Offset);
  WriteU32ToBytes(Buf, Offset, Header.Video.Timescale);
  WriteU16ToBytes(Buf, Offset, Header.Video.Width);
  WriteU16ToBytes(Buf, Offset, Header.Video.Height);
  WriteU32ToBytes(Buf, Offset, Cardinal(Length(Header.Video.Extradata)));
  if Length(Header.Video.Extradata) > 0 then
  begin
    Move(Header.Video.Extradata[0], Buf[Offset], Length(Header.Video.Extradata));
    Inc(Offset, Length(Header.Video.Extradata));
  end;

  if Header.AudioPresent then
    Buf[Offset] := 1
  else
    Buf[Offset] := 0;
  Inc(Offset);
  Buf[Offset] := Byte(Header.Audio.Codec); Inc(Offset);
  WriteU32ToBytes(Buf, Offset, Header.Audio.SampleRate);
  Buf[Offset] := Header.Audio.Channels; Inc(Offset);
  Buf[Offset] := Header.Audio.BitsPerSample; Inc(Offset);
  WriteU32ToBytes(Buf, Offset, Header.Audio.Timescale);
  WriteU32ToBytes(Buf, Offset, Cardinal(Length(Header.Audio.Extradata)));
  if Length(Header.Audio.Extradata) > 0 then
  begin
    Move(Header.Audio.Extradata[0], Buf[Offset], Length(Header.Audio.Extradata));
    Inc(Offset, Length(Header.Audio.Extradata));
  end;

  Crc := Crc32Update(0, Buf, 0, Offset);
  WriteU32ToBytes(Buf, Offset, Crc);

  FStream.WriteBuffer(Buf[0], Length(Buf));
  Inc(FBytes, Length(Buf));
  FHeaderDone := True;
  FFirstUnixMs := Header.CreationUnixMs;
  ReserveIndexRegion;
end;

// Reserva a região de índice viva logo depois do header. Escrita de verdade
// (zeros), não buraco: o primeiro bloco tem que começar DEPOIS dela, e o leitor
// acha a região exatamente em HeaderSize.
procedure TFileRecordingWriter.ReserveIndexRegion;
var
  Buf: TBytes;
  Offset: Integer;
begin
  FRegionOk := False;
  if FRegionCapacity <= 0 then Exit;
  try
    SetLength(Buf, FRegionBytes);   // TBytes nasce zerado: os dois slots de
    Offset := 0;                    // commit ficam em (0 entradas, geração 0)
    Move(VMS_MAGIC_REGION[0], Buf[Offset], 4); Inc(Offset, 4);
    WriteU32ToBytes(Buf, Offset, Cardinal(FRegionBytes));
    WriteU32ToBytes(Buf, Offset, Cardinal(FRegionCapacity));
    FRegionOffset := FBytes;
    FStream.WriteBuffer(Buf[0], Length(Buf));
    Inc(FBytes, FRegionBytes);
    FRegionOk := True;
  except
    // Sem região o arquivo continua válido; só volta a custar varredura para
    // quem quiser tocá-lo antes de ele fechar.
    FRegionOk := False;
  end;
end;

// Grava na região as entradas que ainda não estavam lá e commita.
//
// Ordem que dá a garantia: primeiro as ENTRADAS (numa área que nenhum commit
// válido cobre ainda), depois o SLOT DE COMMIT. Queda no meio das entradas
// deixa o commit anterior valendo e o lixo além dele é ignorado; queda no meio
// do commit estraga um slot só, e o outro continua de pé.
procedure TFileRecordingWriter.CommitIndexRegion;
var
  Buf: TBytes;
  Offset, I, UpTo, Pending: Integer;
  SlotOfs, SavedPos: Int64;
begin
  if (not FRegionOk) or (FStream = nil) then Exit;
  UpTo := FIndexCount;
  if UpTo > FRegionCapacity then UpTo := FRegionCapacity;
  Pending := UpTo - FCommittedCount;
  if Pending <= 0 then Exit;

  SavedPos := FBytes;
  try
    SetLength(Buf, Pending * VMS_INDEX_ENTRY_SIZE);
    Offset := 0;
    for I := FCommittedCount to UpTo - 1 do
    begin
      WriteI64ToBytes(Buf, Offset, FIndex[I].Offset);
      WriteI64ToBytes(Buf, Offset, FIndex[I].StartUnixMs);
      Buf[Offset] := FIndex[I].Flags; Inc(Offset);
    end;
    FStream.Position := FRegionOffset + VMS_REGION_HEADER_SIZE +
                        Int64(FCommittedCount) * VMS_INDEX_ENTRY_SIZE;
    FStream.WriteBuffer(Buf[0], Length(Buf));
    // CRC corrente: as entradas entram sempre no fim e nunca são reescritas,
    // então continuar o crc de onde parou dá o mesmo que recalcular tudo.
    FCommitCrc := Crc32Update(FCommitCrc, Buf, 0, Length(Buf));

    Inc(FCommitGen);
    SetLength(Buf, VMS_REGION_COMMIT_SIZE);
    Offset := 0;
    WriteU32ToBytes(Buf, Offset, Cardinal(UpTo));
    WriteU32ToBytes(Buf, Offset, FCommitGen);
    WriteU32ToBytes(Buf, Offset, FCommitCrc);
    if FCommitSlot = 0 then
      SlotOfs := VMS_REGION_COMMIT_A_OFS
    else
      SlotOfs := VMS_REGION_COMMIT_B_OFS;
    FStream.Position := FRegionOffset + SlotOfs;
    FStream.WriteBuffer(Buf[0], Length(Buf));

    FCommittedCount := UpTo;
    FCommitSlot := (FCommitSlot + 1) mod VMS_REGION_SLOTS;
  except
    // Falhou uma vez, para de tentar: gravar a mídia é o que não pode parar.
    FRegionOk := False;
  end;
  // O corpo do arquivo continua sendo escrito no fim, sempre.
  try
    FStream.Position := SavedPos;
  except
    FRegionOk := False;
  end;
end;

procedure TFileRecordingWriter.WriteBlock(const Block: TVmsBlock);
var
  Buf: TBytes;
  Offset, IndexSize, PayloadSize, TotalSize: Integer;
  I: Integer;
  Crc: Cardinal;
  StartOffset: UInt64;
  HasAnchor: Boolean;
begin
  if not FHeaderDone then
    raise EVmsIoError.Create('Header must be written before blocks');

  // A âncora A/V entra DENTRO da área de índice, depois das entradas de sample:
  // leitor que não a conhece percorre só `sampleCount` entradas e acha o payload
  // por `indexSize`, então ignora estes bytes sem sair do lugar (ver
  // VMS.Rec.Format). Bloco sem nenhuma trilha datada não leva âncora.
  HasAnchor := (Block.VideoAnchorMs > 0) or (Block.AudioAnchorMs > 0);
  IndexSize := Length(Block.Samples) * VMS_SAMPLE_ENTRY_SIZE;
  if HasAnchor then
    Inc(IndexSize, VMS_ANCHOR_SIZE);
  PayloadSize := Length(Block.Payload);
  TotalSize :=
    4 +              // magic
    4 +              // block size
    4 +              // block seq
    8 +              // start unix ms
    4 +              // sample count
    4 +              // index size
    IndexSize +
    PayloadSize +
    4;               // crc32

  SetLength(Buf, TotalSize);
  Offset := 0;
  Move(VMS_MAGIC_BLOCK[0], Buf[Offset], 4); Inc(Offset, 4);
  WriteU32ToBytes(Buf, Offset, Cardinal(TotalSize));
  WriteU32ToBytes(Buf, Offset, Block.BlockSeq);
  WriteI64ToBytes(Buf, Offset, Block.StartUnixMs);
  WriteU32ToBytes(Buf, Offset, Cardinal(Length(Block.Samples)));
  WriteU32ToBytes(Buf, Offset, Cardinal(IndexSize));

  for I := 0 to High(Block.Samples) do
  begin
    Buf[Offset] := Block.Samples[I].TrackId; Inc(Offset);
    Buf[Offset] := Block.Samples[I].FlagsByte; Inc(Offset);
    WriteI64ToBytes(Buf, Offset, Block.Samples[I].Pts);
    WriteU32ToBytes(Buf, Offset, Block.Samples[I].PayloadOffset);
    WriteU32ToBytes(Buf, Offset, Block.Samples[I].PayloadSize);
  end;

  if HasAnchor then
  begin
    Move(VMS_MAGIC_ANCHOR[0], Buf[Offset], 4); Inc(Offset, 4);
    WriteI64ToBytes(Buf, Offset, Block.VideoAnchorMs);
    WriteI64ToBytes(Buf, Offset, Block.AudioAnchorMs);
  end;

  if PayloadSize > 0 then
  begin
    Move(Block.Payload[0], Buf[Offset], PayloadSize);
    Inc(Offset, PayloadSize);
  end;

  Crc := Crc32Update(0, Buf, 0, Offset);
  WriteU32ToBytes(Buf, Offset, Crc);

  StartOffset := UInt64(FBytes);
  FStream.WriteBuffer(Buf[0], Length(Buf));
  Inc(FBytes, Length(Buf));
  FLastBlockOffset := StartOffset;
  Inc(FBlocks);
  FLastUnixMs := Block.StartUnixMs;
  NoteBlockInIndex(Block, StartOffset);
  if FRegionOk and (FIndexCount - FCommittedCount >= REGION_COMMIT_EVERY) then
    CommitIndexRegion;
end;

procedure TFileRecordingWriter.NoteBlockInIndex(const Block: TVmsBlock; Offset: UInt64);
begin
  if FIndexOverflow then Exit;
  if FIndexCount >= MAX_INDEX_ENTRIES then
  begin
    FIndexOverflow := True;
    SetLength(FIndex, 0);
    FIndexCount := 0;
    Exit;
  end;
  if FIndexCount >= Length(FIndex) then
    if Length(FIndex) = 0 then
      SetLength(FIndex, 1024)
    else
      SetLength(FIndex, Length(FIndex) * 2);
  FIndex[FIndexCount].Offset := Int64(Offset);
  FIndex[FIndexCount].StartUnixMs := Block.StartUnixMs;
  if SamplesHaveKeyframe(Block.Samples) then
    FIndex[FIndexCount].Flags := VMS_IDX_FLAG_KEYFRAME
  else
    FIndex[FIndexCount].Flags := 0;
  Inc(FIndexCount);
end;

// Devolve o offset onde o chunk começou, ou 0 se não escreveu nada (é o valor
// que o rodapé usa para dizer "sem índice").
function TFileRecordingWriter.WriteIndexChunk: UInt64;
var
  Buf: TBytes;
  Offset, I, TotalSize: Integer;
  Crc: Cardinal;
  StartOffset: UInt64;
begin
  Result := 0;
  if (FIndexCount = 0) or FIndexOverflow then Exit;

  TotalSize := VMS_INDEX_HEADER_SIZE + FIndexCount * VMS_INDEX_ENTRY_SIZE + 4;
  SetLength(Buf, TotalSize);
  Offset := 0;
  Move(VMS_MAGIC_INDEX[0], Buf[Offset], 4); Inc(Offset, 4);
  WriteU32ToBytes(Buf, Offset, Cardinal(TotalSize));
  WriteU32ToBytes(Buf, Offset, Cardinal(FIndexCount));
  for I := 0 to FIndexCount - 1 do
  begin
    WriteI64ToBytes(Buf, Offset, FIndex[I].Offset);
    WriteI64ToBytes(Buf, Offset, FIndex[I].StartUnixMs);
    Buf[Offset] := FIndex[I].Flags; Inc(Offset);
  end;
  Crc := Crc32Update(0, Buf, 0, Offset);
  WriteU32ToBytes(Buf, Offset, Crc);

  StartOffset := UInt64(FBytes);
  FStream.WriteBuffer(Buf[0], Length(Buf));
  Inc(FBytes, Length(Buf));
  Result := StartOffset;
end;

procedure TFileRecordingWriter.Close(WriteFooter: Boolean);
var
  Buf: TBytes;
  Offset: Integer;
  Crc: Cardinal;
  Duration: Int64;
  IndexOffset: UInt64;
begin
  if FStream = nil then Exit;

  // Commit final: o arquivo fechado é lido pelo VIDX do rodapé, mas quem já
  // estava com ele aberto (uma sessão ao vivo, o cache do servidor) pode ler a
  // região — e ela tem que refletir o arquivo inteiro.
  if FRegionOk then
    CommitIndexRegion;

  if WriteFooter and FHeaderDone then
  begin
    // Índice primeiro, rodapé depois: é o rodapé que aponta para ele, e ele
    // precisa estar no fim para ser achado a partir do tamanho do arquivo.
    try
      IndexOffset := WriteIndexChunk;
    except
      IndexOffset := 0; // sem índice o arquivo continua válido; quem precisar varre
    end;

    SetLength(Buf, VMS_FOOTER_SIZE);
    Offset := 0;
    Move(VMS_MAGIC_FOOTER[0], Buf[Offset], 4); Inc(Offset, 4);
    WriteU32ToBytes(Buf, Offset, FBlocks);
    Duration := 0;
    if (FFirstUnixMs > 0) and (FLastUnixMs >= FFirstUnixMs) then
      Duration := FLastUnixMs - FFirstUnixMs;
    WriteI64ToBytes(Buf, Offset, Duration);
    WriteU64ToBytes(Buf, Offset, FLastBlockOffset);
    WriteU64ToBytes(Buf, Offset, IndexOffset);
    if IndexOffset = 0 then
      WriteU32ToBytes(Buf, Offset, 0)
    else
      WriteU32ToBytes(Buf, Offset, Cardinal(FIndexCount));
    Crc := Crc32Update(0, Buf, 0, Offset);
    WriteU32ToBytes(Buf, Offset, Crc);
    try
      FStream.WriteBuffer(Buf[0], Length(Buf));
      Inc(FBytes, Length(Buf));
    except
    end;
  end;

  try
    FlushDisk;
  except
  end;

  FreeAndNil(FStream);
end;

procedure TFileRecordingWriter.FlushDisk;
{$IFDEF MSWINDOWS}
var
  H: THandle;
{$ENDIF}
begin
  if FStream = nil then Exit;
  {$IFDEF MSWINDOWS}
  H := FStream.Handle;
  if H <> INVALID_HANDLE_VALUE then
    FlushFileBuffers(H);
  {$ENDIF}
end;

function TFileRecordingWriter.HeaderWritten: Boolean; begin Result := FHeaderDone; end;
function TFileRecordingWriter.BlocksWritten: Cardinal; begin Result := FBlocks; end;
function TFileRecordingWriter.BytesWritten: Int64; begin Result := FBytes; end;
function TFileRecordingWriter.FilePath: string; begin Result := FFilePath; end;

function TFileRecordingWriter.IndexRegionFull: Boolean;
begin
  // Sem região não há gatilho de rotação: o arquivo corre solto, como antes.
  Result := FRegionOk and (FIndexCount >= FRegionCapacity);
end;

function TFileRecordingWriter.IndexRegionNearlyFull: Boolean;
begin
  Result := FRegionOk and
            (FIndexCount >= FRegionCapacity - VMS_REGION_KEYFRAME_SLACK);
end;

end.
