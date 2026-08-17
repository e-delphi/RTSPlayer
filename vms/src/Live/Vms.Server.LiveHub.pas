unit Vms.Server.LiveHub;

// Caminho ao vivo que não passa pelo disco.
//
// Por que existe: o servidor publicava /live/<camera> lendo o .vms que o
// gravador estava escrevendo, e o arquivo só cresce quando um bloco FECHA
// (block.maxDurationMs, 2 s). Somada a idade do último keyframe, a latência
// ficava entre 2 e 6 s. Aqui a sessão da câmera entrega o sample ao mesmo tempo
// para o gravador e para este hub, e o servidor RTSP lê da memória: o sample sai
// para o cliente no instante em que chega da câmera. O arquivo continua sendo
// escrito, mas só é lido para histórico (e como plano B, quando a câmera ainda
// não conectou nesta execução).
//
// Um TLiveStream por câmera, buffer circular com teto de tempo e de bytes.
// Guardar alguns segundos serve para dois propósitos: dar ao cliente que acaba
// de chegar um keyframe recente (senão a tela fica preta até o próximo) e
// absorver um cliente lento sem segurar a câmera.
//
// Threading: publicação vem da thread da sessão da câmera (uma por câmera);
// consumo vem da thread do pacer de cada cliente (várias). Tudo que toca o anel
// está sob TMonitor do próprio TLiveStream, e o publicador dá PulseAll para
// acordar quem espera. Nenhum envio de rede acontece com o lock na mão: o Fetch
// copia as referências e devolve.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.MediaSink,
  VMS.Rec.Format;

const
  LIVE_DEFAULT_BUFFER_MS = 4000;
  LIVE_DEFAULT_MAX_BYTES = 32 * 1024 * 1024;
  // Teto de samples no anel. Só entra em jogo se o teto de bytes e o de tempo
  // não pegarem antes (áudio G711 são 50 samples/s minúsculos por câmera).
  LIVE_RING_CAPACITY = 8192;
  // RTP de vídeo é 90 kHz. Mesma base do TRecordingSink e do que o SDP anuncia.
  LIVE_VIDEO_TIMESCALE = 90000;

