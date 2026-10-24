unit VMS.Rtp.Packet;

interface

uses
  System.SysUtils,
  VMS.Domain.Types;

type
  TRtpPacket = record
    Version: Byte;
    Padding: Boolean;
    Extension: Boolean;
    CC: Byte;
    Marker: Boolean;
    PayloadType: Byte;
    SequenceNumber: Word;
    Timestamp: Cardinal;
    Ssrc: Cardinal;
    Csrc: array of Cardinal;
    ExtensionProfile: Word;
    ExtensionData: TBytes;
    Payload: TBytes;
  end;

function ParseRtpPacket(const Buffer: TBytes; Size: Integer; out Packet: TRtpPacket): Boolean; overload;
function ParseRtpPacket(Buffer: PByte; Size: Integer; out Packet: TRtpPacket): Boolean; overload;

implementation

function ReadU16(P: PByte): Word; inline;
begin
  Result := (Word(P[0]) shl 8) or Word(P[1]);
end;

function ReadU32(P: PByte): Cardinal; inline;
begin
  Result := (Cardinal(P[0]) shl 24) or (Cardinal(P[1]) shl 16) or
            (Cardinal(P[2]) shl 8)  or Cardinal(P[3]);
end;

function ParseRtpPacket(const Buffer: TBytes; Size: Integer; out Packet: TRtpPacket): Boolean;
begin
  if Size <= 0 then
  begin
    FillChar(Packet, SizeOf(Packet), 0);
    Exit(False);
  end;
  Result := ParseRtpPacket(@Buffer[0], Size, Packet);
end;

function ParseRtpPacket(Buffer: PByte; Size: Integer; out Packet: TRtpPacket): Boolean;
var
  B0, B1: Byte;
  Offset, ExtLen, PayloadLen, I: Integer;
  PaddingLen: Byte;
begin
  Result := False;
  FillChar(Packet, SizeOf(Packet), 0);
  if Size < 12 then Exit;
  B0 := Buffer[0];
  B1 := Buffer[1];
  Packet.Version := (B0 shr 6) and $03;
  if Packet.Version <> 2 then Exit;
  Packet.Padding := (B0 and $20) <> 0;
  Packet.Extension := (B0 and $10) <> 0;
  Packet.CC := B0 and $0F;
  Packet.Marker := (B1 and $80) <> 0;
  Packet.PayloadType := B1 and $7F;
  Packet.SequenceNumber := ReadU16(@Buffer[2]);
  Packet.Timestamp := ReadU32(@Buffer[4]);
  Packet.Ssrc := ReadU32(@Buffer[8]);
  Offset := 12;
  if Packet.CC > 0 then
  begin
    if Size < Offset + Integer(Packet.CC) * 4 then Exit;
    SetLength(Packet.Csrc, Packet.CC);
    for I := 0 to Packet.CC - 1 do
    begin
      Packet.Csrc[I] := ReadU32(@Buffer[Offset]);
      Inc(Offset, 4);
    end;
  end;
  if Packet.Extension then
  begin
    if Size < Offset + 4 then Exit;
    Packet.ExtensionProfile := ReadU16(@Buffer[Offset]);
    ExtLen := ReadU16(@Buffer[Offset + 2]) * 4;
    Inc(Offset, 4);
    if Size < Offset + ExtLen then Exit;
    SetLength(Packet.ExtensionData, ExtLen);
    if ExtLen > 0 then
      Move(Buffer[Offset], Packet.ExtensionData[0], ExtLen);
    Inc(Offset, ExtLen);
  end;
  PayloadLen := Size - Offset;
  if Packet.Padding then
  begin
    if PayloadLen < 1 then Exit;
    PaddingLen := Buffer[Size - 1];
    if PaddingLen > PayloadLen then Exit;
    Dec(PayloadLen, PaddingLen);
  end;
  if PayloadLen < 0 then Exit;
  SetLength(Packet.Payload, PayloadLen);
  if PayloadLen > 0 then
    Move(Buffer[Offset], Packet.Payload[0], PayloadLen);
  Result := True;
end;

end.
