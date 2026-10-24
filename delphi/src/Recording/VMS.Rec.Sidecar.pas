unit VMS.Rec.Sidecar;

// Índice do arquivo que ainda está sendo gravado, num arquivo ao lado:
// `<gravação>.vms.idx`.
//
// Por que existe: o índice do `.vms` (VIDX) só é escrito quando a gravação
// FECHA, e até lá achar um instante custa varrer o arquivo bloco a bloco. Só que
// o arquivo em gravação é justamente o de hoje — o que mais se quer assistir.
// Este arquivo lateral cobre exatamente essa janela.
//
// Quando a gravação fecha direito, o VIDX vai para o fim do `.vms` e o sidecar é
// APAGADO: gravação terminada é auto-suficiente, e não fica meio índice espalhado
// pelo disco. Fechou torto (queda de energia, processo morto)? Aí não há VIDX, e o
// sidecar FICA — é ele que evita a varredura naquele arquivo para sempre.
//
// Formato — tudo little-endian, mesma entrada de 17 bytes do VIDX:
//
//   cabeçalho: 'VIDS' | versão(2) | reservado(2) | creation_unix_ms(8) | crc32(4)
//   lote:      'IDXB' | count(4) | valid_up_to(8)
//              | count × (offset(8) start_unix_ms(8) flags(1)) | crc32(4)
//
// `creation_unix_ms` é o do header do `.vms` e amarra os dois: sidecar que não
// casa é sidecar de outra gravação, e se ignora.
//
// `valid_up_to` é o primeiro offset do `.vms` que aquele lote ainda NÃO cobre —
// é de onde quem lê retoma a varredura para pegar os blocos gravados depois do
// último lote.
//
// A escrita é só append, e o CRC de cada lote é conferido na leitura: um lote
// cortado no meio (queda no meio da escrita) é descartado, e o que vale é tudo
// que veio antes dele. Não há atualização no lugar em lugar nenhum — nem no
// sidecar, nem no `.vms`. É isso que dá a garantia, e não o fato de ser um
// arquivo à parte: o `WriteFile` volta antes de o dado sair do cache do sistema,
// então a cauda de qualquer um dos dois pode simplesmente não existir depois de
// uma queda.
//
// E como são DOIS arquivos, o sistema não os despeja no mesmo instante: dá para
// a queda levar a cauda da mídia e não a do índice, deixando o sidecar apontando
// para blocos que já não existem. Quem lê tem que tratar isso aproveitando o
// prefixo que ainda tem arquivo por baixo — ver TVmsReader.LoadIndexFromSidecar.
// Descartar o sidecar inteiro nesse caso seria varrer aquele arquivo em toda
// subida do servidor, para sempre: ele nunca mais vai ganhar um rodapé.

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  VMS.Rec.Format,
  VMS.Rec.Crc32;

const
  VMS_MAGIC_SIDECAR : array[0..3] of Byte = (Ord('V'), Ord('I'), Ord('D'), Ord('S'));
  VMS_MAGIC_BATCH   : array[0..3] of Byte = (Ord('I'), Ord('D'), Ord('X'), Ord('B'));

  // magic(4) + versão(2) + reservado(2) + creation(8) + crc(4)
  VMS_SIDECAR_HEADER_SIZE = 20;
  // magic(4) + count(4) + validUpTo(8); o crc fica no FIM do lote
  VMS_BATCH_HEADER_SIZE = 16;
  VMS_SIDECAR_VERSION = 1;

  // De quantos em quantos blocos um lote é escrito. 16 blocos são ~32 s e ~290
  // bytes; o que ficar de fora do último lote quem lê recupera varrendo a cauda
  // do `.vms`, que são poucas leituras.
  VMS_SIDECAR_BATCH_BLOCKS = 16;

  // Sanidade contra lote com contagem corrompida, para não pedir uma alocação
  // absurda antes de o CRC ter chance de reprovar.
  VMS_SIDECAR_MAX_BATCH = 1000000;

