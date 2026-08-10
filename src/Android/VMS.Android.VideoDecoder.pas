unit VMS.Android.VideoDecoder;

// Decodificador de vídeo por hardware (Android MediaCodec) em modo ByteBuffer.
// Entrada: access units Annex-B (TSample) vindos do depacketizer.
// Saída: frame RGBA pronto para blit num TImage (apresentado na UI thread).
//
// Threading:
//   - Configure()/Enqueue()/FlushReset() são chamados na thread de rede.
//   - A decodificação roda nesta própria thread (Execute).
//   - O frame pronto é sinalizado via OnFrame (TThread.Queue -> UI thread).

{$POINTERMATH ON}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Media,
  Androidapi.Helpers,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Android.JNIUtil,
  Androidapi.Jni;

type
  TVideoDecoder = class(TThread)
  strict private
    // fila de entrada (AUs comprimidas)
    FLock: TCriticalSection;
    FItems: TList<TSample>;
    FDataEvent: TEvent;
    // pedido de (re)configuração
    FConfigLock: TCriticalSection;
    FNeedConfig: Boolean;
    FPendingMime: string;
    FPendingW, FPendingH: Integer;
    FPendingExtra: TBytes;
    // codec
    FCodec: JMediaCodec;
    FBufferInfo: JMediaCodec_BufferInfo;
    FMime: string;
    FWidth, FHeight: Integer;
    FExtradata: TBytes;
    FGotKeyframe: Boolean;
    // fallback p/ decoder por software quando o de hardware falha (driver bugado
    // em certas resoluções). Escala após algumas falhas seguidas de decode.
    FUseSoftware: Boolean;
    FHwFailCount: Integer;
    // diagnóstico
    FLogger: ILogger;
    FInCount, FOutBufCount, FOutCount: Integer;
    FLoggedKey, FLoggedFrame, FWarnedNoOut, FLoggedNilImg: Boolean;
    FWarnedBufSize: Boolean;
    FStatTick: UInt64;
    FLastConvertTick: UInt64;
    FWinIn, FWinOut, FWinEnq: Integer;
    // downscale na conversão
    FSxTab: TArray<Integer>;
    FSxTabSrcW: Integer;
    FLoggedScale: Boolean;
    // frame de saída (RGBA, double-buffer)
    FFrameLock: TCriticalSection;
    FFrameRGBA: TBytes;   // pronto p/ apresentar (protegido por FFrameLock)
    FWorkRGBA: TBytes;    // buffer de trabalho da thread de decode
    FFrameW, FFrameH: Integer;
    FHasFrame: Boolean;
    FFramePending: Boolean;
    FOnFrame: TThreadProcedure;
    procedure DoConfigure;
    procedure ReleaseCodec;
    procedure DropForBound;
    function FeedAvailable: Boolean;
    function ShouldConvertNow: Boolean;
    procedure DrainOutput;
    procedure ProcessOutput(Index: Integer);
    procedure ConvertImage(const Img: JImage);
    procedure QueuePresent;
    procedure LogStatsIfDue;
  protected
    procedure Execute; override;
  public
    constructor Create(const ALogger: ILogger = nil);
    destructor Destroy; override;
    procedure Configure(Codec: TVideoCodec; W, H: Integer; const Extradata: TBytes);
    procedure Enqueue(const S: TSample);
    procedure FlushReset;
    // Acesso ao último frame; mantém o lock até UnlockFrame (chamar em par).
    function LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
    procedure UnlockFrame;
    property OnFrame: TThreadProcedure read FOnFrame write FOnFrame;
  end;

function VideoCodecMime(Codec: TVideoCodec): string;

implementation

const
  MAX_QUEUE = 120; // só rede de segurança: com feed-all a fila fica ~vazia
  DISPLAY_MIN_INTERVAL_MS = 33; // teto de ~30fps de conversão/exibição
  MAX_DISPLAY_DIM = 1280; // maior lado do frame exibido; acima disso faz downscale
  // android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
  COLOR_FormatYUV420Flexible = 2135033992;
  VIDEO_CLOCK = 90000.0;

function VideoCodecMime(Codec: TVideoCodec): string;
begin
  case Codec of
    vcH264:  Result := 'video/avc';
    vcH265:  Result := 'video/hevc';
    vcMJPEG: Result := 'video/mjpeg';
  else
    Result := '';
  end;
end;

{ TVideoDecoder }

