unit VMS.Rec.Reader;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.StrUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Paths,
  VMS.Rec.Sidecar,
  VMS.Rec.Crc32;

type
  TVmsReader = class
  strict private
    // TStream, e não TFileStream: o app toca fragmentos que chegam pela rede e
    // vivem em memória. É o mesmo leitor nos dois casos — o formato é um só.
    FStream: TStream;
    FOwnsStream: Boolean;
    // Caminho do .vms, quando o leitor foi aberto a partir de um arquivo. Vazio
    // para leitura em memória (o fragmento que a API entrega), que não tem
    // sidecar nem precisa dele.
    FFilePath: string;
    FHeader: TVmsHeader;
    FHeaderRead: Boolean;
    FLiveMode: Boolean;
    FLiveTimeoutMs: Cardinal;
    FFirstBlockOffset: Int64;
    FIndex: TVmsIndex;
    FIndexCount: Integer;
    FIndexBuilt: Boolean;
    FIndexFromFooter: Boolean;
    FScannedUpTo: Int64;   // primeiro offset ainda não varrido (arquivo crescendo)
    FLogger: ILogger;      // opcional: só para avisar de bloco corrompido
    FBadBlocks: Integer;
    FSawClosedEnd: Boolean;   // a leitura sequencial esbarrou no rodapé/índice
    FLastBadPos: Int64;    // offset que já falhou no CRC (0 = nenhum)
    function ReadU16(var Buf: TBytes; var Offset: Integer): Word;
    function ReadU32(var Buf: TBytes; var Offset: Integer): Cardinal;
    function ReadI64(var Buf: TBytes; var Offset: Integer): Int64;
    // Lê cabeçalho + índice de samples de um bloco, sem tocar no payload. False
    // quando não há bloco completo ali (fim do arquivo, rodapé, índice, ou bloco
    // ainda sendo escrito).
    function ReadBlockMeta(Offset: Int64; out BlockSize: Cardinal; out StartUnixMs: Int64;
                           out HasKeyframe: Boolean): Boolean;
    procedure AddIndexEntry(Offset, StartUnixMs: Int64; HasKeyframe: Boolean);
    function ScanBlocksFrom(FromOffset: Int64): Integer;
    function LoadIndexFromFooter: Boolean;
    // Índice do arquivo AINDA EM GRAVAÇÃO, lido do `.vms.idx` ao lado. Deixa
    // FScannedUpTo onde o sidecar parou, para a varredura pegar só a cauda.
    function LoadIndexFromSidecar: Boolean;
    function WaitForBytes(Need: Int64): Boolean;
  public
    constructor Create(const FilePath: string); overload;
    // Fragmento em memória (o que a rota /api/media entrega): mesmo leitor,
    // outra origem. AOwnsStream = quem libera o stream depois.
    constructor Create(AStream: TStream; AOwnsStream: Boolean); overload;
    destructor Destroy; override;
    function ReadHeader: Boolean;
    function ReadNextBlock(out Block: TVmsBlock): Boolean;
    function AtEof: Boolean;
    procedure EnableLiveMode(TimeoutMs: Cardinal = 30000);
    procedure DisableLiveMode;
    function IsLiveMode: Boolean;
    function ReadFooter(out Footer: TVmsFooter): Boolean;
    // Garante índice: usa o do rodapé quando existe (arquivo fechado), senão
    // varre. Devolve o número de blocos indexados.
    function EnsureIndex: Integer;
    function BuildIndex: Integer;
    // Arquivo em gravação: retoma a varredura de onde parou, sem refazer o que
    // já está indexado. Devolve quantos blocos entraram agora.
    function ExtendIndex: Integer;
    // Recebe um índice montado noutra leitura (o cache do servidor) para poder
    // continuar dali. Existe porque manter um TVmsReader aberto entre consultas
    // seguraria o handle do arquivo, e handle aberto impede a retenção de
    // apagá-lo no Windows.
    procedure SeedIndex(const AIndex: TVmsIndex; AScannedUpTo: Int64);
    // ---- resumo barato, para quem monta inventário -------------------------
    // Estas duas existem para o servidor descrever um arquivo (começo, fim,
    // quantos blocos) SEM montar o índice: uma consulta de timeline toca dezenas
    // de arquivos, e montar índice em cada um era o que fazia a primeira
    // consulta depois de subir o servidor demorar.
    //
    // O instante do primeiro bloco — o começo real da faixa deste arquivo, que
    // não é o mesmo que o instante de criação gravado no header.
    function FirstBlockStartMs(out StartUnixMs: Int64): Boolean;
    // O que o `.vms.idx` já registrou: quantos blocos, e o intervalo que eles
    // cobrem. Fica até um lote atrás do arquivo (~30 s), o que é invisível numa
    // timeline; o índice de verdade, com a cauda, sai do EnsureIndex.
    function SidecarSummary(out Count: Integer; out FirstMs, LastMs: Int64): Boolean;

    function SeekToTime(WallClockMs: Int64): Boolean;
    function SeekToBlock(BlockIdx: Integer): Boolean;
    // Índice do bloco que contém o instante (ou o anterior mais próximo); -1 se
    // o instante é anterior ao arquivo ou não há índice.
    function FindBlockAtTime(WallClockMs: Int64): Integer;
    // Andando para trás a partir de BlockIdx, o primeiro bloco com keyframe de
    // vídeo — o ponto de entrada para quem vai decodificar. -1 se não há.
    function FindKeyframeBlockAtOrBefore(BlockIdx: Integer): Integer;
    // Os bytes do header, para prefixar um fragmento servido pela API: o pedaço
    // entregue ao cliente é um .vms válido, que abre com este mesmo leitor.
    function ReadHeaderBytes(out Data: TBytes): Boolean;
    // Onde um bloco começa e quanto ocupa — para copiar bytes crus sem
    // desmontar e remontar o bloco.
    function BlockRange(BlockIdx: Integer; out Offset: Int64; out Size: Cardinal): Boolean;
    function ReadRaw(Offset, Size: Int64; out Data: TBytes): Boolean;
    function SeekToStart: Boolean;
    // Posiciona no último bloco que contém um keyframe de vídeo. É o que o
    // modo ao vivo precisa: entrar no ponto de entrada mais recente, e não no
    // começo do arquivo (que pode ter horas) nem no meio de um GOP, onde o
    // decodificador fica sem por onde começar. Não depende do índice, então
    // funciona com o arquivo ainda sendo gravado.
    function SeekToLastKeyframe: Boolean;
    // O instante de parede do último keyframe do arquivo — a idade da imagem
    // que o SeekToLastKeyframe vai entregar. 0 = não há keyframe nenhum.
    function LastKeyframeMs: Int64;
    function CurrentBlockOffset: Int64;
    property Header: TVmsHeader read FHeader;
    property Index: TVmsIndex read FIndex;
    property IndexCount: Integer read FIndexCount;
    // Primeiro offset ainda não varrido; guardado junto com o índice por quem
    // faz cache, para devolver no SeedIndex da leitura seguinte.
    property ScannedUpTo: Int64 read FScannedUpTo;
    // True = o índice veio pronto do rodapé; False = foi varrido (ou nem existe)
    property IndexFromFooter: Boolean read FIndexFromFooter;
    // A leitura sequencial parou porque encontrou o rodapé (ou o índice que vem
    // antes dele): este arquivo ACABOU, não é o fim provisório de um que ainda
    // cresce. Quem tocava ao vivo pode trocar de arquivo na hora, sem esperar
    // para ver se ele volta a crescer.
    property AtClosedEnd: Boolean read FSawClosedEnd;
    // Quem quiser saber de bloco corrompido põe um logger aqui; sem ele o
    // leitor pula em silêncio e só o contador registra.
    property Logger: ILogger read FLogger write FLogger;
    property BadBlocks: Integer read FBadBlocks;
  end;

