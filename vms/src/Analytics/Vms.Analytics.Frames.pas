unit Vms.Analytics.Frames;

// Percorrer a gravacao entregando quadros no ritmo PEDIDO, e nao no do GOP.
//
// ## O problema
//
// Ate aqui a analise so olhava keyframe: o IKeyframeSource acha o quadro
// comprimido de um instante e o IFrameGrabber o decodifica sozinho. E barato --
// busca binaria no indice e a leitura de UM bloco -- e foi o que permitiu a
// analise nascer sem saber o que e `.vms` nem o que e H.264.
//
// So que a cadencia deixa de ser uma escolha: vira o GOP da camera. Numa camera
// de GOP 4 s, pedir passo de 500 ms nao muda nada -- o mesmo keyframe volta oito
// vezes, e o laco antigo pulava as repeticoes. Movimento mais curto que o GOP
// simplesmente nao tem quadro em que ser visto, e baixar o limiar nao recupera
// isso: nao e o limiar que esta comendo, e a amostragem que nao existe.
//
// ## O que este percurso faz
//
// Abre UM decodificador e alimenta todos os AUs em ordem a partir do keyframe
// anterior ao instante pedido, entregando de volta so os quadros que caem no
// ritmo. E o unico jeito: quadro P descreve a diferenca para os anteriores, e
// para ver o do segundo 7 e preciso ter decodificado desde o keyframe.
//
// ## O preco, que e real
//
// Aqui se decodifica TUDO. Numa camera de 10 fps com GOP de 4 s, o caminho de
// keyframe decodificava 1 quadro a cada 40; este decodifica os 40. O custo nao
// depende do passo pedido -- pedir 500 ms ou 2 s custa o mesmo --, entao quem
// escolhe o passo esta escolhendo entre granularidade e CPU, e nao entre dois
// niveis de custo.
//
// Por isso quem chama fica com os dois caminhos: passo grosso continua no
// keyframe, que e barato; passo fino vem para ca.
//
// ## Troca de arquivo
//
// Arquivo novo pode ter outra resolucao ou ate outro codec, e o decodificador
// nao atravessa isso: ele e refeito na virada, comecando pelo keyframe do
// arquivo seguinte. E a mesma descontinuidade que o player trata.

interface

uses
  System.SysUtils,
  System.Math,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Reader,
  Vms.Server.IndexCache,
  Vms.Thumb.Intf,
  Vms.Analytics.Intf;

type
  TVmsFrameWalkSource = class(TInterfacedObject, IFrameWalkSource)
  strict private
    FCache: TVmsIndexCache;
    FOpener: IFrameSequenceOpener;
    FLogger: ILogger;
  public
    constructor Create(ACache: TVmsIndexCache;
                       const AOpener: IFrameSequenceOpener;
                       const ALogger: ILogger);
    { IFrameWalkSource }
    function Walk(const Camera: string; FromMs, ToMs, StepMs: Int64;
                  MaxW, MaxH: Integer): IFrameWalk;
    function Available: Boolean;
  end;

implementation

type
  TVmsFrameWalk = class(TInterfacedObject, IFrameWalk)
  strict private
    FCache: TVmsIndexCache;
    FOpener: IFrameSequenceOpener;
    FLogger: ILogger;
    FCamera: string;
    FToMs, FStepMs, FAlvoMs: Int64;
    FMaxW, FMaxH: Integer;

    FReader: TVmsReader;
    FSeq: IFrameSequence;
    FArquivo: string;          // o que esta aberto
    FMotivo: string;           // por que o passeio terminou
    FBloco: TVmsBlock;
    FIdxSample: Integer;       // proximo sample do bloco corrente
    FTemBloco: Boolean;
    FAncora, FPrimeiroPts, FTimescale: Int64;
    FAcabou: Boolean;

    function AbrirArquivoEm(Ms: Int64): Boolean;
    function ProximoArquivo: Boolean;
    function ProximoBloco: Boolean;
    procedure Fechar;
  public
    constructor Create(ACache: TVmsIndexCache;
                       const AOpener: IFrameSequenceOpener;
                       const ALogger: ILogger; const ACamera: string;
                       AFromMs, AToMs, AStepMs: Int64; AMaxW, AMaxH: Integer);
    destructor Destroy; override;
    { IFrameWalk }
    function Next(out Img: TRgbImage; out Ms: Int64): Boolean;
    function MotivoDoFim: string;
  end;

{ TVmsFrameWalkSource }

constructor TVmsFrameWalkSource.Create(ACache: TVmsIndexCache;
  const AOpener: IFrameSequenceOpener; const ALogger: ILogger);
begin
  inherited Create;
  FCache := ACache;
  FOpener := AOpener;
  FLogger := ALogger;
