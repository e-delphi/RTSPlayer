unit VMS.Rec.Reader;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.StrUtils,
  VMS.Domain.Types,
  VMS.Rec.Format,
  VMS.Rec.Crc32;

type
  TVmsBlockIndexEntry = record
    Offset: Int64;
    BlockSeq: Cardinal;
    StartUnixMs: Int64;
  end;

  TVmsReader = class
  strict private
    FStream: TFileStream;
    FOwnsStream: Boolean;
    FHeader: TVmsHeader;
    FHeaderRead: Boolean;
    FLiveMode: Boolean;
    FLiveTimeoutMs: Cardinal;
    FFirstBlockOffset: Int64;
    FIndex: TArray<TVmsBlockIndexEntry>;
    FIndexBuilt: Boolean;
    function ReadU16(var Buf: TBytes; var Offset: Integer): Word;
    function ReadU32(var Buf: TBytes; var Offset: Integer): Cardinal;
    function ReadI64(var Buf: TBytes; var Offset: Integer): Int64;
    function PeekBlockMetaAt(Offset: Int64; out Magic: array of Byte; out BlockSize: Cardinal;
                             out BlockSeq: Cardinal; out StartUnixMs: Int64): Boolean;
    function WaitForBytes(Need: Int64): Boolean;
  public
    constructor Create(const FilePath: string);
    destructor Destroy; override;
    function ReadHeader: Boolean;
    function ReadNextBlock(out Block: TVmsBlock): Boolean;
    function AtEof: Boolean;
    procedure EnableLiveMode(TimeoutMs: Cardinal = 30000);
    procedure DisableLiveMode;
    function IsLiveMode: Boolean;
    function BuildIndex: Integer;
    function SeekToTime(WallClockMs: Int64): Boolean;
    function SeekToStart: Boolean;
    function CurrentBlockOffset: Int64;
    property Header: TVmsHeader read FHeader;
    property Index: TArray<TVmsBlockIndexEntry> read FIndex;
  end;

function FindMostRecentVmsForCamera(const RecordingsDir, CameraName: string): string;

implementation

{ TVmsReader }

constructor TVmsReader.Create(const FilePath: string);
begin
  inherited Create;
  FStream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  FOwnsStream := True;
  FHeaderRead := False;
end;

destructor TVmsReader.Destroy;
begin
  if FOwnsStream and (FStream <> nil) then
    FStream.Free;
  inherited;
end;

function TVmsReader.ReadU16(var Buf: TBytes; var Offset: Integer): Word;
begin
  Result := Word(Buf[Offset]) or (Word(Buf[Offset + 1]) shl 8);
  Inc(Offset, 2);
end;

function TVmsReader.ReadU32(var Buf: TBytes; var Offset: Integer): Cardinal;
begin
  Result := Cardinal(Buf[Offset]) or
           (Cardinal(Buf[Offset + 1]) shl 8) or
           (Cardinal(Buf[Offset + 2]) shl 16) or
           (Cardinal(Buf[Offset + 3]) shl 24);
  Inc(Offset, 4);
end;

function TVmsReader.ReadI64(var Buf: TBytes; var Offset: Integer): Int64;
var
  U: UInt64;
  K: Integer;
begin
  U := 0;
  for K := 0 to 7 do
    U := U or (UInt64(Buf[Offset + K]) shl (K * 8));
  Result := Int64(U);
  Inc(Offset, 8);
end;

function TVmsReader.ReadHeader: Boolean;
var
  Magic: array[0..3] of Byte;
  Version: Word;
  HeaderSize: Cardinal;
  Buf: TBytes;
  Offset: Integer;
  UriLen: Word;
  ExtraLen: Cardinal;
  PreambleLen: Integer;