type
  // Escreve o sidecar enquanto a gravação corre. Falha em qualquer operação
  // desliga o sidecar e a gravação segue sem ele — mídia é o que não pode parar.
  TSidecarWriter = class
  strict private
    FPath: string;
    FStream: TFileStream;
    FOk: Boolean;
    FWritten: Integer;   // entradas já gravadas
  public
    // ACreationUnixMs é o do header do .vms que este sidecar descreve.
    constructor Create(const AVmsPath: string; ACreationUnixMs: Int64);
    destructor Destroy; override;
    // Grava um lote com as entradas de Index[From..Count-1]. ValidUpTo é o
    // primeiro offset do .vms que este lote ainda não cobre (o ponto de append
    // do gravador). Devolve False se o sidecar foi desligado.
    function WriteBatch(const Index: TVmsIndex; Count: Integer; ValidUpTo: Int64): Boolean;
    // Fecha o arquivo. Apaga = a gravação fechou direito e o VIDX ficou no .vms.
    procedure Close(Delete: Boolean);
    function Ok: Boolean;
    function Written: Integer;
    property Path: string read FPath;
  end;

// O caminho do sidecar de uma gravação.
function SidecarPathOf(const VmsPath: string): string;
// Lê o sidecar de VmsPath. CreationUnixMs vem do header do .vms e tem de bater.
// Devolve as entradas dos lotes íntegros e o offset de onde retomar a varredura.
function ReadSidecar(const VmsPath: string; CreationUnixMs: Int64;
                     out Index: TVmsIndex; out ValidUpTo: Int64): Boolean;
// Só as pontas, para quem monta inventário e não precisa do índice.
function SidecarSummary(const VmsPath: string; CreationUnixMs: Int64;
                        out Count: Integer; out FirstMs, LastMs: Int64): Boolean;
// Some com o sidecar de uma gravação. Usado pela retenção, ao apagar o .vms.
procedure DeleteSidecar(const VmsPath: string);

implementation

function SidecarPathOf(const VmsPath: string): string;
begin
  Result := VmsPath + '.idx';
end;

procedure DeleteSidecar(const VmsPath: string);
begin
  try
    if TFile.Exists(SidecarPathOf(VmsPath)) then
      TFile.Delete(SidecarPathOf(VmsPath));
  except
    // Sidecar órfão não estraga nada: ninguém o lê sem o .vms ao lado.
  end;
end;

procedure PutU16(var Buf: TBytes; var Offset: Integer; V: Word);
begin
  Buf[Offset] := Byte(V and $FF);
  Buf[Offset + 1] := Byte((V shr 8) and $FF);
  Inc(Offset, 2);
end;

procedure PutU32(var Buf: TBytes; var Offset: Integer; V: Cardinal);
begin
  Buf[Offset] := Byte(V and $FF);
  Buf[Offset + 1] := Byte((V shr 8) and $FF);
  Buf[Offset + 2] := Byte((V shr 16) and $FF);
  Buf[Offset + 3] := Byte((V shr 24) and $FF);
  Inc(Offset, 4);
end;

procedure PutI64(var Buf: TBytes; var Offset: Integer; V: Int64);
var
  U: UInt64;
  K: Integer;
begin
  U := UInt64(V);
  for K := 0 to 7 do
  begin
    Buf[Offset + K] := Byte(U and $FF);
    U := U shr 8;
  end;
  Inc(Offset, 8);
end;

function GetU16(const Buf: TBytes; var Offset: Integer): Word;
begin
  Result := Word(Buf[Offset]) or (Word(Buf[Offset + 1]) shl 8);
  Inc(Offset, 2);
end;

function GetU32(const Buf: TBytes; var Offset: Integer): Cardinal;
begin
  Result := Cardinal(Buf[Offset]) or (Cardinal(Buf[Offset + 1]) shl 8) or
            (Cardinal(Buf[Offset + 2]) shl 16) or (Cardinal(Buf[Offset + 3]) shl 24);
  Inc(Offset, 4);
end;

function GetI64(const Buf: TBytes; var Offset: Integer): Int64;
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

{ TSidecarWriter }

constructor TSidecarWriter.Create(const AVmsPath: string; ACreationUnixMs: Int64);
var
  Buf: TBytes;
  Offset: Integer;
