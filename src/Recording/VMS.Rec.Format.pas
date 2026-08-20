unit VMS.Rec.Format;

interface

uses
  System.SysUtils,
  VMS.Domain.Types;

const
  VMS_MAGIC_FILE   : array[0..3] of Byte = (Ord('V'), Ord('M'), Ord('S'), Ord('1'));
  VMS_MAGIC_BLOCK  : array[0..3] of Byte = (Ord('B'), Ord('L'), Ord('K'), $01);
  VMS_MAGIC_FOOTER : array[0..3] of Byte = (Ord('V'), Ord('E'), Ord('O'), Ord('F'));
  // Índice tempo -> posição, escrito logo antes do rodapé quando a gravação
  // fecha. Sem ele, achar um instante no arquivo custa uma varredura bloco a
  // bloco — tolerável para o ao vivo (uma vez), inviável para uma timeline.
  VMS_MAGIC_INDEX  : array[0..3] of Byte = (Ord('V'), Ord('I'), Ord('D'), Ord('X'));

  // Âncora A/V do bloco: o instante de parede do PRIMEIRO sample de cada trilha
  // dentro dele. Sem isso as duas trilhas só têm PTS em bases diferentes, e nada
  // que as relacione — quem toca precisa supor que começam juntas, congelando na
  // saída a defasagem que houver.
  //
  // Mora no FIM DA ÁREA DE ÍNDICE do bloco, contada dentro do `indexSize`: quem
  // lê percorre `sampleCount` entradas e acha o payload por `indexSize`, então
  // ela cabe ali sem mexer em mais nada.
  VMS_MAGIC_ANCHOR : array[0..3] of Byte = (Ord('B'), Ord('A'), Ord('N'), Ord('C'));

  // Formato em desenvolvimento: um número só, sem leitura de versão anterior.
  // Mudou o layout, apaga-se a gravação antiga — é mais barato que carregar
  // caminho de compatibilidade que nunca vai rodar em produção.
  VMS_FORMAT_VERSION = 1;

  // magic(4) + blocos(4) + duração(8) + offset do último bloco(8)
  //   + offset do índice(8) + entradas(4) + crc(4)
  VMS_FOOTER_SIZE = 40;
  // offset(8) + startUnixMs(8) + flags(1)
  VMS_INDEX_ENTRY_SIZE = 17;
  // magic(4) + tamanho(4) + entradas(4) + ... + crc(4)
  VMS_INDEX_HEADER_SIZE = 12;

  // magic(4) + âncora de vídeo(8) + âncora de áudio(8)
  VMS_ANCHOR_SIZE = 20;

  // ------------------------------------------------------------------------
  // Região de índice viva ('VLIX'), entre o header e o primeiro bloco.
  //
  // O VIDX do rodapé só existe depois que a gravação fecha; enquanto ela corre,
  // achar um instante custa varrer bloco a bloco (ScanBlocksFrom). Esta região é
  // reservada na criação do arquivo e atualizada NO LUGAR a cada punhado de
  // blocos, então o arquivo em gravação — que é justamente o que se quer
  // assistir — também tem índice.
  //
  // Fica FORA do header de propósito: o header é copiado byte a byte para dentro
  // de cada fragmento servido pela API (TVmsReader.ReadHeaderBytes), e um índice
  // ali dentro viajaria para o celular a cada pedaço de reprodução.
  //
  // Quando ela enche, quem grava RODA DE ARQUIVO (ver TRecordingSink). É por isso
  // que não há encadeamento: o tamanho da região é o que define o tamanho do
  // segmento, e estourar deixa de ser um caso a tratar. Se alguém gravar sem
  // rodar assim mesmo, o arquivo continua válido — o índice vivo para de crescer
  // e quem ler antes do fechamento varre a cauda.
  VMS_MAGIC_REGION : array[0..3] of Byte = (Ord('V'), Ord('L'), Ord('I'), Ord('X'));

  // magic(4) + tamanho(4) + capacidade(4) + slot A(12) + slot B(12) + reserva(4)
  VMS_REGION_HEADER_SIZE  = 40;
  VMS_REGION_COMMIT_A_OFS = 12;
  VMS_REGION_COMMIT_B_OFS = 24;
  // entradas(4) + geração(4) + crc(4) das `entradas` primeiras entradas
  VMS_REGION_COMMIT_SIZE  = 12;

  // Dois slots de commit alternados: a escrita de 12 bytes num setor não é
  // atômica por contrato. Escrevendo sempre no slot que NÃO está valendo, uma
  // queda no meio da atualização deixa o commit anterior intacto — perde-se o
  // último punhado de blocos do índice, que a varredura de cauda recupera.
  VMS_REGION_SLOTS = 2;

  // 64 KB = 3852 blocos = ~2 h a 2 s por bloco, ~600 MB de arquivo a 650 kbps.
  // Este número é o que decide de quanto em quanto tempo a gravação roda de
  // arquivo, e portanto quantos arquivos ficam na pasta da câmera.
  VMS_REGION_DEFAULT_BYTES = 64 * 1024;
  VMS_REGION_MIN_BYTES     = 4 * 1024;
  VMS_REGION_MAX_BYTES     = 8 * 1024 * 1024;
  // Folga no fim da região para esperar um keyframe antes de rodar de arquivo:
  // assim o arquivo novo começa por um ponto de entrada do decodificador.
  VMS_REGION_KEYFRAME_SLACK = 64;

  // magic(4)+tamanho(4)+seq(4)+startMs(8)+samples(4)+tamanho do índice(4)
  VMS_BLOCK_HEADER_SIZE = 28;
  // trackId(1) + flags(1) + pts(8) + offset(4) + tamanho(4)
  VMS_SAMPLE_ENTRY_SIZE = 18;

  VMS_IDX_FLAG_KEYFRAME = $01;

