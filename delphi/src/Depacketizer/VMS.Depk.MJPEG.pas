unit VMS.Depk.MJPEG;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

type
  TMjpegDepacketizer = class(TBaseDepacketizer)
  strict private
    // Acúmulo do quadro: CAPACIDADE no array, tamanho à parte — ver o
    // comentário gêmeo em VMS.Depk.H264. Um JPEG de 100 KB chega em dezenas de
    // pacotes, e crescer o array a cada um copiava tudo de novo a cada pacote.
    FBuffer: TBytes;
    FBufLen: Integer;
    FStarted: Boolean;
    FExpectedOffset: Cardinal;
    FCurrentPts: Int64;
    FType: Byte;
    FQ: Byte;
    FWidth8: Byte;
    FHeight8: Byte;
    FQTables: TBytes;
    FRestartInterval: Word;
    procedure ResetAccum;
    procedure EnsureCapacity(Need: Integer);
    procedure AppendBytes(const Src: TBytes; Offset, Count: Integer);
    function BuildJpegHeader: TBytes;
  public
    function Kind: TTrackKind; override;
    procedure Feed(const Packet: TRtpPacket); override;
    procedure Reset; override;
  end;

implementation

const
  // Capacidade inicial do acúmulo: cobre um quadro MJPEG típico sem realocar.
  ACCUM_INITIAL_CAP = 128 * 1024;

  STD_LUM_QUANT: array[0..63] of Byte = (
    16,  11,  10,  16,  24,  40,  51,  61,
    12,  12,  14,  19,  26,  58,  60,  55,
    14,  13,  16,  24,  40,  57,  69,  56,
    14,  17,  22,  29,  51,  87,  80,  62,
    18,  22,  37,  56,  68, 109, 103,  77,
    24,  35,  55,  64,  81, 104, 113,  92,
    49,  64,  78,  87, 103, 121, 120, 101,
    72,  92,  95,  98, 112, 100, 103,  99
  );
  STD_CHROM_QUANT: array[0..63] of Byte = (
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99
  );

  LUM_DC_BITS: array[0..15] of Byte = (0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0);
  LUM_DC_VAL:  array[0..11] of Byte = (0,1,2,3,4,5,6,7,8,9,10,11);

  LUM_AC_BITS: array[0..15] of Byte = (0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,$7D);
  LUM_AC_VAL: array[0..161] of Byte = (
    $01,$02,$03,$00,$04,$11,$05,$12,
    $21,$31,$41,$06,$13,$51,$61,$07,
    $22,$71,$14,$32,$81,$91,$A1,$08,
    $23,$42,$B1,$C1,$15,$52,$D1,$F0,
    $24,$33,$62,$72,$82,$09,$0A,$16,
    $17,$18,$19,$1A,$25,$26,$27,$28,
    $29,$2A,$34,$35,$36,$37,$38,$39,
    $3A,$43,$44,$45,$46,$47,$48,$49,
    $4A,$53,$54,$55,$56,$57,$58,$59,
    $5A,$63,$64,$65,$66,$67,$68,$69,
    $6A,$73,$74,$75,$76,$77,$78,$79,
    $7A,$83,$84,$85,$86,$87,$88,$89,
    $8A,$92,$93,$94,$95,$96,$97,$98,
    $99,$9A,$A2,$A3,$A4,$A5,$A6,$A7,
    $A8,$A9,$AA,$B2,$B3,$B4,$B5,$B6,
    $B7,$B8,$B9,$BA,$C2,$C3,$C4,$C5,
    $C6,$C7,$C8,$C9,$CA,$D2,$D3,$D4,
    $D5,$D6,$D7,$D8,$D9,$DA,$E1,$E2,
    $E3,$E4,$E5,$E6,$E7,$E8,$E9,$EA,
    $F1,$F2,$F3,$F4,$F5,$F6,$F7,$F8,
    $F9,$FA
  );

  CHROM_DC_BITS: array[0..15] of Byte = (0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0);
  CHROM_DC_VAL:  array[0..11] of Byte = (0,1,2,3,4,5,6,7,8,9,10,11);

  CHROM_AC_BITS: array[0..15] of Byte = (0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,$77);
  CHROM_AC_VAL: array[0..161] of Byte = (
    $00,$01,$02,$03,$11,$04,$05,$21,
    $31,$06,$12,$41,$51,$07,$61,$71,
    $13,$22,$32,$81,$08,$14,$42,$91,
    $A1,$B1,$C1,$09,$23,$33,$52,$F0,
    $15,$62,$72,$D1,$0A,$16,$24,$34,
    $E1,$25,$F1,$17,$18,$19,$1A,$26,
    $27,$28,$29,$2A,$35,$36,$37,$38,
    $39,$3A,$43,$44,$45,$46,$47,$48,
    $49,$4A,$53,$54,$55,$56,$57,$58,
    $59,$5A,$63,$64,$65,$66,$67,$68,
    $69,$6A,$73,$74,$75,$76,$77,$78,
    $79,$7A,$82,$83,$84,$85,$86,$87,
    $88,$89,$8A,$92,$93,$94,$95,$96,
    $97,$98,$99,$9A,$A2,$A3,$A4,$A5,
    $A6,$A7,$A8,$A9,$AA,$B2,$B3,$B4,
    $B5,$B6,$B7,$B8,$B9,$BA,$C2,$C3,
    $C4,$C5,$C6,$C7,$C8,$C9,$CA,$D2,
    $D3,$D4,$D5,$D6,$D7,$D8,$D9,$DA,
    $E2,$E3,$E4,$E5,$E6,$E7,$E8,$E9,
    $EA,$F2,$F3,$F4,$F5,$F6,$F7,$F8,
    $F9,$FA
  );