type
  TLiveConfig = record
    Enabled: Boolean;
    BufferMs: Integer;
    MaxBytes: Int64;
    function Describe: string;
  end;

  TLiveSampleRec = record
    TrackId: Byte;      // 0 = vídeo, 1 = áudio (mesma numeração do .vms)
    Pts: Int64;
    Keyframe: Boolean;
    WallMs: Int64;      // chegada, no relógio monotônico
    Data: TBytes;
  end;

  // Posição de um cliente dentro do anel. Fica com o chamador: o stream não
  // guarda lista de assinantes, então cliente que morre não deixa rastro.
  TLiveCursor = record
    NextSeq: Int64;
    Epoch: Integer;
    WaitKeyframe: Boolean;
    Valid: Boolean;
  end;

  TLiveFetch = (
    lfNone,          // nada novo dentro do timeout
    lfSamples,       // samples em sequência
    lfResync,        // o cliente ficou para trás e foi reposicionado
    lfFormatChanged  // a câmera voltou com outro codec: o SDP entregue caducou
  );

  TLiveStream = class
  strict private
    FName: string;
    FLogger: ILogger;
    FClock: IClock;
    FBufferMs: Int64;
    FMaxBytes: Int64;
    FItems: array of TLiveSampleRec;
    FFirstSeq: Int64;   // samples válidos são [FFirstSeq, FNextSeq)
    FNextSeq: Int64;
    FBytes: Int64;
    FEpoch: Integer;
    FHasVideo: Boolean;
    FVideo: TVideoTrackInfo;
    FHasAudio: Boolean;
    FAudio: TAudioTrackInfo;
    FLastSampleMs: Int64;
    function SlotOf(Seq: Int64): Integer;
    procedure DropOldestLocked;
    procedure TrimLocked;
    procedure ClearSamplesLocked;
    function LastKeyframeSeqLocked: Int64;
    procedure PositionLocked(var Cursor: TLiveCursor);
    procedure Log(Level: TLogLevel; const Msg: string);
  public
    constructor Create(const AName: string; ABufferMs: Integer; AMaxBytes: Int64;
                       const ALogger: ILogger; const AClock: IClock);

    { publicação — thread da sessão da câmera }
    procedure PublishVideoFormat(Codec: TVideoCodec; Width, Height: Word;
                                 const Extradata: TBytes);
    procedure PublishAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
                                 Channels: Byte; const Extradata: TBytes);
    procedure PublishSample(const Sample: TSample);
    // Câmera caiu: o que está no anel é passado, e o cliente que continuar
    // conectado não deve receber isso emendado no que vier depois da reconexão.
    procedure NotifyStopped;

    { consumo — thread do pacer de cada cliente }
    // Monta um TVmsHeader com os formatos correntes, para reusar o mesmo
    // BuildSdpForHeader do caminho de arquivo. False = câmera ainda não
    // anunciou vídeo nesta execução.
    function TryGetHeader(out Header: TVmsHeader): Boolean;
    // Posiciona no keyframe mais recente do anel (entrada imediata na imagem);
    // sem keyframe guardado, posiciona no fim e segura o vídeo até vir um.
    function Subscribe(out Cursor: TLiveCursor): Boolean;
    function Fetch(var Cursor: TLiveCursor; TimeoutMs: Integer;
                   out Items: TArray<TLiveSampleRec>): TLiveFetch;
    // A câmera entregou mídia há pouco? Diferente de "já anunciou formato": os
    // formatos ficam guardados depois que a câmera cai, e o que interessa a quem
    // pergunta (a API, para dizer se está ao vivo) é o agora.
    function IsPublishing(WithinMs: Int64 = 10000): Boolean;
    // Os samples de vídeo em memória, do keyframe mais recente em diante, para
    // quem precisa olhar dentro do bitstream (o SDP tira daí os parameter sets
    // de verdade, em vez de confiar no que a câmera anunciou).
    function RecentVideoSamples(Max: Integer): TArray<TBytes>;

    property Name: string read FName;
  end;

  TLiveHub = class
  strict private
    FConfig: TLiveConfig;
    FLogger: ILogger;
    FClock: IClock;
    FLock: TCriticalSection;
    FStreams: TObjectDictionary<string, TLiveStream>;
  public
    constructor Create(const AConfig: TLiveConfig; const ALogger: ILogger; const AClock: IClock);
    destructor Destroy; override;
    function GetOrCreate(const CameraName: string): TLiveStream;
    function Find(const CameraName: string): TLiveStream;
    property Config: TLiveConfig read FConfig;
  end;

  // IMediaSink que publica no hub e repassa para o sink de dentro (o caminho
  // dvrip grava por um TRecordingSink; o rtsp grava na própria sessão e aqui
  // ANext vem nil). Decorador em vez de um fan-out genérico: são sempre dois.
  TLiveSink = class(TInterfacedObject, IMediaSink)
  strict private
    FStream: TLiveStream;
    FNext: IMediaSink;
    FPublishAudio: Boolean;
  public
    constructor Create(AStream: TLiveStream; const ANext: IMediaSink; APublishAudio: Boolean);
    { IMediaSink }
    procedure OnVideoFormat(Codec: TVideoCodec; Width, Height: Word; const Extradata: TBytes);
    procedure OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
                            const Extradata: TBytes);
    procedure OnSample(const Sample: TSample);
    procedure OnStreamStopped;
  end;

implementation

function SameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

{ TLiveConfig }

function TLiveConfig.Describe: string;
begin
  if not Enabled then
    Exit('desligado (ao vivo lido do arquivo)');
  Result := Format('buffer %d ms, teto %.0f MB', [BufferMs, MaxBytes / (1024 * 1024)]);
end;

{ TLiveStream }

constructor TLiveStream.Create(const AName: string; ABufferMs: Integer; AMaxBytes: Int64;
  const ALogger: ILogger; const AClock: IClock);
begin
  inherited Create;
  FName := AName;
  FLogger := ALogger;
  FClock := AClock;
  if ABufferMs <= 0 then ABufferMs := LIVE_DEFAULT_BUFFER_MS;
  if AMaxBytes <= 0 then AMaxBytes := LIVE_DEFAULT_MAX_BYTES;
  FBufferMs := ABufferMs;
  FMaxBytes := AMaxBytes;
  SetLength(FItems, LIVE_RING_CAPACITY);
  FFirstSeq := 0;
  FNextSeq := 0;
  FEpoch := 1;
end;

