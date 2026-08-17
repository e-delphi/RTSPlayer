unit VMS.Win.AudioDecoder;

// Reprodução de áudio no Windows.
//   G711 A-law/U-law -> decodificação em software -> PCM16 -> waveOut
//   PCM (L16)        -> byte-swap (big->little)    -> PCM16 -> waveOut
//   AAC              -> FFmpeg (avcodec)           -> PCM16 -> waveOut
//   G726 e demais    -> silenciado (não suportado)
//
// Saída via winmm (waveOut) — sem DLL externa, sem COM. Um rodízio de buffers
// WAVEHDR: escreve nos livres, recicla os que terminaram (WHDR_DONE).
//
// Threading: Configure()/Enqueue()/FlushReset() na thread de rede; decode e
// reprodução nesta própria thread (Execute). O waveOut é aberto/fechado só aqui.

{$IFDEF MSWINDOWS}
{$POINTERMATH ON}
{$ENDIF}

interface

{$IFDEF MSWINDOWS}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.MMSystem,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  FFmpegLib;

type
  TAudioDecoder = class(TThread)
  strict private
    // fila de entrada
    FLock: TCriticalSection;
    FItems: TList<TSample>;
    FDataEvent: TEvent;
    // (re)configuração pedida pela thread de rede
    FConfigLock: TCriticalSection;
    FNeedConfig: Boolean;
    FPendingCodec: TAudioCodec;
    FPendingRate: Cardinal;
    FPendingChannels: Byte;
    FFlushReq: Integer;
    // estado ativo
    FCodecKind: TAudioCodec;
    FRate: Cardinal;
    FChannels: Byte;
    // buffer de jitter: acumula uma folga (~PRIME_MS) antes de começar a tocar,
    // pra fila do waveOut não esvaziar com jitter de chegada (evita chiado/underrun).
    FAccum: TBytes;
    FAccumLen: Integer;
    FBytesPerMs: Integer;
    FPrimed: Boolean;
    FPrimeMs: Integer; // folga do jitter buffer (config. por câmera)
    // waveOut
    FWaveOut: HWAVEOUT;
    FWaveOpen: Boolean;
    FHdrs: array of TWaveHdr;
    FBufs: array of TBytes;
    FBusy: array of Boolean;
    // ffmpeg (AAC)
    FFAvail: Boolean;
    FUseFF: Boolean;
    FCodec: PAVCodec;
    FCtx: PAVCodecContext;
    FFrame: PAVFrame;
    FPkt: PAVPacket;
    FAdtsFreqIdx, FAdtsChan: Integer;
    // diagnóstico
    FLogger: ILogger;
    FTag: string;
    FLoggedPlay: Boolean;
    procedure Log(const Msg: string);
    procedure DoConfigure;
    procedure ReleaseFF;
    function OpenWave(Rate: Cardinal; Channels: Byte): Boolean;
    procedure CloseWave;
    procedure ReclaimHeaders;
    procedure PlayPcm(const Pcm: TBytes; Len: Integer);
    procedure QueueAudio(const Pcm: TBytes; Len: Integer);
    function PopSample(out S: TSample): Boolean;
    procedure DecodeG711(const S: TSample; ALaw: Boolean);
    procedure DecodePcmL16(const S: TSample);
    procedure DecodeAac(const S: TSample);
  protected
    procedure Execute; override;
  public
    constructor Create(const ALogger: ILogger = nil);
    destructor Destroy; override;
    procedure Configure(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
                        const Extradata: TBytes);
    procedure SetPrimeMs(Ms: Integer);
    procedure Enqueue(const S: TSample);
    procedure FlushReset;
  end;

{$ENDIF MSWINDOWS}

implementation

{$IFDEF MSWINDOWS}

const
  MAX_QUEUE  = 60;
  SLOT_COUNT = 24; // buffers waveOut em rodízio (folga p/ jitter buffer)
  PRIME_MS   = 200; // folga acumulada antes de tocar (evita underrun/chiado)
  CHUNK_MS   = 40;  // tamanho de cada buffer entregue ao waveOut depois de primado
  // formatos de sample do FFmpeg (avutil/samplefmt.h)
  AV_SAMPLE_FMT_S16  = 1;
  AV_SAMPLE_FMT_FLT  = 3;
  AV_SAMPLE_FMT_S16P = 6;
  AV_SAMPLE_FMT_FLTP = 8;

// ---- G711 (portado do decoder Android) ----