constructor TVideoDecoder.Create(const ALogger: ILogger);
begin
  inherited Create(True); // suspenso: inicializa campos antes de Execute
  FreeOnTerminate := False;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FConfigLock := TCriticalSection.Create;
  FFrameLock := TCriticalSection.Create;
  FItems := TList<TSample>.Create;
  FDataEvent := TEvent.Create(nil, True, False, '');
  Start;
end;

destructor TVideoDecoder.Destroy;
begin
  Terminate;
  FDataEvent.SetEvent;
  WaitFor;
  TThread.RemoveQueuedEvents(Self); // descarta presents pendentes na UI
  FItems.Free;
  FDataEvent.Free;
  FLock.Free;
  FConfigLock.Free;
  FFrameLock.Free;
  inherited;
end;

procedure TVideoDecoder.Configure(Codec: TVideoCodec; W, H: Integer; const Extradata: TBytes);
begin
  FConfigLock.Enter;
  try
    FPendingMime := VideoCodecMime(Codec);
    FPendingW := W;
    FPendingH := H;
    FPendingExtra := Copy(Extradata);
    FNeedConfig := True;
    // Novo formato: recomeça tentando hardware (escala p/ software se falhar).
    FUseSoftware := False;
    FHwFailCount := 0;
  finally
    FConfigLock.Leave;
  end;
end;

procedure TVideoDecoder.DropForBound;
var
  I, DropIdx: Integer;
begin
  // Mantém a fila limitada para baixa latência: descarta o AU não-keyframe
  // mais antigo; se só houver keyframes, descarta o mais antigo.
  while FItems.Count > MAX_QUEUE do
  begin
    DropIdx := 0;
    for I := 0 to FItems.Count - 1 do
      if not (sfKeyframe in FItems[I].Flags) then
      begin
        DropIdx := I;
        Break;
      end;
    FItems.Delete(DropIdx);
  end;
end;

procedure TVideoDecoder.Enqueue(const S: TSample);
begin
  FLock.Enter;
  try
    FItems.Add(S);
    DropForBound;
  finally
    FLock.Leave;
  end;
  Inc(FWinEnq); // contador de diagnóstico (race benigno)
  FDataEvent.SetEvent;
end;

procedure TVideoDecoder.FlushReset;
begin
  FLock.Enter;
  try
    FItems.Clear;
    FDataEvent.ResetEvent;
  finally
    FLock.Leave;
  end;
end;

// Alimenta o máximo de AUs possível enquanto houver input buffer livre no codec.
// NUNCA descarta AU comprimido: se não houver buffer, deixa na fila p/ a próxima
// iteração (o decode HW libera buffers rápido). Mantém o GOP íntegro.
function TVideoDecoder.FeedAvailable: Boolean;
var
  S: TSample;
  Idx: Integer;
  Buf: JByteBuffer;
  NewKey, Got: Boolean;
begin
  Result := False;
  NewKey := False;
  // IMPORTANTE: só o pop da fila é feito sob o FLock (rápido). As chamadas JNI
  // ao MediaCodec ficam FORA do lock — senão a thread de rede (Enqueue) fica
  // bloqueada durante o decode, o socket TCP não é drenado e a câmera
  // estrangula o envio (backpressure). Só esta thread mexe no codec.
  while True do
  begin
    FLock.Enter;
    try
      Got := FItems.Count > 0;
    finally
      FLock.Leave;
    end;
    if not Got then Break;

    Idx := FCodec.dequeueInputBuffer(0); // JNI, não-bloqueante, fora do lock
    if Idx < 0 then Break;               // sem buffer livre agora

    FLock.Enter;
    try
      Got := FItems.Count > 0;
      if Got then
      begin
        S := FItems[0];
        FItems.Delete(0);
      end;
      if FItems.Count = 0 then
        FDataEvent.ResetEvent;
    finally
      FLock.Leave;
    end;
    if not Got then
    begin
      FCodec.queueInputBuffer(Idx, 0, 0, 0, 0); // devolve o buffer (raríssimo)
      Break;
    end;

    // alimenta o AU (JNI + memcpy) FORA do lock
    Buf := FCodec.getInputBuffer(Idx);
    if Buf = nil then
    begin
      FCodec.queueInputBuffer(Idx, 0, 0, 0, 0); // devolve o buffer vazio
      Continue;
    end;
    // Proteção: o AU TEM que caber no buffer de entrada. Se não couber, copiar
    // estoura a memória nativa e mata o codec ("Released state"). Nesse caso
    // descarta o AU (com max-input-size correto isso praticamente não ocorre).
    if Length(S.Data) > Buf.capacity then
    begin
      if (not FWarnedBufSize) and (FLogger <> nil) then
      begin
        FWarnedBufSize := True;
        FLogger.Warn('video', Format('AU %d bytes nao cabe no buffer de entrada (cap=%d); descartando',
          [Length(S.Data), Buf.capacity]));
      end;
      FCodec.queueInputBuffer(Idx, 0, 0, 0, 0); // devolve o buffer vazio
      Continue;
    end;
    CopyToDirectBuffer(Buf, S.Data, Length(S.Data));
    FCodec.queueInputBuffer(Idx, 0, Length(S.Data),
      Round(S.Pts * (1000000.0 / VIDEO_CLOCK)), 0);
    Inc(FInCount);
    Inc(FWinIn);
    if (not FLoggedKey) and (sfKeyframe in S.Flags) then
    begin
      FLoggedKey := True;
      NewKey := True;
    end;
    Result := True;
  end;
  if NewKey and (FLogger <> nil) then
    FLogger.Info('video', 'keyframe (IDR) recebido');
