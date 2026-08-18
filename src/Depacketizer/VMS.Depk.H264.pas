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
  H264_NAL_TYPE_NON_IDR = 1;
  H264_NAL_TYPE_IDR   = 5;
  H264_NAL_TYPE_SPS   = 7;
  H264_NAL_TYPE_PPS   = 8;

type
  TH264Depacketizer = class(TBaseDepacketizer)
  strict private
    // Remontagem de FU-A: CAPACIDADE no array, tamanho à parte. Um quadro-chave
    // de 1080p chega em mais de cem fragmentos; crescer o array a cada um deles
    // fazia o buffer inteiro ser copiado de novo a cada fragmento — custo que
    // sobe com o quadrado do tamanho do quadro. Aqui ele cresce dobrando, no
    // máximo umas poucas vezes na vida da sessão, e nunca encolhe.
    FFuBuffer: TBytes;
    FFuLen: Integer;
    FFuStarted: Boolean;
    FFuNalHeader: Byte;
    FCurrentPts: Int64;
    procedure EnsureFuCapacity(Need: Integer);
    procedure EmitNal(const Nal: TBytes; Len: Integer; Pts: Int64);
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
  // Capacidade inicial do buffer de remontagem: cobre um quadro-chave típico
  // sem nenhuma realocação.
  FU_INITIAL_CAP = 64 * 1024;

// Só os Len primeiros bytes de Nal entram. O array de saída sai do tamanho
// exato de propósito: ele muda de dono aqui (vai para o sink e daí para o
// decodificador ou para a gravação).
function AnnexBWrap(const Nal: TBytes; Len: Integer): TBytes;
begin
  if Len <= 0 then Exit(nil);
  SetLength(Result, 4 + Len);
  Move(ANNEXB_PREFIX[0], Result[0], 4);
  Move(Nal[0], Result[4], Len);
end;

{ TH264Depacketizer }

function TH264Depacketizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TH264Depacketizer.Reset;
begin
  inherited;
  // A capacidade fica: reconectar não é motivo para devolver e realocar o
  // buffer de remontagem.
  FFuLen := 0;
  FFuStarted := False;
  FFuNalHeader := 0;
  FCurrentPts := 0;
end;

// True se a unidade é ponto de entrada para o decodificador.
//
// O teste óbvio é NAL tipo 5 (IDR), e é o que basta na maioria das câmeras.
// Mas existem câmeras que mandam o access unit INTEIRO — SPS + PPS + quadro I
// — como uma única unidade, declarando no cabeçalho o tipo da PRIMEIRA NAL
// (7 = SPS). Aí o quadro-chave está lá, completo, e o teste de tipo 5 nunca
// casa: a gravação inteira fica sem um único ponto de entrada marcado. Por
// isso, quando a unidade começa com parâmetros, olhamos o que vem dentro dela.
function UnitIsKeyframe(const Nal: TBytes; Len: Integer): Boolean;
var
  I, T: Integer;
begin
  if Len <= 0 then Exit(False);
  T := Nal[0] and H264_NAL_TYPE_MASK;
  if T = H264_NAL_TYPE_IDR then Exit(True);
  // só vale a varredura se a unidade abre com SPS/PPS
  if (T <> H264_NAL_TYPE_SPS) and (T <> H264_NAL_TYPE_PPS) then Exit(False);
  I := 0;
  while I <= Len - 5 do
  begin
    if (Nal[I] = 0) and (Nal[I + 1] = 0) then
    begin
      if (Nal[I + 2] = 1) then
        T := Nal[I + 3] and H264_NAL_TYPE_MASK
      else if (Nal[I + 2] = 0) and (Nal[I + 3] = 1) then
        T := Nal[I + 4] and H264_NAL_TYPE_MASK
      else
        T := -1;
      // parâmetros seguidos de slice = quadro-chave completo
      if (T = H264_NAL_TYPE_IDR) or (T = H264_NAL_TYPE_NON_IDR) then
        Exit(True);
    end;
    Inc(I);
  end;
  Result := False;
end;

procedure TH264Depacketizer.EnsureFuCapacity(Need: Integer);
var
  NewCap: Integer;
begin
  if Need <= Length(FFuBuffer) then Exit;
  NewCap := Length(FFuBuffer);
  if NewCap < FU_INITIAL_CAP then NewCap := FU_INITIAL_CAP;
  while NewCap < Need do NewCap := NewCap * 2;
  SetLength(FFuBuffer, NewCap);
end;

procedure TH264Depacketizer.EmitNal(const Nal: TBytes; Len: Integer; Pts: Int64);
var
  Flags: TSampleFlags;
  Data: TBytes;
begin
  if Len <= 0 then Exit;
  Flags := [];
  if UnitIsKeyframe(Nal, Len) then
    Include(Flags, sfKeyframe);
  Data := AnnexBWrap(Nal, Len);
  Emit(tkVideo, Pts, Flags, Data);
end;

procedure TH264Depacketizer.HandleSingleNal(const Payload: TBytes; Pts: Int64);
begin
  EmitNal(Payload, Length(Payload), Pts);
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
    EmitNal(Nal, NalLen, Pts);
  end;
end;

procedure TH264Depacketizer.HandleFuA(const Payload: TBytes; Marker: Boolean; Pts: Int64);
var
  FuIndicator, FuHeader: Byte;
  IsStart, IsEnd: Boolean;
  StartIdx, Frag: Integer;
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
    EnsureFuCapacity(1);
    FFuBuffer[0] := FFuNalHeader;
    FFuLen := 1;
    FCurrentPts := Pts;
  end;
  if not FFuStarted then Exit;
  StartIdx := FFuLen;
  Frag := Length(Payload) - 2;
  if Frag > 0 then
  begin
    EnsureFuCapacity(StartIdx + Frag);
    Move(Payload[2], FFuBuffer[StartIdx], Frag);
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