procedure TLiveStream.Log(Level: TLogLevel; const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Log(Level, 'live.' + FName, Msg);
end;

function TLiveStream.SlotOf(Seq: Int64): Integer;
begin
  // O anel tem capacidade fixa, então a posição é o resto do número de sequência
  Result := Integer(Seq mod Length(FItems));
end;

procedure TLiveStream.DropOldestLocked;
var
  Slot: Integer;
begin
  if FFirstSeq >= FNextSeq then Exit;
  Slot := SlotOf(FFirstSeq);
  Dec(FBytes, Length(FItems[Slot].Data));
  FItems[Slot].Data := nil;
  Inc(FFirstSeq);
end;

procedure TLiveStream.TrimLocked;
var
  NewestMs: Int64;
begin
  if FNextSeq <= FFirstSeq then Exit;
  NewestMs := FItems[SlotOf(FNextSeq - 1)].WallMs;
  while FFirstSeq < FNextSeq do
  begin
    if (FNextSeq - FFirstSeq) > Length(FItems) then
    begin
      DropOldestLocked;
      Continue;
    end;
    if FBytes > FMaxBytes then
    begin
      DropOldestLocked;
      Continue;
    end;
    if (NewestMs - FItems[SlotOf(FFirstSeq)].WallMs) > FBufferMs then
    begin
      DropOldestLocked;
      Continue;
    end;
    Break;
  end;
end;

procedure TLiveStream.ClearSamplesLocked;
begin
  while FFirstSeq < FNextSeq do
    DropOldestLocked;
  FBytes := 0;
end;

procedure TLiveStream.PublishVideoFormat(Codec: TVideoCodec; Width, Height: Word;
  const Extradata: TBytes);
var
  Changed: Boolean;
begin
  TMonitor.Enter(Self);
  try
    // Só é troca de formato — e portanto SDP caduco — quando muda o codec ou a
    // resolução. Reconexão da mesma câmera reanuncia os mesmos valores, e ali
    // derrubar quem está assistindo seria gratuito. O extradata é sempre
    // atualizado: quem chegar depois merece o parameter set mais novo.
    Changed := (not FHasVideo) or (FVideo.Codec <> Codec) or
               (FVideo.Width <> Width) or (FVideo.Height <> Height);
    FHasVideo := True;
    FVideo.Codec := Codec;
    FVideo.Timescale := LIVE_VIDEO_TIMESCALE;
    FVideo.Width := Width;
    FVideo.Height := Height;
    if not SameBytes(FVideo.Extradata, Extradata) then
      FVideo.Extradata := Copy(Extradata);
    if Changed then
    begin
      Inc(FEpoch);
      ClearSamplesLocked;
      Log(llInfo, Format('formato de video: %s %dx%d', [VideoCodecToStr(Codec), Width, Height]));
    end;
    TMonitor.PulseAll(Self);
  finally
    TMonitor.Exit(Self);
  end;
end;

procedure TLiveStream.PublishAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
  Channels: Byte; const Extradata: TBytes);
var
  Changed: Boolean;
begin
  TMonitor.Enter(Self);
  try
    Changed := (not FHasAudio) or (FAudio.Codec <> Codec) or (FAudio.SampleRate <> SampleRate);
    FHasAudio := True;
    FAudio.Codec := Codec;
    FAudio.Timescale := SampleRate;  // áudio numera PTS na taxa de amostragem
    FAudio.SampleRate := SampleRate;
    FAudio.Channels := Channels;
    FAudio.BitsPerSample := 16;
    if not SameBytes(FAudio.Extradata, Extradata) then
      FAudio.Extradata := Copy(Extradata);
    if Changed then
    begin
      Inc(FEpoch);
      ClearSamplesLocked;
      Log(llInfo, Format('formato de audio: %s %dHz %dch',
        [AudioCodecToStr(Codec), SampleRate, Channels]));
    end;
    TMonitor.PulseAll(Self);
  finally
    TMonitor.Exit(Self);
  end;
end;

procedure TLiveStream.PublishSample(const Sample: TSample);
var
  Slot: Integer;
begin
  if Length(Sample.Data) = 0 then Exit;
  TMonitor.Enter(Self);
  try
    if (FNextSeq - FFirstSeq) >= Length(FItems) then
      DropOldestLocked;
    Slot := SlotOf(FNextSeq);
    FItems[Slot].TrackId := Sample.TrackId;
    FItems[Slot].Pts := Sample.Pts;
    FItems[Slot].Keyframe := sfKeyframe in Sample.Flags;
    FItems[Slot].WallMs := FClock.MonotonicMs;
    FItems[Slot].Data := Sample.Data;   // TBytes é COW: cópia é só a referência
    FLastSampleMs := FItems[Slot].WallMs;
    Inc(FBytes, Length(Sample.Data));
    Inc(FNextSeq);
    TrimLocked;
    TMonitor.PulseAll(Self);
  finally
    TMonitor.Exit(Self);
  end;