end;

// Limita a conversão/exibição ao teto de fps (poupa CPU em streams leves;
// no caso pesado a própria conversão já é o limite).
function TVideoDecoder.ShouldConvertNow: Boolean;
var
  NowTick: UInt64;
begin
  NowTick := TThread.GetTickCount64;
  if (FLastConvertTick = 0) or ((NowTick - FLastConvertTick) >= DISPLAY_MIN_INTERVAL_MS) then
  begin
    FLastConvertTick := NowTick;
    Result := True;
  end
  else
    Result := False;
end;

procedure TVideoDecoder.ReleaseCodec;
begin
  if FCodec <> nil then
  begin
    try FCodec.stop; except end;
    try FCodec.release; except end;
    FCodec := nil;
  end;
  FGotKeyframe := False;
end;

// --- Extração da resolução real do SPS H265 (csd-0 Annex-B) ---
// O Android novo (MediaCodec estrito) erra ("Released state") se configuramos
// com uma resolução que não bate com o stream. Parseamos a resolução do SPS
// pra configurar certo. Se falhar, o chamador usa o placeholder.
type
  TBitRdr = record
    Data: TBytes;
    BitPos, BitLen: Integer;
    function Bit: Integer;
    function Bits(N: Integer): Cardinal;
    function UE: Cardinal;
    function SE: Integer;
  end;

function TBitRdr.Bit: Integer;
begin
  if BitPos >= BitLen then Exit(0);
  Result := (Data[BitPos shr 3] shr (7 - (BitPos and 7))) and 1;
  Inc(BitPos);
end;

