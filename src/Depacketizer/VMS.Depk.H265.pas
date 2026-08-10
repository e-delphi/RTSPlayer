unit VMS.Depk.H265;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

const
  H265_NAL_TYPE_AP = 48;
  H265_NAL_TYPE_FU = 49;

  H265_NAL_TYPE_BLA_W_LP   = 16;
  H265_NAL_TYPE_BLA_W_RADL = 17;
  H265_NAL_TYPE_BLA_N_LP   = 18;
  H265_NAL_TYPE_IDR_W_RADL = 19;
  H265_NAL_TYPE_IDR_N_LP   = 20;
  H265_NAL_TYPE_CRA_NUT    = 21;

type
  TH265Depacketizer = class(TBaseDepacketizer)
  strict private
    FFuBuffer: TBytes;
    FFuStarted: Boolean;
    FFuOriginalHeader0: Byte;
    FFuOriginalHeader1: Byte;
    FCurrentPts: Int64;
    procedure EmitNal(const Nal: TBytes; Pts: Int64);
    procedure HandleSingleNal(const Payload: TBytes; Pts: Int64);
    procedure HandleAp(const Payload: TBytes; Pts: Int64);
    procedure HandleFu(const Payload: TBytes; Marker: Boolean; Pts: Int64);
    function NalIsKeyframe(NalType: Byte): Boolean;
  public
    function Kind: TTrackKind; override;
    procedure Feed(const Packet: TRtpPacket); override;
    procedure Reset; override;
  end;

implementation

const
  ANNEXB_PREFIX: array[0..3] of Byte = ($00, $00, $00, $01);

function AnnexBWrap(const Nal: TBytes): TBytes;
begin
  if Length(Nal) = 0 then Exit(nil);
  SetLength(Result, 4 + Length(Nal));
  Move(ANNEXB_PREFIX[0], Result[0], 4);
  Move(Nal[0], Result[4], Length(Nal));
end;

{ TH265Depacketizer }

function TH265Depacketizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TH265Depacketizer.Reset;
begin
  inherited;
  SetLength(FFuBuffer, 0);
  FFuStarted := False;
  FFuOriginalHeader0 := 0;
  FFuOriginalHeader1 := 0;
  FCurrentPts := 0;
end;

function TH265Depacketizer.NalIsKeyframe(NalType: Byte): Boolean;
begin
  Result := (NalType >= H265_NAL_TYPE_BLA_W_LP) and (NalType <= H265_NAL_TYPE_CRA_NUT);
end;

procedure TH265Depacketizer.EmitNal(const Nal: TBytes; Pts: Int64);
var
  NalType: Byte;
  Flags: TSampleFlags;
  Data: TBytes;
begin
  if Length(Nal) < 2 then Exit;
  NalType := (Nal[0] shr 1) and $3F;
  Flags := [];
  if NalIsKeyframe(NalType) then
    Include(Flags, sfKeyframe);
  Data := AnnexBWrap(Nal);
  Emit(tkVideo, Pts, Flags, Data);
end;

procedure TH265Depacketizer.HandleSingleNal(const Payload: TBytes; Pts: Int64);
begin
  EmitNal(Payload, Pts);
end;

procedure TH265Depacketizer.HandleAp(const Payload: TBytes; Pts: Int64);
var
  Offset: Integer;
  NalLen: Word;
  Nal: TBytes;
begin
  Offset := 2;
  while Offset + 2 <= Length(Payload) do
  begin
    NalLen := (Word(Payload[Offset]) shl 8) or Word(Payload[Offset + 1]);
    Inc(Offset, 2);
    if NalLen = 0 then Continue;
    if Offset + NalLen > Length(Payload) then Break;
    SetLength(Nal, NalLen);
    Move(Payload[Offset], Nal[0], NalLen);
    Inc(Offset, NalLen);
    EmitNal(Nal, Pts);
  end;
end;

procedure TH265Depacketizer.HandleFu(const Payload: TBytes; Marker: Boolean; Pts: Int64);
var
  PayloadHdr0, PayloadHdr1, FuHeader: Byte;
  IsStart, IsEnd: Boolean;
  FuType: Byte;
  StartIdx: Integer;
begin
  if Length(Payload) < 3 then Exit;
  PayloadHdr0 := Payload[0];
  PayloadHdr1 := Payload[1];
  FuHeader := Payload[2];
  IsStart := (FuHeader and $80) <> 0;
  IsEnd := (FuHeader and $40) <> 0;
  FuType := FuHeader and $3F;
  if IsStart then
  begin
    FFuStarted := True;
    FFuOriginalHeader0 := (PayloadHdr0 and $81) or (FuType shl 1);
    FFuOriginalHeader1 := PayloadHdr1;
    SetLength(FFuBuffer, 2);
    FFuBuffer[0] := FFuOriginalHeader0;
    FFuBuffer[1] := FFuOriginalHeader1;
    FCurrentPts := Pts;
  end;
  if not FFuStarted then Exit;
  StartIdx := Length(FFuBuffer);
  SetLength(FFuBuffer, StartIdx + Length(Payload) - 3);
  if Length(Payload) - 3 > 0 then
    Move(Payload[3], FFuBuffer[StartIdx], Length(Payload) - 3);
  if IsEnd or Marker then
  begin
    if Length(FFuBuffer) > 0 then
      EmitNal(FFuBuffer, FCurrentPts);
    SetLength(FFuBuffer, 0);
    FFuStarted := False;
  end;
end;

procedure TH265Depacketizer.Feed(const Packet: TRtpPacket);
var
  NalType: Byte;
begin
  if Length(Packet.Payload) < 2 then Exit;
  NalType := (Packet.Payload[0] shr 1) and $3F;
  case NalType of
    0..47:             HandleSingleNal(Packet.Payload, Packet.Timestamp);
    H265_NAL_TYPE_AP:  HandleAp(Packet.Payload, Packet.Timestamp);
    H265_NAL_TYPE_FU:  HandleFu(Packet.Payload, Packet.Marker, Packet.Timestamp);
  end;
end;

end.