type
  TVmsHeader = record
    Version: Word;
    HeaderSize: Cardinal;
    CreationUnixMs: Int64;
    SourceUri: string;
    VideoPresent: Boolean;
    Video: TVideoTrackInfo;
    AudioPresent: Boolean;
    Audio: TAudioTrackInfo;
  end;

  TVmsSampleEntry = record
    TrackId: TTrackId;
    FlagsByte: Byte;
    Pts: Int64;
    PayloadOffset: Cardinal;
    PayloadSize: Cardinal;
  end;

  TVmsBlock = record
    BlockSeq: Cardinal;
    StartUnixMs: Int64;
    Samples: array of TVmsSampleEntry;
    Payload: TBytes;
    // Instante de parede do primeiro sample de cada trilha neste bloco; 0 = a
    // trilha não aparece aqui. É o que permite relacionar os PTS das duas
    // trilhas, que correm em bases diferentes.
    VideoAnchorMs: Int64;
    AudioAnchorMs: Int64;
  end;

  TVmsFooter = record
    TotalBlocks: Cardinal;
    TotalDurationMs: Int64;
    LastBlockOffset: UInt64;
    // IndexOffset = 0 significa "fechou sem conseguir escrever o índice"; quem
    // precisa do índice varre o arquivo.
    IndexOffset: UInt64;
    IndexCount: Cardinal;
  end;

  // Uma entrada por bloco, na ordem do arquivo. O fim de um bloco é o começo do
  // seguinte; o do último sai da duração no rodapé.
  TVmsIndexEntry = record
    Offset: Int64;
    StartUnixMs: Int64;
    Flags: Byte;
    function HasKeyframe: Boolean;
  end;

  TVmsIndex = TArray<TVmsIndexEntry>;

function FlagsToByte(const Flags: TSampleFlags): Byte;
function ByteToFlags(B: Byte): TSampleFlags;
// Bloco que contém aquele instante, ou o anterior mais próximo; -1 se o instante
// é anterior ao primeiro bloco. Busca binária: o índice está em ordem de tempo
// porque está em ordem de arquivo, e o gravador só acrescenta.
function IndexBlockAtTime(const Index: TVmsIndex; WallClockMs: Int64): Integer;
// Andando para trás a partir de From, o primeiro bloco com keyframe de vídeo —
// o ponto por onde um decodificador consegue entrar. -1 se não há nenhum.
function IndexKeyframeAtOrBefore(const Index: TVmsIndex; From: Integer): Integer;
// Um bloco serve de ponto de entrada quando traz keyframe de vídeo. Como o
// TBlockBuilder fecha bloco por tempo/tamanho e não por keyframe, isso é uma
// propriedade a descobrir olhando os samples, não um invariante do formato.
function SamplesHaveKeyframe(const Samples: array of TVmsSampleEntry): Boolean;
// Tamanho de região válido, com os extremos aparados. 0 (ou negativo) devolve o
// padrão — é o que a config faz quando o campo não está lá.
function NormalizeRegionBytes(Bytes: Integer): Integer;
// Quantas entradas cabem numa região deste tamanho.
function RegionCapacity(RegionBytes: Integer): Integer;

implementation

function FlagsToByte(const Flags: TSampleFlags): Byte;
begin
  Result := 0;
  if sfKeyframe in Flags    then Result := Result or $01;
  if sfStartOfFrame in Flags then Result := Result or $02;
  if sfEndOfFrame in Flags   then Result := Result or $04;
end;

function ByteToFlags(B: Byte): TSampleFlags;
begin
  Result := [];
  if (B and $01) <> 0 then Include(Result, sfKeyframe);
  if (B and $02) <> 0 then Include(Result, sfStartOfFrame);
  if (B and $04) <> 0 then Include(Result, sfEndOfFrame);
end;

function NormalizeRegionBytes(Bytes: Integer): Integer;
begin
  if Bytes <= 0 then Exit(VMS_REGION_DEFAULT_BYTES);
  Result := Bytes;
  if Result < VMS_REGION_MIN_BYTES then Result := VMS_REGION_MIN_BYTES;
  if Result > VMS_REGION_MAX_BYTES then Result := VMS_REGION_MAX_BYTES;
end;

function RegionCapacity(RegionBytes: Integer): Integer;
begin
  Result := (RegionBytes - VMS_REGION_HEADER_SIZE) div VMS_INDEX_ENTRY_SIZE;
  if Result < 0 then Result := 0;
end;

function SamplesHaveKeyframe(const Samples: array of TVmsSampleEntry): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Samples) do
    if (Samples[I].TrackId = 0) and ((Samples[I].FlagsByte and $01) <> 0) then
      Exit(True);
  Result := False;
end;

function IndexBlockAtTime(const Index: TVmsIndex; WallClockMs: Int64): Integer;
var
  Lo, Hi, Mid, Best: Integer;
begin
  Result := -1;
  if Length(Index) = 0 then Exit;
  if WallClockMs < Index[0].StartUnixMs then Exit;
  Lo := 0;
  Hi := High(Index);
  Best := 0;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if Index[Mid].StartUnixMs <= WallClockMs then
    begin
      Best := Mid;
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  Result := Best;
end;

function IndexKeyframeAtOrBefore(const Index: TVmsIndex; From: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (From < 0) or (From > High(Index)) then Exit;
  for I := From downto 0 do
    if Index[I].HasKeyframe then
      Exit(I);
end;

{ TVmsIndexEntry }

function TVmsIndexEntry.HasKeyframe: Boolean;
begin
  Result := (Flags and VMS_IDX_FLAG_KEYFRAME) <> 0;
end;

end.
