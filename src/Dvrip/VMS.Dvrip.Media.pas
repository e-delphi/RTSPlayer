unit VMS.Dvrip.Media;

// Parser dos frames de mídia XM que vêm no payload das mensagens DVRIP após o
// OPMonitor Start. Cada frame começa com o marcador 00 00 01 XX:
//
//   FC / FE : vídeo I-frame  -> header 16 bytes
//             00 00 01 FC | tipo(1) | fps(1) | res(2) | timestamp(4) | length(4)
//             (confirmado por captura; o length é LE32 no offset 12)
//   FD      : vídeo P-frame  -> header 8 bytes:  00 00 01 FD | length(4 LE)
//   FA      : áudio          -> header 8 bytes:  00 00 01 FA | fmt(1) | ?(1) | length(2 LE)
//   F8/F9/FB: info/extra      -> header 8 bytes (length LE16 no offset 6) -> ignorado
//
// O que vem depois do header já é Annex-B (SPS+PPS+IDR nos I-frames; slice nos
// P-frames), pronto para o MediaCodec. FD/FA são o formato padrão XM (verificar
// com uma captura de P-frame/áudio se necessário).

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Dvrip.Protocol;

type
  TDvripVideoEvent = reference to procedure(const AnnexB: TBytes; Keyframe: Boolean;
                                            Codec: TVideoCodec);
  TDvripAudioEvent = reference to procedure(const Data: TBytes; Codec: TAudioCodec);

  TDvripMediaParser = class
  strict private
    FBuf: TBytes;
    FLen: Integer;
    FVideoCodec: TVideoCodec;
    FCodecKnown: Boolean;
    FOnVideo: TDvripVideoEvent;
    FOnAudio: TDvripAudioEvent;
    FLogger: ILogger;
    FTag: string;
    FLoggedType: array[Byte] of Boolean; // rate-limit: 1 log por tipo desconhecido
    FResyncs: Integer;
    // Contabilidade por marcador, INCLUSIVE dos que são descartados. É a única
    // forma de responder "a câmera não manda áudio" x "o áudio vem num frame
    // que estamos jogando fora" sem uma captura de rede.
    FTypeFrames: array[Byte] of Integer;
    FTypeBytes: array[Byte] of Int64;
    FFedBytes: Int64; // bytes entregues ao parser na janela (fecha a conta)
    procedure CountFrame(FrameType: Byte; PayloadLen: Integer);
    procedure Grow(Extra: Integer);
    procedure ParseFrames;
    function FindMarker(FromPos: Integer): Integer;
    procedure EmitVideo(Offset, Len: Integer; Keyframe: Boolean);
    procedure EmitAudio(Offset, Len: Integer; Fmt: Byte);
    function DetectCodec(const AnnexB: TBytes): TVideoCodec;
  public
    constructor Create;
    procedure SetOnVideo(const CB: TDvripVideoEvent);
    procedure SetOnAudio(const CB: TDvripAudioEvent);
    procedure SetLogger(const ALogger: ILogger; const ATag: string);
    procedure Feed(const Data: TBytes; Count: Integer);
    procedure Reset;
    // "in=612000B fc=2(184320B) fd=48(390000B) fa=12(3840B)" — tudo que passou
    // pelo parser desde a última chamada, que também zera os contadores.
    function TakeFrameStats: string;
  end;

implementation

const
  // Teto sadio p/ um frame (um I-frame 1080P raramente passa de ~1 MB). Se o
  // length lido passar disso, o header do frame provavelmente está errado nessa
  // câmera -> ressincroniza em vez de bufferizar sem limite (evita OOM).
  MAX_FRAME = 8 * 1024 * 1024;

function LE32(const B: TBytes; O: Integer): Cardinal; inline;
begin
  Result := Cardinal(B[O]) or (Cardinal(B[O + 1]) shl 8) or
            (Cardinal(B[O + 2]) shl 16) or (Cardinal(B[O + 3]) shl 24);
end;

function LE16(const B: TBytes; O: Integer): Integer; inline;
begin
  Result := Integer(B[O]) or (Integer(B[O + 1]) shl 8);
end;

{ TDvripMediaParser }

constructor TDvripMediaParser.Create;
begin
  inherited Create;
  FLen := 0;
  FVideoCodec := vcH264;
  FCodecKnown := False;
end;

procedure TDvripMediaParser.SetOnVideo(const CB: TDvripVideoEvent);
begin
  FOnVideo := CB;
end;

