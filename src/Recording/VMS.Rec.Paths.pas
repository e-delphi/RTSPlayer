unit VMS.Rec.Paths;

// Onde cada gravação mora: <storageDir>\<câmera>\<arquivo>.vms
//
// Uma pasta por câmera. Com tudo numa pasta só, três câmeras gravando um
// arquivo por hora enchem o diretório de milhares de arquivos misturados, e
// tanto o Explorer quanto qualquer varredura pagam por isso — inclusive a
// listagem que o app faz para montar a timeline, que precisa filtrar por prefixo
// o que agora é só "o que está na pasta dela".
//
// O nome do arquivo continua trazendo o nome da câmera ({name}_{data}.vms): ele
// é o que identifica a gravação fora do disco (log, API, cursor de playback), e
// depender da pasta para saber de quem é o arquivo tornaria o nome ambíguo se
// alguém o copiasse para outro lugar.
//
// Quem descobre a câmera de um arquivo deve preferir a PASTA ao prefixo do nome:
// nome de câmera com '_' quebra a leitura por prefixo, a pasta não.

interface

uses
  System.SysUtils,
  System.IOUtils;

// Nome de pasta seguro a partir do nome da câmera. Fora de [A-Za-z0-9._-] vira
// '_' — o mesmo alfabeto que a API aceita em nome de arquivo (IsSafeVmsName),
// para que nada que chegue de fora consiga sair da pasta de gravações.
function CameraFolderName(const Camera: string): string;

// <storageDir>\<pasta da câmera>, sem criar nada. StorageDir vazio vira
// 'recordings' (mesmo padrão dos gravadores).
function CameraDir(const StorageDir, Camera: string): string;

// Igual ao anterior, criando a pasta se não existir. É o que os gravadores usam
// antes de abrir o arquivo.
function EnsureCameraDir(const StorageDir, Camera: string): string;

// Caminho ainda livre para uma gravação nova. O padrão de nome tem resolução de
// segundo, e a gravação roda de arquivo quando a região de índice enche — duas
// trocas no mesmo segundo dariam o mesmo nome, e o writer abre com fmCreate, ou
// seja, por cima. Isto apagaria a gravação que acabou de fechar.
function UniqueRecordingPath(const Path: string): string;

implementation

function CameraFolderName(const Camera: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(Camera) do
  begin
    C := Camera[I];
    if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-']) then
      Result := Result + C
    else
      Result := Result + '_';
  end;
  // Windows não guarda pasta terminada em ponto ou espaço, e '.'/'..' seriam
  // outra coisa completamente diferente.
  while (Result <> '') and CharInSet(Result[Length(Result)], ['.', ' ']) do
    SetLength(Result, Length(Result) - 1);
  if Result = '' then
    Result := 'camera';
end;

function CameraDir(const StorageDir, Camera: string): string;
var
  Base: string;
begin
  Base := StorageDir;
  if Base = '' then Base := 'recordings';
  Base := ExpandFileName(Base);
  Result := IncludeTrailingPathDelimiter(Base) + CameraFolderName(Camera);
end;

function EnsureCameraDir(const StorageDir, Camera: string): string;
begin
  Result := CameraDir(StorageDir, Camera);
  if not DirectoryExists(Result) then
    ForceDirectories(Result);
end;

function UniqueRecordingPath(const Path: string): string;
var
  Dir, Base, Ext: string;
  I: Integer;
begin
  Result := Path;
  if not FileExists(Result) then Exit;
  Dir := ExtractFilePath(Path);
  Ext := ExtractFileExt(Path);
  Base := ChangeFileExt(ExtractFileName(Path), '');
  for I := 2 to 999 do
  begin
    Result := Dir + Base + '-' + IntToStr(I) + Ext;
    if not FileExists(Result) then Exit;
  end;
  // 999 arquivos no mesmo segundo é outro problema; melhor devolver algo que
  // não existe do que sobrescrever gravação.
  Result := Dir + Base + '-' + IntToStr(Random(1000000)) + Ext;
end;

end.
