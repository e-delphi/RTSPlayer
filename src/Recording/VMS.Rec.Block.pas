unit VMS.Rec.Block;

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Rec.Format;

type
  TBlockClosedEvent = reference to procedure(const Block: TVmsBlock);

  // O que liga o pts de uma trilha ao relógio de parede, ao longo da gravação
  // inteira. Ver TBlockBuilder.AncoraDe para o porquê de ser da GRAVAÇÃO e não
  // do bloco.
  TAncoraTrilha = record
    Valida: Boolean;
    WallMs: Int64;        // parede do sample de referência
    Pts: Int64;           // pts desse mesmo sample
    Timescale: Cardinal;  // 0 = desconhecida; aí vale o relógio de chegada
    FimMs: Int64;         // parede do fim do último bloco emitido
  end;

  TBlockBuilder = class
  strict private
    FSeq: Cardinal;
    FStartUnixMs: Int64;
    FStartMonotonicMs: Int64;
    // instante de parede do primeiro sample de cada trilha neste bloco (0 = a
    // trilha ainda não apareceu); é a âncora A/V que vai no bloco
    FFirstVideoMs: Int64;
    FFirstAudioMs: Int64;
    // Âncora da gravação, e o pts do primeiro e do último sample de cada trilha
    // NESTE bloco -- é deles que sai onde o bloco termina, em parede.
    FAncora: array[TTrackKind] of TAncoraTrilha;
    FPrimeiroPts: array[TTrackKind] of Int64;
    FUltimoPts: array[TTrackKind] of Int64;
    FSamples: array of TVmsSampleEntry;
    FSampleCount: Integer;
    FPayload: TBytes;
    FPayloadSize: Integer;
    FMaxSamples: Integer;
    FMaxDurationMs: Integer;
    FMaxSizeBytes: Integer;
    FOnClose: TBlockClosedEvent;
    procedure GrowPayload(Need: Integer);
    function AncoraDe(Trilha: TTrackKind; Pts, ChegouMs: Int64): Int64;
    procedure FecharAncora(Trilha: TTrackKind; AncoraDoBloco: Int64);
    procedure StartNew(NowUnixMs, NowMonotonicMs: Int64);
    function ShouldClose(NowMonotonicMs: Int64): Boolean;
    procedure EmitBlock;
  public
    constructor Create(AMaxSamples, AMaxDurationMs, AMaxSizeBytes: Integer);
    procedure SetOnBlockClosed(const Callback: TBlockClosedEvent);
    // As escalas de tempo das trilhas, do header. Sem elas o builder se comporta
    // como antes -- âncora igual ao relógio de chegada --, e é por isso que pode
    // ser chamado depois do Create, quando o formato aparece.
    procedure SetTimescales(AVideo, AAudio: Cardinal);
    procedure AddSample(const Sample: TSample; NowUnixMs, NowMonotonicMs: Int64);
    procedure ForceFlush(NowUnixMs, NowMonotonicMs: Int64);
    function IsEmpty: Boolean;
    function CurrentSeq: Cardinal;
  end;

implementation

const
  INITIAL_PAYLOAD_CAP = 64 * 1024;
  INITIAL_SAMPLES_CAP = 128;
  // O quanto o relógio derivado do pts pode se afastar do relógio de quem grava
  // antes de a âncora ser refeita. Ver AncoraDe.
  //
  // Dez segundos é folgado de propósito: jitter de rede e rajada de câmera que
  // esvazia buffer valem segundos, e é justamente isso que não pode virar
  // re-ancoragem. O que passa disto não é jitter -- é o pts falando de outro
  // relógio.
  MAX_DESVIO_ANCORA_MS = 10000;

{ TBlockBuilder }

constructor TBlockBuilder.Create(AMaxSamples, AMaxDurationMs, AMaxSizeBytes: Integer);
begin
  inherited Create;
  FSeq := 0;
  FMaxSamples := AMaxSamples;
  FMaxDurationMs := AMaxDurationMs;
  FMaxSizeBytes := AMaxSizeBytes;
  if FMaxSamples <= 0 then FMaxSamples := 256;
  if FMaxDurationMs <= 0 then FMaxDurationMs := 2000;
  if FMaxSizeBytes <= 0 then FMaxSizeBytes := 1024 * 1024;
  SetLength(FSamples, INITIAL_SAMPLES_CAP);
  SetLength(FPayload, INITIAL_PAYLOAD_CAP);
  FSampleCount := 0;
  FPayloadSize := 0;
  FStartUnixMs := 0;
  FStartMonotonicMs := 0;
end;

procedure TBlockBuilder.SetOnBlockClosed(const Callback: TBlockClosedEvent);
begin
  FOnClose := Callback;
end;

procedure TBlockBuilder.SetTimescales(AVideo, AAudio: Cardinal);
begin
  FAncora[tkVideo].Timescale := AVideo;
  FAncora[tkAudio].Timescale := AAudio;
