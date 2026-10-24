unit VMS.App.Decodificacao;

// Decodificar no Delphi o que o WebView nao consegue, e devolver JPEG.
//
// ## Por que existe
//
// O Chromium deste aparelho recusa HEVC acima de 2048 de largura. Medido de tres
// jeitos na camera de 2560x1440: WebCodecs erra no primeiro keyframe
// ("EncodingError", zero quadros), o `<video>`/MSE devolve
// PIPELINE_ERROR_DECODE, e o proprio `MediaCapabilities` responde
// `supported: false` para esse tamanho -- e `true` para 2048x1440. Nao ha
// decodificador de software de HEVC no navegador: o Chromium nao embute um, e
// nao alcanca o do sistema.
//
// O aparelho, porem, TEM como: o `c2.android.hevc.decoder` vai ate 4096x4096, e
// o MediaCodec chega nele. O TVideoDecoder desta pasta ja sabe pedi-lo pelo nome
// quando o de hardware falha -- aquele fallback foi escrito para este defeito.
//
// ## O desenho
//
// A PAGINA continua buscando os fragmentos `.vms` como sempre: o que falhava era
// so a decodificacao, e o resto (cursor, emenda de arquivo, autenticacao) ja
// funciona e nao vale reescrever em Delphi. Ela entrega os bytes aqui e pede um
// quadro de cada vez.
//
// Pedir UM DE CADA VEZ, e nao "o mais recente", e o que preserva o ritmo. O
// decodificador esvazia um fragmento de dois segundos em uma fracao disso; se
// aqui se devolvesse sempre o ultimo, a pagina veria um salto e depois dois
// segundos parada. Quem tem o relogio da reproducao e ela, e e ela que decide
// quando pedir o proximo.
//
// Fora do Android nada disto e construido: no Windows o WebView2 decodifica o
// que precisamos.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging;

type
  TDecodificacaoNativa = class
  strict private
  type
    TCamera = class
      Decodificador: TObject;      // TVideoDecoder; TObject para nao vazar a
                                   // unit do Android na interface
      Pendentes: TList<TSample>;
      Instantes: TList<Int64>;     // parede de cada sample pendente
      Codec: TVideoCodec;
      Largura, Altura: Integer;
      Extradata: TBytes;
      Configurado: Boolean;
      UltimoSeq: Int64;      // ultimo quadro ja entregue a pagina
      UltimoMs: Int64;
      // A parede do primeiro sample desta sessao. Os pts entregues ao
      // decodificador sao relativos a ela -- ver Alimentar.
      BaseMs: Int64;
      TemBase: Boolean;
      destructor Destroy; override;
    end;
  strict private
    FLock: TCriticalSection;
    FCameras: TObjectDictionary<string, TCamera>;
    FLogger: ILogger;
    FQualidade: Integer;
    function Obter(const Camera: string): TCamera;
{$IFDEF ANDROID}
    // Manda o proximo sample da fila para o decodificador. False = fila vazia.
    function EnfileirarProximo(const Camera: string): Boolean;
{$ENDIF}
  public
    constructor Create(const ALogger: ILogger; AQualidade: Integer = 70);
    destructor Destroy; override;

    // Ha como decodificar por este caminho nesta plataforma?
    function Disponivel: Boolean;

    // Recebe um fragmento .vms -- exatamente o que /api/media devolve -- e
    // enfileira os samples de video dele. False = fragmento ilegivel.
    function Alimentar(const Camera: string; const Fragmento: TBytes): Boolean;

    // Decodifica ate sair UM quadro e o devolve em JPEG, com o instante de
    // parede dele. False = nao havia sample pendente, ou nenhum quadro saiu no
    // tempo dado.
    function ProximoQuadro(const Camera: string; EsperaMs: Integer;
                           out Jpeg: TBytes; out Ms: Int64): Boolean;

    // Quantos samples ainda nao foram entregues. E por este numero que a pagina
    // sabe que esta na hora de buscar outro fragmento.
    function Pendentes(const Camera: string): Integer;

    // Esquece o que estava enfileirado: troca de camera, ou salto no tempo.
    procedure Reiniciar(const Camera: string);
  end;

