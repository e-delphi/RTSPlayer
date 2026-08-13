unit VMS.Win.VideoDecoder;

// Decodificador de vídeo por software no Windows via FFmpeg (libavcodec).
// Entrada: access units Annex-B (TSample) vindos do depacketizer/DVRIP.
// Saída: frame RGBA pronto para blit num TImage (apresentado na UI thread).
//
// Espelha a superfície pública do TVideoDecoder Android (Configure/Enqueue/
// FlushReset/LockLatestFrame/UnlockFrame/OnFrame), então o renderer e a UI
// não sabem qual backend está por baixo.
//
// Threading:
//   - Configure()/Enqueue()/FlushReset() são chamados na thread de rede.
//   - A decodificação roda nesta própria thread (Execute).
//   - O frame pronto é sinalizado via OnFrame (TThread.Queue -> UI thread).
//
// Requisito: as DLLs do FFmpeg 7.x (avcodec-61, avutil-59, swscale-8) ao lado
// do .exe. Se faltarem, o decoder loga e apenas descarta os samples.

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
  VMS.Domain.Types,
  VMS.Domain.Logging,
  FFmpegLib;

type
  // AU comprimida + instante de chegada (pra atrasar o vídeo e casar com a
  // latência do jitter buffer de áudio -> A/V em sincronia).
  TTimedSample = record
    Tick: UInt64;
    Sample: TSample;
  end;

  TVideoDecoder = class(TThread)
  strict private
    // fila de entrada (AUs comprimidas, com timestamp de chegada)
    FLock: TCriticalSection;
    FItems: TList<TTimedSample>;
    FDataEvent: TEvent;
    FDelayMs: Integer; // atraso de exibição (config. por câmera) p/ A/V sync
    // (re)configuração pedida pela thread de rede
    FConfigLock: TCriticalSection;
    FNeedConfig: Boolean;
    FPendingCodec: TVideoCodec;
    FPendingExtra: TBytes;  // extradata (VPS/SPS/PPS Annex-B do SDP) pendente
    FFlushReq: Integer;
    // parameter sets Annex-B pra prefixar (câmeras que só mandam no SDP)
    FExtradata: TBytes;
    FNeedPrepend: Boolean;
    // ffmpeg
    FCodec: PAVCodec;
    FCtx: PAVCodecContext;
    FFrame: PAVFrame;
    FPkt: PAVPacket;
    FSws: SwsContext;
    FSwsW, FSwsH, FSwsFmt: Integer;
    FConfigured: Boolean;
    FAvail: Boolean;
    FInPts: Int64;
    // diagnóstico
    FLogger: ILogger;
    FTag: string;
    FLoggedReady, FLoggedFrame, FLoggedRecvErr: Boolean;
    FWinFrames: Integer;
    FStatTickMs: UInt64;
    // frame de saída (RGBA, double-buffer)
    FFrameLock: TCriticalSection;
    FFrameRGBA: TBytes;   // pronto p/ apresentar (protegido por FFrameLock)
    FWorkRGBA: TBytes;    // buffer de trabalho da thread de decode
    FFrameW, FFrameH: Integer;
    FHasFrame: Boolean;
    FPresentQueued: Integer;
    FOnFrame: TThreadProcedure;
    procedure Log(const Msg: string);
    function CodecId: Integer;
    procedure DoConfigure;
    procedure ReleaseCodec;
    function PopSample(out S: TSample): Boolean;
    procedure DecodeSample(const S: TSample);
    procedure DrainFrames;
    procedure EnsureSws(W, H, Fmt: Integer);
    procedure ConvertAndStore;
    procedure QueuePresent;
    procedure LogStatsIfDue;
  protected
    procedure Execute; override;
  public
    constructor Create(const ALogger: ILogger = nil);
    destructor Destroy; override;
    procedure Configure(Codec: TVideoCodec; W, H: Integer; const Extradata: TBytes);
    procedure SetDelayMs(Ms: Integer);
    procedure Enqueue(const S: TSample);
    procedure FlushReset;
    // Acesso ao último frame; mantém o lock até UnlockFrame (chamar em par).
    function LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
    procedure UnlockFrame;
    property OnFrame: TThreadProcedure read FOnFrame write FOnFrame;
  end;

{$ENDIF MSWINDOWS}

implementation

{$IFDEF MSWINDOWS}

const
  MAX_QUEUE   = 120;
  SWS_BILINEAR = 2;
  // Atraso de exibição do vídeo. Deve casar com a latência do jitter buffer de
  // áudio (PRIME_MS no VMS.Win.AudioDecoder) pra A/V ficar em sincronia.
  VIDEO_DELAY_MS = 200;

