unit Vms.Thumb.FFmpeg;

// Decodifica UM quadro comprimido e devolve pixels. É a única peça do
// subsistema de miniaturas que conhece FFmpeg.
//
// A sequência é a mesma do decodificador de vídeo do app
// (VMS.Win.VideoDecoder), de propósito: contexto sem extradata, parameter sets
// prefixados no próprio pacote quando a câmera só os manda fora do stream, e
// buffer com os bytes de padding que a API exige. Mudar de sequência aqui seria
// manter dois jeitos de falar com a mesma biblioteca.
//
// Diferenças, porque o caso de uso é outro:
//   * é síncrono e sem fila — um quadro entra, uma imagem sai;
//   * o contexto é recriado a cada chamada. Uma miniatura por minuto não
//     justifica manter decodificador vivo, e recriar evita carregar estado de
//     uma gravação para outra;
//   * a saída é RGB24 no tamanho da miniatura, já reduzida pelo swscale — que
//     escala melhor e mais barato do que reduzir depois.
//
// Biblioteca ausente é resposta, não exceção: Available devolve False e a
// composição liga a fonte nula.

{$IFDEF MSWINDOWS}
{$POINTERMATH ON}
{$ENDIF}

interface

{$IFDEF MSWINDOWS}

uses
  System.SysUtils,
  System.Math,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  FFmpegLib,
  Vms.Thumb.Intf;

type
  TFFmpegFrameGrabber = class(TInterfacedObject, IFrameGrabber)
  strict private
    FLogger: ILogger;
    FTag: string;
    FProbed: Boolean;
    FAvail: Boolean;
    procedure Log(const Msg: string);
  public
    // ATag so separa quem esta decodificando no log: a mesma classe serve as
    // miniaturas e a analise, e 'analytics' logando como 'thumb' e confusao na
    // hora de ler o arquivo.
    //
    // NOTA sobre quadro corrompido: quando o bitstream tem erro, o FFmpeg
    // REMENDA os macroblocos ruins e devolve o quadro assim mesmo, e aqui isso
    // vira `Result := True`. Para miniatura esta certo — imagem com um
    // retangulo sujo ainda diz que horas eram. Para a ANALISE nao: o detector
    // de movimento compara luma celula a celula, e macrobloco remendado muda de
    // nivel e vira "mexeu". Recusar exigiria `err_detect = AV_EF_EXPLODE`, que
    // nesta versao do h264 tambem torna fatal o "Invalid NAL unit 0" — ou seja,
    // podia derrubar quadros bons junto. Antes de ligar isso, ver a contagem de
    // falhas que o TAnalyticsWorker agora escreve no log.
    constructor Create(const ALogger: ILogger; const ATag: string = 'thumb');
    { IFrameGrabber }
    function Decode(const AU, Extra: TBytes; Codec: TVideoCodec;
                    MaxW, MaxH: Integer; out Img: TRgbImage): Boolean;
    function Available: Boolean;
  end;

{$ENDIF}

implementation

{$IFDEF MSWINDOWS}

// Um AU que já traz os próprios parameter sets não pode receber os do header:
// há câmera cujo header anuncia um SPS velho e incompatível com o que ela
// transmite, com o mesmo sps_id — prefixar sobrescreveria o bom. Mesmo motivo,
// mesmo comentário, do VMS.Win.VideoDecoder.
function HasParameterSets(const Data: TBytes; Codec: TVideoCodec): Boolean;
var
  I, NalType: Integer;