function MuLawDecode(U: Byte): SmallInt;
const
  BIAS = $84;
var
  T, Sign, Exponent, Mantissa: Integer;
begin
  U := not U;
  Sign := U and $80;
  Exponent := (U shr 4) and $07;
  Mantissa := U and $0F;
  T := ((Mantissa shl 3) + BIAS) shl Exponent;
  T := T - BIAS;
  if Sign <> 0 then Result := SmallInt(-T) else Result := SmallInt(T);
end;

function ALawDecode(A: Byte): SmallInt;
var
  T, Seg: Integer;
begin
  A := A xor $55;
  T := (A and $0F) shl 4;
  Seg := (A and $70) shr 4;
  case Seg of
    0: T := T + 8;
    1: T := T + 264;
  else
    T := (T + 264) shl (Seg - 1);
  end;
  if (A and $80) <> 0 then Result := SmallInt(T) else Result := SmallInt(-T);
end;

function FreqIndexFor(Rate: Cardinal): Integer;
begin
  case Rate of
    96000: Result := 0;  88200: Result := 1;  64000: Result := 2;
    48000: Result := 3;  44100: Result := 4;  32000: Result := 5;
    24000: Result := 6;  22050: Result := 7;  16000: Result := 8;
    12000: Result := 9;  11025: Result := 10; 8000:  Result := 11;
    7350:  Result := 12;
  else
    Result := 4; // 44100
  end;
end;

function ClampToS16(V: Int64): SmallInt; inline;
begin
  if V > 32767 then Result := 32767
  else if V < -32768 then Result := -32768
  else Result := SmallInt(V);
end;

{ TAudioDecoder }

constructor TAudioDecoder.Create(const ALogger: ILogger);
begin
  // Campos antes da thread rodar; Create(False) inicia via AfterConstruction
  // uma única vez (Create(True)+Start dá EThread no Windows — ver VideoDecoder).
  FLogger := ALogger;
  FTag := 'adec.win';
  FLock := TCriticalSection.Create;
  FItems := TList<TSample>.Create;
  FDataEvent := TEvent.Create(nil, False, False, '');
  FConfigLock := TCriticalSection.Create;
  SetLength(FHdrs, SLOT_COUNT);
  SetLength(FBufs, SLOT_COUNT);
  SetLength(FBusy, SLOT_COUNT);
  FPrimeMs := PRIME_MS;
  inherited Create(False);
end;

destructor TAudioDecoder.Destroy;
begin
  Terminate;
  if FDataEvent <> nil then
    FDataEvent.SetEvent;
  inherited; // aguarda a thread (WaitFor); ela fecha o waveOut/FFmpeg
  FItems.Free;
  FLock.Free;
  FConfigLock.Free;
  FDataEvent.Free;
end;

