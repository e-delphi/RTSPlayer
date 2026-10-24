unit Tx.Pkt.H265;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Base,
  Tx.Pkt.H264;

const
  H265_FU_TYPE = 49;

type
  TH265Packetizer = class(TBasePacketizer)
  strict private
    procedure SendSingle(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
    procedure SendFu(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
  public
    function Kind: TTrackKind; override;
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean); override;
  end;

implementation

function TH265Packetizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TH265Packetizer.SendSingle(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
begin
  EmitRtp(Marker, Ts, Nal);
end;

procedure TH265Packetizer.SendFu(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
var
  PayloadHdr0, PayloadHdr1: Byte;
  NalType: Byte;
  Offset, ChunkSize, MaxPayload: Integer;
  Payload: TBytes;
  IsStart, IsEnd: Boolean;
  FuHeader, NewPayloadHdr0: Byte;
begin
  if Length(Nal) < 3 then Exit;
  PayloadHdr0 := Nal[0];
  PayloadHdr1 := Nal[1];
  NalType := (PayloadHdr0 shr 1) and $3F;
  NewPayloadHdr0 := (PayloadHdr0 and $81) or (H265_FU_TYPE shl 1);

  MaxPayload := FMtu - 3;
  if MaxPayload < 1 then Exit;

  Offset := 2;
  while Offset < Length(Nal) do
  begin
    ChunkSize := Length(Nal) - Offset;
    if ChunkSize > MaxPayload then ChunkSize := MaxPayload;
    IsStart := Offset = 2;
    IsEnd := (Offset + ChunkSize) >= Length(Nal);
    FuHeader := NalType;
    if IsStart then FuHeader := FuHeader or $80;
    if IsEnd   then FuHeader := FuHeader or $40;

    SetLength(Payload, 3 + ChunkSize);
    Payload[0] := NewPayloadHdr0;
    Payload[1] := PayloadHdr1;
    Payload[2] := FuHeader;
    Move(Nal[Offset], Payload[3], ChunkSize);

    EmitRtp(IsEnd and Marker, Ts, Payload);
    Inc(Offset, ChunkSize);
  end;
end;

procedure TH265Packetizer.PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean);
var
  Nals: TArray<TBytes>;
  I: Integer;
  Marker: Boolean;
  Ts: Cardinal;
begin
  Nals := SplitAnnexBNals(Data);
  if Length(Nals) = 0 then Exit;
  Ts := Cardinal(Pts);
  for I := 0 to High(Nals) do
  begin
    Marker := I = High(Nals);
    if Length(Nals[I]) <= FMtu then
      SendSingle(Nals[I], Ts, Marker)
    else
      SendFu(Nals[I], Ts, Marker);
  end;
end;

end.
