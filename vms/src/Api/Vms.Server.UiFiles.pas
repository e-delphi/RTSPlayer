unit Vms.Server.UiFiles;

// A interface, quando ela estiver em disco.
//
// As páginas são embutidas no executável (ver tools/gen_ui_pas.py) porque é
// isso que faz o programa ser um arquivo só. O preço aparece na hora de mexer
// nelas: trocar uma linha de CSS custava gerar a unit, recompilar e reabrir.
//
// Existindo uma pasta `ui` ao lado do executável, cada arquivo dela substitui o
// embutido correspondente. Editar e recarregar a página passa a bastar, e o
// executável continua o mesmo. Sem a pasta, nada muda: o embutido é o padrão, e
// é ele que vai para quem instala.
//
// A pasta é o interruptor inteiro -- não há ajuste a lembrar de desligar depois.
// O nome do arquivo nunca vem do cliente: as rotas são fixas e cada uma cita o
// arquivo dela aqui dentro, então não há caminho para atravessar.
//
// O conteúdo NÃO fica em cache. É para desenvolvimento, e cache aqui só serviria
// para mostrar o arquivo velho depois de salvar o novo.

interface

uses
  System.SysUtils,
  System.IOUtils;

// A pasta `ui` ao lado do executável. Existindo ou não.
function UiDir: string;

// Ela existe? Serve para o servidor dizer isso no log ao subir -- uma pasta
// esquecida ali mudaria a interface sem nenhum outro sinal.
function UiDirAtivo: Boolean;

// O conteúdo do arquivo, se ele estiver na pasta; senão o embutido que veio
// junto. É por aqui que cada rota passa.
function UiTexto(const NomeArquivo, Embutido: string): string;

implementation

function UiDir: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'ui');
end;

function UiDirAtivo: Boolean;
begin
  Result := TDirectory.Exists(UiDir);
end;

function UiTexto(const NomeArquivo, Embutido: string): string;
var
  Caminho: string;
begin
  Result := Embutido;
  if NomeArquivo = '' then Exit;
  Caminho := TPath.Combine(UiDir, NomeArquivo);
  if not TFile.Exists(Caminho) then Exit;
  try
    Result := TFile.ReadAllText(Caminho, TEncoding.UTF8);
  except
    // Arquivo ilegível (sendo salvo neste instante, permissão, disco): o
    // embutido é uma resposta melhor do que meia página ou uma exceção.
    Result := Embutido;
  end;
end;

end.