implementation

uses
  System.Math,
  VMS.Rec.Format,
  VMS.Rec.Reader
{$IFDEF ANDROID}
  , VMS.Android.VideoDecoder
  , VMS.Android.Jpeg
{$ENDIF}
  ;

const
  // Teto do que fica enfileirado esperando ser pedido. Um fragmento tem uns
  // vinte samples; se a pagina parar de pedir, nao se guarda o dia inteiro.
  MAX_PENDENTES = 240;
  // Quantos samples uma chamada pode empurrar enquanto espera o primeiro quadro.
  MAX_POR_PEDIDO = 16;

{ TDecodificacaoNativa.TCamera }

destructor TDecodificacaoNativa.TCamera.Destroy;
begin
{$IFDEF ANDROID}
  if Decodificador <> nil then
  begin
    TVideoDecoder(Decodificador).Terminate;
    TVideoDecoder(Decodificador).WaitFor;
    Decodificador.Free;
  end;
{$ENDIF}
  Pendentes.Free;
  Instantes.Free;
  inherited;
end;

{ TDecodificacaoNativa }

constructor TDecodificacaoNativa.Create(const ALogger: ILogger;
  AQualidade: Integer);
begin
  inherited Create;
  FLogger := ALogger;
  FQualidade := AQualidade;
  FLock := TCriticalSection.Create;
  FCameras := TObjectDictionary<string, TCamera>.Create([doOwnsValues]);
end;

destructor TDecodificacaoNativa.Destroy;
begin
  FCameras.Free;
  FLock.Free;
  inherited;
end;

function TDecodificacaoNativa.Disponivel: Boolean;
begin
{$IFDEF ANDROID}
  Result := True;
{$ELSE}
  Result := False;
{$ENDIF}
end;

function TDecodificacaoNativa.Obter(const Camera: string): TCamera;
begin
  if FCameras.TryGetValue(Camera, Result) then Exit;
  Result := TCamera.Create;
  Result.Pendentes := TList<TSample>.Create;
  Result.Instantes := TList<Int64>.Create;
{$IFDEF ANDROID}
  // Sem OnFrame: quem avisa que ha quadro novo e o FrameSeq, lido daqui. O
  // OnFrame passaria pela thread principal, e esta chamada vem de uma conexao
  // do servidor local.
  Result.Decodificador := TVideoDecoder.Create(FLogger);
  // O teto padrao (1280) foi pensado para a tela do aparelho. Aqui o quadro vai
  // para a pagina, que pode estar exibindo em cima de um 1440p -- 1920 e o que
  // o proprio navegador entrega nas cameras que ele consegue decodificar, e nao
  // faz sentido entregar menos por este caminho.
  TVideoDecoder(Result.Decodificador).MaxDisplayDim := 1920;
{$ENDIF}
  FCameras.Add(Camera, Result);
end;

function TDecodificacaoNativa.Alimentar(const Camera: string;
  const Fragmento: TBytes): Boolean;
var
  C: TCamera;
  Fluxo: TBytesStream;
  Leitor: TVmsReader;
  Bloco: TVmsBlock;
  I: Integer;
  Ancora, PrimeiroPts, Timescale, Parede: Int64;
  S: TSample;
  Achou: Boolean;