end;

// Em que instante de parede começa esta trilha, neste bloco.
//
// Era o relógio de quem grava, no momento em que o sample chegou. E aí estava o
// defeito: o leitor calcula o instante de cada sample como
//
//   wallMs = âncora do bloco + (pts - primeiro pts do bloco) / timescale
//
// ou seja, DENTRO do bloco quem manda é o pts, e na virada quem manda é o
// relógio de chegada. Os dois não andam no mesmo passo. Quando a câmera segura
// quadros e depois os despeja de uma vez -- reconexão, congestionamento, buffer
// esvaziando --, o pts avança mais do que a parede: o bloco se estende além de
// onde o seguinte foi ancorado, e os dois passam a cobrir o mesmo intervalo.
// Medido numa gravação real: 7 de 39 fragmentos começavam antes do fim do
// anterior, com até 2,1 s de sobreposição, sempre na fronteira de bloco. Na
// reprodução isso é a imagem voltando um pedaço e tocando de novo.
//
// Quem tem razão sobre o ESPAÇAMENTO entre quadros é o pts: ele diz quando cada
// quadro foi capturado. O relógio de chegada só diz quando o pacote apareceu
// aqui, o que passa por rede e por fila. Então a âncora passa a ser derivada de
// uma referência única da gravação, e o relógio de chegada vira o que sempre
// deveria ter sido: o modo de descobrir que o pts parou de fazer sentido.
function TBlockBuilder.AncoraDe(Trilha: TTrackKind; Pts, ChegouMs: Int64): Int64;
var
  Ts: Cardinal;
  Derivada: Int64;
begin
  Ts := FAncora[Trilha].Timescale;
  // Sem escala não há o que derivar: fica como era antes de existir âncora de
  // gravação. É também o caminho do primeiro sample de tudo.
  if (Ts = 0) or (not FAncora[Trilha].Valida) then
  begin
    Result := ChegouMs;
    FAncora[Trilha].Valida := True;
    FAncora[Trilha].WallMs := Result;
    FAncora[Trilha].Pts := Pts;
    Exit;
  end;

  // Inteiro, e não ponto flutuante: pts de 90 kHz num dia inteiro vezes mil já
  // sai da faixa exata do double, e o erro apareceria como tremor de ms.
  Derivada := FAncora[Trilha].WallMs +
              ((Pts - FAncora[Trilha].Pts) * 1000) div Int64(Ts);

  if Abs(Derivada - ChegouMs) <= MAX_DESVIO_ANCORA_MS then
    Exit(Derivada);

  // Longe demais: o pts deixou de falar do mesmo relógio -- a câmera reconectou,
  // reiniciou a contagem, ou o contador deu a volta. Refaz a referência pelo
  // relógio de quem grava, mas NUNCA para trás do fim do bloco anterior: recuar
  // aqui recriaria exatamente a sobreposição que isto veio consertar.
  Result := ChegouMs;
  if Result < FAncora[Trilha].FimMs then Result := FAncora[Trilha].FimMs;
  FAncora[Trilha].WallMs := Result;
  FAncora[Trilha].Pts := Pts;
end;

// Onde este bloco termina, em parede -- pela MESMA conta que o leitor faz.
procedure TBlockBuilder.FecharAncora(Trilha: TTrackKind; AncoraDoBloco: Int64);
var
  Ts: Cardinal;
begin
  if AncoraDoBloco = 0 then Exit;   // trilha não apareceu neste bloco
  Ts := FAncora[Trilha].Timescale;
  if Ts = 0 then
    FAncora[Trilha].FimMs := AncoraDoBloco
  else
    FAncora[Trilha].FimMs := AncoraDoBloco +
      ((FUltimoPts[Trilha] - FPrimeiroPts[Trilha]) * 1000) div Int64(Ts);
end;

procedure TBlockBuilder.GrowPayload(Need: Integer);
var
  NewCap: Integer;
begin
  if Need <= Length(FPayload) then Exit;
  NewCap := Length(FPayload);
  while NewCap < Need do NewCap := NewCap * 2;
  SetLength(FPayload, NewCap);
end;

procedure TBlockBuilder.StartNew(NowUnixMs, NowMonotonicMs: Int64);
begin
  FSampleCount := 0;
  FPayloadSize := 0;
  FStartUnixMs := NowUnixMs;
  FStartMonotonicMs := NowMonotonicMs;
  FFirstVideoMs := 0;
  FFirstAudioMs := 0;
  FPrimeiroPts[tkVideo] := 0;
  FPrimeiroPts[tkAudio] := 0;
  FUltimoPts[tkVideo] := 0;
  FUltimoPts[tkAudio] := 0;
end;

