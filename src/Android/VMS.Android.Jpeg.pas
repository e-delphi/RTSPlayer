unit VMS.Android.Jpeg;

// Um quadro RGBA vira JPEG, usando o encoder do proprio Android.
//
// Existe porque o WebView nao consegue decodificar tudo que a gravacao tem: o
// Chromium deste aparelho recusa HEVC acima de 2048 de largura, por qualquer
// caminho (WebCodecs, <video>, MediaCapabilities -- os tres medidos). Quem da
// conta e o MediaCodec, que o Delphi alcanca direto. O quadro decodificado por
// ele precisa entao voltar para a pagina, e JPEG e o formato que qualquer
// navegador exibe sem ajuda nenhuma.
//
// Vai pelo Bitmap do Android, e nao por um encoder proprio: o do sistema costuma
// ter aceleracao, e escrever JPEG a mao seria reinventar sem motivo.
//
// Fora do Android e no-op -- ali o FFmpeg ja resolve.

interface

uses
  System.SysUtils;

// RGBA em ordem de memoria (R, G, B, A), que e o que o TVideoDecoder entrega e
// tambem o layout nativo do ARGB_8888 do Android -- por isso a copia e direta.
// Devolve nil quando nao da.
function RgbaParaJpeg(const RGBA: TBytes; W, H, Qualidade: Integer): TBytes;

implementation

{$IFDEF ANDROID}

uses
  Androidapi.Jni,
  Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.GraphicsContentViewText,
  VMS.Android.JNIUtil;

function RgbaParaJpeg(const RGBA: TBytes; W, H, Qualidade: Integer): TBytes;
var
  Bmp: JBitmap;
  Buf: JByteBuffer;
  Saida: JByteArrayOutputStream;
  Arr: TJavaArray<Byte>;
begin
  Result := nil;
  if (W <= 0) or (H <= 0) then Exit;
  if Length(RGBA) < W * H * 4 then Exit;
  if Qualidade <= 0 then Qualidade := 70;

  Bmp := TJBitmap.JavaClass.createBitmap(W, H,
           TJBitmap_Config.JavaClass.ARGB_8888);
  if Bmp = nil then Exit;
  try
    Buf := BytesToDirectBuffer(RGBA);
    if Buf = nil then Exit;
    Bmp.copyPixelsFromBuffer(Buf);
    Saida := TJByteArrayOutputStream.JavaClass.init;
    if not Bmp.compress(TJBitmap_CompressFormat.JavaClass.JPEG,
                        Qualidade, Saida) then Exit;
    Arr := Saida.toByteArray;
    if (Arr = nil) or (Arr.Length <= 0) then Exit;
    SetLength(Result, Arr.Length);
    Move(Arr.Data^, Result[0], Arr.Length);
  finally
    // recycle explicito: sao megabytes por quadro, e esperar o coletor do Java
    // com dez quadros por segundo entrando enche a memoria antes dele acordar.
    Bmp.recycle;
  end;
end;

{$ELSE}

function RgbaParaJpeg(const RGBA: TBytes; W, H, Qualidade: Integer): TBytes;
begin
  // Fora do Android ninguem precisa disto: o Windows decodifica com FFmpeg.
  Result := nil;
end;

{$ENDIF}

end.