begin
  Result := False;
  FStream.Position := 0;
  if FStream.Read(Magic[0], 4) <> 4 then Exit;
  if (Magic[0] <> VMS_MAGIC_FILE[0]) or (Magic[1] <> VMS_MAGIC_FILE[1])
     or (Magic[2] <> VMS_MAGIC_FILE[2]) or (Magic[3] <> VMS_MAGIC_FILE[3]) then Exit;

  SetLength(Buf, 6);
  if FStream.Read(Buf[0], 6) <> 6 then Exit;
  Offset := 0;
  Version := ReadU16(Buf, Offset);
  HeaderSize := ReadU32(Buf, Offset);
  FHeader.Version := Version;
  FHeader.HeaderSize := HeaderSize;

  PreambleLen := 4 + 6;
  if HeaderSize < Cardinal(PreambleLen) then Exit;
  SetLength(Buf, Integer(HeaderSize - Cardinal(PreambleLen)));
  if FStream.Read(Buf[0], Length(Buf)) <> Length(Buf) then Exit;
  Offset := 0;
  FHeader.CreationUnixMs := ReadI64(Buf, Offset);
  UriLen := ReadU16(Buf, Offset);
  if UriLen > 0 then
  begin
    FHeader.SourceUri := TEncoding.UTF8.GetString(Buf, Offset, UriLen);
    Inc(Offset, UriLen);
  end
  else
    FHeader.SourceUri := '';
  FHeader.VideoPresent := Buf[Offset] <> 0; Inc(Offset);
  FHeader.Video.Codec := TVideoCodec(Buf[Offset]); Inc(Offset);
  FHeader.Video.Timescale := ReadU32(Buf, Offset);
  FHeader.Video.Width := ReadU16(Buf, Offset);
  FHeader.Video.Height := ReadU16(Buf, Offset);
  ExtraLen := ReadU32(Buf, Offset);
  if ExtraLen > 0 then
  begin
    SetLength(FHeader.Video.Extradata, ExtraLen);
    Move(Buf[Offset], FHeader.Video.Extradata[0], ExtraLen);
    Inc(Offset, Integer(ExtraLen));
  end
  else
    SetLength(FHeader.Video.Extradata, 0);

  FHeader.AudioPresent := Buf[Offset] <> 0; Inc(Offset);
  FHeader.Audio.Codec := TAudioCodec(Buf[Offset]); Inc(Offset);
  FHeader.Audio.SampleRate := ReadU32(Buf, Offset);
  FHeader.Audio.Channels := Buf[Offset]; Inc(Offset);
  FHeader.Audio.BitsPerSample := Buf[Offset]; Inc(Offset);
  FHeader.Audio.Timescale := ReadU32(Buf, Offset);
  ExtraLen := ReadU32(Buf, Offset);
  if ExtraLen > 0 then
  begin
    SetLength(FHeader.Audio.Extradata, ExtraLen);
    Move(Buf[Offset], FHeader.Audio.Extradata[0], ExtraLen);
    Inc(Offset, Integer(ExtraLen));
  end
  else
    SetLength(FHeader.Audio.Extradata, 0);

  FHeaderRead := True;
  FFirstBlockOffset := FStream.Position;
  Result := True;
end;

function TVmsReader.WaitForBytes(Need: Int64): Boolean;
var
  Deadline: UInt64;
  CurSize, CurPos: Int64;
begin
  Result := False;
  CurPos := FStream.Position;
  if FStream.Size - CurPos >= Need then Exit(True);
  if not FLiveMode then Exit(False);
  Deadline := UInt64(TThread.GetTickCount64) + FLiveTimeoutMs;
  while UInt64(TThread.GetTickCount64) < Deadline do
  begin
    TThread.Sleep(100);
    CurSize := FStream.Size;
    if CurSize - CurPos >= Need then
      Exit(True);
  end;
end;

function TVmsReader.ReadNextBlock(out Block: TVmsBlock): Boolean;
var
  Magic: array[0..3] of Byte;
  BlockSize: Cardinal;
  Buf, RestBuf: TBytes;
  Offset, RemSize: Integer;
  SampleCount, IndexSize: Cardinal;
  Pos, Read: Int64;
  I: Integer;
  PayloadLen: Integer;
