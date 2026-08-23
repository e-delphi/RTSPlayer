unit Vms.Server.Media;

// Monta o pedaço de mídia que a rota /api/media entrega: **header do .vms +
// N blocos crus**, sem rodapé. O que sai é um .vms válido — abre no TVmsReader
// do app sem caso especial, e salvo em disco abre no vmsdump e toca no ffplay.
// Isso é de propósito: o formato que já existe é o protocolo.
//
// A regra que manda aqui: **o cliente não sabe que existem arquivos**. Ele pede
// um instante da linha do tempo da câmera, e é este código que descobre em qual
// .vms aquilo cai, por qual keyframe começar, e o que vem depois. Nome de
// arquivo só aparece no parâmetro de diagnóstico.
//
// **Varredura (stepMs)**: em 8x, 16x, 64x o cliente não exibe nem consegue
// decodificar todos os quadros — e mandar o que ele vai jogar fora é desperdício
// de rede, que é justamente o que dói num acesso remoto. Com `stepMs`, o
// servidor entrega no máximo um quadro a cada `stepMs` de mídia, só keyframes e
// sem áudio. Aí os blocos são REESCRITOS em vez de copiados crus: filtrar por
// bloco não adiantaria nada, porque com GOP menor que o bloco quase todo bloco
// tem keyframe — o desperdício está DENTRO do bloco, nos quadros P.
//
// Uma resposta nunca atravessa arquivo: termina no fim do .vms corrente, e a
// seguinte começa no próximo com Discontinuity — porque header e base de PTS
// mudam ali, e o cliente precisa saber para reanunciar formato e re-ancorar o
// ritmo. Emendar dois arquivos num fragmento só exigiria dois headers no mesmo
// corpo, que é justamente o que o formato não tem.

interface

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.IOUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Reader,
  VMS.Rec.Writer,
  Vms.Server.IndexCache;

const
  // Teto de bytes por resposta, além do teto de blocos: um bloco pode ter 1 MB
  // (block.maxSizeBytes), e 32 deles seriam 32 MB em cima de um celular.
  MEDIA_MAX_FRAGMENT_BYTES = 4 * 1024 * 1024;
  MEDIA_DEFAULT_BLOCKS = 4;

type
  // Onde a próxima requisição continua. Opaco para o cliente: ele só devolve o
  // que recebeu. Por dentro carrega o instante (que sempre resolve) mais a dica
  // de arquivo e bloco (que evita a busca, quando ainda vale).
  TMediaCursor = record
    Valid: Boolean;
    NextMs: Int64;
    FileName: string;
    BlockIdx: Integer;
    // Este cursor entra em OUTRO arquivo. Precisa estar aqui porque o cursor
    // aponta para onde se vai, não para onde se estava: sem esta marca, o
    // servidor que o recebe não teria como saber que aquilo é uma emenda.
    NewFile: Boolean;
    function Encode: string;
    class function Decode(const S: string; out C: TMediaCursor): Boolean; static;
  end;

  TMediaRequest = record
    Camera: string;
    FileName: string;      // diagnóstico: fixa o arquivo, ignora a câmera
    HasFromMs: Boolean;
    FromMs: Int64;
    HasFromBlock: Boolean;
    FromBlock: Integer;
    Cursor: TMediaCursor;
    Blocks: Integer;
    // > 0: varredura. Um quadro a cada StepMs de mídia, só keyframe, sem áudio.
    StepMs: Int64;
  end;

  TMediaFragment = record
    Ok: Boolean;
    Status: Integer;       // quando não Ok
    Error: string;
    Data: TBytes;
    FileName: string;      // não vai para o cliente; serve ao log e ao cursor
    FirstBlock: Integer;
    BlockCount: Integer;
    StartMs: Int64;
    EndMs: Int64;
    NextMs: Int64;         // -1 = não há mais gravação depois disto
    GapMs: Int64;
    Discontinuity: Boolean;
    Keyframe: Boolean;
    Growing: Boolean;
    Thinned: Boolean;      // veio decimado: é varredura, não reprodução
    Cursor: string;
  end;

  TMediaBuilder = class
  strict private
    FCache: TVmsIndexCache;
    FMaxBlocks: Integer;
    FLogger: ILogger;
    function Fail(Status: Integer; const Msg: string): TMediaFragment;
    function NextFileAfter(const Camera, CurrentName: string; CurrentEndMs: Int64;
                           out Info: TVmsFileInfo): Boolean;
    function ResolveByTime(const Camera: string; FromMs: Int64;
                           out Info: TVmsFileInfo): Boolean;
    function OpenByName(const Camera, Name: string; out Info: TVmsFileInfo): Boolean;
  public
    constructor Create(ACache: TVmsIndexCache; AMaxBlocks: Integer; const ALogger: ILogger);
    function Fetch(const Req: TMediaRequest): TMediaFragment;
  end;

