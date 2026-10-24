unit Vms.Thumb.Cache;

// O cache de miniaturas em disco. Sabe de pastas e arquivos, e de mais nada:
// não conhece codec, nem `.vms`, nem HTTP.
//
// Layout, uma pasta por dia para o diretório não virar um despejo de 1.440
// arquivos por dia acumulados para sempre:
//
//   <pasta do executável>/cache/<câmera>/thumbs/2026-08-22/1437.jpg
//
// A chave é o MINUTO: toda consulta dentro do mesmo minuto cai no mesmo
// arquivo. Um minuto é o passo que o player usa para preencher a barra, e é
// grosso o bastante para o cache de um dia inteiro caber em poucos MB (~4 KB por
// imagem, ~6 MB por dia por câmera).
//
// O minuto é contado no fuso LOCAL, porque o nome da pasta e do arquivo existem
// para alguém conseguir olhar o diretório e entender o que está vendo.
//
// A raiz é FIXA, ao lado do executável, e não configurável nem dentro do
// storageDir. São coisas de naturezas diferentes: gravação é o dado, e vai para
// o disco grande que o usuário escolheu; miniatura é cache descartável, some
// sem consequência e é regenerada. Misturar as duas fazia a pasta de gravações
// carregar peso que ninguém precisa mover num backup.

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  System.Classes,
  VMS.Rec.Paths;

// <pasta do executável>\cache — a raiz de tudo o que é descartável.
function DefaultCacheDir: string;

type
  TThumbDiskCache = class
  strict private
    FStorageDir: string;
    function DayDir(const Camera: string; MinuteMs: Int64): string;
  public
    constructor Create(const AStorageDir: string);
    // O começo do minuto que contém Ms. É a chave de tudo aqui.
    class function MinuteOf(Ms: Int64): Int64; static;
    function PathOf(const Camera: string; MinuteMs: Int64): string;
    function TryRead(const Camera: string; MinuteMs: Int64;
                     out Data: TBytes): Boolean;
    // Grava fora do lugar e move por cima: quem estiver lendo vê o arquivo
    // inteiro ou nenhum, nunca meio JPEG.
    procedure Write(const Camera: string; MinuteMs: Int64; const Data: TBytes);
    // Apaga as pastas de dia anteriores a KeepFromMs. Chamada pela retenção:
    // miniatura de gravação que já foi embora é lixo que ninguém mais remove.
    function PruneOlderThan(const Camera: string; KeepFromMs: Int64): Integer;
  end;

implementation

const
  THUMBS_DIR = 'thumbs';
  CACHE_DIR = 'cache';
  ONE_MINUTE_MS = Int64(60000);

function DefaultCacheDir: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), CACHE_DIR);
end;

constructor TThumbDiskCache.Create(const AStorageDir: string);
begin
  inherited Create;
  FStorageDir := AStorageDir;
end;

class function TThumbDiskCache.MinuteOf(Ms: Int64): Int64;
begin
  if Ms < 0 then Exit(0);
  Result := (Ms div ONE_MINUTE_MS) * ONE_MINUTE_MS;
end;

// Data local, para a pasta ser legível por quem abrir o diretório.
function TThumbDiskCache.DayDir(const Camera: string; MinuteMs: Int64): string;
var
  DT: TDateTime;
begin
  DT := TTimeZone.Local.ToLocalTime(UnixToDateTime(MinuteMs div 1000, True));
  Result := TPath.Combine(TPath.Combine(CameraDir(FStorageDir, Camera), THUMBS_DIR),
                          FormatDateTime('yyyy-mm-dd', DT));
end;

function TThumbDiskCache.PathOf(const Camera: string; MinuteMs: Int64): string;
var
  DT: TDateTime;
begin
  DT := TTimeZone.Local.ToLocalTime(UnixToDateTime(MinuteMs div 1000, True));
  Result := TPath.Combine(DayDir(Camera, MinuteMs),
                          FormatDateTime('hhnn', DT) + '.jpg');
end;

function TThumbDiskCache.TryRead(const Camera: string; MinuteMs: Int64;
  out Data: TBytes): Boolean;
var
  Path: string;
begin
  Data := nil;
  Result := False;
  Path := PathOf(Camera, MinuteMs);
  try
    if not TFile.Exists(Path) then Exit;
    Data := TFile.ReadAllBytes(Path);
    // Arquivo vazio é resto de uma gravação interrompida: trata como ausente,
    // e a próxima tentativa regenera.
    Result := Length(Data) > 0;
  except
    Result := False;
  end;
end;

procedure TThumbDiskCache.Write(const Camera: string; MinuteMs: Int64;
  const Data: TBytes);
var
  Path, Tmp, Dir: string;
begin
  if Length(Data) = 0 then Exit;
  Path := PathOf(Camera, MinuteMs);
  Tmp := Path + '.tmp';
  try
    Dir := DayDir(Camera, MinuteMs);
    if not TDirectory.Exists(Dir) then
      TDirectory.CreateDirectory(Dir);
    TFile.WriteAllBytes(Tmp, Data);
    if TFile.Exists(Path) then TFile.Delete(Path);
    TFile.Move(Tmp, Path);
  except
    // Cache é otimização: não conseguir gravar não pode impedir a resposta.
    try
      if TFile.Exists(Tmp) then TFile.Delete(Tmp);
    except
    end;
  end;
end;

function TThumbDiskCache.PruneOlderThan(const Camera: string;
  KeepFromMs: Int64): Integer;
var
  Root, Name: string;
  Dirs: TArray<string>;
  I: Integer;
  Limite: TDateTime;
  Dia: TDateTime;
begin
  Result := 0;
  Root := TPath.Combine(CameraDir(FStorageDir, Camera), THUMBS_DIR);
  if not TDirectory.Exists(Root) then Exit;
  Limite := DateOf(TTimeZone.Local.ToLocalTime(
              UnixToDateTime(KeepFromMs div 1000, True)));
  try
    Dirs := TDirectory.GetDirectories(Root);
  except
    Exit;
  end;
  for I := 0 to High(Dirs) do
  begin
    Name := ExtractFileName(ExcludeTrailingPathDelimiter(Dirs[I]));
    // Só apaga pasta que o próprio cache criou, e cujo nome ele entende: um
    // diretório com outro nome ali dentro não é problema nosso.
    if not TryEncodeDate(StrToIntDef(Copy(Name, 1, 4), 0),
                         StrToIntDef(Copy(Name, 6, 2), 0),
                         StrToIntDef(Copy(Name, 9, 2), 0), Dia) then Continue;
    if Length(Name) <> 10 then Continue;
    if Dia >= Limite then Continue;
    try
      TDirectory.Delete(Dirs[I], True);
      Inc(Result);
    except
      // em uso, ou sem permissão: fica para a próxima varredura
    end;
  end;
end;

end.
