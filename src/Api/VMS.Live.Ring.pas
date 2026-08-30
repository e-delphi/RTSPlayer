unit VMS.Live.Ring;

// O ao vivo servido em memória, no MESMO formato `.vms` das gravações.
//
// É um `IMediaSink`: entra na cadeia da câmera junto com o que já existe, e vai
// acumulando samples num `TBlockBuilder` — o mesmo que o gravador usa. Quando o
// bloco fecha, ele vira bytes e entra num anel.
//
// ## Por que .vms, e não um formato novo
//
// Porque o player em HTML já lê `.vms`: cabeçalho, blocos, âncora, cursor. Ao
// vivo e gravação passam a ser a mesma coisa para ele, e a única diferença é a
// rota que respondeu. Inventar um formato de streaming aqui significaria um
// segundo leitor em JavaScript, e a chance de os dois discordarem.
//
// É a mesma regra que o vmsserver já segue: o formato que existe é o protocolo.
//
// ## O anel
//
// Só os últimos segundos ficam. Não é cache de gravação — isso é do vmsserver,
// que grava em disco. Aqui o anel existe para o espectador que chegou meio
// segundo atrasado achar um keyframe, e para aguentar um engasgo de rede sem
// perder o fio.
//
// ## Concorrência
//
// Alimentado pela thread da sessão da câmera; lido pelas threads do Indy. Tudo
// que toca o anel passa pelo lock. Os bytes entregues são cópia: devolver a
// referência deixaria o leitor com um array que o anel pode descartar no
// instante seguinte.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Clock,
  VMS.Domain.MediaSink,
  VMS.Rec.Format,
  VMS.Rec.Block;

type
  TLiveRing = class(TInterfacedObject, IMediaSink)
  strict private
    type
      TItem = record
        Seq: Cardinal;
        StartMs: Int64;
        Bytes: TBytes;
      end;
  strict private
    FLock: TCriticalSection;
    FBuilder: TBlockBuilder;
    FItens: TList<TItem>;
    FHeaderBytes: TBytes;
    FHeader: TVmsHeader;
    FTemVideo, FTemAudio: Boolean;
    FCabecalhoPronto: Boolean;
    FProxSeq: Cardinal;
    FMaxItens: Integer;
    FUltimoMs: Int64;
    // O TSample nao carrega instante: ele traz PTS, que e da escala da
    // trilha. A hora de parede entra aqui, como no gravador faz.
    FClock: IClock;
    procedure BlocoFechado(const Block: TVmsBlock);
    procedure RefazerCabecalho;
  public
    constructor Create(const AUri: string; const AClock: IClock;
                      AMaxItens: Integer = 60);
    destructor Destroy; override;

    { IMediaSink }
    procedure OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
                            const Extradata: TBytes);
    procedure OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
                            Channels: Byte; const Extradata: TBytes);
    procedure OnSample(const Sample: TSample);
    procedure OnStreamStopped;

    // Os bytes a entregar a partir de um cursor. Cursor 0 = comece no bloco
    // mais antigo que tenha keyframe; sem isso o decodificador receberia
    // quadros P sem referência e não mostraria nada.
    //
    // ProxCursor volta com o ponto de retomada. Resultado vazio significa "nada
    // novo ainda", e não fim: ao vivo não acaba.
    function Ler(Cursor: Cardinal; out Dados: TBytes;
                 out ProxCursor: Cardinal): Boolean;
    // Instante do último sample que entrou. 0 = nunca chegou nada.
    function UltimoMs: Int64;
    function Pronto: Boolean;
  end;

implementation

uses
  VMS.Rec.Writer;   // BuildHeaderBytes, BuildBlockBytes

const
  // Um bloco fecha por qualquer um destes. Curto de propósito: ao vivo, cada
  // bloco é latência — o espectador só vê o quadro depois que o bloco fecha.
  MAX_SAMPLES = 120;
  MAX_DURACAO_MS = 1000;
  MAX_BYTES = 512 * 1024;

constructor TLiveRing.Create(const AUri: string; const AClock: IClock;
  AMaxItens: Integer);
begin
  inherited Create;
  FClock := AClock;
  FLock := TCriticalSection.Create;
  FItens := TList<TItem>.Create;
  FMaxItens := AMaxItens;
  FProxSeq := 1;

  FHeader := Default(TVmsHeader);
  FHeader.Version := VMS_FORMAT_VERSION;
  FHeader.CreationUnixMs := FClock.NowUtcMs;
  FHeader.SourceUri := AUri;

  FBuilder := TBlockBuilder.Create(MAX_SAMPLES, MAX_DURACAO_MS, MAX_BYTES);
  FBuilder.SetOnBlockClosed(BlocoFechado);
end;

destructor TLiveRing.Destroy;
begin
  FBuilder.Free;
  FItens.Free;
  FLock.Free;
  inherited;
end;

procedure TLiveRing.RefazerCabecalho;
begin
  // Só depois de conhecer as trilhas: um cabeçalho sem codec faria o leitor
  // configurar um decodificador que não existe.
  FHeader.VideoPresent := FTemVideo;
  FHeader.AudioPresent := FTemAudio;
  FHeaderBytes := BuildHeaderBytes(FHeader);
  FCabecalhoPronto := FTemVideo;