begin
  Result := False;
  I := 0;
  while I + 4 < Length(Data) do
  begin
    // start code Annex-B, de 3 ou 4 bytes
    if (Data[I] = 0) and (Data[I + 1] = 0) then
    begin
      if Data[I + 2] = 1 then
        NalType := I + 3
      else if (Data[I + 2] = 0) and (Data[I + 3] = 1) then
        NalType := I + 4
      else
      begin
        Inc(I);
        Continue;
      end;
      if NalType >= Length(Data) then Exit;
      if Codec = vcH265 then
      begin
        // H.265: tipo nos bits 6..1 do primeiro byte; 32=VPS 33=SPS 34=PPS
        case (Data[NalType] shr 1) and $3F of
          32, 33, 34: Exit(True);
        end;
      end
      else
        // H.264: tipo nos 5 bits baixos; 7=SPS 8=PPS
        case Data[NalType] and $1F of
          7, 8: Exit(True);
        end;
      I := NalType;
    end
    else
      Inc(I);
  end;
end;

function CodecIdOf(Codec: TVideoCodec): Integer;
begin
  case Codec of
    vcH264:  Result := AV_CODEC_ID_H264;
    vcH265:  Result := AV_CODEC_ID_HEVC;
    vcMJPEG: Result := AV_CODEC_ID_MJPEG;
  else
    Result := 0;
  end;
end;

constructor TFFmpegFrameGrabber.Create(const ALogger: ILogger;
  const ATag: string);
begin
  inherited Create;
  FLogger := ALogger;
  FTag := ATag;
  if FTag = '' then FTag := 'thumb';
  FProbed := False;
  FAvail := False;
end;

