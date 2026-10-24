unit VMS.Rec.Crc32;

interface

uses
  System.SysUtils;

function Crc32Update(Crc: Cardinal; const Data: TBytes; Offset, Count: Integer): Cardinal; overload;
function Crc32Update(Crc: Cardinal; Data: PByte; Count: Integer): Cardinal; overload;
function Crc32Compute(const Data: TBytes): Cardinal;

implementation

var
  GCrcTable: array[0..255] of Cardinal;
  GCrcInit: Boolean;

procedure InitCrcTable;
var
  I, J: Integer;
  C: Cardinal;
begin
  for I := 0 to 255 do
  begin
    C := Cardinal(I);
    for J := 0 to 7 do
    begin
      if (C and 1) <> 0 then
        C := $EDB88320 xor (C shr 1)
      else
        C := C shr 1;
    end;
    GCrcTable[I] := C;
  end;
  GCrcInit := True;
end;

function Crc32Update(Crc: Cardinal; const Data: TBytes; Offset, Count: Integer): Cardinal;
begin
  if Count <= 0 then Exit(Crc);
  Result := Crc32Update(Crc, @Data[Offset], Count);
end;

function Crc32Update(Crc: Cardinal; Data: PByte; Count: Integer): Cardinal;
var
  I: Integer;
begin
  if not GCrcInit then InitCrcTable;
  Result := Crc xor $FFFFFFFF;
  for I := 0 to Count - 1 do
    Result := GCrcTable[Byte(Result xor Data[I])] xor (Result shr 8);
  Result := Result xor $FFFFFFFF;
end;

function Crc32Compute(const Data: TBytes): Cardinal;
begin
  Result := Crc32Update(0, Data, 0, Length(Data));
end;

initialization
  InitCrcTable;

end.
