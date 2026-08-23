unit VMS.Play.Engine;

// Toca gravação no mesmo decodificador que o ao vivo usa.
//
// Por que existe um pacer aqui: **nenhum dos dois renderers apresenta por PTS**.
// No Android o SetDelays é no-op declarado (quem manda é o MediaCodec/AudioTrack)
// e no Windows a fila usa o tick de chegada mais um atraso fixo. Ou seja: quem
// despeja os samples vê o vídeo passar acelerado. O ritmo é problema desta unit,
// e a regra é a mesma que o servidor já usa no caminho de arquivo — o VÍDEO dita,
// o áudio sai na posição em que foi gravado, e re-ancora quando o desvio passa
// dos limites.
//
// Duas threads:
//   rede  — mantém ~8 s de mídia na fila, pedindo o pedaço seguinte pelo cursor.
//           Não conhece arquivo: pede instante, recebe mídia (ver Vms.Server.Api).
//   ritmo — tira da fila e entrega ao IMediaSink na hora certa.
//
// A travessia de arquivo chega como `Discontinuity` no pedaço: ali o formato é
// reanunciado ao renderer e o ritmo re-ancora pelo tempo de parede do primeiro
// bloco novo, porque a base de PTS mudou. É o mesmo tratamento que a sessão ao
// vivo faz quando a câmera reconecta.

interface

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.MediaSink,
  VMS.Rec.Format,
  VMS.Rec.Reader,
  VMS.Api.Client;

const
  // Ponto de partida do prefetch; daqui ele se ajusta sozinho ao que a rede
  // entrega (ver AdaptPrefetch). Os limites existem para o ajuste não passar dos
  // extremos: fila curta demais engasga, longa demais atrasa o seek.
  PLAY_START_BUFFER_MS  = 8000;
  PLAY_MIN_BUFFER_MS    = 4000;
  PLAY_MAX_BUFFER_MS    = 20000;
  PLAY_BLOCKS_PER_FETCH = 4;
  PLAY_MIN_BLOCKS       = 2;
  PLAY_MAX_BLOCKS       = 16;
  // Fora destes limites não é atraso normal e sim descontinuidade: re-ancora em
  // vez de dormir um tempo absurdo ou despejar tudo de uma vez. Mesmos valores
  // do pacer do servidor.
  PLAY_MAX_WAIT_MS = 1000;
  PLAY_MAX_LAG_MS  = 2000;
  // Teto de velocidade, e a partir de onde a reprodução vira varredura.
  PLAY_MAX_SPEED = 64;
  // Acima disto só keyframe é entregue ao decodificador. 8x de 30 fps são 240
  // quadros por segundo, que decodificador de celular nenhum sustenta; sem esta
  // regra o player não fica rápido, fica ATRASADO — o pacer re-ancora sem parar
  // e a posição anda a uma fração da velocidade pedida.
  PLAY_ALLFRAMES_MAX_SPEED = 4;
  // Quadros por segundo de TELA durante a varredura. É daqui que sai o stepMs
  // pedido ao servidor: a 64x, 12 quadros na tela por segundo são um quadro a
  // cada 5,3 s de mídia — e é só isso que precisa atravessar a rede.
  PLAY_SCAN_FPS = 12;
  // Em varredura cabe pedir mais blocos por requisição: cada um rende pouca
  // coisa (um keyframe ou nenhum), e o teto de bytes não é mais o que limita.
  PLAY_MAX_BLOCKS_SCAN = 32;
  // Teto absoluto da fila, em ms de mídia. O alvo cresce com a velocidade (ver
  // AdaptPrefetch) porque a 64x a fila esvazia 64 vezes mais rápido, e a conta
  // quem paga é a memória do celular. Estes 4 minutos só são alcançáveis em
  // varredura, e lá a fila guarda SÓ keyframes (ver PushChunk): são ~120
  // imagens, e não os ~19 mil samples que 4 minutos de mídia teriam.
  PLAY_MAX_QUEUE_MS = 240000;