begin
  Result := False;
  if (not Disponivel) or (Length(Fragmento) = 0) then Exit;

  Fluxo := TBytesStream.Create(Fragmento);
  Leitor := nil;
  try
    try
      Leitor := TVmsReader.Create(Fluxo, False);
    except
      Exit;
    end;
    if not Leitor.ReadHeader then Exit;
    if not Leitor.Header.VideoPresent then Exit;
    Timescale := Leitor.Header.Video.Timescale;
    if Timescale <= 0 then Timescale := 90000;

    FLock.Enter;
    try
      C := Obter(Camera);
      // Formato novo (ou primeiro fragmento): reconfigura. Trocar de arquivo
      // pode trocar de resolucao, e o decodificador nao atravessa isso.
      if (not C.Configurado) or (C.Codec <> Leitor.Header.Video.Codec) or
         (Length(C.Extradata) <> Length(Leitor.Header.Video.Extradata)) then
      begin
        C.Codec := Leitor.Header.Video.Codec;
        C.Extradata := Copy(Leitor.Header.Video.Extradata);
        C.Largura := Leitor.Header.Video.Width;
        C.Altura := Leitor.Header.Video.Height;
{$IFDEF ANDROID}
        TVideoDecoder(C.Decodificador).Configure(C.Codec, C.Largura, C.Altura,
                                                 C.Extradata);
{$ENDIF}
        C.Configurado := True;
      end;

      while Leitor.ReadNextBlock(Bloco) do
      begin
        // O instante de parede sai da ancora do bloco, pela mesma conta do
        // player e do gravador.
        Ancora := Bloco.VideoAnchorMs;
        if Ancora = 0 then Ancora := Bloco.StartUnixMs;
        PrimeiroPts := 0;
        Achou := False;
        for I := 0 to High(Bloco.Samples) do
        begin
          if Bloco.Samples[I].TrackId <> 0 then Continue;
          if not Achou then
          begin
            PrimeiroPts := Bloco.Samples[I].Pts;
            Achou := True;
          end;
          if Bloco.Samples[I].PayloadSize = 0 then Continue;
          if C.Pendentes.Count >= MAX_PENDENTES then Break;

          Parede := Ancora +
            ((Bloco.Samples[I].Pts - PrimeiroPts) * 1000) div Timescale;
          if not C.TemBase then
          begin
            C.BaseMs := Parede;
            C.TemBase := True;
          end;

          S := Default(TSample);
          S.Kind := tkVideo;
          S.TrackId := 0;
          // O pts que vai para o MediaCodec e a PAREDE, e nao o pts do arquivo:
          // ele volta junto com o quadro decodificado, e e assim que se sabe a
          // que instante o quadro pronto corresponde. Entre a entrada e a saida
          // ha uma fila de profundidade desconhecida, e supor que saiu o que
          // acabou de entrar adiantaria o relogio da pagina em alguns quadros.
          //
          // A unidade e a que o decodificador espera (90 kHz) e a origem e o
          // primeiro sample da sessao, para o numero nao ficar gigante.
          S.Pts := (Parede - C.BaseMs) * 90;
          S.Flags := ByteToFlags(Bloco.Samples[I].FlagsByte);
          SetLength(S.Data, Bloco.Samples[I].PayloadSize);
          Move(Bloco.Payload[Bloco.Samples[I].PayloadOffset], S.Data[0],
               Bloco.Samples[I].PayloadSize);
          C.Pendentes.Add(S);
          C.Instantes.Add(Parede);
          Result := True;
        end;
      end;
    finally
      FLock.Leave;
    end;
  finally
    Leitor.Free;
    Fluxo.Free;
  end;
end;

{$IFDEF ANDROID}
function TDecodificacaoNativa.EnfileirarProximo(const Camera: string): Boolean;
var
  C: TCamera;
  Dec: TVideoDecoder;
  S: TSample;
begin
  Result := False;
  // Sob o lock so o que e rapido: tirar o sample da fila. O Enqueue fica de
  // fora dele -- ele pode esperar buffer do MediaCodec, e segurar o lock ai
  // travaria as outras cameras.
  FLock.Enter;
  try
    if not FCameras.TryGetValue(Camera, C) then Exit;
    if C.Pendentes.Count = 0 then Exit;
    Dec := TVideoDecoder(C.Decodificador);
    S := C.Pendentes[0];
    C.Pendentes.Delete(0);
    C.Instantes.Delete(0);
  finally
    FLock.Leave;
  end;
  Dec.Enqueue(S);
  Result := True;
end;
{$ENDIF}

