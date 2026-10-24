unit VMS.Android.JNIUtil;

// Pequenos helpers JNI para mover bytes entre Delphi e java.nio.ByteBuffer
// usando o endereço direto do buffer (zero-cópia via memcpy nativo).

{$IFDEF ANDROID}
interface

uses
  System.SysUtils,
  Androidapi.Jni,
  Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes;

// Endereço nativo de um ByteBuffer direto (nil se não for direto).
function DirectBufferAddress(const Buf: JByteBuffer): PByte;

// Aloca um ByteBuffer direto e copia os bytes para dentro.
function BytesToDirectBuffer(const B: TBytes): JByteBuffer;

// Copia Src[0..Len-1] para dentro de um ByteBuffer direto (limpa antes).
procedure CopyToDirectBuffer(const Buf: JByteBuffer; const Src: TBytes; Len: Integer);

// Converte TBytes em um array Java (byte[]) — usado por AudioTrack.write.
function BytesToJavaArray(const Src: TBytes; Len: Integer): TJavaArray<Byte>;

implementation

function DirectBufferAddress(const Buf: JByteBuffer): PByte;
var
  Env: PJNIEnv;
begin
  if Buf = nil then Exit(nil);
  Env := TJNIResolver.GetJNIEnv;
  Result := PByte(Env^.GetDirectBufferAddress(Env, (Buf as ILocalObject).GetObjectID));
end;

function BytesToDirectBuffer(const B: TBytes): JByteBuffer;
var
  P: PByte;
begin
  Result := TJByteBuffer.JavaClass.allocateDirect(Length(B));
  if Length(B) > 0 then
  begin
    P := DirectBufferAddress(Result);
    if P <> nil then
      Move(B[0], P^, Length(B));
  end;
end;

procedure CopyToDirectBuffer(const Buf: JByteBuffer; const Src: TBytes; Len: Integer);
var
  P: PByte;
begin
  if (Buf = nil) or (Len <= 0) then Exit;
  Buf.clear;
  P := DirectBufferAddress(Buf);
  if P <> nil then
    Move(Src[0], P^, Len);
end;

function BytesToJavaArray(const Src: TBytes; Len: Integer): TJavaArray<Byte>;
var
  I: Integer;
begin
  Result := TJavaArray<Byte>.Create(Len);
  for I := 0 to Len - 1 do
    Result.Items[I] := Src[I];
end;

{$ELSE}

// Fora do Android esta unit nao existe de fato: ela fala JNI direto, e so entra
// no projeto porque a lista de units do .dpr vale para todas as plataformas.
interface

implementation

{$ENDIF}

end.