end;

function TVmsFrameWalkSource.Available: Boolean;
begin
  Result := (FCache <> nil) and (FOpener <> nil);
end;

function TVmsFrameWalkSource.Walk(const Camera: string;
  FromMs, ToMs, StepMs: Int64; MaxW, MaxH: Integer): IFrameWalk;
var
  W: TVmsFrameWalk;
begin
  Result := nil;
  if not Available then Exit;
  if (Camera = '') or (ToMs <= FromMs) or (StepMs <= 0) then Exit;
  W := TVmsFrameWalk.Create(FCache, FOpener, FLogger, Camera,
                            FromMs, ToMs, StepMs, MaxW, MaxH);
  Result := W;
end;

{ TVmsFrameWalk }

constructor TVmsFrameWalk.Create(ACache: TVmsIndexCache;
  const AOpener: IFrameSequenceOpener; const ALogger: ILogger;
  const ACamera: string; AFromMs, AToMs, AStepMs: Int64;
  AMaxW, AMaxH: Integer);
begin
  inherited Create;
  FCache := ACache;
  FOpener := AOpener;
  FLogger := ALogger;
  FCamera := ACamera;
  FToMs := AToMs;
  FStepMs := AStepMs;
  FMaxW := AMaxW;
  FMaxH := AMaxH;
  // O primeiro quadro que servir ja vale: o alvo comeca no inicio da janela.
  FAlvoMs := AFromMs;
  FAcabou := not AbrirArquivoEm(AFromMs);
end;

destructor TVmsFrameWalk.Destroy;
begin
  Fechar;
  inherited;
end;

procedure TVmsFrameWalk.Fechar;
begin
  FSeq := nil;
  FreeAndNil(FReader);
  FTemBloco := False;
end;

// Abre o arquivo que contem o instante (ou o primeiro depois dele, quando o
// instante cai num buraco de gravacao) e posiciona no keyframe anterior a ele.
function TVmsFrameWalk.AbrirArquivoEm(Ms: Int64): Boolean;
var
  Arquivos: TVmsFileInfoArray;
  Info: TVmsFileInfo;
  Index: TVmsIndex;
  I, BlocoIdx, ChaveIdx: Integer;
  Achou: Boolean;
begin
  Result := False;
  Fechar;
  Arquivos := FCache.ListFiles(FCamera);
  if Length(Arquivos) = 0 then Exit;

  Achou := False;
  for I := 0 to High(Arquivos) do
    if (Ms >= Arquivos[I].StartMs) and (Ms < Arquivos[I].EndMs) then
    begin
      Info := Arquivos[I];
      Achou := True;
      Break;
    end;
  // Caiu num buraco: vale o proximo que comeca depois, e nao o anterior --
  // andar para tras entregaria material ja passado.
  if not Achou then
    for I := 0 to High(Arquivos) do
      if Arquivos[I].StartMs >= Ms then
      begin
        Info := Arquivos[I];
        Achou := True;
        Break;
      end;
  if not Achou then Exit;
  if Info.StartMs > FToMs then Exit;

  if not FCache.GetIndex(Info.Path, Index) then Exit;
  if Length(Index) = 0 then Exit;

  BlocoIdx := IndexBlockAtTime(Index, Ms);
  if BlocoIdx < 0 then BlocoIdx := 0;
  // Comecar no keyframe: do meio de um GOP o decodificador nao reconstroi nada.
  ChaveIdx := IndexKeyframeAtOrBefore(Index, BlocoIdx);
  if ChaveIdx < 0 then ChaveIdx := 0;

  try
    FReader := TVmsReader.Create(Info.Path);
  except
    FReader := nil;
    Exit;
  end;
  FReader.Logger := FLogger;
  if not FReader.ReadHeader then begin Fechar; Exit; end;
  if not FReader.Header.VideoPresent then begin Fechar; Exit; end;

  FTimescale := FReader.Header.Video.Timescale;
  if FTimescale <= 0 then FTimescale := 90000;
  // O indice veio do CACHE; este leitor acabou de abrir e o dele esta vazio.
  // Sem semear, o SeekToBlock reprova todo indice por estar fora de um vetor de
  // tamanho zero (mesma armadilha do Vms.Thumb.Keyframe).
  FReader.SeedIndex(Index, Index[High(Index)].Offset);
  if not FReader.SeekToBlock(ChaveIdx) then begin Fechar; Exit; end;

  FSeq := FOpener.OpenSequence(FReader.Header.Video.Codec,
                               FReader.Header.Video.Extradata, FMaxW, FMaxH);
  if FSeq = nil then begin Fechar; Exit; end;

  FArquivo := Info.Path;
  FTemBloco := False;
  Result := True;