function FindMostRecentVmsForCamera(const RecordingsDir, CameraName: string): string;

implementation

{ TVmsReader }

constructor TVmsReader.Create(const FilePath: string);
begin
  inherited Create;
  // fmShareDenyNone: o gravador continua escrevendo neste arquivo enquanto o
  // servidor o lê.
  FStream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  FOwnsStream := True;
  FFilePath := FilePath;
  FHeaderRead := False;
end;

constructor TVmsReader.Create(AStream: TStream; AOwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := AOwnsStream;
  FFilePath := '';
  FHeaderRead := False;
end;

destructor TVmsReader.Destroy;
begin
  if FOwnsStream and (FStream <> nil) then
    FStream.Free;
  inherited;
end;

function TVmsReader.ReadU16(var Buf: TBytes; var Offset: Integer): Word;
begin
  Result := Word(Buf[Offset]) or (Word(Buf[Offset + 1]) shl 8);
  Inc(Offset, 2);
end;

function TVmsReader.ReadU32(var Buf: TBytes; var Offset: Integer): Cardinal;
begin
  Result := Cardinal(Buf[Offset]) or
           (Cardinal(Buf[Offset + 1]) shl 8) or
           (Cardinal(Buf[Offset + 2]) shl 16) or
           (Cardinal(Buf[Offset + 3]) shl 24);
  Inc(Offset, 4);
end;

function TVmsReader.ReadI64(var Buf: TBytes; var Offset: Integer): Int64;
var
  U: UInt64;
  K: Integer;
begin
  U := 0;
  for K := 0 to 7 do
    U := U or (UInt64(Buf[Offset + K]) shl (K * 8));
  Result := Int64(U);
  Inc(Offset, 8);
end;

function TVmsReader.ReadHeader: Boolean;
var
  Magic: array[0..3] of Byte;
  Version: Word;
  HeaderSize: Cardinal;
  Buf: TBytes;
  Offset: Integer;
  UriLen: Word;
  ExtraLen: Cardinal;
  PreambleLen: Integer;
begin
  Result := False;
  FStream.Position := 0;
  if FStream.Read(Magic[0], 4) <> 4 then Exit;
  if (Magic[0] <> VMS_MAGIC_FILE[0]) or (Magic[1] <> VMS_MAGIC_FILE[1])
     or (Magic[2] <> VMS_MAGIC_FILE[2]) or (Magic[3] <> VMS_MAGIC_FILE[3]) then Exit;

  SetLength(Buf, 6);
  if FStream.Read(Buf[0], 6) <> 6 then Exit;
  Offset := 0;
  Version := ReadU16(Buf, Offset);
  HeaderSize := ReadU32(Buf, Offset);
  FHeader.Version := Version;
  FHeader.HeaderSize := HeaderSize;
  // Sem compatibilidade com layout antigo: versão diferente é arquivo de outro
  // formato, e lê-lo como se fosse deste dá bloco torto em vez de erro. Melhor
  // recusar aqui — a gravação velha se apaga.
  if Version <> VMS_FORMAT_VERSION then
  begin
    if FLogger <> nil then
      FLogger.Warn('vms.reader', Format('arquivo em formato v%d; este build lê v%d',
        [Version, VMS_FORMAT_VERSION]));
    Exit;
  end;

  PreambleLen := 4 + 6;
  if HeaderSize < Cardinal(PreambleLen) then Exit;
  SetLength(Buf, Integer(HeaderSize - Cardinal(PreambleLen)));
  if FStream.Read(Buf[0], Length(Buf)) <> Length(Buf) then Exit;
  Offset := 0;
  FHeader.CreationUnixMs := ReadI64(Buf, Offset);
  UriLen := ReadU16(Buf, Offset);
  if UriLen > 0 then
  begin
    FHeader.SourceUri := TEncoding.UTF8.GetString(Buf, Offset, UriLen);
    Inc(Offset, UriLen);
  end
  else
    FHeader.SourceUri := '';
  FHeader.VideoPresent := Buf[Offset] <> 0; Inc(Offset);
  FHeader.Video.Codec := TVideoCodec(Buf[Offset]); Inc(Offset);
  FHeader.Video.Timescale := ReadU32(Buf, Offset);
  FHeader.Video.Width := ReadU16(Buf, Offset);
  FHeader.Video.Height := ReadU16(Buf, Offset);
  ExtraLen := ReadU32(Buf, Offset);
  if ExtraLen > 0 then
  begin
    SetLength(FHeader.Video.Extradata, ExtraLen);
    Move(Buf[Offset], FHeader.Video.Extradata[0], ExtraLen);
    Inc(Offset, Integer(ExtraLen));
  end
  else
    SetLength(FHeader.Video.Extradata, 0);

  FHeader.AudioPresent := Buf[Offset] <> 0; Inc(Offset);
  FHeader.Audio.Codec := TAudioCodec(Buf[Offset]); Inc(Offset);
  FHeader.Audio.SampleRate := ReadU32(Buf, Offset);
  FHeader.Audio.Channels := Buf[Offset]; Inc(Offset);
  FHeader.Audio.BitsPerSample := Buf[Offset]; Inc(Offset);
  FHeader.Audio.Timescale := ReadU32(Buf, Offset);
  ExtraLen := ReadU32(Buf, Offset);
  if ExtraLen > 0 then
  begin
    SetLength(FHeader.Audio.Extradata, ExtraLen);
    Move(Buf[Offset], FHeader.Audio.Extradata[0], ExtraLen);
    Inc(Offset, Integer(ExtraLen));
  end
  else
    SetLength(FHeader.Audio.Extradata, 0);

  FHeaderRead := True;
  FSawClosedEnd := False;
  FFirstBlockOffset := FStream.Position;
  // header novo, índice velho não vale mais
  FIndexBuilt := False;
  FIndexFromFooter := False;
  FIndexCount := 0;
  SetLength(FIndex, 0);
  FScannedUpTo := 0;
  Result := True;
end;

function TVmsReader.WaitForBytes(Need: Int64): Boolean;
var
  Deadline: UInt64;
  CurSize, CurPos: Int64;
begin
  Result := False;
  CurPos := FStream.Position;
  if FStream.Size - CurPos >= Need then Exit(True);
  if not FLiveMode then Exit(False);
  Deadline := UInt64(TThread.GetTickCount64) + FLiveTimeoutMs;
  while UInt64(TThread.GetTickCount64) < Deadline do
  begin
    TThread.Sleep(100);
    CurSize := FStream.Size;
    if CurSize - CurPos >= Need then
      Exit(True);
  end;
end;

function TVmsReader.ReadNextBlock(out Block: TVmsBlock): Boolean;
var
  Magic: array[0..3] of Byte;
  BlockSize: Cardinal;
  Buf, RestBuf: TBytes;
  Offset, RemSize: Integer;
  SampleCount, IndexSize: Cardinal;
  Pos, Read: Int64;
  I: Integer;
  PayloadLen: Integer;
  Crc, StoredCrc: Cardinal;
  AnchorAt: Integer;
begin
  Result := False;
  if not FHeaderRead then Exit;
  Pos := FStream.Position;

  if FLiveMode then
  begin
    if not WaitForBytes(8) then Exit;
  end;

  Read := FStream.Read(Magic[0], 4);
  if Read < 4 then Exit;
  if (Magic[0] = VMS_MAGIC_FOOTER[0]) and (Magic[1] = VMS_MAGIC_FOOTER[1]) and
     (Magic[2] = VMS_MAGIC_FOOTER[2]) and (Magic[3] = VMS_MAGIC_FOOTER[3]) then
  begin
    FSawClosedEnd := True;
    FStream.Position := FStream.Size;
    Exit(False);
  end;
  // O índice fica entre o último bloco e o rodapé: quem estava lendo mídia em
  // sequência chegou ao fim dela aqui.
  if (Magic[0] = VMS_MAGIC_INDEX[0]) and (Magic[1] = VMS_MAGIC_INDEX[1]) and
     (Magic[2] = VMS_MAGIC_INDEX[2]) and (Magic[3] = VMS_MAGIC_INDEX[3]) then
  begin
    FSawClosedEnd := True;
    FStream.Position := FStream.Size;
    Exit(False);
  end;
  if (Magic[0] <> VMS_MAGIC_BLOCK[0]) or (Magic[1] <> VMS_MAGIC_BLOCK[1])
     or (Magic[2] <> VMS_MAGIC_BLOCK[2]) or (Magic[3] <> VMS_MAGIC_BLOCK[3]) then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;
  SetLength(Buf, 4);
  if FStream.Read(Buf[0], 4) <> 4 then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;
  Offset := 0;
  BlockSize := ReadU32(Buf, Offset);
  if BlockSize < 28 then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;
  RemSize := Integer(BlockSize) - 8;
  if FLiveMode then
    if not WaitForBytes(RemSize) then
    begin
      FStream.Position := Pos;
      Exit(False);
    end;
  SetLength(RestBuf, RemSize);
  if FStream.Read(RestBuf[0], RemSize) <> RemSize then
  begin
    FStream.Position := Pos;
    Exit(False);
  end;

  // CRC do bloco: cobre do magic ao fim do payload e está nos últimos 4 bytes.
  // Era gravado e nunca conferido — bloco corrompido (queda de energia, disco
  // cheio) chegava ao decodificador como se fosse mídia boa. Bloco ruim é
  // PULADO, não derruba o arquivo: um bloco quebrado no meio do dia não pode
  // impedir de assistir ao resto.
  Offset := RemSize - 4;
  StoredCrc := ReadU32(RestBuf, Offset);
  Crc := Crc32Update(0, @Magic[0], 4);
  Crc := Crc32Update(Crc, Buf, 0, 4);
  Crc := Crc32Update(Crc, RestBuf, 0, RemSize - 4);
  if Crc <> StoredCrc then
  begin
    Inc(FBadBlocks);
    // Ao vivo, a primeira falha num offset é tratada como "ainda não pronto":
    // volta e tenta de novo no mesmo lugar. No Windows o tamanho do arquivo só
    // cresce depois de a escrita inteira cair no cache, então meio bloco visível
    // não deveria acontecer — mas num compartilhamento de rede pode, e pular
    // mídia boa é pior que esperar um ciclo.
    if FLiveMode and (FLastBadPos <> Pos) then
    begin
      FLastBadPos := Pos;
      FStream.Position := Pos;
      Exit(False);
    end;
    if FLogger <> nil then
      FLogger.Warn('vms.reader',
        Format('bloco em %d com crc invalido (%d bytes); pulando', [Pos, BlockSize]));
    FStream.Position := Pos + Int64(BlockSize);
    Exit(False);
  end;
  FLastBadPos := 0;

  Offset := 0;
  Block.BlockSeq := ReadU32(RestBuf, Offset);
  Block.StartUnixMs := ReadI64(RestBuf, Offset);
  SampleCount := ReadU32(RestBuf, Offset);
  IndexSize := ReadU32(RestBuf, Offset);

  SetLength(Block.Samples, SampleCount);
  for I := 0 to Integer(SampleCount) - 1 do
  begin
    Block.Samples[I].TrackId := RestBuf[Offset]; Inc(Offset);
    Block.Samples[I].FlagsByte := RestBuf[Offset]; Inc(Offset);
    Block.Samples[I].Pts := ReadI64(RestBuf, Offset);
    Block.Samples[I].PayloadOffset := ReadU32(RestBuf, Offset);
    Block.Samples[I].PayloadSize := ReadU32(RestBuf, Offset);
  end;

  // Âncora A/V: fica depois das entradas de sample, ainda dentro da área de
  // índice. Bloco sem âncora deixa os dois campos em zero — quem toca cai na
  // suposição de que as trilhas começam juntas no bloco.
  Block.VideoAnchorMs := 0;
  Block.AudioAnchorMs := 0;
  AnchorAt := 20 + Integer(SampleCount) * VMS_SAMPLE_ENTRY_SIZE;
  if Integer(IndexSize) >= Integer(SampleCount) * VMS_SAMPLE_ENTRY_SIZE + VMS_ANCHOR_SIZE then
    if (RestBuf[AnchorAt] = VMS_MAGIC_ANCHOR[0]) and
       (RestBuf[AnchorAt + 1] = VMS_MAGIC_ANCHOR[1]) and
       (RestBuf[AnchorAt + 2] = VMS_MAGIC_ANCHOR[2]) and
       (RestBuf[AnchorAt + 3] = VMS_MAGIC_ANCHOR[3]) then
    begin
      Offset := AnchorAt + 4;
      Block.VideoAnchorMs := ReadI64(RestBuf, Offset);
      Block.AudioAnchorMs := ReadI64(RestBuf, Offset);
    end;

  // -20 do cabeçalho do bloco (seq+startMs+count+indexSize), -IndexSize do
  // índice de samples e -4 do CRC. O CRC vinha contado como payload: inofensivo,
  // porque todo sample é endereçado por offset/tamanho, mas deixava 4 bytes de
  // lixo no fim de Block.Payload.
  PayloadLen := RemSize - 20 - Integer(IndexSize) - 4;
  if PayloadLen < 0 then Exit;
  SetLength(Block.Payload, PayloadLen);
  if PayloadLen > 0 then
    Move(RestBuf[Offset], Block.Payload[0], PayloadLen);
  Result := True;
end;

function TVmsReader.AtEof: Boolean;
begin
  Result := FStream.Position >= FStream.Size;
end;

procedure TVmsReader.EnableLiveMode(TimeoutMs: Cardinal);
begin
  FLiveMode := True;
  FLiveTimeoutMs := TimeoutMs;
end;

procedure TVmsReader.DisableLiveMode;
begin
  FLiveMode := False;
end;

function TVmsReader.IsLiveMode: Boolean;
begin
  Result := FLiveMode;
end;

function TVmsReader.LastKeyframeMs: Int64;
var
  I: Integer;
begin
  Result := 0;
  EnsureIndex;
  for I := FIndexCount - 1 downto 0 do
    if FIndex[I].HasKeyframe then
      Exit(FIndex[I].StartUnixMs);
end;

function TVmsReader.CurrentBlockOffset: Int64;
begin
  Result := FStream.Position;
end;

function TVmsReader.ReadBlockMeta(Offset: Int64; out BlockSize: Cardinal;
  out StartUnixMs: Int64; out HasKeyframe: Boolean): Boolean;
var
  Hdr, Idx: TBytes;
  SampleCount, IndexSize: Cardinal;
  I, Base: Integer;

  function LE32(const B: TBytes; O: Integer): Cardinal;
  begin
    Result := Cardinal(B[O]) or (Cardinal(B[O + 1]) shl 8) or
              (Cardinal(B[O + 2]) shl 16) or (Cardinal(B[O + 3]) shl 24);
  end;

  function LE64(const B: TBytes; O: Integer): Int64;
  var
    K: Integer;
    U: UInt64;
  begin
    U := 0;
    for K := 0 to 7 do U := U or (UInt64(B[O + K]) shl (K * 8));
    Result := Int64(U);
  end;

begin
  Result := False;
  BlockSize := 0;
  StartUnixMs := 0;
  HasKeyframe := False;
  if Offset + VMS_BLOCK_HEADER_SIZE > FStream.Size then Exit;

  FStream.Position := Offset;
  SetLength(Hdr, VMS_BLOCK_HEADER_SIZE);
  if FStream.Read(Hdr[0], VMS_BLOCK_HEADER_SIZE) <> VMS_BLOCK_HEADER_SIZE then Exit;
  if (Hdr[0] <> VMS_MAGIC_BLOCK[0]) or (Hdr[1] <> VMS_MAGIC_BLOCK[1]) or
     (Hdr[2] <> VMS_MAGIC_BLOCK[2]) or (Hdr[3] <> VMS_MAGIC_BLOCK[3]) then Exit;

  BlockSize := LE32(Hdr, 4);
  StartUnixMs := LE64(Hdr, 12);
  SampleCount := LE32(Hdr, 20);
  IndexSize := LE32(Hdr, 24);
  // Bloco cortado é bloco que ainda está sendo escrito: não entra no índice,
  // senão o índice aponta para meia mídia.
  if (BlockSize < VMS_BLOCK_HEADER_SIZE) or (Offset + Int64(BlockSize) > FStream.Size) then
  begin
    BlockSize := 0;
    Exit;
  end;

  // O índice de samples cabe dentro do bloco, por construção. Não conferir isso
  // deixaria um tamanho corrompido pedir uma alocação absurda.
  if IndexSize > BlockSize then
  begin
    BlockSize := 0;
    Exit;
  end;

  if (IndexSize > 0) and (SampleCount > 0) then
  begin
    SetLength(Idx, IndexSize);
    if FStream.Read(Idx[0], IndexSize) <> Integer(IndexSize) then Exit;
    for I := 0 to Integer(SampleCount) - 1 do
    begin
      Base := I * VMS_SAMPLE_ENTRY_SIZE;
      if Base + 1 >= Integer(IndexSize) then Break;
      // TrackId 0 = vídeo; bit 0 do flags = keyframe
      if (Idx[Base] = 0) and ((Idx[Base + 1] and $01) <> 0) then
      begin
        HasKeyframe := True;
        Break;
      end;
    end;
  end;
  Result := True;
end;

procedure TVmsReader.AddIndexEntry(Offset, StartUnixMs: Int64; HasKeyframe: Boolean);
begin
  if FIndexCount >= Length(FIndex) then
    if Length(FIndex) = 0 then
      SetLength(FIndex, 256)
    else
      SetLength(FIndex, Length(FIndex) * 2);
  FIndex[FIndexCount].Offset := Offset;
  FIndex[FIndexCount].StartUnixMs := StartUnixMs;
  if HasKeyframe then
    FIndex[FIndexCount].Flags := VMS_IDX_FLAG_KEYFRAME
  else
    FIndex[FIndexCount].Flags := 0;
  Inc(FIndexCount);
end;

// Varre só cabeçalho + índice de cada bloco, pulando o payload — é o que torna a
// varredura viável mesmo num arquivo grande. Ainda assim é uma leitura por
// bloco: é por isso que o índice do rodapé existe.
function TVmsReader.ScanBlocksFrom(FromOffset: Int64): Integer;
var
  Offset, SavedPos: Int64;
  BlockSize: Cardinal;
  StartUnixMs: Int64;
  HasKeyframe: Boolean;
begin
  Result := 0;
  if FromOffset <= 0 then Exit;
  SavedPos := FStream.Position;
  try
    Offset := FromOffset;
    while ReadBlockMeta(Offset, BlockSize, StartUnixMs, HasKeyframe) do
    begin
      AddIndexEntry(Offset, StartUnixMs, HasKeyframe);
      Inc(Result);
      Inc(Offset, Int64(BlockSize));
    end;
    FScannedUpTo := Offset;
  finally
    FStream.Position := SavedPos;
  end;
end;

function TVmsReader.ReadFooter(out Footer: TVmsFooter): Boolean;
var
  Buf: TBytes;
  Offset: Integer;
  Size: Int64;
  Crc: Cardinal;
  O: Integer;
  SavedPos: Int64;
begin
  Result := False;
  FillChar(Footer, SizeOf(Footer), 0);
  if FStream = nil then Exit;
  SavedPos := FStream.Position;
  try
    Size := FStream.Size;
    if Size < VMS_FOOTER_SIZE then Exit;
    FStream.Position := Size - VMS_FOOTER_SIZE;
    SetLength(Buf, VMS_FOOTER_SIZE);
    if FStream.Read(Buf[0], VMS_FOOTER_SIZE) <> VMS_FOOTER_SIZE then Exit;
    if (Buf[0] <> VMS_MAGIC_FOOTER[0]) or (Buf[1] <> VMS_MAGIC_FOOTER[1]) or
       (Buf[2] <> VMS_MAGIC_FOOTER[2]) or (Buf[3] <> VMS_MAGIC_FOOTER[3]) then Exit;
    // Arquivo em gravação não tem rodapé: aqui cai o meio de um bloco, e é o CRC
    // que impede confundir esses bytes com um rodapé de verdade.
    O := VMS_FOOTER_SIZE - 4;
    Crc := Cardinal(Buf[O]) or (Cardinal(Buf[O + 1]) shl 8) or
           (Cardinal(Buf[O + 2]) shl 16) or (Cardinal(Buf[O + 3]) shl 24);
    if Crc32Update(0, Buf, 0, O) <> Crc then Exit;

    Offset := 4;
    Footer.TotalBlocks := ReadU32(Buf, Offset);
    Footer.TotalDurationMs := ReadI64(Buf, Offset);
    Footer.LastBlockOffset := UInt64(ReadI64(Buf, Offset));
    Footer.IndexOffset := UInt64(ReadI64(Buf, Offset));
    Footer.IndexCount := ReadU32(Buf, Offset);
    Result := True;
  finally
    FStream.Position := SavedPos;
  end;
end;

function TVmsReader.LoadIndexFromFooter: Boolean;
var
  Footer: TVmsFooter;
  Buf: TBytes;
  Offset, I: Integer;
  ChunkSize, Count, Crc: Cardinal;
  SavedPos: Int64;
begin
  Result := False;
  if not ReadFooter(Footer) then Exit;
  if (Footer.IndexOffset = 0) or (Footer.IndexCount = 0) then Exit;
  if Int64(Footer.IndexOffset) + VMS_INDEX_HEADER_SIZE > FStream.Size then Exit;

  SavedPos := FStream.Position;
  try
    FStream.Position := Int64(Footer.IndexOffset);
    SetLength(Buf, VMS_INDEX_HEADER_SIZE);
    if FStream.Read(Buf[0], VMS_INDEX_HEADER_SIZE) <> VMS_INDEX_HEADER_SIZE then Exit;
    if (Buf[0] <> VMS_MAGIC_INDEX[0]) or (Buf[1] <> VMS_MAGIC_INDEX[1]) or
       (Buf[2] <> VMS_MAGIC_INDEX[2]) or (Buf[3] <> VMS_MAGIC_INDEX[3]) then Exit;
    Offset := 4;
    ChunkSize := ReadU32(Buf, Offset);
    Count := ReadU32(Buf, Offset);
    if Count <> Footer.IndexCount then Exit;
    // Antes de multiplicar: contagem absurda em arquivo corrompido estouraria a
    // conta do tamanho e passaria pela conferência.
    if (Count = 0) or (Count > Cardinal(FStream.Size div VMS_INDEX_ENTRY_SIZE) + 1) then Exit;
    if ChunkSize <> Cardinal(VMS_INDEX_HEADER_SIZE + Integer(Count) * VMS_INDEX_ENTRY_SIZE + 4) then Exit;
    if Int64(Footer.IndexOffset) + Int64(ChunkSize) > FStream.Size then Exit;

    FStream.Position := Int64(Footer.IndexOffset);
    SetLength(Buf, ChunkSize);
    if FStream.Read(Buf[0], ChunkSize) <> Integer(ChunkSize) then Exit;
    Offset := Integer(ChunkSize) - 4;
    Crc := Cardinal(Buf[Offset]) or (Cardinal(Buf[Offset + 1]) shl 8) or
           (Cardinal(Buf[Offset + 2]) shl 16) or (Cardinal(Buf[Offset + 3]) shl 24);
    // Índice com CRC quebrado é índice que não se usa: cai na varredura, que é
    // lenta mas não mente.
    if Crc32Update(0, Buf, 0, Integer(ChunkSize) - 4) <> Crc then Exit;

    SetLength(FIndex, Count);
    FIndexCount := 0;
    Offset := VMS_INDEX_HEADER_SIZE;
    for I := 0 to Integer(Count) - 1 do
    begin
      FIndex[I].Offset := ReadI64(Buf, Offset);
      FIndex[I].StartUnixMs := ReadI64(Buf, Offset);
      FIndex[I].Flags := Buf[Offset]; Inc(Offset);
      Inc(FIndexCount);
    end;
    FScannedUpTo := Int64(Footer.IndexOffset);
    Result := True;
  finally
    FStream.Position := SavedPos;
  end;
end;

// Índice do arquivo que ainda está sendo gravado, lido da região.
//
// Dois slots de commit: vale o de geração mais alta cujo CRC bate. Se o de cima
// estiver quebrado (queda no meio da atualização), o de baixo ainda descreve um
// estado consistente, alguns blocos atrás — e a varredura de cauda cobre a
// diferença. Nenhum dos dois batendo, devolve False e cai na varredura inteira,
// que é lenta mas não mente.
function TVmsReader.FirstBlockStartMs(out StartUnixMs: Int64): Boolean;
var
  BlockSize: Cardinal;
  HasKey: Boolean;
  SavedPos: Int64;
begin
  StartUnixMs := 0;
  Result := False;
  if not FHeaderRead then Exit;
  SavedPos := FStream.Position;
  try
    Result := ReadBlockMeta(FFirstBlockOffset, BlockSize, StartUnixMs, HasKey)
              and (BlockSize > 0);
  finally
    FStream.Position := SavedPos;
  end;
end;

function TVmsReader.SidecarSummary(out Count: Integer;
  out FirstMs, LastMs: Int64): Boolean;
begin
  Count := 0;
  FirstMs := 0;
  LastMs := 0;
  Result := False;
  if (FFilePath = '') or (not FHeaderRead) then Exit;
  Result := VMS.Rec.Sidecar.SidecarSummary(FFilePath, FHeader.CreationUnixMs,
                                           Count, FirstMs, LastMs);
end;

// Índice do arquivo que ainda está sendo gravado, lido do `.vms.idx` ao lado.
// O que ficou depois do último lote sai da varredura da cauda, a partir de
// FScannedUpTo — que é o ponto de append que o gravador registrou no lote.
function TVmsReader.LoadIndexFromSidecar: Boolean;
var
  Index: TVmsIndex;
  ValidUpTo, Size: Int64;
  Cut: Integer;
begin
  Result := False;
  if FFilePath = '' then Exit;
  if not ReadSidecar(FFilePath, FHeader.CreationUnixMs, Index, ValidUpTo) then Exit;
  if (Length(Index) = 0) or (ValidUpTo <= FFirstBlockOffset) then Exit;

  Size := FStream.Size;
  if ValidUpTo <= Size then
  begin
    FIndex := Index;
    FIndexCount := Length(Index);
    FScannedUpTo := ValidUpTo;
    Exit(True);
  end;

  // O sidecar está À FRENTE do .vms. São dois arquivos, e o sistema não despeja
  // os dois no mesmo instante: uma queda de energia pode levar a cauda da mídia
  // e não a do índice. Aproveita o prefixo que ainda tem arquivo por baixo, em
  // vez de descartar o índice inteiro e varrer — este arquivo nunca mais vai
  // ganhar um rodapé, então varrer aqui seria varrer em toda subida do servidor.
  Cut := 0;
  while (Cut < Length(Index)) and (Index[Cut].Offset < Size) do Inc(Cut);
  // A última entrada que ainda cabia pode descrever um bloco cortado ao meio:
  // ela também sai, e a varredura recomeça nela — é a varredura que sabe
  // recusar bloco que passa do fim do arquivo.
  if Cut > 0 then Dec(Cut);
  if Cut <= 0 then Exit;
  FScannedUpTo := Index[Cut].Offset;   // antes do SetLength: a entrada some ali
  SetLength(Index, Cut);
  FIndex := Index;
  FIndexCount := Cut;
  if FLogger <> nil then
    FLogger.Warn('vms.reader',
      Format('%s: indice adiante da midia (queda de energia?); aproveitando %d blocos',
        [ExtractFileName(FFilePath), Cut]));
  Result := True;
end;

function TVmsReader.EnsureIndex: Integer;
var
  SavedPos: Int64;
begin
  if FIndexBuilt then Exit(FIndexCount);
  // Montar índice não pode mexer em onde a leitura sequencial estava: quem lê
  // ao vivo chama isto no meio do arquivo (SeekToLastKeyframe, BlockRange).
  SavedPos := FStream.Position;
  try
    FIndexCount := 0;
    SetLength(FIndex, 0);
    FIndexFromFooter := LoadIndexFromFooter;
    if not FIndexFromFooter then
    begin
      // Arquivo em gravação: o sidecar dá o índice até o último lote e a
      // varredura pega só o que veio depois — em vez de percorrer o arquivo
      // inteiro bloco a bloco, que é o que doía ao abrir a gravação de hoje.
      if LoadIndexFromSidecar then
        ScanBlocksFrom(FScannedUpTo)
      else
      begin
        FIndexCount := 0;
        SetLength(FIndex, 0);
        ScanBlocksFrom(FFirstBlockOffset);
      end;
    end;
    // O vetor cresce dobrando: sobra capacidade no fim. Quem consome o Index
    // usa Length() para saber quantos são, então ele tem que refletir o que
    // existe.
    SetLength(FIndex, FIndexCount);
    FIndexBuilt := True;
    Result := FIndexCount;
  finally
    FStream.Position := SavedPos;
  end;
end;

function TVmsReader.BuildIndex: Integer;
begin
  FIndexBuilt := False;
  Result := EnsureIndex;
end;

function TVmsReader.ExtendIndex: Integer;
begin
  Result := 0;
  if not FIndexBuilt then
  begin
    EnsureIndex;
    Exit(FIndexCount);
  end;
  // Arquivo fechado já tem tudo; só o que ainda cresce ganha blocos novos.
  if FIndexFromFooter then Exit;
  if FScannedUpTo <= 0 then Exit;
  Result := ScanBlocksFrom(FScannedUpTo);
  if Result > 0 then
    SetLength(FIndex, FIndexCount);
end;

procedure TVmsReader.SeedIndex(const AIndex: TVmsIndex; AScannedUpTo: Int64);
begin
  if (Length(AIndex) = 0) or (AScannedUpTo <= 0) then Exit;
  FIndex := Copy(AIndex);
  FIndexCount := Length(FIndex);
  FScannedUpTo := AScannedUpTo;
  FIndexBuilt := True;
  // Índice semeado é sempre índice varrido: se viesse do rodapé, o arquivo
  // estaria fechado e não haveria o que continuar.
  FIndexFromFooter := False;
end;

function TVmsReader.FindBlockAtTime(WallClockMs: Int64): Integer;
begin
  EnsureIndex;
  Result := IndexBlockAtTime(FIndex, WallClockMs);
end;

function TVmsReader.FindKeyframeBlockAtOrBefore(BlockIdx: Integer): Integer;
begin
  Result := IndexKeyframeAtOrBefore(FIndex, BlockIdx);
end;

function TVmsReader.ReadHeaderBytes(out Data: TBytes): Boolean;
begin
  // O header do fragmento servido pela API é uma CÓPIA CRUA do header do
  // arquivo: byte a byte o mesmo, com o mesmo CRC, sem reserializar nada.
  Result := False;
  Data := nil;
  if not FHeaderRead then Exit;
  if (FHeader.HeaderSize = 0) or (Int64(FHeader.HeaderSize) > FStream.Size) then Exit;
  SetLength(Data, FHeader.HeaderSize);
  FStream.Position := 0;
  Result := FStream.Read(Data[0], FHeader.HeaderSize) = Integer(FHeader.HeaderSize);
  if not Result then Data := nil;
end;

function TVmsReader.BlockRange(BlockIdx: Integer; out Offset: Int64;
  out Size: Cardinal): Boolean;
var
  StartMs: Int64;
  HasKey: Boolean;
begin
  Offset := 0;
  Size := 0;
  EnsureIndex;
  Result := False;
  if (BlockIdx < 0) or (BlockIdx >= FIndexCount) then Exit;
  Offset := FIndex[BlockIdx].Offset;
  Result := ReadBlockMeta(Offset, Size, StartMs, HasKey);
end;

function TVmsReader.ReadRaw(Offset, Size: Int64; out Data: TBytes): Boolean;
begin
  Result := False;
  Data := nil;
  if (Offset < 0) or (Size <= 0) or (Offset + Size > FStream.Size) then Exit;
  SetLength(Data, Size);
  FStream.Position := Offset;
  Result := FStream.Read(Data[0], Size) = Size;
  if not Result then Data := nil;
end;

function TVmsReader.SeekToBlock(BlockIdx: Integer): Boolean;
begin
  Result := False;
  if (BlockIdx < 0) or (BlockIdx >= FIndexCount) then Exit;
  FStream.Position := FIndex[BlockIdx].Offset;
  Result := True;
end;

function TVmsReader.SeekToTime(WallClockMs: Int64): Boolean;
var
  Idx: Integer;
begin
  Idx := FindBlockAtTime(WallClockMs);
  if Idx < 0 then
  begin
    // Antes do primeiro bloco (ou sem índice): começa do começo, que é o que o
    // seek por Range do RTSP sempre fez.
    if FIndexCount = 0 then Exit(False);
    Idx := 0;
  end;
  Result := SeekToBlock(Idx);
end;

function TVmsReader.SeekToStart: Boolean;
begin
  Result := False;
  if FFirstBlockOffset <= 0 then Exit;
  FStream.Position := FFirstBlockOffset;
  Result := True;
end;

function TVmsReader.SeekToLastKeyframe: Boolean;
var
  I: Integer;
begin
  Result := False;
  EnsureIndex;
  for I := FIndexCount - 1 downto 0 do
    if FIndex[I].HasKeyframe then
      Exit(SeekToBlock(I));
end;

function FindMostRecentVmsForCamera(const RecordingsDir, CameraName: string): string;
var
  Files: TArray<string>;
  I: Integer;
  BestTime, T: TDateTime;
  Dir: string;
begin
  // Tudo que está na pasta da câmera é dela: não há mais o que filtrar por
  // prefixo — e nome de câmera com '_' deixava o filtro antigo ambíguo.
  Result := '';
  Dir := CameraDir(RecordingsDir, CameraName);
  if not DirectoryExists(Dir) then Exit;
  Files := TDirectory.GetFiles(Dir, '*.vms');
  BestTime := 0;
  for I := 0 to High(Files) do
  begin
    // O filtro do sistema casa por nome curto também: sem conferir a extensão,
    // um `.vms.idx` recém-escrito seria "a gravação mais recente".
    if not SameText(ExtractFileExt(Files[I]), '.vms') then Continue;
    T := TFile.GetLastWriteTime(Files[I]);
    if T > BestTime then
    begin
      BestTime := T;
      Result := Files[I];
    end;
  end;
end;

end.
