unit Tx.Pkt.MJPEG;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Base;

type
  TJpegMeta = record
    Width: Word;
    Height: Word;
    JpegType: Byte;
    RestartInterval: Word;
    HasRestart: Boolean;
    QTables: TBytes;
    DataOffset: Integer;
    DataEnd: Integer;
    Valid: Boolean;
  end;

  TMjpegPacketizer = class(TBasePacketizer)
  strict private
    function ParseJpeg(const Data: TBytes; out Meta: TJpegMeta): Boolean;
    function ReadU16BE(const Data: TBytes; Offset: Integer): Word;
  public
    function Kind: TTrackKind; override;
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean); override;
  end;

implementation

{ TMjpegPacketizer }

function TMjpegPacketizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

function TMjpegPacketizer.ReadU16BE(const Data: TBytes; Offset: Integer): Word;
begin
  Result := (Word(Data[Offset]) shl 8) or Word(Data[Offset + 1]);
end;

function TMjpegPacketizer.ParseJpeg(const Data: TBytes; out Meta: TJpegMeta): Boolean;
var
  P, SegLen, NumTables, TableStart, K, Components, YSampling, NumComponents: Integer;
  Marker: Byte;
  Pq, Tq: Byte;
  TableData: TBytes;
  Hi, Lo: Byte;
begin
  FillChar(Meta, SizeOf(Meta), 0);
  Result := False;
  if Length(Data) < 4 then Exit;
  if (Data[0] <> $FF) or (Data[1] <> $D8) then Exit;
  P := 2;
  while P + 1 < Length(Data) do
  begin
    if Data[P] <> $FF then Exit;
    Marker := Data[P + 1];
    Inc(P, 2);
    while (P < Length(Data)) and (Marker = $FF) do
    begin
      Marker := Data[P];
      Inc(P);
    end;
    if Marker = $D8 then Continue;
    if Marker = $D9 then Break;
    if (Marker >= $D0) and (Marker <= $D7) then Continue;
    if Marker = $01 then Continue;

    if P + 2 > Length(Data) then Exit;
    SegLen := ReadU16BE(Data, P);
    if (SegLen < 2) or (P + SegLen > Length(Data)) then Exit;

    case Marker of
      $DB:
        begin
          NumTables := (SegLen - 2) div 65;
          TableStart := P + 2;
          for K := 0 to NumTables - 1 do
          begin
            if TableStart + 64 >= Length(Data) then Break;
            Pq := (Data[TableStart] shr 4) and $0F;
            Tq := Data[TableStart] and $0F;
            if Pq <> 0 then Exit;
            Inc(TableStart);
            SetLength(TableData, 64);
            Move(Data[TableStart], TableData[0], 64);
            Inc(TableStart, 64);
            SetLength(Meta.QTables, Length(Meta.QTables) + 64);
            Move(TableData[0], Meta.QTables[Length(Meta.QTables) - 64], 64);
            if Tq = 0 then ;
          end;
        end;
      $DD:
        begin
          if SegLen <> 4 then Exit;
          Meta.RestartInterval := ReadU16BE(Data, P + 2);
          Meta.HasRestart := Meta.RestartInterval > 0;
        end;
      $C0:
        begin
          if SegLen < 8 then Exit;
          Meta.Height := ReadU16BE(Data, P + 3);
          Meta.Width := ReadU16BE(Data, P + 5);
          NumComponents := Data[P + 7];
          YSampling := $11;
          if NumComponents >= 1 then
            YSampling := Data[P + 9];
          Components := NumComponents;
          Hi := (YSampling shr 4) and $0F;
          Lo := YSampling and $0F;
          if (Hi = 2) and (Lo = 2) then
            Meta.JpegType := 1
          else
            Meta.JpegType := 0;
          if Components <> 0 then ;
        end;
      $DA:
        begin
          Meta.DataOffset := P + SegLen;
          Meta.DataEnd := Length(Data);
          for K := Length(Data) - 1 downto Meta.DataOffset do
          begin
            if (K + 1 < Length(Data)) and (Data[K] = $FF) and (Data[K + 1] = $D9) then
            begin
              Meta.DataEnd := K;
              Break;
            end;
          end;
          Meta.Valid := True;
          if Meta.HasRestart then
            Meta.JpegType := Meta.JpegType or $40;
          Exit(True);
        end;
    end;
    Inc(P, SegLen);
  end;
