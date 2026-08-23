unit Vms.Thumb.Intf;

// As fronteiras do subsistema de miniaturas.
//
// Gerar uma miniatura é uma cadeia de quatro coisas que não têm nada a ver umas
// com as outras: achar o keyframe daquele instante (sabe de `.vms`), decodificá-lo
// (sabe de FFmpeg), transformar em JPEG (sabe de imagem no Windows) e guardar o
// resultado (sabe de disco). Cada uma vive atrás de uma interface, e o serviço
// que as orquestra não conhece nenhuma implementação concreta.
//
// O que isso compra, em ordem de importância:
//
//   1. A rota da API depende de IThumbSource e mais nada. Sem essas fronteiras,
//      `Vms.Server.Api` passaria a arrastar FFmpeg e VCL atrás de si — duas
//      dependências pesadas e específicas de Windows dentro da camada que só
//      deveria falar HTTP.
//   2. Sem FFmpeg no disco, a composição liga um IThumbSource que simplesmente
//      não tem miniatura, e o servidor sobe igual. A ausência de um recurso não
//      pode virar exceção no meio de uma requisição.
//   3. Trocar o encoder (GDI hoje, mjpeg do próprio FFmpeg amanhã) ou o
//      decodificador é escrever outra classe, não mexer no serviço.
//   4. O serviço é testável sem FFmpeg, sem disco e sem gravação: são três
//      dublês implementando três interfaces pequenas.

interface

uses
  System.SysUtils,
  VMS.Domain.Types;

type
  // Imagem descomprimida, RGB de 8 bits por canal, linhas sem alinhamento
  // (stride = Width * 3). É o único formato que atravessa as fronteiras daqui:
  // quem decodifica entrega isto, quem encoda recebe isto.
  TRgbImage = record
    Width: Integer;
    Height: Integer;
    Pixels: TBytes;
    function IsValid: Boolean;
  end;

  // Onde arranjar o quadro comprimido de um instante.
  IKeyframeSource = interface
    ['{4C1B4C9E-8E37-4A5F-9E2A-2C6B1B0A7F31}']
    // O keyframe mais próximo (para trás) de Ms. Extra são os parameter sets do
    // header da gravação, para a câmera que só os manda fora do stream.
    // ActualMs é o instante do quadro que saiu, que não é o pedido.
    function Grab(const Camera: string; Ms: Int64; out AU, Extra: TBytes;
                  out Codec: TVideoCodec; out ActualMs: Int64): Boolean;
  end;

  // Quem sabe transformar um quadro comprimido em pixels.
  IFrameGrabber = interface
    ['{9F2D6A44-1F0B-4D6E-B0A1-7A9C3E5D8B02}']
    // MaxW/MaxH limitam o resultado preservando a proporção. False = não deu
    // (codec sem suporte, biblioteca ausente, quadro corrompido) — nunca exceção.
    function Decode(const AU, Extra: TBytes; Codec: TVideoCodec;
                    MaxW, MaxH: Integer; out Img: TRgbImage): Boolean;
    // Há como decodificar nesta máquina? A composição pergunta uma vez.
    function Available: Boolean;
  end;

  // Quem sabe transformar pixels em bytes de um formato de imagem.
  IImageEncoder = interface
    ['{2E7A0C13-55D4-49C8-9F6B-3D4E1A2B6C50}']
    function Encode(const Img: TRgbImage; out Data: TBytes): Boolean;
    // O tipo MIME do que o Encode produz, para a resposta HTTP.
    function ContentType: string;
  end;

  // O que a API enxerga. Uma pergunta só: a miniatura deste instante.
  IThumbSource = interface
    ['{6B8E9D27-70C2-4C3A-8D1E-5F0A2B7C4D63}']
    // False = não há miniatura para este instante (sem gravação, sem
    // decodificador, ou falha ao gerar). ActualMs é o minuto que a imagem
    // representa, que o cliente usa para não pedir o mesmo duas vezes.
    function Get(const Camera: string; Ms: Int64; out Data: TBytes;
                 out ActualMs: Int64): Boolean;
    function ContentType: string;
    function Available: Boolean;
  end;

implementation

{ TRgbImage }

function TRgbImage.IsValid: Boolean;
begin
  Result := (Width > 0) and (Height > 0) and
            (Length(Pixels) >= Width * Height * 3);
end;

end.