begin
  inherited Create;
  FPath := SidecarPathOf(AVmsPath);
  FOk := False;
  FWritten := 0;
  try
    // fmShareDenyWrite: o servidor lê este arquivo enquanto ele cresce.
    FStream := TFileStream.Create(FPath, fmCreate or fmShareDenyWrite);
    SetLength(Buf, VMS_SIDECAR_HEADER_SIZE);
    Offset := 0;
    Move(VMS_MAGIC_SIDECAR[0], Buf[Offset], 4); Inc(Offset, 4);
    PutU16(Buf, Offset, VMS_SIDECAR_VERSION);
    PutU16(Buf, Offset, 0);
    PutI64(Buf, Offset, ACreationUnixMs);
    PutU32(Buf, Offset, Crc32Update(0, Buf, 0, Offset));
    FStream.WriteBuffer(Buf[0], Length(Buf));
    FOk := True;
  except
    FreeAndNil(FStream);
    FOk := False;
  end;
end;

destructor TSidecarWriter.Destroy;
begin
  if FStream <> nil then
    FreeAndNil(FStream);
  inherited;
end;

function TSidecarWriter.WriteBatch(const Index: TVmsIndex; Count: Integer;
  ValidUpTo: Int64): Boolean;
var
  Buf: TBytes;
  Offset, I, N: Integer;
begin
  Result := False;
  if (not FOk) or (FStream = nil) then Exit;
  N := Count - FWritten;
  if N <= 0 then Exit;
  try
    SetLength(Buf, VMS_BATCH_HEADER_SIZE + N * VMS_INDEX_ENTRY_SIZE + 4);
    Offset := 0;
    Move(VMS_MAGIC_BATCH[0], Buf[Offset], 4); Inc(Offset, 4);
    PutU32(Buf, Offset, Cardinal(N));
    PutI64(Buf, Offset, ValidUpTo);
    for I := FWritten to Count - 1 do
    begin
      PutI64(Buf, Offset, Index[I].Offset);
      PutI64(Buf, Offset, Index[I].StartUnixMs);
      Buf[Offset] := Index[I].Flags; Inc(Offset);
    end;
    PutU32(Buf, Offset, Crc32Update(0, Buf, 0, Offset));
    // Um WriteBuffer só: lote pela metade no disco é lote que o CRC reprova, e
    // o que vale continua sendo tudo que veio antes dele.
    FStream.WriteBuffer(Buf[0], Length(Buf));
    FWritten := Count;
    Result := True;
  except
    // Falhou uma vez, desliga: quem lê cai na varredura, que é lenta mas certa.
    FOk := False;
    FreeAndNil(FStream);
  end;
end;

procedure TSidecarWriter.Close(Delete: Boolean);
begin
  if FStream <> nil then
  begin
    try
      FreeAndNil(FStream);
    except
      FStream := nil;
    end;
  end;
  FOk := False;
  if Delete then
    try
      if TFile.Exists(FPath) then
        TFile.Delete(FPath);
    except
      // Não deu para apagar agora: fica um sidecar ao lado de um .vms que já tem
      // VIDX. Quem lê prefere o rodapé, então isto é lixo, não erro.
    end;
end;

function TSidecarWriter.Ok: Boolean;
begin
  Result := FOk;
end;

function TSidecarWriter.Written: Integer;
begin
  Result := FWritten;
end;

function ReadSidecar(const VmsPath: string; CreationUnixMs: Int64;
  out Index: TVmsIndex; out ValidUpTo: Int64): Boolean;
var
  Stream: TFileStream;
  Buf, Head: TBytes;
  Offset, Count, Total, I, Need: Integer;
  Version: Word;
  Creation, Size: Int64;
  Crc: Cardinal;