procedure TAudioDecoder.Log(const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Info(FTag, Msg);
end;

procedure TAudioDecoder.Configure(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
  const Extradata: TBytes);
begin
  FConfigLock.Enter;
  try
    FPendingCodec := Codec;
    FPendingRate := SampleRate;
    FPendingChannels := Channels;
    FNeedConfig := True;
  finally
    FConfigLock.Leave;
  end;
  FDataEvent.SetEvent;
end;

procedure TAudioDecoder.SetPrimeMs(Ms: Integer);
begin
  if Ms < 20 then Ms := 20; // folga mínima p/ não degenerar o playback
  FPrimeMs := Ms;
end;

procedure TAudioDecoder.Enqueue(const S: TSample);
begin
  FLock.Enter;
  try
    if FItems.Count >= MAX_QUEUE then
      FItems.Delete(0);
    FItems.Add(S);
  finally
    FLock.Leave;
  end;
  FDataEvent.SetEvent;
end;

procedure TAudioDecoder.FlushReset;
begin
  FLock.Enter;
  try
    FItems.Clear;
  finally
    FLock.Leave;
  end;
  TInterlocked.Exchange(FFlushReq, 1);
  FDataEvent.SetEvent;
end;

function TAudioDecoder.PopSample(out S: TSample): Boolean;
begin
  FLock.Enter;
  try
    Result := FItems.Count > 0;
    if Result then
    begin
      S := FItems[0];
      FItems.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
end;

// ---- waveOut ----

function TAudioDecoder.OpenWave(Rate: Cardinal; Channels: Byte): Boolean;
var
  Wfx: TWaveFormatEx;
  I: Integer;
begin
  CloseWave;
  if Channels = 0 then Channels := 1;
  if Rate = 0 then Rate := 8000;
  FillChar(Wfx, SizeOf(Wfx), 0);
  Wfx.wFormatTag := WAVE_FORMAT_PCM;
  Wfx.nChannels := Channels;
  Wfx.nSamplesPerSec := Rate;
  Wfx.wBitsPerSample := 16;
  Wfx.nBlockAlign := Channels * 2;
  Wfx.nAvgBytesPerSec := Rate * Channels * 2;
  Wfx.cbSize := 0;
  if waveOutOpen(@FWaveOut, WAVE_MAPPER, @Wfx, 0, 0, CALLBACK_NULL) <> MMSYSERR_NOERROR then
  begin
    Log('waveOutOpen falhou (rate=' + IntToStr(Rate) + ' ch=' + IntToStr(Channels) + ')');
    Exit(False);
  end;
  for I := 0 to SLOT_COUNT - 1 do
  begin
    FillChar(FHdrs[I], SizeOf(TWaveHdr), 0);
    FBusy[I] := False;
    FBufs[I] := nil;
  end;
  FWaveOpen := True;
  Result := True;
end;

procedure TAudioDecoder.CloseWave;
var
  I: Integer;
begin
  if not FWaveOpen then Exit;
  waveOutReset(FWaveOut); // marca todos os buffers como concluídos
  for I := 0 to SLOT_COUNT - 1 do
    if (FHdrs[I].dwFlags and WHDR_PREPARED) <> 0 then
      waveOutUnprepareHeader(FWaveOut, @FHdrs[I], SizeOf(TWaveHdr));
  waveOutClose(FWaveOut);
  FWaveOpen := False;
end;

procedure TAudioDecoder.ReclaimHeaders;
var
  I: Integer;
begin
  for I := 0 to SLOT_COUNT - 1 do
    if FBusy[I] and ((FHdrs[I].dwFlags and WHDR_DONE) <> 0) then
    begin
      waveOutUnprepareHeader(FWaveOut, @FHdrs[I], SizeOf(TWaveHdr));
      FBusy[I] := False;
    end;
end;

procedure TAudioDecoder.PlayPcm(const Pcm: TBytes; Len: Integer);
var
  Slot, Tries, I: Integer;
begin
  if (not FWaveOpen) or (Len <= 0) then Exit;
  Slot := -1;
  for Tries := 0 to 10 do
  begin
    ReclaimHeaders;
    for I := 0 to SLOT_COUNT - 1 do
      if not FBusy[I] then begin Slot := I; Break; end;
    if Slot >= 0 then Break;
    Sleep(2); // todos ocupados: espera brevemente
  end;
  if Slot < 0 then Exit; // overload: descarta esse frame

  SetLength(FBufs[Slot], Len);
  Move(Pcm[0], FBufs[Slot][0], Len);
  FillChar(FHdrs[Slot], SizeOf(TWaveHdr), 0);
  FHdrs[Slot].lpData := PAnsiChar(@FBufs[Slot][0]);
  FHdrs[Slot].dwBufferLength := DWORD(Len);
  if waveOutPrepareHeader(FWaveOut, @FHdrs[Slot], SizeOf(TWaveHdr)) <> MMSYSERR_NOERROR then Exit;
  if waveOutWrite(FWaveOut, @FHdrs[Slot], SizeOf(TWaveHdr)) <> MMSYSERR_NOERROR then
  begin
    waveOutUnprepareHeader(FWaveOut, @FHdrs[Slot], SizeOf(TWaveHdr));
    Exit;
  end;
  FBusy[Slot] := True;
  if not FLoggedPlay then
  begin
    FLoggedPlay := True;
    Log('reproduzindo áudio (' + AudioCodecToStr(FCodecKind) + ', ' +
      IntToStr(FRate) + 'Hz ' + IntToStr(FChannels) + 'ch)');
  end;
end;

procedure TAudioDecoder.QueueAudio(const Pcm: TBytes; Len: Integer);
begin
  if (Len <= 0) or (FBytesPerMs <= 0) then Exit;
  if FAccumLen + Len > Length(FAccum) then
    SetLength(FAccum, (FAccumLen + Len) * 2);
  Move(Pcm[0], FAccum[FAccumLen], Len);
  Inc(FAccumLen, Len);
  // Antes de "primar", segura até juntar PRIME_MS de folga; depois, entrega em
  // blocos de ~CHUNK_MS. A folga inicial mantém a fila do waveOut cheia, então
  // jitter de chegada (comum sobre TCP interleaved) não esvazia -> sem chiado.
  if not FPrimed then
  begin
    if FAccumLen >= FPrimeMs * FBytesPerMs then
    begin
      PlayPcm(FAccum, FAccumLen);
      FAccumLen := 0;
      FPrimed := True;
    end;
  end
  else if FAccumLen >= CHUNK_MS * FBytesPerMs then
  begin
    PlayPcm(FAccum, FAccumLen);
    FAccumLen := 0;
  end;
end;

// ---- decode ----

procedure TAudioDecoder.DecodeG711(const S: TSample; ALaw: Boolean);
var
  I, N: Integer;
  Pcm: TBytes;
  V: SmallInt;
begin
  N := Length(S.Data);
  if N = 0 then Exit;
  SetLength(Pcm, N * 2);
  for I := 0 to N - 1 do
  begin
    if ALaw then V := ALawDecode(S.Data[I]) else V := MuLawDecode(S.Data[I]);
    Pcm[I * 2]     := Byte(V and $FF);
    Pcm[I * 2 + 1] := Byte((V shr 8) and $FF);
  end;
  QueueAudio(Pcm, N * 2);
end;

procedure TAudioDecoder.DecodePcmL16(const S: TSample);
var
  I, N: Integer;
  Pcm: TBytes;
begin
  N := Length(S.Data);
  if N < 2 then Exit;
  SetLength(Pcm, N);
  I := 0;
  while I + 1 < N do
  begin
    Pcm[I]     := S.Data[I + 1]; // big-endian -> little-endian
    Pcm[I + 1] := S.Data[I];
    Inc(I, 2);
  end;
  QueueAudio(Pcm, N);
end;

procedure TAudioDecoder.DecodeAac(const S: TSample);
var
  AacLen, FrameLen, Ret, Ns, Ch, Fmt, I, C: Integer;
  Buf, Pcm: TBytes;
  P: PSingle;
  Src16: PSmallInt;
  V: SmallInt;
begin
  AacLen := Length(S.Data);
  if AacLen = 0 then Exit;
  // Envelopa em ADTS (7 bytes, sem CRC) — auto-descritivo, dispensa extradata.
  FrameLen := AacLen + 7;
  // Mesmo contrato do vídeo: o buffer leva os bytes zerados de padding depois do
  // tamanho declarado, porque o decodificador lê à frente (ver FFmpegLib).
  SetLength(Buf, FrameLen + AV_INPUT_BUFFER_PADDING_SIZE);
  FillChar(Buf[FrameLen], AV_INPUT_BUFFER_PADDING_SIZE, 0);
  Buf[0] := $FF;
  Buf[1] := $F1; // MPEG-4, layer 0, sem proteção (CRC ausente)
  Buf[2] := Byte((1 shl 6) or ((FAdtsFreqIdx and $0F) shl 2) or ((FAdtsChan shr 2) and 1)); // profile AAC-LC=1
  Buf[3] := Byte(((FAdtsChan and 3) shl 6) or ((FrameLen shr 11) and 3));
  Buf[4] := Byte((FrameLen shr 3) and $FF);
  Buf[5] := Byte(((FrameLen and 7) shl 5) or $1F);
  Buf[6] := $FC;
  Move(S.Data[0], Buf[7], AacLen);

  FPkt.data := PByte(@Buf[0]);
  FPkt.size := FrameLen;
  FPkt.pts := 0;
  FPkt.dts := 0;
  avcodec_send_packet(FCtx, FPkt);
  FPkt.data := nil;
  FPkt.size := 0;

  while True do
  begin
    Ret := avcodec_receive_frame(FCtx, FFrame);
    if (Ret = AVERROR_EAGAIN) or (Ret = AVERROR_EOF) or (Ret < 0) then Break;
    Ns := FFrame.nb_samples;
    Fmt := FFrame.format;
    Ch := FChannels;
    if (Ns <= 0) or (Ch <= 0) then begin av_frame_unref(FFrame); Continue; end;
    SetLength(Pcm, Ns * Ch * 2);
    case Fmt of
      AV_SAMPLE_FMT_FLTP: // float planar (saída típica do AAC)
        for C := 0 to Ch - 1 do
        begin
          P := PSingle(FFrame.data[C]);
          for I := 0 to Ns - 1 do
          begin
            V := ClampToS16(Round(P[I] * 32768.0));
            PSmallInt(@Pcm[(I * Ch + C) * 2])^ := V;
          end;
        end;
      AV_SAMPLE_FMT_FLT: // float interleaved
        begin
          P := PSingle(FFrame.data[0]);
          for I := 0 to Ns * Ch - 1 do
            PSmallInt(@Pcm[I * 2])^ := ClampToS16(Round(P[I] * 32768.0));
        end;
      AV_SAMPLE_FMT_S16P: // int16 planar
        for C := 0 to Ch - 1 do
        begin
          Src16 := PSmallInt(FFrame.data[C]);
          for I := 0 to Ns - 1 do
            PSmallInt(@Pcm[(I * Ch + C) * 2])^ := Src16[I];
        end;
    else
      // S16 interleaved (ou desconhecido tratado como tal)
      Move(FFrame.data[0]^, Pcm[0], Ns * Ch * 2);
    end;
    QueueAudio(Pcm, Ns * Ch * 2);
    av_frame_unref(FFrame);
  end;
end;

procedure TAudioDecoder.ReleaseFF;
begin
  if FCtx <> nil then
    avcodec_free_context(@FCtx);
  FCodec := nil;
  FUseFF := False;
end;

procedure TAudioDecoder.DoConfigure;
begin
  FConfigLock.Enter;
  try
    FNeedConfig := False;
    FCodecKind := FPendingCodec;
    FRate := FPendingRate;
    FChannels := FPendingChannels;
  finally
    FConfigLock.Leave;
  end;
  if FRate = 0 then FRate := 8000;
  if FChannels = 0 then FChannels := 1;
  FBytesPerMs := (Integer(FRate) * FChannels * 2) div 1000;
  if FBytesPerMs < 1 then FBytesPerMs := 1;
  FAccumLen := 0;
  FPrimed := False; // re-prima o jitter buffer nesta configuração

  ReleaseFF;

  if FCodecKind = acAAC then
  begin
    if not FFAvail then
      Log('AAC no Windows precisa das DLLs FFmpeg — áudio silenciado')
    else
    begin
      FCodec := avcodec_find_decoder_by_name('aac');
      if FCodec = nil then
        Log('decoder AAC não encontrado no FFmpeg')
      else
      begin
        FCtx := avcodec_alloc_context3(FCodec);
        if (FCtx = nil) or (avcodec_open2(FCtx, FCodec, nil) < 0) then
        begin
          ReleaseFF;
          Log('falha ao abrir decoder AAC');
        end
        else
        begin
          FUseFF := True;
          FAdtsFreqIdx := FreqIndexFor(FRate);
          FAdtsChan := FChannels;
          if FAdtsChan < 1 then FAdtsChan := 1;
        end;
      end;
    end;
  end;

  OpenWave(FRate, FChannels);
  FLoggedPlay := False;
  Log('config: ' + AudioCodecToStr(FCodecKind) + ' ' + IntToStr(FRate) + 'Hz ' +
    IntToStr(FChannels) + 'ch');
end;

procedure TAudioDecoder.Execute;
var
  S: TSample;
begin
  FFAvail := FFmpegLibAvailable;
  if FFAvail then
    try
      FFrame := av_frame_alloc;
      FPkt := av_packet_alloc;
    except
      FFAvail := False;
    end;

  while not Terminated do
  begin
    if TInterlocked.Exchange(FFlushReq, 0) = 1 then
    begin
      FAccumLen := 0;
      FPrimed := False; // re-prima a folga ao retomar o stream
      if FWaveOpen then
      begin
        waveOutReset(FWaveOut);
        ReclaimHeaders;
      end;
    end;

    if FNeedConfig then
      DoConfigure;

    if PopSample(S) then
    begin
      try
        case FCodecKind of
          acG711A: DecodeG711(S, True);
          acG711U: DecodeG711(S, False);
          acPCM:   DecodePcmL16(S);
          acAAC:   if FUseFF then DecodeAac(S);
        end;
      except
        on E: Exception do
          Log('erro no decode de áudio: ' + E.Message);
      end;
    end
    else
      FDataEvent.WaitFor(50);
  end;

  CloseWave;
  ReleaseFF;
  if FFAvail then
  begin
    if FFrame <> nil then av_frame_free(@FFrame);
    if FPkt <> nil then av_packet_free(@FPkt);
  end;
end;

{$ENDIF MSWINDOWS}

end.