end;

procedure TMjpegPacketizer.PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean);
var
  Meta: TJpegMeta;
  FragOffset: Cardinal;
  EntropyLen, BytesPerPacket, MaxPayloadBody, ExtraHdr, QtHdrLen: Integer;
  Payload: TBytes;
  PayloadIdx, Remaining: Integer;
  Ts: Cardinal;
  Marker: Boolean;
  W8, H8: Byte;
begin
  if not ParseJpeg(Data, Meta) then Exit;
  if not Meta.Valid then Exit;
  if Meta.DataEnd <= Meta.DataOffset then Exit;
  EntropyLen := Meta.DataEnd - Meta.DataOffset;
  W8 := Byte(Meta.Width div 8);
  H8 := Byte(Meta.Height div 8);
  Ts := Cardinal(Pts);

  FragOffset := 0;
  Remaining := EntropyLen;
  while Remaining > 0 do
  begin
    ExtraHdr := 0;
    if Meta.HasRestart then ExtraHdr := ExtraHdr + 4;
    QtHdrLen := 0;
    if (FragOffset = 0) and (Length(Meta.QTables) > 0) then
      QtHdrLen := 4 + Length(Meta.QTables);

    MaxPayloadBody := FMtu - 8 - ExtraHdr - QtHdrLen;
    if MaxPayloadBody < 64 then Exit;

    BytesPerPacket := Remaining;
    if BytesPerPacket > MaxPayloadBody then BytesPerPacket := MaxPayloadBody;

    SetLength(Payload, 8 + ExtraHdr + QtHdrLen + BytesPerPacket);
    PayloadIdx := 0;
    Payload[PayloadIdx] := 0; Inc(PayloadIdx);
    Payload[PayloadIdx] := Byte((FragOffset shr 16) and $FF); Inc(PayloadIdx);
    Payload[PayloadIdx] := Byte((FragOffset shr 8) and $FF);  Inc(PayloadIdx);
    Payload[PayloadIdx] := Byte(FragOffset and $FF);          Inc(PayloadIdx);
    Payload[PayloadIdx] := Meta.JpegType; Inc(PayloadIdx);
    Payload[PayloadIdx] := 255;           Inc(PayloadIdx);
    Payload[PayloadIdx] := W8;            Inc(PayloadIdx);
    Payload[PayloadIdx] := H8;            Inc(PayloadIdx);

    if Meta.HasRestart then
    begin
      Payload[PayloadIdx] := Byte((Meta.RestartInterval shr 8) and $FF); Inc(PayloadIdx);
      Payload[PayloadIdx] := Byte(Meta.RestartInterval and $FF);        Inc(PayloadIdx);
      Payload[PayloadIdx] := $FF; Inc(PayloadIdx);
      Payload[PayloadIdx] := $FF; Inc(PayloadIdx);
    end;

    if QtHdrLen > 0 then
    begin
      Payload[PayloadIdx] := 0; Inc(PayloadIdx);
      Payload[PayloadIdx] := 0; Inc(PayloadIdx);
      Payload[PayloadIdx] := Byte((Length(Meta.QTables) shr 8) and $FF); Inc(PayloadIdx);
      Payload[PayloadIdx] := Byte(Length(Meta.QTables) and $FF);        Inc(PayloadIdx);
      Move(Meta.QTables[0], Payload[PayloadIdx], Length(Meta.QTables));
      Inc(PayloadIdx, Length(Meta.QTables));
    end;

    Move(Data[Meta.DataOffset + Integer(FragOffset)], Payload[PayloadIdx], BytesPerPacket);

    Inc(FragOffset, Cardinal(BytesPerPacket));
    Dec(Remaining, BytesPerPacket);
    Marker := Remaining = 0;
    EmitRtp(Marker, Ts, Payload);
  end;
end;

end.
