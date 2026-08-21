unit VMS.Rec.Writer;

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Rec.Format,
  VMS.Rec.Sidecar,
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
    // Índice do arquivo enquanto ele grava, no `.vms.idx` ao lado. Apagado no
    // fechamento limpo, quando o VIDX toma o lugar dele no fim do .vms.
    FSidecar: TSidecarWriter;
    procedure NoteBlockInIndex(const Block: TVmsBlock; Offset: UInt64);
    procedure FlushSidecar;
    function WriteIndexChunk: UInt64;
    procedure FlushDisk;
  public
    constructor Create(const AFilePath: string);
    destructor Destroy; override;
    procedure WriteHeader(const Header: TVmsHeader);
    procedure WriteBlock(const Block: TVmsBlock);
    procedure Close(WriteFooter: Boolean);
    function HeaderWritten: Boolean;
    function BlocksWritten: Cardinal;
    function BytesWritten: Int64;
    function FilePath: string;
  end;

// Os bytes do chunk VIDX de um índice, e os do rodapé. Existem soltos porque há
// DOIS caminhos que fecham uma gravação: o Close normal e a finalização de uma
// gravação que ficou aberta (ver Vms.Server.Repair). Serializar nos dois lugares
// daria dois formatos na primeira vez que um deles mudasse.
function BuildIndexChunk(const Index: TVmsIndex; Count: Integer): TBytes;
function BuildFooter(TotalBlocks: Cardinal; DurationMs: Int64;
                     LastBlockOffset, IndexOffset: UInt64;
                     IndexCount: Cardinal): TBytes;

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

function BuildIndexChunk(const Index: TVmsIndex; Count: Integer): TBytes;
var
  Offset, I, TotalSize: Integer;
begin
  Result := nil;
  if (Count <= 0) or (Count > Length(Index)) then Exit;
  TotalSize := VMS_INDEX_HEADER_SIZE + Count * VMS_INDEX_ENTRY_SIZE + 4;
  SetLength(Result, TotalSize);
  Offset := 0;
  Move(VMS_MAGIC_INDEX[0], Result[Offset], 4); Inc(Offset, 4);
  WriteU32ToBytes(Result, Offset, Cardinal(TotalSize));
  WriteU32ToBytes(Result, Offset, Cardinal(Count));
  for I := 0 to Count - 1 do
  begin
    WriteI64ToBytes(Result, Offset, Index[I].Offset);
    WriteI64ToBytes(Result, Offset, Index[I].StartUnixMs);
    Result[Offset] := Index[I].Flags; Inc(Offset);
  end;
  WriteU32ToBytes(Result, Offset, Crc32Update(0, Result, 0, Offset));
end;

function BuildFooter(TotalBlocks: Cardinal; DurationMs: Int64;
  LastBlockOffset, IndexOffset: UInt64; IndexCount: Cardinal): TBytes;
var
  Offset: Integer;
begin
  SetLength(Result, VMS_FOOTER_SIZE);
  Offset := 0;
  Move(VMS_MAGIC_FOOTER[0], Result[Offset], 4); Inc(Offset, 4);
  WriteU32ToBytes(Result, Offset, TotalBlocks);
  WriteI64ToBytes(Result, Offset, DurationMs);
  WriteU64ToBytes(Result, Offset, LastBlockOffset);
  WriteU64ToBytes(Result, Offset, IndexOffset);
  // IndexOffset = 0 significa "fechou sem índice"; a contagem acompanha, senão o
  // rodapé prometeria entradas que não existem.
  if IndexOffset = 0 then
    WriteU32ToBytes(Result, Offset, 0)
  else
    WriteU32ToBytes(Result, Offset, IndexCount);
  WriteU32ToBytes(Result, Offset, Crc32Update(0, Result, 0, Offset));
end;

{ TFileRecordingWriter }

constructor TFileRecordingWriter.Create(const AFilePath: string);
var
  Dir: string;
begin
  inherited Create;
  FFilePath := AFilePath;
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
  FSidecar := nil;
end;

destructor TFileRecordingWriter.Destroy;
begin
  if FSidecar <> nil then
  begin
    // Chegou aqui sem passar pelo Close: a gravação não fechou direito, então o
    // .vms não tem VIDX e o sidecar é o único índice dele. Fica.
    try
      FSidecar.Close(False);
    except
    end;
    FreeAndNil(FSidecar);
  end;
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
  // O instante de criação amarra o sidecar a ESTA gravação: um `.vms.idx` que
  // não case é de outro arquivo e será ignorado por quem ler.
  FSidecar := TSidecarWriter.Create(FFilePath, Header.CreationUnixMs);
end;

// Despeja no sidecar as entradas que ainda não estavam lá.
//
// ValidUpTo é o ponto de append do gravador: todo bloco antes dele está inteiro
// no disco, e é de lá que quem ler retoma a varredura para pegar o que veio
// depois deste lote.
procedure TFileRecordingWriter.FlushSidecar;
begin
  if FSidecar = nil then Exit;
  if not FSidecar.Ok then Exit;
  FSidecar.WriteBatch(FIndex, FIndexCount, FBytes);
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
  if (FSidecar <> nil) and
     (FIndexCount - FSidecar.Written >= VMS_SIDECAR_BATCH_BLOCKS) then
    FlushSidecar;
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
  StartOffset: UInt64;
begin
  Result := 0;
  if (FIndexCount = 0) or FIndexOverflow then Exit;
  Buf := BuildIndexChunk(FIndex, FIndexCount);
  if Length(Buf) = 0 then Exit;
  StartOffset := UInt64(FBytes);
  FStream.WriteBuffer(Buf[0], Length(Buf));
  Inc(FBytes, Length(Buf));
  Result := StartOffset;
end;

procedure TFileRecordingWriter.Close(WriteFooter: Boolean);
var
  Buf: TBytes;
  Duration: Int64;
  IndexOffset: UInt64;
  FooterOk: Boolean;
begin
  if FStream = nil then Exit;

  // Último lote antes de qualquer outra coisa: se o que vem abaixo falhar, o
  // sidecar sozinho ainda descreve o arquivo inteiro.
  FlushSidecar;

  IndexOffset := 0;
  FooterOk := False;
  if WriteFooter and FHeaderDone then
  begin
    // Índice primeiro, rodapé depois: é o rodapé que aponta para ele, e ele
    // precisa estar no fim para ser achado a partir do tamanho do arquivo.
    try
      IndexOffset := WriteIndexChunk;
    except
      IndexOffset := 0; // sem índice o arquivo continua válido; quem precisar varre
    end;

    Duration := 0;
    if (FFirstUnixMs > 0) and (FLastUnixMs >= FFirstUnixMs) then
      Duration := FLastUnixMs - FFirstUnixMs;
    Buf := BuildFooter(FBlocks, Duration, FLastBlockOffset, IndexOffset,
                       Cardinal(FIndexCount));
    try
      FStream.WriteBuffer(Buf[0], Length(Buf));
      Inc(FBytes, Length(Buf));
      FooterOk := True;
    except
    end;
  end;

  try
    FlushDisk;
  except
  end;

  // O sidecar só some quando o VIDX ficou no lugar dele E o rodapé apontando
  // para ele também entrou — é o rodapé que permite achá-lo. Fechamento torto
  // mantém o sidecar: é o que evita que aquele arquivo custe uma varredura para
  // sempre.
  if FSidecar <> nil then
  begin
    try
      FSidecar.Close(FooterOk and (IndexOffset <> 0));
    except
    end;
    FreeAndNil(FSidecar);
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

end.