implementation

const
  // Mesma estimativa do inventário: ninguém guarda a duração do último bloco.
  ASSUMED_BLOCK_MS = 2000;
  CURSOR_SEP = '-';

{ TMediaCursor }

// '<nextMs>-<bloco>-<novoArquivo>-<arquivo>'. Só dígitos e o nome do arquivo,
// que já é restrito a [A-Za-z0-9._-]: passa numa query sem escapar nada.
function TMediaCursor.Encode: string;
begin
  if not Valid then Exit('');
  Result := Format('%d%s%d%s%d%s%s',
    [NextMs, CURSOR_SEP, BlockIdx, CURSOR_SEP, Ord(NewFile), CURSOR_SEP, FileName]);
end;

class function TMediaCursor.Decode(const S: string; out C: TMediaCursor): Boolean;
var
  P1, P2, P3, Flag: Integer;
begin
  FillChar(C, SizeOf(C), 0);
  C.FileName := '';
  Result := False;
  if S = '' then Exit;
  P1 := Pos(CURSOR_SEP, S);
  if P1 < 2 then Exit;
  P2 := PosEx(CURSOR_SEP, S, P1 + 1);
  if P2 <= P1 + 1 then Exit;
  P3 := PosEx(CURSOR_SEP, S, P2 + 1);
  if P3 <= P2 + 1 then Exit;
  if not TryStrToInt64(Copy(S, 1, P1 - 1), C.NextMs) then Exit;
  if not TryStrToInt(Copy(S, P1 + 1, P2 - P1 - 1), C.BlockIdx) then Exit;
  if not TryStrToInt(Copy(S, P2 + 1, P3 - P2 - 1), Flag) then Exit;
  C.NewFile := Flag <> 0;
  C.FileName := Copy(S, P3 + 1, MaxInt);
  if C.FileName = '' then Exit;
  C.Valid := True;
  Result := True;
end;

// Reescreve um bloco com só os quadros que o cliente vai exibir.
//
// O instante de parede de um sample é `âncora + (pts - primeiro pts do bloco)`,
// e o "primeiro pts do bloco" muda quando se joga fora o começo dele. Por isso a
// âncora do bloco novo passa a ser o instante do PRIMEIRO QUADRO ESCOLHIDO: aí a
// conta que o cliente faz continua dando o horário certo, sem ele saber que o
// bloco foi mexido.
//
// LastMs entra e sai: é o instante do último quadro entregue, e é o que faz o
// espaçamento valer ATRAVÉS dos blocos, não só dentro de cada um.
function ThinBlock(const Src: TVmsBlock; Timescale: Cardinal; StepMs: Int64;
  var LastMs: Int64; out Dst: TVmsBlock): Boolean;
var
  I, N, PayloadLen: Integer;
  SrcAnchor, FirstVideoPts, WallMs, FirstKeptMs: Int64;
  HaveFirstVideo: Boolean;
  Keep: TArray<Integer>;
  E: TVmsSampleEntry;