type
  TPlayState = (pbIdle, pbBuffering, pbPlaying, pbPaused, pbEnded, pbError);

  TPlayItem = record
    Generation: Integer;
    Sample: TSample;
    Timescale: Cardinal;  // base do PTS desta trilha, para o ritmo
    WallMs: Int64;        // instante de parede deste sample
    NewSegment: Boolean;  // primeiro depois de uma emenda: reanunciar e re-ancorar
    Header: TVmsHeader;   // só preenchido quando NewSegment
  end;

  TPlaybackEngine = class;

  TPlayFetchThread = class(TThread)
  strict private
    FEngine: TPlaybackEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TPlaybackEngine);
  end;

  TPlayPaceThread = class(TThread)
  strict private
    FEngine: TPlaybackEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TPlaybackEngine);
  end;

  TPlaybackEngine = class
  strict private
    FSink: IMediaSink;
    FClient: TVmsApiClient;
    FLogger: ILogger;
    FClock: IClock;
    FCamera: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FQueue: TQueue<TPlayItem>;
    FFetcher: TPlayFetchThread;
    FPacer: TPlayPaceThread;
    FStop: Boolean;
    FState: TPlayState;
    FSpeed: Double;
    // protegidos por FLock
    FGeneration: Integer;
    FSeekMs: Int64;        // instante a buscar; -1 = seguir pelo cursor
    FCursor: string;
    FEnded: Boolean;
    FQueuedFromMs: Int64;  // faixa de tempo do que está na fila
    FQueuedToMs: Int64;
    FPositionMs: Int64;
    FSeekTargetMs: Int64;  // alvo do seek corrente: o que vier antes sai sem ritmo
    FFetchFails: Integer;
    // Prefetch que se ajusta: quanto pedir por vez e quanto manter em fila. Uma
    // rede lenta precisa de pedidos maiores (senão a busca nunca alcança o
    // consumo); uma rápida prefere pedidos pequenos, que deixam o seek responder
    // mais rápido.
    FBlocksPerFetch: Integer;
    FTargetBufferMs: Int64;
    FLastRatio: Int64;          // razão busca/mídia do pedido anterior
    FSlowLinkLogged: Boolean;
    FScanWarned: Boolean;       // já avisei que o servidor não decima?
    // buraco na gravação que a UI ainda não mostrou (consumido uma vez só)
    FGapNoticeMs: Int64;
    // só a thread de ritmo mexe nestes: âncora corrente do relógio de saída
    FAnchorValid: Boolean;
    FAnchorPts: Int64;
    FAnchorWallMs: Int64;
    FHasVideo: Boolean;
    // Depois de um seek ou de uma emenda, segura o vídeo até o primeiro
    // keyframe: o bloco não é alinhado por keyframe (o gravador fecha por
    // tempo/tamanho), então ele começa com P-frames cuja referência não veio.
    FWaitKeyframe: Boolean;
    FFedSinceSegment: Int64;
    procedure SetState(S: TPlayState);
    function QueuedMs: Int64;
    procedure ClearQueue;
    procedure PushChunk(const Chunk: TApiMediaChunk; Generation: Integer);
    procedure AnnounceFormats(const Header: TVmsHeader);
    procedure NotifyPosition(UnixMs: Int64);
    procedure AdaptPrefetch(FetchMs, MediaMs: Int64);
    // Espaçamento pedido ao servidor, em ms de mídia. 0 = reprodução normal,
    // manda tudo.
    function ScanStepMs: Int64;
  private
    // chamados pelas threads desta unit (private, não strict: em Delphi o
    // strict fecharia o acesso até para quem mora no mesmo arquivo)
    procedure Log(Level: TLogLevel; const Msg: string);
    procedure FetchOnce;
    procedure PaceOnce;
  public
    constructor Create(const ASink: IMediaSink; AClient: TVmsApiClient;
                       const ALogger: ILogger; const AClock: IClock);
    destructor Destroy; override;
    // Começa a tocar a câmera a partir daquele instante. Chamar de novo com
    // outro instante é o seek.
    procedure Start(const Camera: string; FromMs: Int64);
    procedure SeekTo(UnixMs: Int64);
    procedure Pause;
    procedure Resume;
    procedure Stop;
    procedure SetSpeed(Value: Double);
    // Estado e posição são LIDOS pela UI (o shell já tem um timer de status).
    // Sem evento com callback: um evento enfileirado que rodasse depois de a
    // engine morrer levaria o app junto.
    function State: TPlayState;
    function PositionMs: Int64;
    // Houve um pulo por falta de gravação desde a última pergunta? Consome o
    // aviso: quem pergunta é quem mostra.
    function TakeGapNotice(out GapMs: Int64): Boolean;
    property Speed: Double read FSpeed;
  end;

function PlayStateToStr(S: TPlayState): string;

implementation

function PlayStateToStr(S: TPlayState): string;
begin
  case S of
    pbIdle:      Result := 'parado';
    pbBuffering: Result := 'carregando';
    pbPlaying:   Result := 'tocando';
    pbPaused:    Result := 'pausado';
    pbEnded:     Result := 'fim da gravacao';
    pbError:     Result := 'erro';
  else
    Result := '?';
  end;
