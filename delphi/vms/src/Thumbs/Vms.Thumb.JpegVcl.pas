unit Vms.Thumb.JpegVcl;

// Transforma pixels em JPEG. Única peça do subsistema que conhece imagem do
// Windows, e a única razão de o servidor linkar a VCL.
//
// Por que não o encoder mjpeg do próprio FFmpeg, já que ele está ali: para
// configurar um encoder é preciso escrever largura, altura e formato de pixel
// DENTRO do AVCodecContext, e esses campos não são AVOptions — teria de declarar
// o layout da struct e apostar no ABI. O FFmpegLib evita isso de propósito
// (`PAVCodecContext = type Pointer`), e não é aqui que vale abrir a exceção.
//
// A troca é fácil se um dia compensar: outra classe implementando IImageEncoder,
// uma linha na composição, e nada mais no sistema fica sabendo.

// O laço de conversão indexa PByte direto, que é o jeito barato de percorrer
// uma linha de pixels.
{$POINTERMATH ON}

interface

uses
  System.SysUtils,
  System.Classes,
  Vms.Thumb.Intf;

type
  TVclJpegEncoder = class(TInterfacedObject, IImageEncoder)
  strict private
    FQuality: Integer;
  public
    // Qualidade 1..100. 70 é onde uma miniatura de 160 px para de melhorar
    // visivelmente e continua custando bytes.
    constructor Create(AQuality: Integer = 70);
    { IImageEncoder }
    function Encode(const Img: TRgbImage; out Data: TBytes): Boolean;
    function ContentType: string;
  end;

implementation

uses
  Vcl.Graphics,
  Vcl.Imaging.jpeg;

constructor TVclJpegEncoder.Create(AQuality: Integer);
begin
  inherited Create;
  FQuality := AQuality;
  if FQuality < 1 then FQuality := 1;
  if FQuality > 100 then FQuality := 100;
end;

function TVclJpegEncoder.ContentType: string;
begin
  Result := 'image/jpeg';
end;

function TVclJpegEncoder.Encode(const Img: TRgbImage; out Data: TBytes): Boolean;
var
  Bmp: TBitmap;
  Jpg: TJPEGImage;
  Stream: TBytesStream;
  Y, X: Integer;
  Src: PByte;
  Dst: PByte;
begin
  Result := False;
  Data := nil;
  if not Img.IsValid then Exit;

  Bmp := TBitmap.Create;
  Jpg := nil;
  Stream := nil;
  try
   try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(Img.Width, Img.Height);
    for Y := 0 to Img.Height - 1 do
    begin
      Src := @Img.Pixels[Y * Img.Width * 3];
      Dst := Bmp.ScanLine[Y];
      // O RGB24 do swscale é R,G,B; o pf24bit da VCL é B,G,R. Trocar aqui é
      // mais barato que pedir BGR ao swscale e depois lembrar disso em todo
      // lugar que tocar em TRgbImage.
      for X := 0 to Img.Width - 1 do
      begin
        Dst[X * 3 + 0] := Src[X * 3 + 2];
        Dst[X * 3 + 1] := Src[X * 3 + 1];
        Dst[X * 3 + 2] := Src[X * 3 + 0];
      end;
    end;

    Jpg := TJPEGImage.Create;
    Jpg.CompressionQuality := FQuality;
    Jpg.Assign(Bmp);
    Stream := TBytesStream.Create;
    Jpg.SaveToStream(Stream);
    Data := Copy(Stream.Bytes, 0, Stream.Size);
    Result := Length(Data) > 0;
   except
     Result := False;
     Data := nil;
   end;
  finally
    Stream.Free;
    Jpg.Free;
    Bmp.Free;
  end;
end;

end.