begin
  Result := False;
  Dst := Default(TVmsBlock);
  if Timescale = 0 then Timescale := 90000;
  // Mesma regra do cliente: sem âncora de vídeo, vale o começo do bloco.
  SrcAnchor := Src.VideoAnchorMs;
  if SrcAnchor = 0 then SrcAnchor := Src.StartUnixMs;

  FirstVideoPts := 0;
  HaveFirstVideo := False;
  FirstKeptMs := 0;
  N := 0;
  SetLength(Keep, Length(Src.Samples));
  for I := 0 to High(Src.Samples) do
  begin
    if Src.Samples[I].TrackId <> 0 then Continue;   // áudio não vai em varredura
    if not HaveFirstVideo then
    begin
      FirstVideoPts := Src.Samples[I].Pts;
      HaveFirstVideo := True;
    end;
    // Só keyframe: quadro P depende de referência que não vai junto.
    if (Src.Samples[I].FlagsByte and VMS_IDX_FLAG_KEYFRAME) = 0 then Continue;
    WallMs := SrcAnchor +
              ((Src.Samples[I].Pts - FirstVideoPts) * 1000) div Int64(Timescale);
    if (LastMs > 0) and (WallMs - LastMs < StepMs) then Continue;
    if N = 0 then FirstKeptMs := WallMs;
    Keep[N] := I;
    Inc(N);
    LastMs := WallMs;
  end;
  if N = 0 then Exit;

  SetLength(Dst.Samples, N);
  PayloadLen := 0;
  for I := 0 to N - 1 do
    Inc(PayloadLen, Integer(Src.Samples[Keep[I]].PayloadSize));
  SetLength(Dst.Payload, PayloadLen);

  PayloadLen := 0;
  for I := 0 to N - 1 do
  begin
    E := Src.Samples[Keep[I]];
    if E.PayloadSize > 0 then
      Move(Src.Payload[E.PayloadOffset], Dst.Payload[PayloadLen], E.PayloadSize);
    E.PayloadOffset := Cardinal(PayloadLen);
    Dst.Samples[I] := E;
    Inc(PayloadLen, Integer(E.PayloadSize));
  end;

  Dst.BlockSeq := Src.BlockSeq;
  Dst.StartUnixMs := FirstKeptMs;
  Dst.VideoAnchorMs := FirstKeptMs;
  Dst.AudioAnchorMs := 0;
  Result := True;
end;

{ TMediaBuilder }

constructor TMediaBuilder.Create(ACache: TVmsIndexCache; AMaxBlocks: Integer;
  const ALogger: ILogger);
begin
  inherited Create;
  FCache := ACache;
  FMaxBlocks := AMaxBlocks;
  if FMaxBlocks <= 0 then FMaxBlocks := 32;
  FLogger := ALogger;
end;

function TMediaBuilder.Fail(Status: Integer; const Msg: string): TMediaFragment;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.FileName := '';
  Result.Error := Msg;
  Result.Cursor := '';
  Result.Ok := False;
  Result.Status := Status;
  Result.NextMs := -1;
end;

// O arquivo que contém aquele instante; não havendo, o primeiro que começa
// depois dele — é assim que um seek que cai num buraco de gravação aterrissa na
// gravação seguinte em vez de dar erro.
function TMediaBuilder.ResolveByTime(const Camera: string; FromMs: Int64;
  out Info: TVmsFileInfo): Boolean;
var
  Files: TVmsFileInfoArray;
  I: Integer;
begin
  Result := False;
  Files := FCache.ListFiles(Camera);
  if Length(Files) = 0 then Exit;
  for I := 0 to High(Files) do
    if (FromMs >= Files[I].StartMs) and (FromMs < Files[I].EndMs) then
    begin
      Info := Files[I];
      Exit(True);
    end;
  for I := 0 to High(Files) do
    if Files[I].StartMs >= FromMs then
    begin
      Info := Files[I];
      Exit(True);
    end;
  // Instante depois de tudo que existe: devolve o último, e quem chamou decide
  // (vai cair no fim dele, com NextMs = -1).
  Info := Files[High(Files)];
  Result := True;