{ TVideoDecoder }

constructor TVideoDecoder.Create(const ALogger: ILogger);
begin
  // Campos inicializados ANTES de a thread poder rodar. Usar Create(False)
  // (não Create(True)+Start): no Windows, chamar Start dentro do construtor
  // faz o AfterConstruction dar um segundo ResumeThread -> EThread. Com
  // Create(False) o AfterConstruction inicia a thread uma única vez, e só
  // depois do construtor terminar (então os campos já estão prontos).
  FLogger := ALogger;
  FTag := 'vdec.win';
  FLock := TCriticalSection.Create;
  FItems := TList<TTimedSample>.Create;
  FDataEvent := TEvent.Create(nil, False, False, '');
  FConfigLock := TCriticalSection.Create;
  FFrameLock := TCriticalSection.Create;
  FSwsFmt := -1;
  FDelayMs := VIDEO_DELAY_MS;
  inherited Create(False);
end;

destructor TVideoDecoder.Destroy;
begin
  Terminate;
  if FDataEvent <> nil then
    FDataEvent.SetEvent;
  inherited; // aguarda a thread terminar (WaitFor)
  FItems.Free;
  FLock.Free;
  FConfigLock.Free;
  FFrameLock.Free;
  FDataEvent.Free;
end;

procedure TVideoDecoder.Log(const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Info(FTag, Msg);
end;

function TVideoDecoder.CodecId: Integer;
begin
  case FPendingCodec of
    vcH264:  Result := AV_CODEC_ID_H264;
    vcH265:  Result := AV_CODEC_ID_HEVC;
    vcMJPEG: Result := AV_CODEC_ID_MJPEG;
  else
    Result := 0;
  end;
end;

procedure TVideoDecoder.Configure(Codec: TVideoCodec; W, H: Integer; const Extradata: TBytes);
begin
  FConfigLock.Enter;
  try
    FPendingCodec := Codec;
    FPendingExtra := Copy(Extradata, 0, Length(Extradata));
    FNeedConfig := True;
  finally
    FConfigLock.Leave;
  end;
  FDataEvent.SetEvent;
end;

procedure TVideoDecoder.SetDelayMs(Ms: Integer);
begin
  if Ms < 0 then Ms := 0;
  FDelayMs := Ms; // escrita atômica de Integer; leitura em PopSample tolera valor levemente antigo
end;

procedure TVideoDecoder.Enqueue(const S: TSample);
var
  TS: TTimedSample;
begin
  TS.Tick := TThread.GetTickCount64;
  TS.Sample := S;
  FLock.Enter;
  try
    if FItems.Count >= MAX_QUEUE then
      FItems.Delete(0); // descarta o mais antigo (rede de segurança)
    FItems.Add(TS);
  finally
    FLock.Leave;
  end;
  FDataEvent.SetEvent;
end;

procedure TVideoDecoder.FlushReset;
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

function TVideoDecoder.PopSample(out S: TSample): Boolean;
var
  NowMs: UInt64;
begin
  Result := False;
  FLock.Enter;
  try
    if FItems.Count > 0 then
    begin
      NowMs := TThread.GetTickCount64;
      // Segura cada AU por VIDEO_DELAY_MS (mesma folga do áudio) -> A/V sync.
      // Se a fila encher (atraso patológico), libera assim mesmo (não deixa
      // a latência crescer sem limite).
      if ((NowMs - FItems[0].Tick) >= UInt64(FDelayMs)) or (FItems.Count >= MAX_QUEUE) then
      begin
        S := FItems[0].Sample;
        FItems.Delete(0);
        Result := True;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVideoDecoder.ReleaseCodec;
begin
  if FSws <> nil then
  begin
    sws_freeContext(FSws);
    FSws := nil;
  end;
  FSwsW := 0; FSwsH := 0; FSwsFmt := -1;
  if FCtx <> nil then
    avcodec_free_context(@FCtx); // libera e zera FCtx
  FCodec := nil;
  FConfigured := False;
end;

procedure TVideoDecoder.DoConfigure;
var
  Id: Integer;
begin
  FConfigLock.Enter;
  try
    FNeedConfig := False;
    Id := CodecId;
    FExtradata := FPendingExtra;
  finally
    FConfigLock.Leave;
  end;
  FNeedPrepend := True;

  if Length(FExtradata) = 0 then
    Log('SDP sem parameter sets (SPS/PPS só in-band)');

  ReleaseCodec;
  if Id = 0 then
  begin
    Log('codec de vídeo não suportado no backend FFmpeg');
    Exit;
  end;
  FCodec := avcodec_find_decoder(Id);
  if FCodec = nil then
  begin
    Log('avcodec_find_decoder falhou (id=' + IntToStr(Id) + ')');
    Exit;
  end;
  FCtx := avcodec_alloc_context3(FCodec);
  if FCtx = nil then
  begin
    Log('avcodec_alloc_context3 falhou');
    Exit;
  end;
  if avcodec_open2(FCtx, FCodec, nil) < 0 then
  begin
    Log('avcodec_open2 falhou');
    ReleaseCodec;
    Exit;
  end;
  FConfigured := True;
  FLoggedReady := False;
  FLoggedFrame := False;
  Log('FFmpeg decoder pronto (' + string(AnsiString(FCodec.name)) + ')');
end;

procedure TVideoDecoder.DecodeSample(const S: TSample);
var
  Ret: Integer;
  Buf: TBytes; // vive até o fim do método (mantém FPkt.data válido)
  ExtraLen: Integer;
begin
  if Length(S.Data) = 0 then Exit;

  // Prefixa os parameter sets (Annex-B) no 1o AU e nos keyframes, caso a
  // câmera só os mande no SDP. Se já vierem in-band, o FFmpeg ignora o dup.
  if (Length(FExtradata) > 0) and (FNeedPrepend or (sfKeyframe in S.Flags)) then
  begin
    ExtraLen := Length(FExtradata);
    SetLength(Buf, ExtraLen + Length(S.Data));
    Move(FExtradata[0], Buf[0], ExtraLen);
    Move(S.Data[0], Buf[ExtraLen], Length(S.Data));
    FPkt.data := PByte(@Buf[0]);
    FPkt.size := Length(Buf);
    // FNeedPrepend só é desligado quando um quadro sai de fato (ver
    // DrainFrames). Desligar aqui, no 1o sample, deixava o decoder órfão
    // quando o stream não traz IDR marcado: os parameter sets iam junto de um
    // P-frame, não davam início a nada, e nunca mais eram reenviados.
  end
  else
  begin
    FPkt.data := PByte(@S.Data[0]);
    FPkt.size := Length(S.Data);
  end;
  FPkt.pts := FInPts;
  FPkt.dts := FInPts;
  Inc(FInPts);
  Ret := avcodec_send_packet(FCtx, FPkt);
  if Ret = AVERROR_EAGAIN then
  begin
    // decoder cheio: drena e reenvia
    DrainFrames;
    avcodec_send_packet(FCtx, FPkt);
  end;
  FPkt.data := nil;
  FPkt.size := 0;
  DrainFrames;
end;

procedure TVideoDecoder.DrainFrames;
var
  Ret: Integer;
begin
  while True do
  begin
    Ret := avcodec_receive_frame(FCtx, FFrame);
    if (Ret = AVERROR_EAGAIN) or (Ret = AVERROR_EOF) then Break;
    if Ret < 0 then
    begin
      if not FLoggedRecvErr then
      begin
        FLoggedRecvErr := True;
        Log('avcodec_receive_frame erro (' + IntToStr(Ret) + ')');
      end;
      Break;
    end;
    // decodificou: a partir daqui os parameter sets só vão nos keyframes
    FNeedPrepend := False;
    ConvertAndStore;
    av_frame_unref(FFrame);
  end;
end;

procedure TVideoDecoder.EnsureSws(W, H, Fmt: Integer);
begin
  if (FSws <> nil) and (W = FSwsW) and (H = FSwsH) and (Fmt = FSwsFmt) then Exit;
  if FSws <> nil then
  begin
    sws_freeContext(FSws);
    FSws := nil;
  end;
  FSws := sws_getContext(W, H, Fmt, W, H, AV_PIX_FMT_RGBA, SWS_BILINEAR, nil, nil, nil);
  FSwsW := W; FSwsH := H; FSwsFmt := Fmt;
  if FSws = nil then
    Log('sws_getContext falhou (fmt=' + IntToStr(Fmt) + ')');
end;

procedure TVideoDecoder.ConvertAndStore;
var
  W, H, Fmt, Needed: Integer;
  DstData: array[0..3] of PByte;
  DstLines: array[0..3] of Integer;
  Tmp: TBytes;
begin
  W := FFrame.width;
  H := FFrame.height;
  Fmt := FFrame.format;
  if (W <= 0) or (H <= 0) then Exit;
  EnsureSws(W, H, Fmt);
  if FSws = nil then Exit;

  Needed := W * H * 4;
  if Length(FWorkRGBA) <> Needed then
    SetLength(FWorkRGBA, Needed);
  DstData[0] := @FWorkRGBA[0]; DstData[1] := nil; DstData[2] := nil; DstData[3] := nil;
  DstLines[0] := W * 4;        DstLines[1] := 0;  DstLines[2] := 0;  DstLines[3] := 0;
  sws_scale(FSws, @FFrame.data[0], @FFrame.linesize[0], 0, H, @DstData[0], @DstLines[0]);

  FFrameLock.Enter;
  try
    Tmp := FFrameRGBA; FFrameRGBA := FWorkRGBA; FWorkRGBA := Tmp; // swap
    FFrameW := W; FFrameH := H;
    FHasFrame := True;
  finally
    FFrameLock.Leave;
  end;

  Inc(FWinFrames);
  if not FLoggedFrame then
  begin
    FLoggedFrame := True;
    Log(Format('1o frame decodificado %dx%d (fmt=%d)', [W, H, Fmt]));
  end;
  QueuePresent;
end;

procedure TVideoDecoder.QueuePresent;
begin
  if TInterlocked.Exchange(FPresentQueued, 1) = 1 then Exit; // já há um present pendente
  TThread.Queue(nil,
    procedure
    begin
      TInterlocked.Exchange(FPresentQueued, 0);
      if Assigned(FOnFrame) then
        FOnFrame();
    end);
end;

procedure TVideoDecoder.LogStatsIfDue;
var
  NowMs: UInt64;
begin
  NowMs := TThread.GetTickCount64;
  if FStatTickMs = 0 then
  begin
    FStatTickMs := NowMs;
    Exit;
  end;
  if (NowMs - FStatTickMs) < 5000 then Exit;
  if FWinFrames > 0 then
    Log(Format('decodificando %dx%d, %d frames/5s', [FFrameW, FFrameH, FWinFrames]));
  FWinFrames := 0;
  FStatTickMs := NowMs;
end;

procedure TVideoDecoder.Execute;
var
  S: TSample;
begin
  FAvail := FFmpegLibAvailable;
  if not FAvail then
  begin
    if FLogger <> nil then
      FLogger.Warn(FTag, 'FFmpeg indisponível: coloque as DLLs do FFmpeg 7.x ' +
        '(avformat-61, avcodec-61, avutil-59, swscale-8) ao lado do .exe (vídeo não será decodificado)');
  end
  else
    try
      FFrame := av_frame_alloc;
      FPkt := av_packet_alloc;
    except
      on E: Exception do
      begin
        FAvail := False;
        if FLogger <> nil then
          FLogger.Warn(FTag, 'falha ao iniciar FFmpeg: ' + E.Message);
      end;
    end;

  while not Terminated do
  begin
    if TInterlocked.Exchange(FFlushReq, 0) = 1 then
      if FAvail and FConfigured and (FCtx <> nil) then
        avcodec_flush_buffers(FCtx);

    if FAvail and FNeedConfig then
      DoConfigure;

    if PopSample(S) then
    begin
      if FAvail and FConfigured then
      try
        DecodeSample(S);
      except
        on E: Exception do
        begin
          if FLogger <> nil then
            FLogger.Warn(FTag, 'EXCEÇÃO no decode: ' + E.Message + ' (recriando codec)');
          ReleaseCodec;
          FConfigLock.Enter;
          try FNeedConfig := True; finally FConfigLock.Leave; end;
        end;
      end;
      LogStatsIfDue;
    end
    else
      // curto: precisa re-checar o delay do jitter buffer com granularidade fina
      FDataEvent.WaitFor(15);
  end;

  if FAvail then
  begin
    ReleaseCodec;
    if FFrame <> nil then av_frame_free(@FFrame);
    if FPkt <> nil then av_packet_free(@FPkt);
  end;
end;

function TVideoDecoder.LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
begin
  FFrameLock.Enter;
  Result := FHasFrame and (FFrameW > 0) and (FFrameH > 0);
  if Result then
  begin
    RGBA := FFrameRGBA;
    W := FFrameW;
    H := FFrameH;
  end
  else
  begin
    RGBA := nil;
    W := 0;
    H := 0;
    FFrameLock.Leave; // sem frame: solta já (não haverá UnlockFrame)
  end;
end;

procedure TVideoDecoder.UnlockFrame;
begin
  FFrameLock.Leave;
end;

{$ENDIF MSWINDOWS}

end.