begin
  Result := False;
  Index := nil;
  ValidUpTo := 0;
  if not TFile.Exists(SidecarPathOf(VmsPath)) then Exit;
  try
    Stream := TFileStream.Create(SidecarPathOf(VmsPath), fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    Size := Stream.Size;
    if Size < VMS_SIDECAR_HEADER_SIZE then Exit;
    SetLength(Head, VMS_SIDECAR_HEADER_SIZE);
    if Stream.Read(Head[0], VMS_SIDECAR_HEADER_SIZE) <> VMS_SIDECAR_HEADER_SIZE then Exit;
    if (Head[0] <> VMS_MAGIC_SIDECAR[0]) or (Head[1] <> VMS_MAGIC_SIDECAR[1]) or
       (Head[2] <> VMS_MAGIC_SIDECAR[2]) or (Head[3] <> VMS_MAGIC_SIDECAR[3]) then Exit;
    Offset := VMS_SIDECAR_HEADER_SIZE - 4;
    Crc := GetU32(Head, Offset);
    if Crc32Update(0, Head, 0, VMS_SIDECAR_HEADER_SIZE - 4) <> Crc then Exit;
    Offset := 4;
    Version := GetU16(Head, Offset);
    if Version <> VMS_SIDECAR_VERSION then Exit;
    GetU16(Head, Offset); // reservado
    Creation := GetI64(Head, Offset);
    // Sidecar de outra gravação (nome reaproveitado, arquivo copiado por cima):
    // ignora. Índice que não é deste arquivo é pior que índice nenhum.
    if Creation <> CreationUnixMs then Exit;

    Total := 0;
    SetLength(Index, 256);
    while Stream.Position + VMS_BATCH_HEADER_SIZE <= Size do
    begin
      SetLength(Head, VMS_BATCH_HEADER_SIZE);
      if Stream.Read(Head[0], VMS_BATCH_HEADER_SIZE) <> VMS_BATCH_HEADER_SIZE then Break;
      if (Head[0] <> VMS_MAGIC_BATCH[0]) or (Head[1] <> VMS_MAGIC_BATCH[1]) or
         (Head[2] <> VMS_MAGIC_BATCH[2]) or (Head[3] <> VMS_MAGIC_BATCH[3]) then Break;
      Offset := 4;
      Count := Integer(GetU32(Head, Offset));
      if (Count <= 0) or (Count > VMS_SIDECAR_MAX_BATCH) then Break;
      Need := Count * VMS_INDEX_ENTRY_SIZE + 4;
      // Lote cortado: é o que a gravação em curso deixa no fim do arquivo.
      if Stream.Position + Need > Size then Break;
      SetLength(Buf, Need);
      if Stream.Read(Buf[0], Need) <> Need then Break;
      Offset := Need - 4;
      Crc := GetU32(Buf, Offset);
      // O CRC cobre o cabeçalho do lote E as entradas: cabeçalho intacto com
      // entradas pela metade é exatamente o que uma queda de energia produz.
      if Crc32Update(Crc32Update(0, Head, 0, VMS_BATCH_HEADER_SIZE),
                     Buf, 0, Need - 4) <> Crc then Break;

      if Total + Count > Length(Index) then
        SetLength(Index, (Total + Count) * 2);
      Offset := 0;
      for I := 0 to Count - 1 do
      begin
        Index[Total + I].Offset := GetI64(Buf, Offset);
        Index[Total + I].StartUnixMs := GetI64(Buf, Offset);
        Index[Total + I].Flags := Buf[Offset]; Inc(Offset);
      end;
      Inc(Total, Count);
      Offset := 8;
      ValidUpTo := GetI64(Head, Offset);
    end;
    SetLength(Index, Total);
    Result := (Total > 0) and (ValidUpTo > 0);
    if not Result then
    begin
      Index := nil;
      ValidUpTo := 0;
    end;
  finally
    Stream.Free;
  end;
end;

function SidecarSummary(const VmsPath: string; CreationUnixMs: Int64;
  out Count: Integer; out FirstMs, LastMs: Int64): Boolean;
var
  Index: TVmsIndex;
  ValidUpTo: Int64;
begin
  Count := 0;
  FirstMs := 0;
  LastMs := 0;
  Result := ReadSidecar(VmsPath, CreationUnixMs, Index, ValidUpTo);
  if not Result then Exit;
  Count := Length(Index);
  FirstMs := Index[0].StartUnixMs;
  LastMs := Index[Count - 1].StartUnixMs;
end;

end.