end;

// Nome só vira caminho depois de passar pelo filtro: tanto o parâmetro de
// diagnóstico quanto o nome que vem dentro do cursor são texto do cliente.
function TMediaBuilder.OpenByName(const Camera, Name: string; out Info: TVmsFileInfo): Boolean;
begin
  Result := False;
  if not IsSafeVmsName(Name) then Exit;
  // Cada câmera tem sua pasta; sem a câmera, o cache deduz pelo prefixo do nome.
  Result := FCache.GetInfo(FCache.PathOf(Camera, Name), Info);
end;

// O arquivo seguinte é o PRÓXIMO DA LISTA, não "o primeiro que começa depois do
// fim deste": o fim é estimado (ninguém guarda a duração do último bloco), e uma
// estimativa alguns ms adiante do começo do seguinte faria pular um arquivo
// inteiro da gravação.
function TMediaBuilder.NextFileAfter(const Camera, CurrentName: string;
  CurrentEndMs: Int64; out Info: TVmsFileInfo): Boolean;
var
  Files: TVmsFileInfoArray;
  I: Integer;
begin
  Result := False;
  if Camera = '' then Exit; // modo diagnóstico: não atravessa arquivo
  Files := FCache.ListFiles(Camera);
  for I := 0 to High(Files) do
    if SameText(Files[I].Name, CurrentName) then
    begin
      if I < High(Files) then
      begin
        Info := Files[I + 1];
        Exit(True);
      end;
      Exit(False); // era o último
    end;
  // Sumiu da lista entre uma coisa e outra (retenção): cai no tempo.
  for I := 0 to High(Files) do
    if Files[I].StartMs >= CurrentEndMs then
    begin
      Info := Files[I];
      Exit(True);
    end;
end;

function TMediaBuilder.Fetch(const Req: TMediaRequest): TMediaFragment;
var
  Info, NextInfo: TVmsFileInfo;
  Index: TVmsIndex;
  Reader: TVmsReader;
  HeaderBytes, BodyBytes: TBytes;
  First, Last, Count, KeyIdx, I: Integer;
  Offset, LastOffset, LastSize, SpanBytes, LastKeptMs: Int64;
  BodyLen: Integer;
  Block, Thin: TVmsBlock;
  Piece: TBytes;
  BlockSize: Cardinal;
  Wanted: Integer;
  CameraOfFile: string;
  UsedCursorHint, Thinned: Boolean;
  Cursor: TMediaCursor;
  FromMs: Int64;