function TBlockBuilder.ShouldClose(NowMonotonicMs: Int64): Boolean;
begin
  if FSampleCount = 0 then Exit(False);
  if FSampleCount >= FMaxSamples then Exit(True);
  if FPayloadSize >= FMaxSizeBytes then Exit(True);
  if (NowMonotonicMs - FStartMonotonicMs) >= FMaxDurationMs then Exit(True);
  Result := False;
end;

procedure TBlockBuilder.EmitBlock;
var
  Block: TVmsBlock;
  I: Integer;
begin
  if FSampleCount = 0 then Exit;
  Block.BlockSeq := FSeq;
  Block.StartUnixMs := FStartUnixMs;
  Block.VideoAnchorMs := FFirstVideoMs;
  Block.AudioAnchorMs := FFirstAudioMs;
  // O StartUnixMs acompanha a âncora, e não o relógio de chegada.
  //
  // É dele que saem o índice, a régua e a busca por instante; das âncoras saem
  // os quadros. Deixar um vindo da chegada e o outro do pts faria a régua
  // apontar para um instante e a imagem para outro -- pelo que o modelo mede,
  // até alguns segundos de diferença numa rajada.
  if FFirstVideoMs > 0 then
    Block.StartUnixMs := FFirstVideoMs
  else if FFirstAudioMs > 0 then
    Block.StartUnixMs := FFirstAudioMs;
  // Onde este bloco acaba: é o piso do próximo, se houver re-ancoragem.
  FecharAncora(tkVideo, FFirstVideoMs);
  FecharAncora(tkAudio, FFirstAudioMs);
  SetLength(Block.Samples, FSampleCount);
  for I := 0 to FSampleCount - 1 do
    Block.Samples[I] := FSamples[I];
  SetLength(Block.Payload, FPayloadSize);
  if FPayloadSize > 0 then
    Move(FPayload[0], Block.Payload[0], FPayloadSize);
  Inc(FSeq);
  FSampleCount := 0;
  FPayloadSize := 0;
  if Assigned(FOnClose) then
    FOnClose(Block);
end;

procedure TBlockBuilder.AddSample(const Sample: TSample; NowUnixMs, NowMonotonicMs: Int64);
var
  Entry: TVmsSampleEntry;
  DataSize: Integer;
begin
  DataSize := Length(Sample.Data);
  if DataSize = 0 then Exit;
  if FSampleCount = 0 then
    StartNew(NowUnixMs, NowMonotonicMs);

  if FSampleCount >= Length(FSamples) then
    SetLength(FSamples, Length(FSamples) * 2);
  GrowPayload(FPayloadSize + DataSize);

  // Primeiro sample de cada trilha no bloco: guarda o instante de parede. É o
  // único ponto do sistema que sabe QUANDO cada trilha começou aqui — depois só
  // restam PTS em bases diferentes.
  if Sample.Kind = tkVideo then
  begin
    if FFirstVideoMs = 0 then
    begin
      FPrimeiroPts[tkVideo] := Sample.Pts;
      FUltimoPts[tkVideo] := Sample.Pts;
      FFirstVideoMs := AncoraDe(tkVideo, Sample.Pts, NowUnixMs);
    end
    // Maior, e não o último: com quadros B o pts não sobe em ordem de
    // decodificação, e o fim do bloco é o maior carimbo que passou por ele.
    else if Sample.Pts > FUltimoPts[tkVideo] then
      FUltimoPts[tkVideo] := Sample.Pts;
  end
  else
  begin
    if FFirstAudioMs = 0 then
    begin
      FPrimeiroPts[tkAudio] := Sample.Pts;
      FUltimoPts[tkAudio] := Sample.Pts;
      FFirstAudioMs := AncoraDe(tkAudio, Sample.Pts, NowUnixMs);
    end
    else if Sample.Pts > FUltimoPts[tkAudio] then
      FUltimoPts[tkAudio] := Sample.Pts;
  end;

  Entry.TrackId := Sample.TrackId;
  Entry.FlagsByte := FlagsToByte(Sample.Flags);
  Entry.Pts := Sample.Pts;
  Entry.PayloadOffset := Cardinal(FPayloadSize);
  Entry.PayloadSize := Cardinal(DataSize);
  if Sample.Kind = tkVideo then
    Entry.TrackId := Sample.TrackId
  else
    Entry.TrackId := Sample.TrackId;

  FSamples[FSampleCount] := Entry;
  Inc(FSampleCount);
  Move(Sample.Data[0], FPayload[FPayloadSize], DataSize);
  Inc(FPayloadSize, DataSize);

  if ShouldClose(NowMonotonicMs) then
    EmitBlock;
end;

procedure TBlockBuilder.ForceFlush(NowUnixMs, NowMonotonicMs: Int64);
begin
  if FSampleCount > 0 then
    EmitBlock;
end;

function TBlockBuilder.IsEmpty: Boolean;
begin
  Result := FSampleCount = 0;
end;

function TBlockBuilder.CurrentSeq: Cardinal;
begin
  Result := FSeq;
end;

end.