end;

procedure TLiveStream.NotifyStopped;
begin
  TMonitor.Enter(Self);
  try
    // Os formatos ficam: o cliente que está conectado continua valendo, e o
    // DESCRIBE de quem chegar durante a queda ainda responde. O que sai é a
    // mídia velha, para não emendar no primeiro frame de depois da reconexão.
    ClearSamplesLocked;
    TMonitor.PulseAll(Self);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TLiveStream.TryGetHeader(out Header: TVmsHeader): Boolean;
var
  H: TVmsHeader;
begin
  // Zera num local recém-nascido e só então copia para fora: o header tem string
  // e TBytes dentro, e FillChar em cima de um registro já preenchido apagaria as
  // referências sem liberá-las.
  FillChar(H, SizeOf(H), 0);
  TMonitor.Enter(Self);
  try
    Result := FHasVideo and (FVideo.Codec <> vcNone);
    if Result then
    begin
      H.Version := VMS_FORMAT_VERSION;
      H.CreationUnixMs := FClock.NowUtcMs;
      H.VideoPresent := True;
      H.Video := FVideo;
      if FHasAudio and (FAudio.Codec <> acNone) then
      begin
        H.AudioPresent := True;
        H.Audio := FAudio;
      end;
    end;
  finally
    TMonitor.Exit(Self);
  end;
  Header := H;
end;

function TLiveStream.IsPublishing(WithinMs: Int64): Boolean;
begin
  TMonitor.Enter(Self);
  try
    Result := (FLastSampleMs > 0) and ((FClock.MonotonicMs - FLastSampleMs) <= WithinMs);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TLiveStream.RecentVideoSamples(Max: Integer): TArray<TBytes>;
var
  Seq, From: Int64;
  Count: Integer;
  It: TLiveSampleRec;
begin
  Result := nil;
  if Max <= 0 then Exit;
  TMonitor.Enter(Self);
  try
    // Do keyframe mais recente em diante: é onde a câmera costuma pôr os
    // parameter sets. Sem keyframe guardado, pega o começo do que houver.
    From := LastKeyframeSeqLocked;
    if From < 0 then From := FFirstSeq;
    SetLength(Result, Max);
    Count := 0;
    Seq := From;
    while (Seq < FNextSeq) and (Count < Max) do
    begin
      It := FItems[SlotOf(Seq)];
      if It.TrackId = 0 then
      begin
        Result[Count] := It.Data;
        Inc(Count);
      end;
      Inc(Seq);
    end;
    SetLength(Result, Count);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TLiveStream.LastKeyframeSeqLocked: Int64;
var
  Seq: Int64;
  It: TLiveSampleRec;
begin
  Seq := FNextSeq - 1;
  while Seq >= FFirstSeq do
  begin
    It := FItems[SlotOf(Seq)];
    if (It.TrackId = 0) and It.Keyframe then Exit(Seq);
    Dec(Seq);
  end;
  Result := -1;
end;

procedure TLiveStream.PositionLocked(var Cursor: TLiveCursor);
var
  KeySeq: Int64;
begin
  Cursor.Epoch := FEpoch;
  Cursor.Valid := True;
  KeySeq := LastKeyframeSeqLocked;
  if KeySeq >= 0 then
  begin
    Cursor.NextSeq := KeySeq;
    Cursor.WaitKeyframe := False;
  end
  else
  begin
    // Sem keyframe guardado: começa do que vier e segura o vídeo até o próximo.
    // Mandar um P-frame sem referência só rende macroblocos quebrados na tela.
    Cursor.NextSeq := FNextSeq;
    Cursor.WaitKeyframe := FHasVideo;
  end;
end;

function TLiveStream.Subscribe(out Cursor: TLiveCursor): Boolean;
begin
  FillChar(Cursor, SizeOf(Cursor), 0);
  TMonitor.Enter(Self);
  try
    Result := FHasVideo or FHasAudio;
    if not Result then Exit;
    PositionLocked(Cursor);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TLiveStream.Fetch(var Cursor: TLiveCursor; TimeoutMs: Integer;
  out Items: TArray<TLiveSampleRec>): TLiveFetch;