end;

{ TPlayFetchThread }

constructor TPlayFetchThread.Create(AEngine: TPlaybackEngine);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FEngine := AEngine;
end;

procedure TPlayFetchThread.Execute;
begin
  while not Terminated do
  begin
    try
      FEngine.FetchOnce;
    except
      on E: Exception do
        FEngine.Log(llWarn, 'busca falhou: ' + E.Message);
    end;
  end;
end;

{ TPlayPaceThread }

constructor TPlayPaceThread.Create(AEngine: TPlaybackEngine);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FEngine := AEngine;
end;

procedure TPlayPaceThread.Execute;
begin
  while not Terminated do
  begin
    try
      FEngine.PaceOnce;
    except
      on E: Exception do
        FEngine.Log(llWarn, 'ritmo falhou: ' + E.Message);
    end;
  end;
end;

{ TPlaybackEngine }

constructor TPlaybackEngine.Create(const ASink: IMediaSink; AClient: TVmsApiClient;
  const ALogger: ILogger; const AClock: IClock);
begin
  inherited Create;
  FSink := ASink;
  FClient := AClient;
  FLogger := ALogger;
  FClock := AClock;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FQueue := TQueue<TPlayItem>.Create;
  FSpeed := 1.0;
  FSeekMs := -1;
  FState := pbIdle;
  FBlocksPerFetch := PLAY_BLOCKS_PER_FETCH;
  FTargetBufferMs := PLAY_START_BUFFER_MS;
  FFetcher := TPlayFetchThread.Create(Self);
  FPacer := TPlayPaceThread.Create(Self);
  FFetcher.Start;
  FPacer.Start;
end;