procedure TFFmpegFrameGrabber.Log(const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Info(FTag, Msg);
end;

// As DLLs são de carga adiada: a primeira chamada é o que descobre se elas
// existem. Uma sondagem barata, uma vez, e o resultado vale para a execução.
function TFFmpegFrameGrabber.Available: Boolean;
begin
  if FProbed then Exit(FAvail);
  FProbed := True;
  try
    FAvail := avcodec_version <> 0;
  except
    FAvail := False;
  end;
  // Cala o log do PROPRIO FFmpeg. Ele escreve direto no stderr, fora do log do
  // servidor, e fala um macrobloco por vez: analisar seis horas de gravacao de
  // tres cameras vira dezenas de milhares de linhas que enterram o log de
  // verdade. O que interessa saber — quantos quadros nao decodificaram e em que
  // trecho — passa a sair no log do servidor, contado, em vez de despejado.
  if FAvail then
  begin
    try av_log_set_level(AV_LOG_FATAL); except end;
    Log('FFmpeg disponivel; da para decodificar video');
  end
  else
    // Sem decodificador a barra do app fica sem miniatura e a analise nem sobe.
    // Quem diz o que cada um faz com isso e a composicao, nao esta classe.
    Log('FFmpeg ausente; nao ha como decodificar video nesta maquina');
  Result := FAvail;
end;

function TFFmpegFrameGrabber.Decode(const AU, Extra: TBytes; Codec: TVideoCodec;
  MaxW, MaxH: Integer; out Img: TRgbImage): Boolean;
var
  Id, Ret, SrcW, SrcH, DstW, DstH, InLen: Integer;
  Escala: Double;
  AvCodec: PAVCodec;
  Ctx: PAVCodecContext;
  Frame: PAVFrame;
  Pkt: PAVPacket;
  Sws: SwsContext;
  Buf: TBytes;
  DstData: array[0..3] of PByte;
  DstLines: array[0..3] of Integer;
begin
  Result := False;
  Img := Default(TRgbImage);
  if (Length(AU) = 0) or (MaxW <= 0) or (MaxH <= 0) then Exit;
  if not Available then Exit;
  Id := CodecIdOf(Codec);
  if Id = 0 then Exit;

  Ctx := nil;
  Frame := nil;
  Pkt := nil;
  Sws := nil;
  // try..FINALLY, e não try..except: quase toda saída daqui é um Exit no meio
  // (codec que não existe, contexto que não abriu, quadro que não saiu), e com
  // except esses Exits pulariam a liberação. Um contexto de decodificação
  // vazado por miniatura falha derrubaria um servidor que fica meses de pé.
  try
   try
    AvCodec := avcodec_find_decoder(Id);
    if AvCodec = nil then Exit;
    Ctx := avcodec_alloc_context3(AvCodec);
    if Ctx = nil then Exit;
    if avcodec_open2(Ctx, AvCodec, nil) < 0 then Exit;
    Frame := av_frame_alloc;
    Pkt := av_packet_alloc;
    if (Frame = nil) or (Pkt = nil) then Exit;

    // Um buffer só, com os parameter sets na frente quando fazem falta e os
    // bytes de padding no fim que os bitreaders do FFmpeg leem por contrato.
    if (Length(Extra) > 0) and (not HasParameterSets(AU, Codec)) then
    begin
      InLen := Length(Extra) + Length(AU);
      SetLength(Buf, InLen + AV_INPUT_BUFFER_PADDING_SIZE);
      Move(Extra[0], Buf[0], Length(Extra));
      Move(AU[0], Buf[Length(Extra)], Length(AU));
    end
    else
    begin
      InLen := Length(AU);
      SetLength(Buf, InLen + AV_INPUT_BUFFER_PADDING_SIZE);
      Move(AU[0], Buf[0], InLen);
    end;
    FillChar(Buf[InLen], AV_INPUT_BUFFER_PADDING_SIZE, 0);

    Pkt.data := PByte(@Buf[0]);
    Pkt.size := InLen;
    Ret := avcodec_send_packet(Ctx, Pkt);
    Pkt.data := nil;
    Pkt.size := 0;
    if Ret < 0 then Exit;
    // Um keyframe sozinho pode não sair na primeira tentativa; o flush força.
    if avcodec_receive_frame(Ctx, Frame) < 0 then
    begin
      avcodec_send_packet(Ctx, nil);   // sinaliza fim: drena o que houver
      if avcodec_receive_frame(Ctx, Frame) < 0 then Exit;
    end;

    SrcW := Frame.width;
    SrcH := Frame.height;
    if (SrcW <= 0) or (SrcH <= 0) then Exit;

    // Cabe na caixa preservando a proporção, e nunca amplia: miniatura maior
    // que o quadro seria borrão e bytes à toa.
    Escala := Min(MaxW / SrcW, MaxH / SrcH);
    if Escala > 1 then Escala := 1;
    DstW := Max(2, Round(SrcW * Escala));
    DstH := Max(2, Round(SrcH * Escala));
    if Odd(DstW) then Inc(DstW);   // largura par evita stride torto no RGB24
    if Odd(DstH) then Inc(DstH);

    Sws := sws_getContext(SrcW, SrcH, Frame.format, DstW, DstH,
                          AV_PIX_FMT_RGB24, SWS_BICUBIC, nil, nil, nil);
    if Sws = nil then Exit;

    Img.Width := DstW;
    Img.Height := DstH;
    SetLength(Img.Pixels, DstW * DstH * 3);
    DstData[0] := @Img.Pixels[0]; DstData[1] := nil; DstData[2] := nil; DstData[3] := nil;
    DstLines[0] := DstW * 3;      DstLines[1] := 0;  DstLines[2] := 0;  DstLines[3] := 0;
    if sws_scale(Sws, @Frame.data[0], @Frame.linesize[0], 0, SrcH,
                 @DstData[0], @DstLines[0]) <= 0 then Exit;
    Result := True;
   except
     on E: Exception do
     begin
       Result := False;
       if FLogger <> nil then
         FLogger.Warn('thumb', 'decode: ' + E.Message);
     end;
   end;
  finally
    if Sws <> nil then sws_freeContext(Sws);
    if Pkt <> nil then av_packet_free(@Pkt);
    if Frame <> nil then av_frame_free(@Frame);
    if Ctx <> nil then avcodec_free_context(@Ctx);
    if not Result then
      Img := Default(TRgbImage);
  end;
end;

{$ENDIF}

end.