var
  Resynced: Boolean;
  Seq: Int64;
  Count: Integer;
  It: TLiveSampleRec;
begin
  Items := nil;
  Result := lfNone;
  if not Cursor.Valid then Exit;
  TMonitor.Enter(Self);
  try
    if Cursor.Epoch <> FEpoch then Exit(lfFormatChanged);
    if Cursor.NextSeq >= FNextSeq then
    begin
      TMonitor.Wait(Self, TimeoutMs);
      if Cursor.Epoch <> FEpoch then Exit(lfFormatChanged);
      if Cursor.NextSeq >= FNextSeq then Exit(lfNone);
    end;

    // Ficou para trás do início do anel: o cliente não consome no ritmo da
    // câmera (rede lenta, decoder travado). Em vez de mandar mídia furada,
    // pula para o keyframe mais recente — perde o intervalo e segue ao vivo.
    Resynced := Cursor.NextSeq < FFirstSeq;
    if Resynced then
      PositionLocked(Cursor);

    SetLength(Items, Integer(FNextSeq - Cursor.NextSeq));
    Count := 0;
    Seq := Cursor.NextSeq;
    while Seq < FNextSeq do
    begin
      It := FItems[SlotOf(Seq)];
      if Cursor.WaitKeyframe and (It.TrackId = 0) then
      begin
        if It.Keyframe then
          Cursor.WaitKeyframe := False
        else
        begin
          Inc(Seq);
          Continue;
        end;
      end;
      Items[Count] := It;
      Inc(Count);
      Inc(Seq);
    end;
    SetLength(Items, Count);
    Cursor.NextSeq := FNextSeq;
    if Resynced then
      Result := lfResync
    else
      Result := lfSamples;
  finally
    TMonitor.Exit(Self);
  end;
end;

{ TLiveHub }

constructor TLiveHub.Create(const AConfig: TLiveConfig; const ALogger: ILogger; const AClock: IClock);
begin
  inherited Create;
  FConfig := AConfig;
  FLogger := ALogger;
  FClock := AClock;
  FLock := TCriticalSection.Create;
  FStreams := TObjectDictionary<string, TLiveStream>.Create([doOwnsValues]);
end;

destructor TLiveHub.Destroy;
begin
  FStreams.Free;
  FLock.Free;
  inherited;
end;

function TLiveHub.GetOrCreate(const CameraName: string): TLiveStream;
var
  Key: string;
begin
  Key := LowerCase(Trim(CameraName));
  FLock.Enter;
  try
    if not FStreams.TryGetValue(Key, Result) then
    begin
      Result := TLiveStream.Create(CameraName, FConfig.BufferMs, FConfig.MaxBytes,
                                   FLogger, FClock);
      FStreams.Add(Key, Result);
    end;
  finally
    FLock.Leave;
  end;
end;

function TLiveHub.Find(const CameraName: string): TLiveStream;
begin
  FLock.Enter;
  try
    if not FStreams.TryGetValue(LowerCase(Trim(CameraName)), Result) then
      Result := nil;
  finally
    FLock.Leave;
  end;
end;

{ TLiveSink }

constructor TLiveSink.Create(AStream: TLiveStream; const ANext: IMediaSink; APublishAudio: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FNext := ANext;
  FPublishAudio := APublishAudio;
end;

procedure TLiveSink.OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
  const Extradata: TBytes);
begin
  if FStream <> nil then
    FStream.PublishVideoFormat(Codec, Width, Height, Extradata);
  if FNext <> nil then
    FNext.OnVideoFormat(Codec, Width, Height, Extradata);
end;

procedure TLiveSink.OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
  Channels: Byte; const Extradata: TBytes);
begin
  if FPublishAudio and (FStream <> nil) then
    FStream.PublishAudioFormat(Codec, SampleRate, Channels, Extradata);
  if FNext <> nil then
    FNext.OnAudioFormat(Codec, SampleRate, Channels, Extradata);
end;

procedure TLiveSink.OnSample(const Sample: TSample);
begin
  if (FStream <> nil) and (FPublishAudio or (Sample.Kind <> tkAudio)) then
    FStream.PublishSample(Sample);
  if FNext <> nil then
    FNext.OnSample(Sample);
end;

procedure TLiveSink.OnStreamStopped;
begin
  if FStream <> nil then
    FStream.NotifyStopped;
  if FNext <> nil then
    FNext.OnStreamStopped;
end;

end.