begin
  Result := False;
  if not FHeaderRead then Exit;
  Pos := FStream.Position;

  if FLiveMode then
  begin
    if not WaitForBytes(8) then Exit;
  end;

  Read := FStream.Read(Magic[0], 4);
  if Read < 4 then Exit;
  if (Magic[0] = VMS_MAGIC_FOOTER[0]) and (Magic[1] = VMS_MAGIC_FOOTER[1]) and
     (Magic[2] = VMS_MAGIC_FOOTER[2]) and (Magic[3] = VMS_MAGIC_FOOTER[3]) then
  begin
    FStream.Position := FStream.Size;
    Exit(False);
  end;
  if (Magic[0] <> VMS_MAGIC_BLOCK[0]) or (Magic[1] <> VMS_MAGIC_BLOCK[1])
     or (Magic[2] <> VMS_MAGIC_BLOCK[2]) or (Magic[3] <> VMS_MAGIC_BLOCK[3]) then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;
  SetLength(Buf, 4);
  if FStream.Read(Buf[0], 4) <> 4 then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;
  Offset := 0;
  BlockSize := ReadU32(Buf, Offset);
  if BlockSize < 28 then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;
  RemSize := Integer(BlockSize) - 8;
  if FLiveMode then
    if not WaitForBytes(RemSize) then
    begin
      FStream.Position := Pos;
      Exit(False);
    end;
  SetLength(RestBuf, RemSize);
  if FStream.Read(RestBuf[0], RemSize) <> RemSize then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;

  Offset := 0;
  Block.BlockSeq := ReadU32(RestBuf, Offset);
  Block.StartUnixMs := ReadI64(RestBuf, Offset);
  SampleCount := ReadU32(RestBuf, Offset);
  IndexSize := ReadU32(RestBuf, Offset);

  SetLength(Block.Samples, SampleCount);
  for I := 0 to Integer(SampleCount) - 1 do
  begin
    Block.Samples[I].TrackId := RestBuf[Offset]; Inc(Offset);
    Block.Samples[I].FlagsByte := RestBuf[Offset]; Inc(Offset);
    Block.Samples[I].Pts := ReadI64(RestBuf, Offset);
    Block.Samples[I].PayloadOffset := ReadU32(RestBuf, Offset);
    Block.Samples[I].PayloadSize := ReadU32(RestBuf, Offset);
  end;

  PayloadLen := RemSize - 4 - 16 - Integer(IndexSize);
  if PayloadLen < 0 then Exit;
  SetLength(Block.Payload, PayloadLen);
  if PayloadLen > 0 then
    Move(RestBuf[Offset], Block.Payload[0], PayloadLen);
  Result := True;
end;

function TVmsReader.AtEof: Boolean;
begin
  Result := FStream.Position >= FStream.Size;
end;

procedure TVmsReader.EnableLiveMode(TimeoutMs: Cardinal);
begin
  FLiveMode := True;
  FLiveTimeoutMs := TimeoutMs;
end;

procedure TVmsReader.DisableLiveMode;
begin
  FLiveMode := False;
end;

function TVmsReader.IsLiveMode: Boolean;
begin
  Result := FLiveMode;
end;

function TVmsReader.CurrentBlockOffset: Int64;
begin
  Result := FStream.Position;
end;

function TVmsReader.PeekBlockMetaAt(Offset: Int64; out Magic: array of Byte;
  out BlockSize: Cardinal; out BlockSeq: Cardinal; out StartUnixMs: Int64): Boolean;
var
  Buf: TBytes;
  K: Integer;
  U: UInt64;