procedure ComputeStdQuantTables(Q: Byte; out Lum, Chrom: TBytes);
var
  Factor, I, Val: Integer;
begin
  if Q = 0 then Q := 1;
  if Q > 99 then
    Factor := 200 - Q * 2
  else
    Factor := 5000 div Q;
  SetLength(Lum, 64);
  SetLength(Chrom, 64);
  for I := 0 to 63 do
  begin
    Val := (STD_LUM_QUANT[I] * Factor + 50) div 100;
    if Val < 1 then Val := 1;
    if Val > 255 then Val := 255;
    Lum[I] := Byte(Val);
    Val := (STD_CHROM_QUANT[I] * Factor + 50) div 100;
    if Val < 1 then Val := 1;
    if Val > 255 then Val := 255;
    Chrom[I] := Byte(Val);
  end;
end;

procedure AppendBytesTo(var Buf: TBytes; const Data: array of Byte);
var
  Start: Integer;
begin
  Start := Length(Buf);
  SetLength(Buf, Start + Length(Data));
  if Length(Data) > 0 then
    Move(Data[0], Buf[Start], Length(Data));
end;

procedure AppendDynBytes(var Buf: TBytes; const Data: TBytes);
var
  Start: Integer;
begin
  if Length(Data) = 0 then Exit;
  Start := Length(Buf);
  SetLength(Buf, Start + Length(Data));
  Move(Data[0], Buf[Start], Length(Data));
end;

procedure AppendU16BE(var Buf: TBytes; V: Word);
var
  Start: Integer;
begin
  Start := Length(Buf);
  SetLength(Buf, Start + 2);
  Buf[Start]     := Byte((V shr 8) and $FF);
  Buf[Start + 1] := Byte(V and $FF);
end;

function BuildDqt(const Lum, Chrom: TBytes): TBytes;
var
  Total: Integer;
begin
  Total := 2 + 1 + 64 + 1 + 64;
  Result := nil;
  AppendBytesTo(Result, [$FF, $DB]);
  AppendU16BE(Result, Word(Total));
  AppendBytesTo(Result, [$00]);
  AppendDynBytes(Result, Lum);
  AppendBytesTo(Result, [$01]);
  AppendDynBytes(Result, Chrom);
end;

function BuildSof0(Width, Height: Word; IsType1: Boolean): TBytes;
var
  Cy, CuCv: Byte;
begin
  if IsType1 then
  begin
    Cy := $22;
    CuCv := $11;
  end
  else
  begin
    Cy := $21;
    CuCv := $11;
  end;
  Result := nil;
  AppendBytesTo(Result, [$FF, $C0]);
  AppendU16BE(Result, 17);
  AppendBytesTo(Result, [$08]);
  AppendU16BE(Result, Height);
  AppendU16BE(Result, Width);
  AppendBytesTo(Result, [$03,
                          $01, Cy,   $00,
                          $02, CuCv, $01,
                          $03, CuCv, $01]);
end;

function BuildDht: TBytes;
var
  TotalLen: Integer;
begin
  Result := nil;
  AppendBytesTo(Result, [$FF, $C4]);
  TotalLen := 2 + (1 + 16 + Length(LUM_DC_VAL)) + (1 + 16 + Length(LUM_AC_VAL))
                + (1 + 16 + Length(CHROM_DC_VAL)) + (1 + 16 + Length(CHROM_AC_VAL));
  AppendU16BE(Result, Word(TotalLen));
  AppendBytesTo(Result, [$00]);
  AppendBytesTo(Result, LUM_DC_BITS);
  AppendBytesTo(Result, LUM_DC_VAL);
  AppendBytesTo(Result, [$10]);
  AppendBytesTo(Result, LUM_AC_BITS);
  AppendBytesTo(Result, LUM_AC_VAL);
  AppendBytesTo(Result, [$01]);
  AppendBytesTo(Result, CHROM_DC_BITS);
  AppendBytesTo(Result, CHROM_DC_VAL);
  AppendBytesTo(Result, [$11]);
  AppendBytesTo(Result, CHROM_AC_BITS);
  AppendBytesTo(Result, CHROM_AC_VAL);
end;

function BuildSos: TBytes;
begin
  Result := nil;
  AppendBytesTo(Result, [$FF, $DA, $00, $0C, $03,
                          $01, $00,
                          $02, $11,
                          $03, $11,
                          $00, $3F, $00]);
end;

function BuildDri(Interval: Word): TBytes;
begin
  Result := nil;
  AppendBytesTo(Result, [$FF, $DD, $00, $04]);
  AppendU16BE(Result, Interval);