destructor TPlaybackEngine.Destroy;
begin
  Stop;
  FStop := True;
  FWake.SetEvent;
  if FFetcher <> nil then
  begin
    FFetcher.Terminate;
    FWake.SetEvent;
    FFetcher.WaitFor;
    FFetcher.Free;
  end;
  if FPacer <> nil then
  begin
    FPacer.Terminate;
    FPacer.WaitFor;
    FPacer.Free;
  end;
  FQueue.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TPlaybackEngine.Log(Level: TLogLevel; const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Log(Level, 'playback', Msg);
end;

procedure TPlaybackEngine.SetState(S: TPlayState);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FState <> S;
    FState := S;
  finally
    FLock.Leave;
  end;
  if not Changed then Exit;
  Log(llInfo, PlayStateToStr(S));
end;

function TPlaybackEngine.State: TPlayState;
begin
  FLock.Enter;
  try
    Result := FState;
  finally
    FLock.Leave;
  end;
end;

function TPlaybackEngine.PositionMs: Int64;
begin
  FLock.Enter;
  try
    Result := FPositionMs;
  finally
    FLock.Leave;
  end;
end;

// Quanto de linha do tempo ainda há na fila. Chamado sob FLock.
function TPlaybackEngine.QueuedMs: Int64;
begin
  if FQueue.Count = 0 then Exit(0);
  Result := FQueuedToMs - FQueuedFromMs;
  if Result < 0 then Result := 0;
end;

procedure TPlaybackEngine.ClearQueue;
begin
  FQueue.Clear;
  FQueuedFromMs := 0;
  FQueuedToMs := 0;
end;

procedure TPlaybackEngine.Start(const Camera: string; FromMs: Int64);
begin
  FLock.Enter;
  try
    FCamera := Camera;
    Inc(FGeneration);
    ClearQueue;
    FCursor := '';
    FSeekMs := FromMs;
    FSeekTargetMs := FromMs;
    FEnded := False;
    FGapNoticeMs := 0;
    FLastRatio := 0;
    FSlowLinkLogged := False;
    FPositionMs := FromMs;
    FState := pbBuffering;
  finally
    FLock.Leave;
  end;
  Log(llInfo, Format('tocando %s a partir de %d', [Camera, FromMs]));
  FWake.SetEvent;
end;

procedure TPlaybackEngine.SeekTo(UnixMs: Int64);
var
  Camera: string;
begin
  FLock.Enter;
  try
    Camera := FCamera;
  finally
    FLock.Leave;
  end;
  if Camera = '' then Exit;
  Start(Camera, UnixMs);
end;

procedure TPlaybackEngine.Pause;
begin
  // pbBuffering conta como tocando: a reprodução alterna entre os dois o tempo
  // todo (o pacer marca pbBuffering sempre que a fila seca por um instante), e
  // aceitar só pbPlaying fazia a pausa não pegar — sem aviso nenhum, porque a
  // UI já tinha trocado o ícone.
  if (State = pbPlaying) or (State = pbBuffering) then
    SetState(pbPaused);
end;

procedure TPlaybackEngine.Resume;
begin
  if State = pbPaused then
  begin
    SetState(pbBuffering);
    FWake.SetEvent;
  end;
end;

procedure TPlaybackEngine.Stop;
begin
  FLock.Enter;
  try
    Inc(FGeneration);
    ClearQueue;
    FCursor := '';
    FSeekMs := -1;
    FCamera := '';
    FSeekTargetMs := 0;
  finally
    FLock.Leave;
  end;
  SetState(pbIdle);
  // Esvazia os decodificadores: sem isto sobra áudio na fila do AudioTrack
  // tocando depois de o usuário ter saído.
  if FSink <> nil then
    FSink.OnStreamStopped;
end;

procedure TPlaybackEngine.SetSpeed(Value: Double);
var
  EraVarredura, ViraVarredura: Boolean;
  Pos: Int64;
begin
  if Value < 0.25 then Value := 0.25;
  if Value > PLAY_MAX_SPEED then Value := PLAY_MAX_SPEED;
  EraVarredura := FSpeed > PLAY_ALLFRAMES_MAX_SPEED;
  ViraVarredura := Value > PLAY_ALLFRAMES_MAX_SPEED;
  FSpeed := Value;
  Log(llInfo, Format('velocidade %.2gx', [Value]));

  // Cruzar o limiar da varredura muda O QUE entra na fila, e o que já está lá
  // foi filtrado pela regra anterior. Saindo de 64x para 1x, seriam minutos de
  // slideshow antes de o vídeo completo voltar; entrando, seriam minutos de
  // vídeo completo antes de a varredura acelerar de verdade. Recomeçar da
  // posição atual é mais barato de entender do que remendar a fila.
  if EraVarredura <> ViraVarredura then
  begin
    Pos := PositionMs;
    if Pos > 0 then SeekTo(Pos);
  end;
end;

procedure TPlaybackEngine.AnnounceFormats(const Header: TVmsHeader);
begin
  if FSink = nil then Exit;
  // O que o decodificador vai receber, dito por extenso: é a primeira coisa a
  // conferir quando o playback "toca" mas a tela fica preta.
  Log(llInfo, Format('formato: video %s %dx%d extradata=%d B | audio %s %d Hz %dch',
    [VideoCodecToStr(Header.Video.Codec), Header.Video.Width, Header.Video.Height,
     Length(Header.Video.Extradata), AudioCodecToStr(Header.Audio.Codec),
     Header.Audio.SampleRate, Header.Audio.Channels]));
  // Ordem importa: formato antes de sample, senão o decodificador recebe mídia
  // sem saber configurar.
  if Header.VideoPresent and (Header.Video.Codec <> vcNone) then
    FSink.OnVideoFormat(Header.Video.Codec, Header.Video.Width, Header.Video.Height,
                        Header.Video.Extradata);
  if Header.AudioPresent and (Header.Audio.Codec <> acNone) then
    FSink.OnAudioFormat(Header.Audio.Codec, Header.Audio.SampleRate,
                        Header.Audio.Channels, Header.Audio.Extradata);
end;

// Desmonta um pedaço (.vms em memória) em samples com o instante de parede de
// cada um, e enfileira. O primeiro sample do pedaço carrega o header quando
// houve emenda.
procedure TPlaybackEngine.PushChunk(const Chunk: TApiMediaChunk; Generation: Integer);
var
  Stream: TBytesStream;
  Reader: TVmsReader;
  Block: TVmsBlock;
  Item: TPlayItem;
  I, Track: Integer;
  Entry: TVmsSampleEntry;
  Timescale: Cardinal;
  // Uma origem POR TRILHA: vídeo numera PTS em 90 kHz e áudio na taxa de
  // amostragem, então subtrair o PTS de vídeo de um sample de áudio dá um
  // instante absurdo — e o sample some.
  FirstPts: array[0..1] of Int64;
  HaveFirst: array[0..1] of Boolean;
  Anchor: Int64;
  First: Boolean;
  Spd: Double;
begin
  Spd := FSpeed;
  Stream := TBytesStream.Create(Chunk.Data);
  Reader := nil;
  try
    Reader := TVmsReader.Create(Stream, False);
    Reader.Logger := FLogger;   // pedaço corrompido na rede vira aviso, não vídeo quebrado
    if not Reader.ReadHeader then
    begin
      Log(llWarn, 'pedaco sem header legivel');
      Exit;
    end;
    First := True;
    while Reader.ReadNextBlock(Block) do
    begin
      HaveFirst[0] := False;
      HaveFirst[1] := False;
      FirstPts[0] := 0;
      FirstPts[1] := 0;
      for I := 0 to High(Block.Samples) do
      begin
        Entry := Block.Samples[I];
        if Entry.TrackId > 1 then Continue; // o formato só tem vídeo(0) e áudio(1)
        Track := Entry.TrackId;
        Item := Default(TPlayItem);
        Item.Generation := Generation;
        if Track = 0 then
        begin
          Item.Sample.Kind := tkVideo;
          Timescale := Reader.Header.Video.Timescale;
        end
        else
        begin
          Item.Sample.Kind := tkAudio;
          Timescale := Reader.Header.Audio.Timescale;
        end;
        if Timescale = 0 then Timescale := 90000;
        Item.Timescale := Timescale;
        Item.Sample.TrackId := Entry.TrackId;
        Item.Sample.Pts := Entry.Pts;
        Item.Sample.Flags := ByteToFlags(Entry.FlagsByte);

        // Instante de parede: cada trilha é contada a partir do próprio primeiro
        // PTS no bloco, e ancorada no instante em que ELA começou aqui. A âncora
        // é o que dá base comum às duas trilhas — sem ela, só resta supor que
        // começam juntas no bloco, e a defasagem real fica congelada na saída.
        // Bloco com uma trilha só não tem as duas âncoras: aí vale o começo do
        // bloco, que é essa mesma suposição.
        //
        // Isto vem ANTES de qualquer descarte de propósito: a base é o primeiro
        // PTS do bloco, e se ela mudasse conforme o que foi pulado, o instante de
        // todo o resto do bloco mudaria junto.
        if not HaveFirst[Track] then
        begin
          FirstPts[Track] := Entry.Pts;
          HaveFirst[Track] := True;
        end;

        // Varredura rápida: o que não vai ser decodificado não entra na fila.
        // Antes ele era copiado, enfileirado e só descartado lá adiante, pelo
        // pacer — a 64x são ~97% da mídia ocupando memória para nada, e era isso
        // que impedia a fila de cobrir tempo de relógio suficiente.
        if Spd > PLAY_ALLFRAMES_MAX_SPEED then
          if (Track = 1) or (not (sfKeyframe in Item.Sample.Flags)) then Continue;

        SetLength(Item.Sample.Data, Entry.PayloadSize);
        if Entry.PayloadSize > 0 then
          Move(Block.Payload[Entry.PayloadOffset], Item.Sample.Data[0], Entry.PayloadSize);

        if Track = 0 then
          Anchor := Block.VideoAnchorMs
        else
          Anchor := Block.AudioAnchorMs;
        if Anchor = 0 then
          Anchor := Block.StartUnixMs;
        Item.WallMs := Anchor +
                       ((Entry.Pts - FirstPts[Track]) * 1000) div Int64(Timescale);

        if First then
        begin
          First := False;
          Item.NewSegment := Chunk.Discontinuity;
          if Chunk.Discontinuity then
            Item.Header := Reader.Header;
        end;

        FLock.Enter;
        try
          if Generation <> FGeneration then Exit; // seek no meio: joga fora
          if FQueue.Count = 0 then
            FQueuedFromMs := Item.WallMs;
          FQueuedToMs := Item.WallMs;
          FQueue.Enqueue(Item);
        finally
          FLock.Leave;
        end;
      end;
    end;
  finally
    Reader.Free;
    Stream.Free;
  end;
end;

procedure TPlaybackEngine.NotifyPosition(UnixMs: Int64);
begin
  FLock.Enter;
  try
    FPositionMs := UnixMs;
  finally
    FLock.Leave;
  end;
end;

// Ajusta o tamanho do pedido e da fila pelo que a rede acabou de fazer.
//
// A régua é comparar o tempo da BUSCA com a duração da MÍDIA que ela trouxe: se
// buscar 8 s de vídeo custa 6 s, pedidos pequenos nunca alcançam o consumo e a
// fila seca (o vídeo trava de tempos em tempos). Se custa 0,2 s, dá para pedir
// menos por vez, e o seek passa a responder mais rápido — é a mesma requisição
// que o usuário espera quando arrasta a barra.
function TPlaybackEngine.ScanStepMs: Int64;
var
  Spd: Double;
begin
  Spd := FSpeed;
  if Spd <= PLAY_ALLFRAMES_MAX_SPEED then Exit(0);
  // Um quadro a cada Spd/PLAY_SCAN_FPS segundos de mídia é exatamente o que
  // rende PLAY_SCAN_FPS quadros por segundo na tela naquela velocidade. Pedir
  // mais que isso é baixar o que vai ser descartado.
  Result := Round(1000 * Spd / PLAY_SCAN_FPS);
  if Result < 1 then Result := 1;
end;

procedure TPlaybackEngine.AdaptPrefetch(FetchMs, MediaMs: Int64);
var
  Antes: Integer;
  Razao: Int64;   // custo da busca sobre a mídia que ela trouxe, em %
  Spd: Double;
begin
  if MediaMs <= 0 then Exit;
  Antes := FBlocksPerFetch;
  Razao := (FetchMs * 100) div MediaMs;

  if Razao > 50 then
  begin
    // Custa caro. Crescer só resolve quando o peso é o CUSTO FIXO por requisição
    // (latência): aí um pedido maior dilui esse custo. Quando o limite é a banda,
    // a razão não melhora por mais que se peça — e continuar crescendo só
    // transforma engasgos curtos em travadas longas. Então cresce enquanto a
    // razão estiver melhorando, e para quando não estiver.
    if (FLastRatio = 0) or (Razao < FLastRatio - 5) then
      Inc(FBlocksPerFetch)
    else if not FSlowLinkLogged then
    begin
      FSlowLinkLogged := True;
      Log(llWarn, Format('a rede nao sustenta esta gravacao: %d ms de busca para %d ms de midia',
        [FetchMs, MediaMs]));
    end;
  end
  else if Razao < 12 then
    Dec(FBlocksPerFetch);                      // sobra folga: pede menos
  FLastRatio := Razao;
  if FBlocksPerFetch < PLAY_MIN_BLOCKS then FBlocksPerFetch := PLAY_MIN_BLOCKS;
  if ScanStepMs > 0 then
  begin
    if FBlocksPerFetch > PLAY_MAX_BLOCKS_SCAN then
      FBlocksPerFetch := PLAY_MAX_BLOCKS_SCAN;
  end
  else if FBlocksPerFetch > PLAY_MAX_BLOCKS then
    FBlocksPerFetch := PLAY_MAX_BLOCKS;

  // A fila cobre quatro buscas: tempo de reagir a uma oscilação sem virar
  // atraso de seek.
  //
  // Ela é medida em tempo de MÍDIA, mas o que precisa cobrir é tempo de
  // RELÓGIO — e a 8x a mídia sai da fila oito vezes mais rápido. Sem multiplicar
  // pela velocidade, os 4 s de fila viram meio segundo a 8x, e o player passa a
  // vida esperando o pedaço seguinte: era isto que faria 8x e 16x engasgarem
  // mesmo com rede sobrando.
  Spd := FSpeed;
  if Spd < 1 then Spd := 1;
  FTargetBufferMs := Round(FetchMs * 4 * Spd);
  if FTargetBufferMs < Round(PLAY_MIN_BUFFER_MS * Spd) then
    FTargetBufferMs := Round(PLAY_MIN_BUFFER_MS * Spd);
  if FTargetBufferMs > Round(PLAY_MAX_BUFFER_MS * Spd) then
    FTargetBufferMs := Round(PLAY_MAX_BUFFER_MS * Spd);
  if FTargetBufferMs > PLAY_MAX_QUEUE_MS then
    FTargetBufferMs := PLAY_MAX_QUEUE_MS;

  if Antes <> FBlocksPerFetch then
    Log(llDebug, Format('prefetch: %d blocos por pedido, fila de %d ms (busca %d ms para %d ms de midia)',
      [FBlocksPerFetch, FTargetBufferMs, FetchMs, MediaMs]));
end;

function TPlaybackEngine.TakeGapNotice(out GapMs: Int64): Boolean;
begin
  FLock.Enter;
  try
    GapMs := FGapNoticeMs;
    Result := GapMs > 0;
    FGapNoticeMs := 0;
  finally
    FLock.Leave;
  end;
end;

procedure TPlaybackEngine.FetchOnce;
var
  Gen: Integer;
  Camera, Cursor: string;
  SeekMs, Started, Step: Int64;
  Chunk: TApiMediaChunk;
  NeedMore, Ok: Boolean;
begin
  if FStop then
  begin
    FWake.WaitFor(100);
    Exit;
  end;

  FLock.Enter;
  try
    Gen := FGeneration;
    Camera := FCamera;
    Cursor := FCursor;
    SeekMs := FSeekMs;
    NeedMore := (Camera <> '') and (not FEnded) and (QueuedMs < FTargetBufferMs);
  finally
    FLock.Leave;
  end;

  // Buffer cheio, nada aberto, ou já chegou ao fim: dorme até alguém acordar
  // (novo seek, fila esvaziando).
  if not NeedMore then
  begin
    FWake.WaitFor(50);
    Exit;
  end;
  if (SeekMs < 0) and (Cursor = '') then
  begin
    FWake.WaitFor(50);
    Exit;
  end;

  Started := FClock.MonotonicMs;
  Step := ScanStepMs;
  if SeekMs >= 0 then
    Ok := FClient.GetMediaAt(Camera, SeekMs, FBlocksPerFetch, Step, Chunk)
  else
    Ok := FClient.GetMediaNext(Camera, Cursor, FBlocksPerFetch, Step, Chunk);

  if not Ok then
  begin
    Inc(FFetchFails);
    // 4xx é resposta, não falha de rede: o servidor disse que não tem o que foi
    // pedido (câmera que ele não conhece, instante sem gravação). Insistir só
    // atrasaria o aviso. Rede oscilando, sim, merece algumas tentativas.
    if (FClient.LastStatus >= 400) and (FClient.LastStatus < 500) then
      FFetchFails := 5;
    if FFetchFails >= 5 then
    begin
      Log(llError, 'nao consegui buscar a midia: ' + FClient.LastError);
      SetState(pbError);
      FLock.Enter;
      try
        FEnded := True;
      finally
        FLock.Leave;
      end;
      Exit;
    end;
    FWake.WaitFor(400);
    Exit;
  end;
  FFetchFails := 0;
  // Servidor antigo ignora o stepMs e manda o stream inteiro. Continua tocando
  // (o descarte local ainda existe), mas a rede carrega tudo — e é isso que
  // explica varredura lenta num acesso remoto.
  if (Step > 0) and (not Chunk.Thinned) and (not FScanWarned) then
  begin
    FScanWarned := True;
    Log(llWarn, 'o servidor nao decima a varredura (stepMs); a rede vai carregar ' +
                'o stream inteiro nas velocidades altas');
  end;
  AdaptPrefetch(FClock.MonotonicMs - Started, Chunk.EndMs - Chunk.StartMs);

  FLock.Enter;
  try
    if Gen <> FGeneration then Exit; // houve seek enquanto isto vinha pela rede
    FSeekMs := -1;
    FCursor := Chunk.Cursor;
    if (Chunk.NextMs < 0) or (Chunk.Cursor = '') then
      FEnded := True;
  finally
    FLock.Leave;
  end;

  if Chunk.GapMs > 0 then
  begin
    // A UI precisa dizer isso ao usuário: a imagem vai saltar no tempo, e sem
    // aviso parece defeito.
    Log(llInfo, Format('buraco de %d ms na gravacao; pulando para o proximo trecho',
      [Chunk.GapMs]));
    FLock.Enter;
    try
      FGapNoticeMs := Chunk.GapMs;
    finally
      FLock.Leave;
    end;
  end;
  PushChunk(Chunk, Gen);
end;

procedure TPlaybackEngine.PaceOnce;
var
  Item: TPlayItem;
  Have, Stale, Burst, Ended: Boolean;
  St: TPlayState;
  RelativeMs, Deadline, NowMs, WaitMs, Target: Int64;
  Spd: Double;
begin
  St := State;
  if (St = pbIdle) or (St = pbPaused) or (St = pbError) then
  begin
    TThread.Sleep(30);
    Exit;
  end;

  Stale := False;
  FLock.Enter;
  try
    Have := FQueue.Count > 0;
    if Have then
    begin
      Item := FQueue.Dequeue;
      Stale := Item.Generation <> FGeneration;
      // O começo da faixa em fila é o PRÓXIMO item, não o que acabou de sair —
      // senão o cálculo de quanto ainda há em fila fica sempre um item adiantado.
      if FQueue.Count > 0 then
        FQueuedFromMs := FQueue.Peek.WallMs;
    end;
    Ended := FEnded and (FQueue.Count = 0);
    Target := FSeekTargetMs;
    Spd := FSpeed;
  finally
    FLock.Leave;
  end;

  // Sample de antes do último seek: descarta sem tocar no relógio.
  if Stale then Exit;

  if not Have then
  begin
    if Ended then
      SetState(pbEnded)
    else
    begin
      SetState(pbBuffering);
      FWake.SetEvent; // fila secou: a busca tem prioridade
    end;
    TThread.Sleep(20);
    Exit;
  end;

  // Emenda: outro arquivo, outro header, outra base de PTS. Limpa o
  // decodificador, reanuncia formato e joga a âncora fora.
  if Item.NewSegment then
  begin
    if FSink <> nil then
      FSink.OnStreamStopped;
    AnnounceFormats(Item.Header);
    FHasVideo := Item.Header.VideoPresent and (Item.Header.Video.Codec <> vcNone);
    FAnchorValid := False;
    FWaitKeyframe := FHasVideo;
    FFedSinceSegment := 0;
  end;

  // Sem keyframe, o decodificador não tem por onde começar: o que vier antes
  // dele só produz macrobloco quebrado (ou nada). O áudio espera junto para as
  // duas trilhas entrarem no mesmo ponto.
  if FWaitKeyframe then
  begin
    if (Item.Sample.Kind <> tkVideo) or (not (sfKeyframe in Item.Sample.Flags)) then
      Exit;
    FWaitKeyframe := False;
    Log(llInfo, 'entrando no keyframe');
  end;

  // O seek cai no keyframe ANTERIOR ao instante pedido. O que está antes do alvo
  // sai sem ritmo — passa num borrão de fração de segundo — e o áudio desse
  // trecho nem é entregue, senão o AudioTrack levaria uma rajada.
  Burst := (Target > 0) and (Item.WallMs < Target);
  if Burst and (Item.Sample.Kind = tkAudio) then Exit;

  // Áudio só faz sentido em 1x: acima disso o AudioTrack não acompanha.
  if (Item.Sample.Kind = tkAudio) and (Abs(Spd - 1.0) > 0.01) then Exit;

  // Varredura rápida: acima de PLAY_ALLFRAMES_MAX_SPEED só o keyframe entra.
  // Cada um decodifica sozinho, sem depender de quadro anterior, então o que sai
  // é uma sequência de imagens inteiras andando na velocidade pedida — em vez de
  // um vídeo completo que o decodificador não dá conta e que acaba andando mais
  // devagar do que o botão promete.
  if (Item.Sample.Kind = tkVideo) and (Spd > PLAY_ALLFRAMES_MAX_SPEED) and
     (not (sfKeyframe in Item.Sample.Flags)) then Exit;

  // Quem dita o ritmo é o vídeo; o áudio sai na posição em que foi gravado, sem
  // espera própria. Sem trilha de vídeo, quem dita é o áudio.
  if (not Burst) and ((Item.Sample.Kind = tkVideo) or (not FHasVideo)) then
  begin
    NowMs := FClock.MonotonicMs;
    if not FAnchorValid then
    begin
      FAnchorValid := True;
      FAnchorPts := Item.Sample.Pts;
      FAnchorWallMs := NowMs;
      WaitMs := 0;
    end
    else
    begin
      if Item.Timescale = 0 then Item.Timescale := 90000;
      RelativeMs := ((Item.Sample.Pts - FAnchorPts) * 1000) div Int64(Item.Timescale);
      if Spd > 0 then
        RelativeMs := Round(RelativeMs / Spd);
      Deadline := FAnchorWallMs + RelativeMs;
      WaitMs := Deadline - NowMs;
      // Fora dos limites não é atraso normal e sim descontinuidade de PTS ou
      // fila que cresceu demais: re-ancora e segue no ritmo certo daqui.
      if (WaitMs > PLAY_MAX_WAIT_MS) or (WaitMs < -PLAY_MAX_LAG_MS) then
      begin
        FAnchorPts := Item.Sample.Pts;
        FAnchorWallMs := NowMs;
        WaitMs := 0;
      end;
    end;
    if WaitMs > 0 then
      TThread.Sleep(Integer(WaitMs));
  end;

  if FSink <> nil then
    FSink.OnSample(Item.Sample);

  Inc(FFedSinceSegment);
  // Uma linha por trecho, com o que efetivamente foi entregue. Sem isto, "está
  // tocando" e "está preto" são indistinguíveis no log.
  if FFedSinceSegment = 1 then
    Log(llInfo, Format('primeiro sample entregue: %s %d bytes keyframe=%d pts=%d',
      [IfThen(Item.Sample.Kind = tkVideo, 'video', 'audio'), Length(Item.Sample.Data),
       Ord(sfKeyframe in Item.Sample.Flags), Item.Sample.Pts]));

  if State <> pbPlaying then
    SetState(pbPlaying);
  NotifyPosition(Item.WallMs);

  FLock.Enter;
  try
    if QueuedMs < FTargetBufferMs div 2 then
      FWake.SetEvent;
  finally
    FLock.Leave;
  end;
end;

end.
