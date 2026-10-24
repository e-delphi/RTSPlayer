unit Vms.Thumb.Keyframe;

// Acha, na gravação, o quadro comprimido que representa um instante.
//
// É o único lugar do subsistema de miniaturas que sabe o que é um `.vms`. Ele
// devolve bytes Annex-B e o codec; quem decodifica não faz ideia de onde vieram.
//
// A busca reusa o índice que já existe (rodapé ou `.vms.idx`), então achar o
// keyframe de um instante é uma busca binária mais a leitura de UM bloco — não
// há varredura nenhuma aqui.

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Reader,
  Vms.Server.IndexCache,
  Vms.Thumb.Intf;

type
  TVmsKeyframeSource = class(TInterfacedObject, IKeyframeSource)
  strict private
    FCache: TVmsIndexCache;
    FLogger: ILogger;
  public
    constructor Create(ACache: TVmsIndexCache; const ALogger: ILogger);
    { IKeyframeSource }
    function Grab(const Camera: string; Ms: Int64; out AU, Extra: TBytes;
                  out Codec: TVideoCodec; out ActualMs: Int64): Boolean;
  end;

implementation

// O arquivo da câmera que contém aquele instante. Mesma regra do /api/media:
// caindo num buraco de gravação, vale o arquivo seguinte.
function FileAt(ACache: TVmsIndexCache; const Camera: string; Ms: Int64;
  out Info: TVmsFileInfo): Boolean;
var
  Files: TVmsFileInfoArray;
  I: Integer;
begin
  Result := False;
  Files := ACache.ListFiles(Camera);
  if Length(Files) = 0 then Exit;
  for I := 0 to High(Files) do
    if (Ms >= Files[I].StartMs) and (Ms < Files[I].EndMs) then
    begin
      Info := Files[I];
      Exit(True);
    end;
  for I := 0 to High(Files) do
    if Files[I].StartMs >= Ms then
    begin
      Info := Files[I];
      Exit(True);
    end;
end;

constructor TVmsKeyframeSource.Create(ACache: TVmsIndexCache; const ALogger: ILogger);
begin
  inherited Create;
  FCache := ACache;
  FLogger := ALogger;
end;

function TVmsKeyframeSource.Grab(const Camera: string; Ms: Int64;
  out AU, Extra: TBytes; out Codec: TVideoCodec; out ActualMs: Int64): Boolean;
var
  Info: TVmsFileInfo;
  Index: TVmsIndex;
  Reader: TVmsReader;
  Block: TVmsBlock;
  BlockIdx, KeyIdx, I: Integer;
  Anchor, FirstPts, Timescale: Int64;
  HaveFirst: Boolean;
begin
  Result := False;
  AU := nil;
  Extra := nil;
  Codec := vcNone;
  ActualMs := 0;

  if not FileAt(FCache, Camera, Ms, Info) then Exit;
  if not FCache.GetIndex(Info.Path, Index) then Exit;
  if Length(Index) = 0 then Exit;

  BlockIdx := IndexBlockAtTime(Index, Ms);
  if BlockIdx < 0 then BlockIdx := 0;
  // O quadro de um instante é o keyframe em vigor nele — o anterior mais
  // próximo. Sem isto a miniatura só existiria nos instantes de keyframe.
  KeyIdx := IndexKeyframeAtOrBefore(Index, BlockIdx);
  if KeyIdx < 0 then Exit;

  try
    Reader := TVmsReader.Create(Info.Path);
  except
    Exit;
  end;
  try
    Reader.Logger := FLogger;
    if not Reader.ReadHeader then Exit;
    if not Reader.Header.VideoPresent then Exit;
    Codec := Reader.Header.Video.Codec;
    Extra := Reader.Header.Video.Extradata;
    Timescale := Reader.Header.Video.Timescale;
    if Timescale <= 0 then Timescale := 90000;
    // O índice que eu tenho na mão veio do CACHE; este leitor acabou de abrir e
    // o dele está vazio. Sem semear, o SeekToBlock reprova todo índice por
    // estar fora de um vetor de tamanho zero — e nenhuma miniatura sairia,
    // sempre com a mesma cara de "não há keyframe aqui".
    Reader.SeedIndex(Index, Index[High(Index)].Offset);
    if not Reader.SeekToBlock(KeyIdx) then Exit;
    if not Reader.ReadNextBlock(Block) then Exit;

    // O instante de parede do sample é contado da âncora de vídeo do bloco,
    // igual ao que o player faz. Sem isto a miniatura diria o horário do começo
    // do bloco, e não o do quadro que ela mostra.
    Anchor := Block.VideoAnchorMs;
    if Anchor = 0 then Anchor := Block.StartUnixMs;
    FirstPts := 0;
    HaveFirst := False;
    for I := 0 to High(Block.Samples) do
    begin
      if Block.Samples[I].TrackId <> 0 then Continue;
      if not HaveFirst then
      begin
        FirstPts := Block.Samples[I].Pts;
        HaveFirst := True;
      end;
      if (Block.Samples[I].FlagsByte and VMS_IDX_FLAG_KEYFRAME) = 0 then Continue;
      if Block.Samples[I].PayloadSize = 0 then Continue;
      SetLength(AU, Block.Samples[I].PayloadSize);
      Move(Block.Payload[Block.Samples[I].PayloadOffset], AU[0],
           Block.Samples[I].PayloadSize);
      ActualMs := Anchor +
                  ((Block.Samples[I].Pts - FirstPts) * 1000) div Timescale;
      Exit(True);
    end;
  finally
    Reader.Free;
  end;
end;

end.