begin
  Result := False;
  BlockSize := 0;
  BlockSeq := 0;
  StartUnixMs := 0;
  if Offset + 20 > FStream.Size then Exit;
  FStream.Position := Offset;
  SetLength(Buf, 4);
  if FStream.Read(Buf[0], 4) <> 4 then Exit;
  for K := 0 to 3 do Magic[K] := Buf[K];
  SetLength(Buf, 16);
  if FStream.Read(Buf[0], 16) <> 16 then Exit;
  BlockSize := Cardinal(Buf[0]) or (Cardinal(Buf[1]) shl 8) or
               (Cardinal(Buf[2]) shl 16) or (Cardinal(Buf[3]) shl 24);
  BlockSeq := Cardinal(Buf[4]) or (Cardinal(Buf[5]) shl 8) or
              (Cardinal(Buf[6]) shl 16) or (Cardinal(Buf[7]) shl 24);
  U := 0;
  for K := 0 to 7 do U := U or (UInt64(Buf[8 + K]) shl (K * 8));
  StartUnixMs := Int64(U);
  Result := True;
end;

function TVmsReader.BuildIndex: Integer;
var
  Offset, SavedPos: Int64;
  Magic: array[0..3] of Byte;
  BlockSize: Cardinal;
  BlockSeq: Cardinal;
  StartUnixMs: Int64;
  Tmp: TArray<TVmsBlockIndexEntry>;
  Count: Integer;
begin
  SavedPos := FStream.Position;
  Count := 0;
  SetLength(Tmp, 64);
  Offset := FFirstBlockOffset;
  if Offset <= 0 then
  begin
    FStream.Position := SavedPos;
    Exit(0);
  end;
  while Offset + 20 <= FStream.Size do
  begin
    if not PeekBlockMetaAt(Offset, Magic, BlockSize, BlockSeq, StartUnixMs) then Break;
    if (Magic[0] = VMS_MAGIC_FOOTER[0]) and (Magic[1] = VMS_MAGIC_FOOTER[1]) and
       (Magic[2] = VMS_MAGIC_FOOTER[2]) and (Magic[3] = VMS_MAGIC_FOOTER[3]) then
      Break;
    if (Magic[0] <> VMS_MAGIC_BLOCK[0]) or (Magic[1] <> VMS_MAGIC_BLOCK[1]) or
       (Magic[2] <> VMS_MAGIC_BLOCK[2]) or (Magic[3] <> VMS_MAGIC_BLOCK[3]) then Break;
    if BlockSize < 28 then Break;
    if Count >= Length(Tmp) then SetLength(Tmp, Length(Tmp) * 2);
    Tmp[Count].Offset := Offset;
    Tmp[Count].BlockSeq := BlockSeq;
    Tmp[Count].StartUnixMs := StartUnixMs;
    Inc(Count);
    Inc(Offset, BlockSize);
  end;
  FIndex := Copy(Tmp, 0, Count);
  FIndexBuilt := True;
  FStream.Position := SavedPos;
  Result := Count;
end;

function TVmsReader.SeekToTime(WallClockMs: Int64): Boolean;
var
  I, Best: Integer;
begin
  Result := False;
  if not FIndexBuilt then BuildIndex;
  if Length(FIndex) = 0 then Exit;
  Best := 0;
  for I := 0 to High(FIndex) do
  begin
    if FIndex[I].StartUnixMs <= WallClockMs then
      Best := I
    else
      Break;
  end;
  FStream.Position := FIndex[Best].Offset;
  Result := True;
end;

function TVmsReader.SeekToStart: Boolean;
begin
  Result := False;
  if FFirstBlockOffset <= 0 then Exit;
  FStream.Position := FFirstBlockOffset;
  Result := True;
end;

function FindMostRecentVmsForCamera(const RecordingsDir, CameraName: string): string;
var
  Files: TArray<string>;
  I: Integer;
  BestTime, T: TDateTime;
  Prefix: string;
  BaseName: string;
begin
  Result := '';
  if not DirectoryExists(RecordingsDir) then Exit;
  Prefix := CameraName + '_';
  Files := TDirectory.GetFiles(RecordingsDir, CameraName + '_*.vms');
  BestTime := 0;
  for I := 0 to High(Files) do
  begin
    BaseName := ExtractFileName(Files[I]);
    if not StartsText(Prefix, BaseName) then Continue;
    T := TFile.GetLastWriteTime(Files[I]);
    if T > BestTime then
    begin
      BestTime := T;
      Result := Files[I];
    end;
  end;
end;

end.
