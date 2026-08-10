unit VMS.Depk.H264;

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

const
  H264_NAL_TYPE_MASK = $1F;
  H264_NAL_TYPE_STAPA = 24;
  H264_NAL_TYPE_FUA   = 28;
  H264_NAL_TYPE_IDR   = 5;
  H264_NAL_TYPE_SPS   = 7;
  H264_NAL_TYPE_PPS   = 8;

type
  TH264Depacketizer = class(TBaseDepacketizer)
  strict private
    FFuBuffer: TBytes;
    FFuStarted: Boolean;
    FFuNalHeader: Byte;
    FCurrentPts: Int64;
    procedure EmitNal(const Nal: TBytes; Pts: Int64);
    procedure HandleSingleNal(const Payload: TBytes; Pts: Int64);
    procedure HandleStapA(const Payload: TBytes; Pts: Int64);
    procedure HandleFuA(const Payload: TBytes; Marker: Boolean; Pts: Int64);
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

{ TH264Depacketizer }

function TH264Depacketizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TH264Depacketizer.Reset;
begin
  inherited;
  SetLength(FFuBuffer, 0);
  FFuStarted := False;
  FFuNalHeader := 0;
  FCurrentPts := 0;
end;

procedure TH264Depacketizer.EmitNal(const Nal: TBytes; Pts: Int64);
var
  NalType: Byte;
  Flags: TSampleFlags;
  Data: TBytes;
begin
  if Length(Nal) = 0 then Exit;
  NalType := Nal[0] and H264_NAL_TYPE_MASK;
  Flags := [];
  if NalType = H264_NAL_TYPE_IDR then
    Include(Flags, sfKeyframe);
  Data := AnnexBWrap(Nal);
  Emit(tkVideo, Pts, Flags, Data);
end;

procedure TH264Depacketizer.HandleSingleNal(const Payload: TBytes; Pts: Int64);
begin
  EmitNal(Payload, Pts);
end;

procedure TH264Depacketizer.HandleStapA(const Payload: TBytes; Pts: Int64);
var
  Offset: Integer;
  NalLen: Word;
  Nal: TBytes;
begin
  Offset := 1;
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

procedure TH264Depacketizer.HandleFuA(const Payload: TBytes; Marker: Boolean; Pts: Int64);
var
  FuIndicator, FuHeader: Byte;
  IsStart, IsEnd: Boolean;
  StartIdx: Integer;
begin
  if Length(Payload) < 2 then Exit;
  FuIndicator := Payload[0];
  FuHeader := Payload[1];
  IsStart := (FuHeader and $80) <> 0;
  IsEnd := (FuHeader and $40) <> 0;
  if IsStart then
  begin
    FFuStarted := True;
    FFuNalHeader := (FuIndicator and $E0) or (FuHeader and $1F);
    SetLength(FFuBuffer, 1);
    FFuBuffer[0] := FFuNalHeader;
    FCurrentPts := Pts;
  end;
  if not FFuStarted then Exit;
  StartIdx := Length(FFuBuffer);
  SetLength(FFuBuffer, StartIdx + Length(Payload) - 2);
  if Length(Payload) - 2 > 0 then
    Move(Payload[2], FFuBuffer[StartIdx], Length(Payload) - 2);
  if IsEnd or Marker then
  begin
    if Length(FFuBuffer) > 0 then
      EmitNal(FFuBuffer, FCurrentPts);
    SetLength(FFuBuffer, 0);
    FFuStarted := False;
  end;
end;

procedure TH264Depacketizer.Feed(const Packet: TRtpPacket);
var
  NalType: Byte;
begin
  if Length(Packet.Payload) < 1 then Exit;
  NalType := Packet.Payload[0] and H264_NAL_TYPE_MASK;
  case NalType of
    1..23:               HandleSingleNal(Packet.Payload, Packet.Timestamp);
    H264_NAL_TYPE_STAPA: HandleStapA(Packet.Payload, Packet.Timestamp);
    H264_NAL_TYPE_FUA:   HandleFuA(Packet.Payload, Packet.Marker, Packet.Timestamp);
  end;
end;

end.