end;

// O arquivo seguinte ao que esta aberto. Decodificador novo: resolucao e codec
// podem ter mudado na virada.
function TVmsFrameWalk.ProximoArquivo: Boolean;
var
  Arquivos: TVmsFileInfoArray;
  I: Integer;
  Alvo: Int64;
  Seguinte: string;
begin
  Result := False;
  Arquivos := FCache.ListFiles(FCamera);
  Alvo := 0;
  Seguinte := '';
  for I := 0 to High(Arquivos) do
    if SameText(Arquivos[I].Path, FArquivo) then
    begin
      if I >= High(Arquivos) then
      begin
        FMotivo := 'nao ha arquivo depois de ' + ExtractFileName(FArquivo);
        Exit;
      end;
      Alvo := Arquivos[I + 1].StartMs;
      Seguinte := Arquivos[I + 1].Path;
      Break;
    end;
  if Alvo <= 0 then
  begin
    // O arquivo aberto sumiu da listagem: rodizio apagou, ou a listagem foi
    // remontada enquanto se andava.
    FMotivo := 'o arquivo aberto saiu da listagem';
    Exit;
  end;
  if Alvo > FToMs then
  begin
    FMotivo := 'fim do trecho pedido';
    Exit;
  end;
  Result := AbrirArquivoEm(Alvo);
  if not Result then
    FMotivo := 'nao consegui abrir ' + ExtractFileName(Seguinte);
end;

function TVmsFrameWalk.ProximoBloco: Boolean;
var
  I: Integer;
begin
  Result := False;
  if FReader = nil then Exit;
  if not FReader.ReadNextBlock(FBloco) then
  begin
    if not ProximoArquivo then Exit;
    if FReader = nil then Exit;
    if not FReader.ReadNextBlock(FBloco) then Exit;
  end;
  FTemBloco := True;
  FIdxSample := 0;
  // A ancora e o pts do primeiro sample de VIDEO deste bloco: e desses dois que
  // sai o instante de parede de cada quadro, pela mesma conta do player.
  FAncora := FBloco.VideoAnchorMs;
  if FAncora = 0 then FAncora := FBloco.StartUnixMs;
  FPrimeiroPts := 0;
  for I := 0 to High(FBloco.Samples) do
    if FBloco.Samples[I].TrackId = 0 then
    begin
      FPrimeiroPts := FBloco.Samples[I].Pts;
      Break;
    end;
  Result := True;
end;

function TVmsFrameWalk.MotivoDoFim: string;
begin
  Result := FMotivo;
end;

function TVmsFrameWalk.Next(out Img: TRgbImage; out Ms: Int64): Boolean;
var
  AU: TBytes;
  Parede: Int64;
  Saiu: Boolean;
begin
  Result := False;
  Img := Default(TRgbImage);
  Ms := 0;
  if FAcabou then Exit;

  while True do
  begin
    if (not FTemBloco) or (FIdxSample > High(FBloco.Samples)) then
    begin
      if not ProximoBloco then
      begin
        FAcabou := True;
        if FMotivo = '' then FMotivo := 'a gravacao acaba aqui';
        Exit;
      end;
      Continue;
    end;

    if FBloco.Samples[FIdxSample].TrackId <> 0 then
    begin
      Inc(FIdxSample);
      Continue;
    end;
    if FBloco.Samples[FIdxSample].PayloadSize = 0 then
    begin
      Inc(FIdxSample);
      Continue;
    end;

    Parede := FAncora +
      ((FBloco.Samples[FIdxSample].Pts - FPrimeiroPts) * 1000) div FTimescale;
    if Parede > FToMs then
    begin
      FAcabou := True;
      FMotivo := 'fim do trecho pedido';
      Exit;
    end;

    SetLength(AU, FBloco.Samples[FIdxSample].PayloadSize);
    Move(FBloco.Payload[FBloco.Samples[FIdxSample].PayloadOffset], AU[0],
         FBloco.Samples[FIdxSample].PayloadSize);
    Inc(FIdxSample);

    // Todo sample vai para o decodificador, sempre: pular um quebraria a cadeia
    // de referencias dos que vem depois. O ritmo escolhe o que SAI daqui, e nao
    // o que entra la.
    Saiu := FSeq.Feed(AU, Img);
    if not Saiu then Continue;
    if Parede < FAlvoMs then Continue;

    // Max, e nao soma simples: com quadros esparsos a soma acumularia atraso e
    // o passo iria escorregando.
    FAlvoMs := Max(FAlvoMs + FStepMs, Parede + 1);
    Ms := Parede;
    Exit(True);
  end;
end;

end.