procedure TDvripMediaParser.SetOnAudio(const CB: TDvripAudioEvent);
begin
  FOnAudio := CB;
end;

procedure TDvripMediaParser.SetLogger(const ALogger: ILogger; const ATag: string);
begin
  FLogger := ALogger;
  FTag := ATag;
end;

procedure TDvripMediaParser.Reset;
begin
  FLen := 0;
  FCodecKnown := False;
  FResyncs := 0;
  FillChar(FLoggedType, SizeOf(FLoggedType), 0);
  FillChar(FTypeFrames, SizeOf(FTypeFrames), 0);
  FillChar(FTypeBytes, SizeOf(FTypeBytes), 0);
  FFedBytes := 0;
end;

procedure TDvripMediaParser.CountFrame(FrameType: Byte; PayloadLen: Integer);
begin
  Inc(FTypeFrames[FrameType]);
  Inc(FTypeBytes[FrameType], PayloadLen);
end;

function TDvripMediaParser.TakeFrameStats: string;
var
  I: Integer;
begin
  // "in" é tudo que a sessão entregou; a soma dos frames tem que bater com ele
  // (menos os headers). Se não bater, há byte sumindo antes dos contadores.
  Result := Format('in=%dB', [FFedBytes]);
  FFedBytes := 0;
  for I := 0 to 255 do
    if FTypeFrames[I] > 0 then
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + Format('%.2x=%d(%dB)', [I, FTypeFrames[I], FTypeBytes[I]]);
      FTypeFrames[I] := 0;
      FTypeBytes[I] := 0;
    end;
end;

procedure TDvripMediaParser.Grow(Extra: Integer);
begin
  if FLen + Extra > Length(FBuf) then
    SetLength(FBuf, (FLen + Extra) * 2);
end;

procedure TDvripMediaParser.Feed(const Data: TBytes; Count: Integer);
begin
  if Count <= 0 then Exit;
  Inc(FFedBytes, Count);
  Grow(Count);
  Move(Data[0], FBuf[FLen], Count);
  Inc(FLen, Count);
  ParseFrames;
end;

