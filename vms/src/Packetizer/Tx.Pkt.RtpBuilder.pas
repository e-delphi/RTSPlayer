unit Tx.Pkt.RtpBuilder;

interface

uses
  System.SysUtils;

type
  TRtpOutPacket = record
    Version: Byte;
    Padding: Boolean;
    Extension: Boolean;
    CC: Byte;
    Marker: Boolean;
    PayloadType: Byte;
    SequenceNumber: Word;
    Timestamp: Cardinal;
    Ssrc: Cardinal;
    Payload: TBytes;
  end;

function SerializeRtp(const Packet: TRtpOutPacket): TBytes;
function BuildInterleavedFrame(Channel: Byte; const RtpBytes: TBytes): TBytes;

implementation

procedure WriteU16BE(var Buf: TBytes; Offset: Integer; V: Word); inline;
begin
  Buf[Offset]     := Byte((V shr 8) and $FF);
  Buf[Offset + 1] := Byte(V and $FF);
end;

procedure WriteU32BE(var Buf: TBytes; Offset: Integer; V: Cardinal); inline;
begin
  Buf[Offset]     := Byte((V shr 24) and $FF);
  Buf[Offset + 1] := Byte((V shr 16) and $FF);
  Buf[Offset + 2] := Byte((V shr 8) and $FF);
  Buf[Offset + 3] := Byte(V and $FF);
end;

function SerializeRtp(const Packet: TRtpOutPacket): TBytes;
var
  HeaderLen, TotalLen: Integer;
  B0, B1: Byte;
begin
  HeaderLen := 12;
  TotalLen := HeaderLen + Length(Packet.Payload);
  SetLength(Result, TotalLen);

  B0 := ((Packet.Version and $03) shl 6);
  if Packet.Padding then B0 := B0 or $20;
  if Packet.Extension then B0 := B0 or $10;
  B0 := B0 or (Packet.CC and $0F);

  B1 := Packet.PayloadType and $7F;
  if Packet.Marker then B1 := B1 or $80;

  Result[0] := B0;
  Result[1] := B1;
  WriteU16BE(Result, 2, Packet.SequenceNumber);
  WriteU32BE(Result, 4, Packet.Timestamp);
  WriteU32BE(Result, 8, Packet.Ssrc);
  if Length(Packet.Payload) > 0 then
    Move(Packet.Payload[0], Result[HeaderLen], Length(Packet.Payload));
end;

function BuildInterleavedFrame(Channel: Byte; const RtpBytes: TBytes): TBytes;
var
  Len: Word;
begin
  Len := Word(Length(RtpBytes));
  SetLength(Result, 4 + Len);
  Result[0] := $24;
  Result[1] := Channel;
  Result[2] := Byte((Len shr 8) and $FF);
  Result[3] := Byte(Len and $FF);
  if Len > 0 then
    Move(RtpBytes[0], Result[4], Len);
end;

end.
