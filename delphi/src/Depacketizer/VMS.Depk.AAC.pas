unit VMS.Depk.AAC;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

type
  TAacDepacketizer = class(TBaseDepacketizer)
  strict private
    FSizeLength: Integer;
    FIndexLength: Integer;
    FIndexDeltaLength: Integer;
  public
    constructor Create; reintroduce;
    function Kind: TTrackKind; override;
    procedure SetMode(SizeLength, IndexLength, IndexDeltaLength: Integer);
    procedure Feed(const Packet: TRtpPacket); override;
  end;

implementation

{ TAacDepacketizer }

constructor TAacDepacketizer.Create;
begin
  inherited Create;
  FSizeLength := 13;
  FIndexLength := 3;
  FIndexDeltaLength := 3;
end;

function TAacDepacketizer.Kind: TTrackKind;
begin
  Result := tkAudio;
end;

procedure TAacDepacketizer.SetMode(SizeLength, IndexLength, IndexDeltaLength: Integer);
begin
  if SizeLength > 0 then FSizeLength := SizeLength;
  if IndexLength >= 0 then FIndexLength := IndexLength;
  if IndexDeltaLength >= 0 then FIndexDeltaLength := IndexDeltaLength;
end;

function ReadBits(const Buf: TBytes; BitOffset: Integer; BitCount: Integer): Cardinal;
var
  I, ByteIdx, BitIdx: Integer;
  Bit: Cardinal;
begin
  Result := 0;
  for I := 0 to BitCount - 1 do
  begin
    ByteIdx := (BitOffset + I) shr 3;
    BitIdx := 7 - ((BitOffset + I) and 7);
    if ByteIdx >= Length(Buf) then Exit;
    Bit := (Cardinal(Buf[ByteIdx]) shr BitIdx) and 1;
    Result := (Result shl 1) or Bit;
  end;
end;

procedure TAacDepacketizer.Feed(const Packet: TRtpPacket);
var
  P: TBytes;
  HeadersBits, HeaderSize, PerHeaderBits, NumAUs: Integer;
  AuSizes: array of Integer;
  AuDataOffset, I: Integer;
  HeaderBitOffset: Integer;
  AuStart: Integer;
  AuLen: Integer;
  Sample: TBytes;
begin
  P := Packet.Payload;
  if Length(P) < 2 then Exit;
  HeadersBits := (Integer(P[0]) shl 8) or P[1];
  HeaderSize := (HeadersBits + 7) div 8;
  if 2 + HeaderSize > Length(P) then Exit;

  PerHeaderBits := FSizeLength + FIndexLength;
  if PerHeaderBits <= 0 then Exit;
  NumAUs := HeadersBits div PerHeaderBits;
  if NumAUs <= 0 then Exit;

  SetLength(AuSizes, NumAUs);
  HeaderBitOffset := 2 * 8;
  for I := 0 to NumAUs - 1 do
  begin
    AuSizes[I] := Integer(ReadBits(P, HeaderBitOffset, FSizeLength));
    if I = 0 then
      Inc(HeaderBitOffset, FSizeLength + FIndexLength)
    else
      Inc(HeaderBitOffset, FSizeLength + FIndexDeltaLength);
  end;

  AuDataOffset := 2 + HeaderSize;
  AuStart := AuDataOffset;
  for I := 0 to NumAUs - 1 do
  begin
    AuLen := AuSizes[I];
    if AuLen <= 0 then Continue;
    if AuStart + AuLen > Length(P) then Break;
    SetLength(Sample, AuLen);
    Move(P[AuStart], Sample[0], AuLen);
    Emit(tkAudio, Packet.Timestamp + Int64(I * 1024), [], Sample);
    Inc(AuStart, AuLen);
  end;
end;

end.
