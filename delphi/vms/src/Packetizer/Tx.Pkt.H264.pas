unit Tx.Pkt.H264;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Base;

const
  H264_FUA_TYPE = 28;

type
  TH264Packetizer = class(TBasePacketizer)
  strict private
    procedure SendSingle(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
    procedure SendFuA(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
  public
    function Kind: TTrackKind; override;
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean); override;
  end;

function SplitAnnexBNals(const Data: TBytes): TArray<TBytes>;

implementation

function SplitAnnexBNals(const Data: TBytes): TArray<TBytes>;
var
  I, NalStart, Count: Integer;
  Tmp: TArray<TBytes>;
  NalBytes: TBytes;

  function StartCodeAt(P: Integer): Integer;
  begin
    if (P + 3 < Length(Data)) and (Data[P] = 0) and (Data[P+1] = 0) and (Data[P+2] = 0) and (Data[P+3] = 1) then
      Exit(4);
    if (P + 2 < Length(Data)) and (Data[P] = 0) and (Data[P+1] = 0) and (Data[P+2] = 1) then
      Exit(3);
    Result := 0;
  end;

var
  Sk: Integer;
begin
  Result := nil;
  Count := 0;
  SetLength(Tmp, 4);
  I := 0;
  NalStart := -1;
  while I < Length(Data) do
  begin
    Sk := StartCodeAt(I);
    if Sk > 0 then
    begin
      if NalStart >= 0 then
      begin
        SetLength(NalBytes, I - NalStart);
        if I - NalStart > 0 then
          Move(Data[NalStart], NalBytes[0], I - NalStart);
        if Count >= Length(Tmp) then
          SetLength(Tmp, Length(Tmp) * 2);
        Tmp[Count] := NalBytes;
        Inc(Count);
      end;
      Inc(I, Sk);
      NalStart := I;
    end
    else
      Inc(I);
  end;
  if (NalStart >= 0) and (NalStart < Length(Data)) then
  begin
    SetLength(NalBytes, Length(Data) - NalStart);
    Move(Data[NalStart], NalBytes[0], Length(Data) - NalStart);
    if Count >= Length(Tmp) then
      SetLength(Tmp, Length(Tmp) * 2);
    Tmp[Count] := NalBytes;
    Inc(Count);
  end;
  Result := Copy(Tmp, 0, Count);
end;

{ TH264Packetizer }

function TH264Packetizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TH264Packetizer.SendSingle(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
begin
  EmitRtp(Marker, Ts, Nal);
end;

procedure TH264Packetizer.SendFuA(const Nal: TBytes; Ts: Cardinal; Marker: Boolean);
var
  NalHdr: Byte;
  NalType, Nri: Byte;
  Offset, ChunkSize, MaxPayload: Integer;
  Payload: TBytes;
  IsStart, IsEnd: Boolean;
  FuIndicator, FuHeader: Byte;
begin
  if Length(Nal) < 2 then Exit;
  NalHdr := Nal[0];
  NalType := NalHdr and $1F;
  Nri := NalHdr and $60;

  FuIndicator := (NalHdr and $80) or Nri or H264_FUA_TYPE;
  MaxPayload := FMtu - 2;
  if MaxPayload < 1 then Exit;

  Offset := 1;
  while Offset < Length(Nal) do
  begin
    ChunkSize := Length(Nal) - Offset;
    if ChunkSize > MaxPayload then ChunkSize := MaxPayload;
    IsStart := Offset = 1;
    IsEnd := (Offset + ChunkSize) >= Length(Nal);
    FuHeader := NalType;
    if IsStart then FuHeader := FuHeader or $80;
    if IsEnd   then FuHeader := FuHeader or $40;

    SetLength(Payload, 2 + ChunkSize);
    Payload[0] := FuIndicator;
    Payload[1] := FuHeader;
    Move(Nal[Offset], Payload[2], ChunkSize);

    EmitRtp(IsEnd and Marker, Ts, Payload);
    Inc(Offset, ChunkSize);
  end;
end;

procedure TH264Packetizer.PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean);
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
      SendFuA(Nals[I], Ts, Marker);
  end;
end;

end.