end;

{ TMjpegDepacketizer }

function TMjpegDepacketizer.Kind: TTrackKind;
begin
  Result := tkVideo;
end;

procedure TMjpegDepacketizer.Reset;
begin
  inherited;
  ResetAccum;
end;

procedure TMjpegDepacketizer.ResetAccum;
begin
  // A capacidade fica: o próximo quadro tem o mesmo tamanho do anterior.
  FBufLen := 0;
  FStarted := False;
  FExpectedOffset := 0;
  FCurrentPts := 0;
  FType := 0;
  FQ := 0;
  FWidth8 := 0;
  FHeight8 := 0;
  SetLength(FQTables, 0);
  FRestartInterval := 0;
end;

procedure TMjpegDepacketizer.EnsureCapacity(Need: Integer);
var
  NewCap: Integer;
begin
  if Need <= Length(FBuffer) then Exit;
  NewCap := Length(FBuffer);
  if NewCap < ACCUM_INITIAL_CAP then NewCap := ACCUM_INITIAL_CAP;
  while NewCap < Need do NewCap := NewCap * 2;
  SetLength(FBuffer, NewCap);
end;

procedure TMjpegDepacketizer.AppendBytes(const Src: TBytes; Offset, Count: Integer);
begin
  if Count <= 0 then Exit;
  EnsureCapacity(FBufLen + Count);
  Move(Src[Offset], FBuffer[FBufLen], Count);
  Inc(FBufLen, Count);
end;

function TMjpegDepacketizer.BuildJpegHeader: TBytes;
var
  Lum, Chrom: TBytes;
  Width, Height: Word;
  IsType1: Boolean;
begin
  Result := nil;
  AppendBytesTo(Result, [$FF, $D8]);
  if Length(FQTables) = 128 then
  begin
    SetLength(Lum, 64);
    SetLength(Chrom, 64);
    Move(FQTables[0], Lum[0], 64);
    Move(FQTables[64], Chrom[0], 64);
  end
  else
    ComputeStdQuantTables(FQ, Lum, Chrom);
  AppendDynBytes(Result, BuildDqt(Lum, Chrom));
  if FRestartInterval > 0 then
    AppendDynBytes(Result, BuildDri(FRestartInterval));
  Width := Word(FWidth8) * 8;
  Height := Word(FHeight8) * 8;
  IsType1 := (FType and $01) <> 0;
  AppendDynBytes(Result, BuildSof0(Width, Height, IsType1));
  AppendDynBytes(Result, BuildDht);
  AppendDynBytes(Result, BuildSos);
end;

procedure TMjpegDepacketizer.Feed(const Packet: TRtpPacket);
var
  P: TBytes;
  Offset: Integer;
  FragOffset: Cardinal;
  Header: TBytes;
  QtLen: Word;
  Flags: TSampleFlags;
  FullJpeg: TBytes;
  T, Qv, W8, H8: Byte;
begin
  P := Packet.Payload;
  if Length(P) < 8 then Exit;
  FragOffset := (Cardinal(P[1]) shl 16) or (Cardinal(P[2]) shl 8) or Cardinal(P[3]);
  T := P[4];
  Qv := P[5];
  W8 := P[6];
  H8 := P[7];
  Offset := 8;

  if T >= 64 then
  begin
    if Length(P) < Offset + 4 then Exit;
    Inc(Offset, 4);
  end;

  if (FragOffset = 0) and (Qv >= 128) then
  begin
    if Length(P) < Offset + 4 then Exit;
    QtLen := (Word(P[Offset + 2]) shl 8) or Word(P[Offset + 3]);
    Inc(Offset, 4);
    if Length(P) < Offset + QtLen then Exit;
    SetLength(FQTables, QtLen);
    if QtLen > 0 then
      Move(P[Offset], FQTables[0], QtLen);
    Inc(Offset, QtLen);
  end;

  if FragOffset = 0 then
  begin
    ResetAccum;
    FStarted := True;
    FType := T;
    FQ := Qv;
    FWidth8 := W8;
    FHeight8 := H8;
    FCurrentPts := Packet.Timestamp;
    Header := BuildJpegHeader;
    AppendBytes(Header, 0, Length(Header));
    FExpectedOffset := 0;
  end
  else
  begin
    if not FStarted then Exit;
  end;

  AppendBytes(P, Offset, Length(P) - Offset);
  FExpectedOffset := FragOffset + Cardinal(Length(P) - Offset);

  if Packet.Marker then
  begin
    EnsureCapacity(FBufLen + 2);
    FBuffer[FBufLen] := $FF;
    FBuffer[FBufLen + 1] := $D9;
    Inc(FBufLen, 2);
    Flags := [sfKeyframe];
    // Cópia do tamanho exato: o quadro muda de dono aqui, e o buffer continua
    // sendo nosso para o próximo.
    SetLength(FullJpeg, FBufLen);
    Move(FBuffer[0], FullJpeg[0], FBufLen);
    Emit(tkVideo, FCurrentPts, Flags, FullJpeg);
    ResetAccum;
  end;
end;

end.