function TDecodificacaoNativa.ProximoQuadro(const Camera: string;
  EsperaMs: Integer; out Jpeg: TBytes; out Ms: Int64): Boolean;
{$IFDEF ANDROID}
var
  C: TCamera;
  Dec: TVideoDecoder;
  RGBA: TBytes;
  W, H: Integer;
  Alvo, Base, PtsUs: Int64;
  Enfileirados: Integer;
  Fim: TDateTime;
{$ENDIF}
begin
  Result := False;
  Jpeg := nil;
  Ms := 0;
{$IFDEF ANDROID}
  FLock.Enter;
  try
    if not FCameras.TryGetValue(Camera, C) then Exit;
    if (C.Pendentes.Count = 0) or (not C.TemBase) then Exit;
    Dec := TVideoDecoder(C.Decodificador);
    Base := C.BaseMs;
    Alvo := C.UltimoSeq;
  finally
    FLock.Leave;
  end;

  Enfileirados := 1;
  if not EnfileirarProximo(Camera) then Exit;

  // Espera um quadro NOVO. O decodificador nem sempre devolve um por sample --
  // ha referencias a juntar e pode haver reordenacao --, e comparar o contador
  // e o que distingue "saiu outro" de "o mesmo de antes".
  if EsperaMs <= 0 then EsperaMs := 400;
  Fim := Now + EsperaMs / 86400000.0;
  repeat
    if Dec.FrameSeq > Alvo then
    begin
      PtsUs := 0;
      if Dec.LockLatestFrame(RGBA, W, H) then
      try
        PtsUs := Dec.FramePtsUs;
        Jpeg := RgbaParaJpeg(RGBA, W, H, FQualidade);
      finally
        Dec.UnlockFrame;
      end;
      if Length(Jpeg) > 0 then
      begin
        // O instante e o do QUADRO, reconstruido do pts que voltou com ele.
        Ms := Base + PtsUs div 1000;
        FLock.Enter;
        try
          if FCameras.TryGetValue(Camera, C) then
          begin
            C.UltimoSeq := Dec.FrameSeq;
            C.UltimoMs := Ms;
          end;
        finally
          FLock.Leave;
        end;
        Exit(True);
      end;
    end;
    // Nada saiu ainda. No arranque isso e normal: o MediaCodec junta algumas
    // unidades antes do primeiro quadro. Continuar alimentando enquanto se
    // espera faz o arranque custar uma espera so, e nao uma por sample.
    // O teto existe para o caso de o decodificador emperrar: sem ele, uma
    // chamada so despejaria o fragmento inteiro la dentro, a pagina ficaria sem
    // nada para pedir e a reproducao pararia de vez em vez de so engasgar.
    if (Enfileirados >= MAX_POR_PEDIDO) or (not EnfileirarProximo(Camera)) then
      Sleep(8)
    else
      Inc(Enfileirados);
  until Now >= Fim;
{$ENDIF}
end;

function TDecodificacaoNativa.Pendentes(const Camera: string): Integer;
var
  C: TCamera;
begin
  Result := 0;
  FLock.Enter;
  try
    if FCameras.TryGetValue(Camera, C) then
      Result := C.Pendentes.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TDecodificacaoNativa.Reiniciar(const Camera: string);
var
  C: TCamera;
begin
  FLock.Enter;
  try
    if not FCameras.TryGetValue(Camera, C) then Exit;
    C.Pendentes.Clear;
    C.Instantes.Clear;
    C.TemBase := False;    // a origem dos pts e por sessao
{$IFDEF ANDROID}
    TVideoDecoder(C.Decodificador).FlushReset;
    // O contador de quadros NAO volta a zero no flush: zerar o alvo aqui faria
    // o primeiro pedido da sessao nova devolver o ultimo quadro da anterior.
    C.UltimoSeq := TVideoDecoder(C.Decodificador).FrameSeq;
{$ELSE}
    C.UltimoSeq := 0;
{$ENDIF}
    C.Configurado := False;
  finally
    FLock.Leave;
  end;
end;

end.