end;

procedure TLiveRing.OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
  const Extradata: TBytes);
begin
  FLock.Enter;
  try
    FHeader.Video.Codec := Codec;
    FHeader.Video.Width := Width;
    FHeader.Video.Height := Height;
    FHeader.Video.Timescale := 90000;
    FBuilder.SetTimescales(FHeader.Video.Timescale, FHeader.Audio.Timescale);
    FHeader.Video.Extradata := Copy(Extradata);
    FTemVideo := True;
    RefazerCabecalho;
    // Formato novo invalida o que estava no anel: os blocos antigos podem ser
    // de outra resolução, e um leitor que pegasse o cabeçalho novo com bloco
    // velho decodificaria lixo.
    FItens.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TLiveRing.OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
  Channels: Byte; const Extradata: TBytes);
begin
  FLock.Enter;
  try
    FHeader.Audio.Codec := Codec;
    FHeader.Audio.SampleRate := SampleRate;
    FHeader.Audio.Channels := Channels;
    FHeader.Audio.BitsPerSample := 16;
    FHeader.Audio.Timescale := SampleRate;
    FBuilder.SetTimescales(FHeader.Video.Timescale, FHeader.Audio.Timescale);
    FHeader.Audio.Extradata := Copy(Extradata);
    FTemAudio := True;
    RefazerCabecalho;
  finally
    FLock.Leave;
  end;
end;

procedure TLiveRing.OnSample(const Sample: TSample);
begin
  FLock.Enter;
  try
    if not FCabecalhoPronto then Exit;   // ainda não sei o formato
    FUltimoMs := FClock.NowUtcMs;
    FBuilder.AddSample(Sample, FUltimoMs, FClock.MonotonicMs);
  finally
    FLock.Leave;
  end;
end;

// Chamado de dentro do AddSample, portanto já com o lock tomado.
procedure TLiveRing.BlocoFechado(const Block: TVmsBlock);
var
  Item: TItem;
begin
  Item.Seq := FProxSeq;
  Item.StartMs := Block.StartUnixMs;
  Item.Bytes := BuildBlockBytes(Block);
  Inc(FProxSeq);
  FItens.Add(Item);
  while FItens.Count > FMaxItens do
    FItens.Delete(0);
end;

procedure TLiveRing.OnStreamStopped;
begin
  FLock.Enter;
  try
    FBuilder.ForceFlush(FClock.NowUtcMs, FClock.MonotonicMs);
  finally
    FLock.Leave;
  end;
end;

function TLiveRing.UltimoMs: Int64;
begin
  FLock.Enter;
  try
    Result := FUltimoMs;
  finally
    FLock.Leave;
  end;
end;

function TLiveRing.Pronto: Boolean;
begin
  FLock.Enter;
  try
    Result := FCabecalhoPronto and (FItens.Count > 0);
  finally
    FLock.Leave;
  end;
end;

function TLiveRing.Ler(Cursor: Cardinal; out Dados: TBytes;
  out ProxCursor: Cardinal): Boolean;
var
  I, Inicio, Total, Pos: Integer;
begin
  Result := False;
  Dados := nil;
  ProxCursor := Cursor;

  FLock.Enter;
  try
    if not FCabecalhoPronto then Exit;

    Inicio := -1;
    if Cursor = 0 then
    begin
      // Começo de sessão: o mais antigo serve, e o player descarta sozinho os
      // quadros sem referência até achar o primeiro keyframe. Preferir o mais
      // antigo dá contexto; preferir o mais novo daria menos latência e mais
      // tela preta. Latência aqui é um bloco, então contexto ganha.
      if FItens.Count > 0 then Inicio := 0;
    end
    else
      for I := 0 to FItens.Count - 1 do
        if FItens[I].Seq >= Cursor then
        begin
          Inicio := I;
          Break;
        end;

    if Inicio < 0 then
    begin
      // Cursor à frente do anel: nada novo. Cursor atrás dele (o leitor sumiu
      // tempo demais) também cai aqui, e ao voltar ele recomeça do zero.
      if (Cursor > 0) and (FItens.Count > 0) and
         (Cursor < FItens[0].Seq) then
        ProxCursor := 0;
      Exit;
    end;

    Total := Length(FHeaderBytes);
    for I := Inicio to FItens.Count - 1 do
      Inc(Total, Length(FItens[I].Bytes));

    SetLength(Dados, Total);
    Pos := 0;
    if Length(FHeaderBytes) > 0 then
    begin
      Move(FHeaderBytes[0], Dados[Pos], Length(FHeaderBytes));
      Inc(Pos, Length(FHeaderBytes));
    end;
    for I := Inicio to FItens.Count - 1 do
      if Length(FItens[I].Bytes) > 0 then
      begin
        Move(FItens[I].Bytes[0], Dados[Pos], Length(FItens[I].Bytes));
        Inc(Pos, Length(FItens[I].Bytes));
      end;

    ProxCursor := FItens[FItens.Count - 1].Seq + 1;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

end.
