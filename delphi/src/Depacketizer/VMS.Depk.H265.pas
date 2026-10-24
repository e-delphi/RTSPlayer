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
    // Remontagem de FU: CAPACIDADE no array, tamanho à parte — ver o comentário
    // gêmeo em VMS.Depk.H264. Crescer o array a cada fragmento copiava o buffer
    // inteiro de novo a cada fragmento do quadro-chave.
    FFuBuffer: TBytes;
    FFuLen: Integer;
    FFuStarted: Boolean;
    FFuOriginalHeader0: Byte;
    FFuOriginalHeader1: Byte;
    FCurrentPts: Int64;
    procedure EnsureFuCapacity(Need: Integer);
    procedure EmitNal(const Nal: TBytes; Len: Integer; Pts: Int64);
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
  FU_INITIAL_CAP = 64 * 1024;

// Só os Len primeiros bytes entram. A saída sai do tamanho exato: ela muda de
// dono aqui (vai para o sink, e daí para o decodificador ou a gravação).
function AnnexBWrap(const Nal: TBytes; Len: Integer): TBytes;
begin
  if Len <= 0 then Exit(nil);
  SetLength(Result, 4 + Len);
  Move(ANNEXB_PREFIX[0], Result[0], 4);
  Move(Nal[0], Result[4], Len);
end;

{ TH265Depacketizer }

function TH265Depacketizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TH265Depacketizer.Reset;
begin
  inherited;
  // A capacidade fica; reconectar não devolve o buffer.
  FFuLen := 0;
  FFuStarted := False;
  FFuOriginalHeader0 := 0;
  FFuOriginalHeader1 := 0;
  FCurrentPts := 0;
end;

function TH265Depacketizer.NalIsKeyframe(NalType: Byte): Boolean;
begin
  Result := (NalType >= H265_NAL_TYPE_BLA_W_LP) and (NalType <= H265_NAL_TYPE_CRA_NUT);
end;

procedure TH265Depacketizer.EnsureFuCapacity(Need: Integer);
var
  NewCap: Integer;
begin
  if Need <= Length(FFuBuffer) then Exit;
  NewCap := Length(FFuBuffer);
  if NewCap < FU_INITIAL_CAP then NewCap := FU_INITIAL_CAP;
  while NewCap < Need do NewCap := NewCap * 2;
  SetLength(FFuBuffer, NewCap);
end;

procedure TH265Depacketizer.EmitNal(const Nal: TBytes; Len: Integer; Pts: Int64);
var
  NalType: Byte;
  Flags: TSampleFlags;
  Data: TBytes;
begin
  if Len < 2 then Exit;
  NalType := (Nal[0] shr 1) and $3F;
  Flags := [];
  if NalIsKeyframe(NalType) then
    Include(Flags, sfKeyframe);
  Data := AnnexBWrap(Nal, Len);
  Emit(tkVideo, Pts, Flags, Data);
end;

procedure TH265Depacketizer.HandleSingleNal(const Payload: TBytes; Pts: Int64);
begin
  EmitNal(Payload, Length(Payload), Pts);
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
    EmitNal(Nal, NalLen, Pts);
  end;
end;

procedure TH265Depacketizer.HandleFu(const Payload: TBytes; Marker: Boolean; Pts: Int64);
var
  PayloadHdr0, PayloadHdr1, FuHeader: Byte;
  IsStart, IsEnd: Boolean;
  FuType: Byte;
  StartIdx, Frag: Integer;
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
    EnsureFuCapacity(2);
    FFuBuffer[0] := FFuOriginalHeader0;
    FFuBuffer[1] := FFuOriginalHeader1;
    FFuLen := 2;
    FCurrentPts := Pts;
  end;
  if not FFuStarted then Exit;
  StartIdx := FFuLen;
  Frag := Length(Payload) - 3;
  if Frag > 0 then
  begin
    EnsureFuCapacity(StartIdx + Frag);
    Move(Payload[3], FFuBuffer[StartIdx], Frag);
    Inc(FFuLen, Frag);
  end;
  if IsEnd or Marker then
  begin
    if FFuLen > 0 then
      EmitNal(FFuBuffer, FFuLen, FCurrentPts);
    FFuLen := 0;
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