begin
  Info := Default(TVmsFileInfo);
  Result := Default(TMediaFragment);
  UsedCursorHint := False;

  // 1. Que arquivo. Três entradas: continuação (cursor), diagnóstico (file) e
  //    busca por instante (camera + fromMs).
  if Req.FileName <> '' then
  begin
    if not OpenByName(Req.Camera, Req.FileName, Info) then
      Exit(Fail(404, 'arquivo nao encontrado'));
  end
  else if Req.Cursor.Valid then
  begin
    // A dica do cursor vale enquanto o arquivo existir. Se a retenção o apagou
    // entre uma requisição e a seguinte, o instante resolve sozinho — e o
    // cliente não percebe nada além de um buraco.
    if OpenByName(Req.Camera, Req.Cursor.FileName, Info) then
      UsedCursorHint := True
    else if not ResolveByTime(Req.Camera, Req.Cursor.NextMs, Info) then
      Exit(Fail(404, 'nao ha gravacao a partir daqui'));
  end
  else if Req.HasFromMs then
  begin
    if not ResolveByTime(Req.Camera, Req.FromMs, Info) then
      Exit(Fail(404, 'nao ha gravacao para esta camera'));
  end
  else
    Exit(Fail(400, 'informe fromMs ou cursor'));

  if not FCache.GetIndex(Info.Path, Index) then
    Exit(Fail(404, 'arquivo sem indice legivel'));
  if Length(Index) = 0 then
    Exit(Fail(404, 'arquivo sem blocos'));

  CameraOfFile := Req.Camera;
  if (CameraOfFile = '') and (Req.FileName = '') then
    CameraOfFile := Info.Camera;

  // 2. Que bloco.
  if UsedCursorHint then
  begin
    First := Req.Cursor.BlockIdx;
    // Dica velha (arquivo cresceu de outro jeito, ou índice mudou): resolve pelo
    // instante, que é o dado que nunca mente.
    if (First < 0) or (First > High(Index)) or
       (Index[First].StartUnixMs <> Req.Cursor.NextMs) then
    begin
      First := IndexBlockAtTime(Index, Req.Cursor.NextMs);
      if First < 0 then First := 0;
    end;
  end
  else if Req.HasFromBlock then
  begin
    First := Req.FromBlock;
    if (First < 0) or (First > High(Index)) then
      Exit(Fail(416, 'bloco fora do arquivo'));
  end
  else
  begin
    if Req.HasFromMs then
      FromMs := Req.FromMs
    else
      FromMs := Req.Cursor.NextMs;
    First := IndexBlockAtTime(Index, FromMs);
    if First < 0 then First := 0;
    // Recua até o keyframe: começar no meio de um GOP é tela preta até o
    // próximo. O preço é entregar até um GOP de mídia anterior ao instante
    // pedido, que o cliente despeja sem ritmo.
    KeyIdx := IndexKeyframeAtOrBefore(Index, First);
    if KeyIdx >= 0 then
      First := KeyIdx;
  end;

  // 3. Quantos blocos, limitado por pedido, por config e por bytes.
  Wanted := Req.Blocks;
  if Wanted <= 0 then Wanted := MEDIA_DEFAULT_BLOCKS;
  if Wanted > FMaxBlocks then Wanted := FMaxBlocks;

  try
    Reader := TVmsReader.Create(Info.Path);
  except
    Exit(Fail(404, 'arquivo sumiu'));
  end;
  try
    if not Reader.ReadHeader then
      Exit(Fail(500, 'header ilegivel'));
    if not Reader.ReadHeaderBytes(HeaderBytes) then
      Exit(Fail(500, 'nao consegui ler o header'));

    Last := First;
    SpanBytes := 0;
    LastOffset := 0;
    LastSize := 0;
    Count := 0;
    for I := First to High(Index) do
    begin
      if not Reader.BlockRange(I, Offset, BlockSize) then Break;
      // Pelo menos um bloco sempre sai, mesmo se sozinho já estourar o teto:
      // resposta vazia deixaria o cliente sem por onde continuar. Em varredura o
      // teto é folgado de propósito: o que sai são keyframes esparsos, e cortar
      // pelo tamanho do bloco ORIGINAL faria a varredura andar devagar à toa.
      if (Count > 0) and (Req.StepMs <= 0) and
         (SpanBytes + Int64(BlockSize) > MEDIA_MAX_FRAGMENT_BYTES) then Break;
      Inc(SpanBytes, Int64(BlockSize));
      // LastSize acompanha o último bloco INCLUÍDO. Reaproveitar o BlockSize do
      // laço daria o tamanho do bloco que ficou de fora quando o teto corta.
      LastOffset := Offset;
      LastSize := Int64(BlockSize);
      Last := I;
      Inc(Count);
      if Count >= Wanted then Break;
    end;
    if Count = 0 then
      Exit(Fail(416, 'nada para ler a partir deste bloco'));

    if Req.StepMs > 0 then
    begin
      // Varredura: em vez de copiar os bytes crus, lê cada bloco e reescreve só
      // com os quadros que serão exibidos.
      LastKeptMs := 0;
      BodyLen := 0;
      SetLength(BodyBytes, 0);
      for I := First to Last do
      begin
        // Bloco sem keyframe não tem nada a entregar em varredura, e o índice já
        // sabe disso: nem vale a leitura do disco. Só ajuda quando o GOP é maior
        // que o bloco — com GOP curto, todo bloco tem keyframe.
        if not Index[I].HasKeyframe then Continue;
        if not Reader.SeekToBlock(I) then Break;
        if not Reader.ReadNextBlock(Block) then Continue;  // bloco ruim: pula
        if not ThinBlock(Block, Reader.Header.Video.Timescale, Req.StepMs,
                         LastKeptMs, Thin) then Continue;
        Piece := BuildBlockBytes(Thin);
        if Length(Piece) = 0 then Continue;
        SetLength(BodyBytes, BodyLen + Length(Piece));
        Move(Piece[0], BodyBytes[BodyLen], Length(Piece));
        Inc(BodyLen, Length(Piece));
      end;
      // Nenhum quadro no intervalo: não é erro, é um trecho sem keyframe novo.
      // O cliente segue pelo cursor e pede o próximo.
      Result.Thinned := True;
    end
    else if not Reader.ReadRaw(Index[First].Offset,
                          (LastOffset + LastSize) - Index[First].Offset,
                          BodyBytes) then
      Exit(Fail(500, 'falha ao ler os blocos'));
  finally
    Reader.Free;
  end;

  Thinned := Result.Thinned;   // o FillChar abaixo zera tudo
  FillChar(Result, SizeOf(Result), 0);
  Result.FileName := '';
  Result.Error := '';
  Result.Cursor := '';
  Result.Thinned := Thinned;
  Result.Ok := True;
  Result.Status := 200;
  Result.FileName := Info.Name;
  Result.FirstBlock := First;
  Result.BlockCount := Count;
  Result.StartMs := Index[First].StartUnixMs;
  if Last < High(Index) then
    Result.EndMs := Index[Last + 1].StartUnixMs
  else
    Result.EndMs := Index[Last].StartUnixMs + ASSUMED_BLOCK_MS;
  Result.Keyframe := Index[First].HasKeyframe;
  Result.Growing := not Info.Closed;
  // Descontinuidade = este pedaço não continua o anterior dentro do mesmo
  // arquivo. Três casos: início de reprodução (sem cursor), cursor marcado como
  // travessia, e cursor que caducou e foi resolvido noutro arquivo (retenção
  // apagou o que ele apontava).
  Result.Discontinuity := (not Req.Cursor.Valid) or Req.Cursor.NewFile or
                          (not SameText(Req.Cursor.FileName, Info.Name));

  SetLength(Result.Data, Length(HeaderBytes) + Length(BodyBytes));
  if Length(HeaderBytes) > 0 then
    Move(HeaderBytes[0], Result.Data[0], Length(HeaderBytes));
  if Length(BodyBytes) > 0 then
    Move(BodyBytes[0], Result.Data[Length(HeaderBytes)], Length(BodyBytes));

  // 4. Por onde continuar.
  Cursor.Valid := False;
  Result.NextMs := -1;
  Result.GapMs := 0;
  if Last < High(Index) then
  begin
    Result.NextMs := Index[Last + 1].StartUnixMs;
    Cursor.Valid := True;
    Cursor.NextMs := Result.NextMs;
    Cursor.FileName := Info.Name;
    Cursor.BlockIdx := Last + 1;
    Cursor.NewFile := False;
  end
  else if NextFileAfter(CameraOfFile, Info.Name, Result.EndMs, NextInfo) then
  begin
    // Acabou o arquivo, mas a câmera continuou noutro: a emenda é aqui, e o
    // cliente só vai saber dela pelo Discontinuity da resposta seguinte.
    Result.NextMs := NextInfo.StartMs;
    if Result.NextMs > Result.EndMs then
      Result.GapMs := Result.NextMs - Result.EndMs;
    Cursor.Valid := True;
    Cursor.NextMs := NextInfo.StartMs;
    Cursor.FileName := NextInfo.Name;
    Cursor.BlockIdx := 0;
    Cursor.NewFile := True;
  end;
  Result.Cursor := Cursor.Encode;
end;

end.