// Procura o próximo 00 00 01 XX com XX de tipo de frame conhecido (fallback de
// ressincronização; em operação normal nunca é usado, pois pulamos pelo length).
function TDvripMediaParser.FindMarker(FromPos: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  I := FromPos;
  while I + 3 < FLen do
  begin
    if (FBuf[I] = 0) and (FBuf[I + 1] = 0) and (FBuf[I + 2] = 1) then
      case FBuf[I + 3] of
        $FC, $FD, $FE, $FA, $F8, $F9, $FB: Exit(I);
      end;
    Inc(I);
  end;
end;

procedure TDvripMediaParser.ParseFrames;
var
  P, Len, Q: Integer;
  FrameType: Byte;
begin
  P := 0;
  while FLen - P >= 8 do
  begin
    if not ((FBuf[P] = 0) and (FBuf[P + 1] = 0) and (FBuf[P + 2] = 1)) then
    begin
      Q := FindMarker(P + 1);
      if Q < 0 then Break;
      Inc(FResyncs);
      if (FLogger <> nil) and (FResyncs <= 20) then
        FLogger.Warn(FTag, Format('ressincronizou (pulou %d bytes de lixo)', [Q - P]));
      P := Q;
      Continue;
    end;
    FrameType := FBuf[P + 3];
    case FrameType of
      $FC, $FE: // I-frame (header 16)
        begin
          if FLen - P < 16 then Break;
          Len := Integer(LE32(FBuf, P + 12));
          if (Len < 0) or (Len > MAX_FRAME) then
          begin
            if (FLogger <> nil) and (FResyncs <= 20) then
              FLogger.Warn(FTag, Format('I-frame com length insano (%d) -> ressync', [Len]));
            Inc(FResyncs);
            Q := FindMarker(P + 1);
            if Q < 0 then Break;
            P := Q; Continue;
          end;
          if FLen - P < 16 + Len then Break; // frame incompleto: espera mais
          CountFrame(FrameType, Len);
          EmitVideo(P + 16, Len, True);
          Inc(P, 16 + Len);
        end;
      $FD: // P-frame (header 8)
        begin
          Len := Integer(LE32(FBuf, P + 4));
          if (Len < 0) or (Len > MAX_FRAME) then
          begin
            if (FLogger <> nil) and (FResyncs <= 20) then
              FLogger.Warn(FTag, Format('P-frame com length insano (%d) -> ressync (header FD errado?)', [Len]));
            Inc(FResyncs);
            Q := FindMarker(P + 1);
            if Q < 0 then Break;
            P := Q; Continue;
          end;
          if FLen - P < 8 + Len then Break; // frame incompleto: espera mais
          CountFrame(FrameType, Len);
          EmitVideo(P + 8, Len, False);
          Inc(P, 8 + Len);
        end;
      $FA: // áudio (header 8)
        begin
          Len := LE16(FBuf, P + 6);
          if FLen - P < 8 + Len then Break;
          CountFrame(FrameType, Len);
          EmitAudio(P + 8, Len, FBuf[P + 4]);
          Inc(P, 8 + Len);
        end;
      $F8, $F9, $FB: // info/extra -> pula
        begin
          Len := LE16(FBuf, P + 6);
          if FLen - P < 8 + Len then Break;
          CountFrame(FrameType, Len);
          // Descartado sem barulho até agora. Loga o 1º de cada tipo com o
          // início do payload: é o que diz se aqui dentro vem áudio (a isis
          // entrega só 6% do áudio esperado e o resto não aparece em lugar
          // nenhum) ou se é mesmo metadado.
          if (FLogger <> nil) and (not FLoggedType[FrameType]) then
          begin
            FLoggedType[FrameType] := True;
            FLogger.Info(FTag, Format('frame 00 00 01 %.2x descartado (len=%d) [%s]',
              [FrameType, Len, BytesToHex(Copy(FBuf, P, 24), 24)]));
          end;
          Inc(P, 8 + Len);
        end;
    else
      // Tipo de frame não mapeado — loga 1x por tipo (revela formato novo
      // numa câmera/rede diferente) e tenta ressincronizar no próximo marcador.
      CountFrame(FrameType, 0);
      if (FLogger <> nil) and (not FLoggedType[FrameType]) then
      begin
        FLoggedType[FrameType] := True;
        FLogger.Warn(FTag, Format('marcador de frame desconhecido: 00 00 01 %.2x [%s]',
          [FrameType, BytesToHex(Copy(FBuf, P, 16), 16)]));
      end;
      Q := FindMarker(P + 1);
      if Q < 0 then Break;
      P := Q;
    end;
  end;
  if P > 0 then
  begin
    if FLen - P > 0 then
      Move(FBuf[P], FBuf[0], FLen - P);
    FLen := FLen - P;
  end;
end;

function TDvripMediaParser.DetectCodec(const AnnexB: TBytes): TVideoCodec;
var
  I: Integer;
  B: Byte;
  T: Integer;
begin
  Result := vcH264;
  I := 0;
  while (I < Length(AnnexB)) and (AnnexB[I] = 0) do Inc(I); // pula zeros
  if (I < Length(AnnexB)) and (AnnexB[I] = 1) then Inc(I);  // pula o 01
  if I >= Length(AnnexB) then Exit;
  B := AnnexB[I];
  // H265: tipo do NAL = (B shr 1) and $3F; param sets = 32/33/34 (VPS/SPS/PPS).
  // O 1º NAL do I-frame é sempre um param set, então isso distingue com segurança.
  T := (B shr 1) and $3F;
  if (T = 32) or (T = 33) or (T = 34) then
    Result := vcH265;
end;

procedure TDvripMediaParser.EmitVideo(Offset, Len: Integer; Keyframe: Boolean);
var
  NAL: TBytes;
begin
  if Len <= 0 then Exit;
  SetLength(NAL, Len);
  Move(FBuf[Offset], NAL[0], Len);
  if (not FCodecKnown) and Keyframe then
  begin
    FVideoCodec := DetectCodec(NAL);
    FCodecKnown := True;
  end;
  if Assigned(FOnVideo) then
    FOnVideo(NAL, Keyframe, FVideoCodec);
end;

procedure TDvripMediaParser.EmitAudio(Offset, Len: Integer; Fmt: Byte);
var
  Data: TBytes;
  Codec: TAudioCodec;
begin
  if Len <= 0 then Exit;
  SetLength(Data, Len);
  Move(FBuf[Offset], Data[0], Len);
  // Mapeamento do formato XM (verificar): a maioria dessas câmeras usa G711A.
  case Fmt of
    $0E: Codec := acG711A;
    $0A, $07: Codec := acG711U;
  else
    Codec := acG711A;
  end;
  if Assigned(FOnAudio) then
    FOnAudio(Data, Codec);
end;

end.