function TBitRdr.Bits(N: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to N do
    Result := (Result shl 1) or Cardinal(Bit);
end;

function TBitRdr.UE: Cardinal;
var
  Lz: Integer;
begin
  Lz := 0;
  while (BitPos < BitLen) and (Bit = 0) do
    Inc(Lz);
  if (Lz = 0) or (Lz > 31) then Exit(0);
  Result := (Cardinal(1) shl Lz) - 1 + Bits(Lz);
end;

function TBitRdr.SE: Integer;
var
  K: Cardinal;
begin
  K := UE;
  if (K and 1) = 1 then
    Result := Integer((K + 1) shr 1)
  else
    Result := -Integer(K shr 1);
end;

// Acha o NAL SPS no csd Annex-B e devolve o RBSP (sem header NAL, sem emulation
// prevention). H265: header de 2 bytes, tipo = (b0 shr 1) and $3F, SPS=33.
// H264: header de 1 byte, tipo = b0 and $1F, SPS=7.
function ExtractSpsRbsp(const Csd: TBytes; IsH265: Boolean; out Rbsp: TBytes): Boolean;
var
  I, N, NalStart, NalEnd, NalType, J, K, HdrLen, WantType: Integer;
  Raw: TBytes;
begin
  Result := False;
  N := Length(Csd);
  if IsH265 then
  begin
    WantType := 33; HdrLen := 2;
  end
  else
  begin
    WantType := 7; HdrLen := 1;
  end;
  I := 0;
  while I + 3 < N do
  begin
    if (Csd[I] = 0) and (Csd[I + 1] = 0) and (Csd[I + 2] = 1) then
    begin
      NalStart := I + 3;
      if IsH265 then
        NalType := (Csd[NalStart] shr 1) and $3F
      else
        NalType := Csd[NalStart] and $1F;
      NalEnd := N;
      K := NalStart + HdrLen;
      while K + 2 < N do
      begin
        if (Csd[K] = 0) and (Csd[K + 1] = 0) and (Csd[K + 2] = 1) then
        begin
          NalEnd := K;
          Break;
        end;
        Inc(K);
      end;
      if NalType = WantType then
      begin
        if NalEnd - (NalStart + HdrLen) < 4 then Exit; // NAL curto demais
        SetLength(Raw, NalEnd - (NalStart + HdrLen));
        J := 0;
        K := NalStart + HdrLen;
        while K < NalEnd do
        begin
          if (K + 2 < NalEnd) and (Csd[K] = 0) and (Csd[K + 1] = 0) and (Csd[K + 2] = 3) then
          begin
            Raw[J] := 0; Raw[J + 1] := 0; Inc(J, 2);
            Inc(K, 3);
          end
          else
          begin
            Raw[J] := Csd[K]; Inc(J); Inc(K);
          end;
        end;
        SetLength(Raw, J);
        Rbsp := Raw;
        Exit(True);
      end;
      I := NalEnd;
    end
    else
      Inc(I);
  end;
end;

function ParseH265Resolution(const Csd: TBytes; out W, H: Integer): Boolean;
var
  Rbsp: TBytes;
  R: TBitRdr;
  MaxSub, ChromaIdc: Integer;
begin
  Result := False;
  W := 0; H := 0;
  if not ExtractSpsRbsp(Csd, True, Rbsp) then Exit;
  if Length(Rbsp) < 16 then Exit;
  R.Data := Rbsp;
  R.BitPos := 0;
  R.BitLen := Length(Rbsp) * 8;
  R.Bits(4);              // sps_video_parameter_set_id
  MaxSub := R.Bits(3);    // sps_max_sub_layers_minus1
  R.Bit;                  // sps_temporal_id_nesting_flag
  if MaxSub <> 0 then Exit; // profile_tier_level com sub-layers: não parseamos
  R.BitPos := R.BitPos + 96; // profile_tier_level (96 bits p/ maxSub=0)
  if R.BitPos >= R.BitLen then Exit;
  R.UE;                   // sps_seq_parameter_set_id
  ChromaIdc := R.UE;      // chroma_format_idc
  if ChromaIdc = 3 then R.Bit; // separate_colour_plane_flag
  W := Integer(R.UE);     // pic_width_in_luma_samples
  H := Integer(R.UE);     // pic_height_in_luma_samples
  if (W >= 16) and (W <= 8192) and (H >= 16) and (H <= 8192) then
    Result := True
  else
  begin
    W := 0; H := 0;
  end;
end;

function ParseH264Resolution(const Csd: TBytes; out W, H: Integer): Boolean;
var
  Rbsp: TBytes;
  R: TBitRdr;
  ProfileIdc, ChromaIdc, FrameMbsOnly, I: Integer;
  PicOrderType, NumRef, WidthMbs, HeightMapUnits: Cardinal;
begin
  Result := False;
  W := 0; H := 0;
  if not ExtractSpsRbsp(Csd, False, Rbsp) then Exit;
  if Length(Rbsp) < 4 then Exit;
  R.Data := Rbsp;
  R.BitPos := 0;
  R.BitLen := Length(Rbsp) * 8;
  ProfileIdc := Integer(R.Bits(8));  // profile_idc
  R.Bits(8);                         // constraint flags + reserved
  R.Bits(8);                         // level_idc
  R.UE;                              // seq_parameter_set_id
  if ProfileIdc in [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135] then
  begin
    ChromaIdc := Integer(R.UE);      // chroma_format_idc
    if ChromaIdc = 3 then R.Bit;     // separate_colour_plane_flag
    R.UE;                            // bit_depth_luma_minus8
    R.UE;                            // bit_depth_chroma_minus8
    R.Bit;                           // qpprime_y_zero_transform_bypass_flag
    if R.Bit = 1 then Exit;          // seq_scaling_matrix: não parseamos (raro) -> placeholder
  end;
  R.UE;                              // log2_max_frame_num_minus4
  PicOrderType := R.UE;              // pic_order_cnt_type
  if PicOrderType = 0 then
    R.UE                             // log2_max_pic_order_cnt_lsb_minus4
  else if PicOrderType = 1 then
  begin
    R.Bit;                           // delta_pic_order_always_zero_flag
    R.SE;                            // offset_for_non_ref_pic
    R.SE;                            // offset_for_top_to_bottom_field
    NumRef := R.UE;                  // num_ref_frames_in_pic_order_cnt_cycle
    if NumRef > 255 then Exit;       // sanidade
    for I := 1 to Integer(NumRef) do
      R.SE;                          // offset_for_ref_frame[i]
  end;
  R.UE;                              // max_num_ref_frames
  R.Bit;                             // gaps_in_frame_num_value_allowed_flag
  WidthMbs := R.UE;                  // pic_width_in_mbs_minus1
  HeightMapUnits := R.UE;            // pic_height_in_map_units_minus1
  FrameMbsOnly := R.Bit;             // frame_mbs_only_flag
  W := (Integer(WidthMbs) + 1) * 16;
  H := (Integer(HeightMapUnits) + 1) * 16 * (2 - FrameMbsOnly);
  if (W >= 16) and (W <= 8192) and (H >= 16) and (H <= 8192) then
    Result := True
  else
  begin
    W := 0; H := 0;
  end;
end;

// Procura um decoder POR SOFTWARE para o mime (nomes AOSP "c2.android.*" ou
// "omx.google.*"). Vazio se não achar. Usado como fallback quando o decoder de
// hardware do aparelho falha (bug de driver em certas resoluções).
function FindSoftwareDecoder(const Mime: string): string;
var
  List: JMediaCodecList;
  Infos: TJavaObjectArray<JMediaCodecInfo>;
  Info: JMediaCodecInfo;
  Types: TJavaObjectArray<JString>;
  I, J: Integer;
  Name, LName, WantMime: string;
begin
  Result := '';
  WantMime := LowerCase(Mime);
  try
    List := TJMediaCodecList.JavaClass.init(TJMediaCodecList.JavaClass.REGULAR_CODECS);
    Infos := List.getCodecInfos;
    if Infos = nil then Exit;
    for I := 0 to Infos.Length - 1 do
    begin
      Info := Infos.Items[I];
      if Info.isEncoder then Continue;
      Name := JStringToString(Info.getName);
      LName := LowerCase(Name);
      if (Pos('c2.android.', LName) <> 1) and (Pos('omx.google.', LName) <> 1) then
        Continue;
      Types := Info.getSupportedTypes;
      if Types = nil then Continue;
      for J := 0 to Types.Length - 1 do
        if LowerCase(JStringToString(Types.Items[J])) = WantMime then
        begin
          Result := Name;
          Exit;
        end;
    end;
  except
    on E: Exception do
      Result := '';
  end;
end;

procedure TVideoDecoder.DoConfigure;
var
  MaxIn: Integer;

  function TryCfg(CW, CH: Integer): Boolean;
  var
    Fmt: JMediaFormat;
    SwName: string;
  begin
    Result := False;
    try
      SwName := '';
      if FUseSoftware then
        SwName := FindSoftwareDecoder(FMime);
      if SwName <> '' then
        FCodec := TJMediaCodec.JavaClass.createByCodecName(StringToJString(SwName))
      else
        FCodec := TJMediaCodec.JavaClass.createDecoderByType(StringToJString(FMime));
      Fmt := TJMediaFormat.JavaClass.createVideoFormat(StringToJString(FMime), CW, CH);
      Fmt.setInteger(StringToJString('color-format'), COLOR_FormatYUV420Flexible);
      // Buffer de entrada grande o bastante pro keyframe (comprimido) caber.
      Fmt.setInteger(StringToJString('max-input-size'), MaxIn);
      if Length(FExtradata) > 0 then
        Fmt.setByteBuffer(StringToJString('csd-0'), BytesToDirectBuffer(FExtradata));
      FCodec.configure(Fmt, nil, nil, 0);
      FCodec.start;
      Result := True;
      if FLogger <> nil then
        FLogger.Info('video', 'decoder: ' + JStringToString(FCodec.getName));
    except
      on E: Exception do
      begin
        if FLogger <> nil then
          FLogger.Error('video', Format('falha ao configurar %s %dx%d: %s: %s',
            [FMime, CW, CH, E.ClassName, E.Message]));
        ReleaseCodec;
      end;
    end;
  end;

begin
  FConfigLock.Enter;
  try
    FMime := FPendingMime;
    FWidth := FPendingW;
    FHeight := FPendingH;
    FExtradata := Copy(FPendingExtra);
    FNeedConfig := False;
  finally
    FConfigLock.Leave;
  end;

  ReleaseCodec;
  if FMime = '' then
  begin
    if FLogger <> nil then
      FLogger.Warn('video', 'config invalida (mime vazio)');
    Exit;
  end;
  // Resolução real do SPS (csd-0), quando disponível. Serve pra (a) tentar
  // configurar já na resolução certa e (b) dimensionar o buffer de entrada, que
  // precisa comportar o keyframe do stream real (senão CopyToDirectBuffer estoura
  // a memória nativa e o codec morre com "Released state" no Android novo).
  if (FWidth <= 0) and (Length(FExtradata) > 0) then
  begin
    if FMime = 'video/hevc' then
      ParseH265Resolution(FExtradata, FWidth, FHeight)
    else if FMime = 'video/avc' then
      ParseH264Resolution(FExtradata, FWidth, FHeight);
    if (FWidth > 0) and (FLogger <> nil) then
      FLogger.Info('video', Format('resolucao do SPS: %dx%d', [FWidth, FHeight]));
  end;
  if FWidth <= 0 then FWidth := 1920;
  if FHeight <= 0 then FHeight := 1080;

  // max-input-size = nº de pixels de luma (generoso; keyframe comprimido é bem
  // menor), com piso de 2 MB. Vale mesmo no fallback 1920x1080, pra o keyframe
  // do stream maior ainda caber no buffer.
  MaxIn := FWidth * FHeight;
  if MaxIn < 2 * 1024 * 1024 then MaxIn := 2 * 1024 * 1024;

  if FLogger <> nil then
    FLogger.Info('video', Format('configurando %s %dx%d csd=%d bytes maxin=%d',
      [FMime, FWidth, FHeight, Length(FExtradata), MaxIn]));

  // Tenta na resolução real; se o device rejeitar (ex. decoder HEVC que não
  // aceita 1440p), cai pro 1920x1080 e deixa o MediaCodec crescer pelo stream.
  if not TryCfg(FWidth, FHeight) then
  begin
    if (FWidth <> 1920) or (FHeight <> 1080) then
    begin
      if FLogger <> nil then
        FLogger.Warn('video', 'configure falhou; tentando fallback 1920x1080');
      if not TryCfg(1920, 1080) then Exit;
    end
    else
      Exit;
  end;

  // Se temos csd (SPS/PPS) o decoder já está configurado: aguardamos o
  // primeiro keyframe. Sem csd, alimentamos tudo (SPS/PPS chegam in-band).
  FGotKeyframe := True; // sem gate: MediaCodec sincroniza no 1º IDR sozinho
  FInCount := 0;
  FOutBufCount := 0;
  FOutCount := 0;
  FLoggedKey := False;
  FLoggedFrame := False;
  FWarnedNoOut := False;
  FWarnedBufSize := False;
  FLoggedNilImg := False;
  FStatTick := 0;
  FLastConvertTick := 0;
  FWinIn := 0;
  FWinOut := 0;
  FWinEnq := 0;
  FSxTabSrcW := 0; // força reconstrução da tabela de downscale
  FLoggedScale := False;
  if FLogger <> nil then
    FLogger.Info('video', Format('decoder iniciado (csd=%d, alimentando todos os AUs)',
      [Length(FExtradata)]));

  FLock.Enter;
  try
    FItems.Clear;
    FDataEvent.ResetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TVideoDecoder.DrainOutput;
var
  Idx, Latest: Integer;
begin
  // Drena TODAS as saídas; libera os frames decodificados antigos SEM converter
  // e converte/apresenta só o mais recente (respeitando o teto de fps). Como as
  // saídas são liberadas rápido, o decoder não trava esperando conversão ->
  // a entrada não acumula -> sem descarte de AU comprimido -> sem artefato.
  Latest := -1;
  Idx := FCodec.dequeueOutputBuffer(FBufferInfo, 0);
  while Idx >= 0 do
  begin
    Inc(FOutBufCount);
    if Latest >= 0 then
      FCodec.releaseOutputBuffer(Latest, False); // descarta decodificado antigo
    Latest := Idx;
    Idx := FCodec.dequeueOutputBuffer(FBufferInfo, 0);
  end;
  if Latest >= 0 then
  begin
    if ShouldConvertNow then
      ProcessOutput(Latest);
    FCodec.releaseOutputBuffer(Latest, False);
  end;
end;

procedure TVideoDecoder.ProcessOutput(Index: Integer);
var
  Img: JImage;
begin
  Img := FCodec.getOutputImage(Index);
  if Img = nil then
  begin
    if (not FLoggedNilImg) then
    begin
      FLoggedNilImg := True;
      if FLogger <> nil then
        FLogger.Warn('video', 'getOutputImage retornou nil (color-format nao mapeavel p/ Image)');
    end;
    Exit;
  end;
  try
    ConvertImage(Img);
  finally
    Img.close;
  end;
  Inc(FOutCount);
  Inc(FWinOut);
  FHwFailCount := 0; // decode funcionou; não escala p/ software
  if (not FLoggedFrame) then
  begin
    FLoggedFrame := True;
    if FLogger <> nil then
      FLogger.Info('video', Format('primeiro frame decodificado %dx%d', [FFrameW, FFrameH]));
  end;
  QueuePresent;
end;

procedure TVideoDecoder.LogStatsIfDue;
var
  NowTick: UInt64;
begin
  if FCodec = nil then Exit;
  NowTick := TThread.GetTickCount64;
  if FStatTick = 0 then
  begin
    FStatTick := NowTick;
    Exit;
  end;
  if (NowTick - FStatTick) < 5000 then Exit;
  if FLogger <> nil then
    FLogger.Info('video', Format('janela 5s: enq=%d in=%d out=%d frames',
      [FWinEnq, FWinIn, FWinOut]));
  FWinIn := 0;
  FWinOut := 0;
  FWinEnq := 0;
  FStatTick := NowTick;
end;

procedure TVideoDecoder.ConvertImage(const Img: JImage);
var
  W, H, DW, DH, X, Y, LongSide, Sx, Sy, Cx, Cy: Integer;
  Planes: TJavaObjectArray<JImage_Plane>;
  YP, UP, VP: JImage_Plane;
  YPtr, UPtr, VPtr: PByte;
  YRow, URow, VRow, UPix, VPix: Integer;
  Y0, U0, V0, C, D, E, R, G, B, Stride: Integer;
  OutRow: PByte;
  Tmp: TBytes;
begin
  W := Img.getWidth;
  H := Img.getHeight;
  if (W <= 0) or (H <= 0) then Exit;

  Planes := Img.getPlanes;
  YP := Planes.Items[0];
  UP := Planes.Items[1];
  VP := Planes.Items[2];
  YPtr := DirectBufferAddress(YP.getBuffer); YRow := YP.getRowStride;
  UPtr := DirectBufferAddress(UP.getBuffer); URow := UP.getRowStride; UPix := UP.getPixelStride;
  VPtr := DirectBufferAddress(VP.getBuffer); VRow := VP.getRowStride; VPix := VP.getPixelStride;
  if (YPtr = nil) or (UPtr = nil) or (VPtr = nil) then Exit;

  // Tamanho de destino: limita o maior lado a MAX_DISPLAY_DIM (downscale nearest).
  // Corta o custo da conversão e do blit; o TImage (WrapMode=Fit) reescala.
  LongSide := W;
  if H > LongSide then LongSide := H;
  if LongSide > MAX_DISPLAY_DIM then
  begin
    DW := Integer((Int64(W) * MAX_DISPLAY_DIM) div LongSide);
    DH := Integer((Int64(H) * MAX_DISPLAY_DIM) div LongSide);
    if DW < 1 then DW := 1;
    if DH < 1 then DH := 1;
  end
  else
  begin
    DW := W;
    DH := H;
  end;

  if (not FLoggedScale) and (FLogger <> nil) then
  begin
    FLoggedScale := True;
    if (DW <> W) or (DH <> H) then
      FLogger.Info('video', Format('downscale %dx%d -> %dx%d', [W, H, DW, DH]))
    else
      FLogger.Info('video', Format('sem downscale (%dx%d)', [W, H]));
  end;

  // Tabela: X de origem para cada X de destino (sem mult/div no laço interno).
  if (Length(FSxTab) <> DW) or (FSxTabSrcW <> W) then
  begin
    SetLength(FSxTab, DW);
    for X := 0 to DW - 1 do
      FSxTab[X] := Integer((Int64(X) * W) div DW);
    FSxTabSrcW := W;
  end;

  // Conversão pesada fora do lock, no buffer de trabalho (já no tamanho de destino).
  Stride := DW * 4;
  if Length(FWorkRGBA) <> Stride * DH then
    SetLength(FWorkRGBA, Stride * DH);
  for Y := 0 to DH - 1 do
  begin
    Sy := Integer((Int64(Y) * H) div DH);
    Cy := Sy shr 1;
    OutRow := @FWorkRGBA[Y * Stride];
    for X := 0 to DW - 1 do
    begin
      Sx := FSxTab[X];
      Cx := Sx shr 1;
      Y0 := (YPtr + (Sy * YRow + Sx))^;
      U0 := (UPtr + (Cy * URow + Cx * UPix))^;
      V0 := (VPtr + (Cy * VRow + Cx * VPix))^;
      C := Y0 - 16; D := U0 - 128; E := V0 - 128;
      // shr em Integer é shift LÓGICO: um valor negativo viraria um positivo
      // enorme (preto -> branco). Tratar o negativo ANTES de deslocar.
      R := 298 * C + 409 * E + 128;
      G := 298 * C - 100 * D - 208 * E + 128;
      B := 298 * C + 516 * D + 128;
      if R < 0 then R := 0 else R := R shr 8;
      if G < 0 then G := 0 else G := G shr 8;
      if B < 0 then B := 0 else B := B shr 8;
      if R > 255 then R := 255;
      if G > 255 then G := 255;
      if B > 255 then B := 255;
      OutRow^ := Byte(R); Inc(OutRow);
      OutRow^ := Byte(G); Inc(OutRow);
      OutRow^ := Byte(B); Inc(OutRow);
      OutRow^ := 255;     Inc(OutRow);
    end;
  end;

  // Troca rápida sob lock (O(1)).
  FFrameLock.Enter;
  try
    Tmp := FFrameRGBA;
    FFrameRGBA := FWorkRGBA;
    FWorkRGBA := Tmp;
    FFrameW := DW;
    FFrameH := DH;
    FHasFrame := True;
  finally
    FFrameLock.Leave;
  end;
end;

procedure TVideoDecoder.QueuePresent;
var
  NeedQueue: Boolean;
begin
  NeedQueue := False;
  FFrameLock.Enter;
  try
    if not FFramePending then
    begin
      FFramePending := True;
      NeedQueue := True;
    end;
  finally
    FFrameLock.Leave;
  end;
  if NeedQueue then
    TThread.Queue(Self,
      procedure
      begin
        FFrameLock.Enter;
        try
          FFramePending := False;
        finally
          FFrameLock.Leave;
        end;
        if Assigned(FOnFrame) then
          FOnFrame();
      end);
end;

function TVideoDecoder.LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
begin
  FFrameLock.Enter;
  if not FHasFrame then
  begin
    FFrameLock.Leave;
    Exit(False);
  end;
  RGBA := FFrameRGBA;
  W := FFrameW;
  H := FFrameH;
  Result := True;
end;

procedure TVideoDecoder.UnlockFrame;
begin
  FFrameLock.Leave;
end;

procedure TVideoDecoder.Execute;
var
  Fed: Boolean;
begin
  FBufferInfo := TJMediaCodec_BufferInfo.JavaClass.init;
  while not Terminated do
  begin
    try
      if FNeedConfig then
        DoConfigure;
      if FCodec = nil then
      begin
        TThread.Sleep(10);
        Continue;
      end;
      Fed := FeedAvailable;
      DrainOutput;

      if (not FWarnedNoOut) and (FInCount >= 90) and (FOutBufCount = 0) then
      begin
        FWarnedNoOut := True;
        if FLogger <> nil then
          FLogger.Warn('video', Format('%d AUs enviados, 0 frames do decoder ' +
            '(verifique csd/keyframe/codec)', [FInCount]));
      end;

      if not Fed then
        FDataEvent.WaitFor(5); // sem entrada agora: espera curta por novos AUs
      LogStatsIfDue;
    except
      on E: Exception do
      begin
        // NÃO deixar a thread morrer em silêncio (era o que escondia a falha no
        // Android novo). Loga e recria o codec na próxima volta.
        if FLogger <> nil then
          FLogger.Error('video', Format('EXCECAO no decode (%s): %s -> recria codec',
            [E.ClassName, E.Message]));
        ReleaseCodec;
        // Se o decoder de hardware falha repetidamente (driver bugado em certas
        // resoluções), escala para o decoder por software na próxima config.
        Inc(FHwFailCount);
        if (not FUseSoftware) and (FHwFailCount >= 2) then
        begin
          FUseSoftware := True;
          if FLogger <> nil then
            FLogger.Warn('video', 'decoder de hardware falhando; mudando para software');
        end;
        FNeedConfig := True;
        TThread.Sleep(50);
      end;
    end;
  end;
  ReleaseCodec;
end;

end.
