unit Vms.Server.UiFiles;

// A interface vem de arquivos, e só deles.
//
// HTML, CSS e JavaScript são fonte, moram em `src/UI/web`, e o que o servidor
// serve é o arquivo -- não uma cópia dele embutida no executável. Isso é uma
// decisão, e vale escrever por quê.
//
// Já foi ao contrário: as páginas eram convertidas em units Pascal por um
// gerador e compiladas junto. O programa ficava um arquivo só, e cada linha de
// CSS custava gerar a unit, recompilar e reabrir. Pior, havia duas verdades
// possíveis para a mesma tela -- o arquivo e a cópia da última compilação --, e
// nada avisava quando elas divergiam.
//
// Agora há uma verdade só. O preço é a pasta ter de acompanhar o executável.
//
//   Windows   `ui` ao lado do executável. No desenvolvimento é uma junção para
//             `src/UI/web`, criada pelo pós-build do vmsserver na primeira
//             compilação; para instalar em outra máquina, copia-se a pasta
//             junto com o executável.
//
//   Android   a pasta interna do app (TPath.GetDocumentsPath), onde o Delphi
//             deposita, na instalação, o que foi mandado no Deployment com o
//             caminho remoto `assets\internal\ui\`. Ao lado do executável ali
//             seria uma pasta do sistema, onde nada se escreve.
//
// Onde a pasta está, em ordem: a variável de ambiente VMS_UI_DIR, se apontar
// para uma pasta que existe; senão o padrão de cada plataforma, acima.
//
// A variável é para a máquina de quem desenvolve: apontando-a para
// `src/UI/web`, a interface servida é o fonte, e editar e recarregar volta a
// bastar -- sem cópia no meio, e sem depender de compilar. E como ela é da
// máquina, e não do projeto, quem instala o programa não tem nada a desligar.
//
// Ela ganha do padrão de propósito. Fosse ao contrário -- pasta primeiro, e a
// variável só quando não houvesse pasta --, ela nunca valeria na máquina de
// desenvolvimento, que é justamente onde a pasta sempre existe (o pós-build
// copia a cada compilação).
//
// O nome do arquivo nunca vem do cliente: as rotas são fixas e cada uma cita o
// arquivo dela, então não há caminho para atravessar.
//
// Nada fica em cache. O arquivo é lido a cada pedido, que é o que faz salvar e
// recarregar bastar -- e custa ler algumas dezenas de KB de um disco que o
// sistema já mantém em cache.

interface

uses
  System.SysUtils,
  System.IOUtils;

// A variável de ambiente que aponta a pasta da interface.
const
  UI_VAR = 'VMS_UI_DIR';

// A pasta de onde a interface vem: a da variável, se ela apontar para algo que
// existe; senão a padrão da plataforma.
function UiDir: string;

// A pasta padrão, ignorando a variável.
function UiDirPadrao: string;

// Ela existe?
function UiDirAtivo: Boolean;

// Uma linha dizendo qual pasta está valendo e por quê -- inclusive quando a
// variável está definida e foi ignorada, que é o engano fácil de cometer e
// impossível de perceber sem isto.
function UiExplicacao: string;

// O conteúdo do arquivo. Vazio = não está lá, e quem chama responde 404 em vez
// de mandar página em branco: sem embutido para cair, sumir calado seria o
// mesmo que a tela nunca ter existido.
function UiTexto(const NomeArquivo: string): string;

// Todos os arquivos que as rotas pedem. Uma lista só, para os dois servidores
// concordarem sobre o que a pasta precisa ter.
function UiArquivos: TArray<string>;

// Os que faltam na pasta, em uma linha. Vazio = está tudo lá.
//
// É o que o servidor diz no log ao subir. Descobrir pelo navegador que um
// arquivo não foi copiado custa uma tela quebrada e nenhuma pista.
function UiFaltando: string;

implementation

function UiDirPadrao: string;
begin
{$IFDEF ANDROID}
  Result := TPath.Combine(TPath.GetDocumentsPath, 'ui');
{$ELSE}
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'ui');
{$ENDIF}
end;

// O que a variável diz, sem julgar se existe. Vazio = não está definida.
function UiDirDaVariavel: string;
begin
  Result := Trim(GetEnvironmentVariable(UI_VAR));
  if Result <> '' then
    Result := ExcludeTrailingPathDelimiter(Result);
end;

function UiDir: string;
var
  Apontada: string;
begin
  Apontada := UiDirDaVariavel;
  // Definida mas apontando para o nada NÃO vale: seria trocar a interface
  // inteira por um erro de digitação. Cai no padrão, e o UiExplicacao conta.
  if (Apontada <> '') and TDirectory.Exists(Apontada) then Exit(Apontada);
  Result := UiDirPadrao;
end;

function UiExplicacao: string;
var
  Apontada: string;
begin
  Apontada := UiDirDaVariavel;
  if Apontada = '' then
    Exit(UiDirPadrao + ' (ao lado do executavel)');
  if TDirectory.Exists(Apontada) then
    Exit(Apontada + ' (' + UI_VAR + ')');
  Result := UiDirPadrao + ' (ao lado do executavel; ' + UI_VAR +
            ' aponta para ' + Apontada + ', que nao existe)';
end;

function UiDirAtivo: Boolean;
begin
  Result := TDirectory.Exists(UiDir);
end;

function UiTexto(const NomeArquivo: string): string;
var
  Caminho: string;
begin
  Result := '';
  if NomeArquivo = '' then Exit;
  Caminho := TPath.Combine(UiDir, NomeArquivo);
  if not TFile.Exists(Caminho) then Exit;
  try
    Result := TFile.ReadAllText(Caminho, TEncoding.UTF8);
    // Um U+FEFF sobrando na frente do arquivo é erro de sintaxe dentro de um
    // <script>, e não se vê olhando.
    if (Length(Result) > 0) and (Result[1] = #$FEFF) then Delete(Result, 1, 1);
  except
    // Ilegível: sendo salvo neste instante, permissão, disco. Vazio faz quem
    // chama responder 404, que é melhor do que meia página.
    Result := '';
  end;
end;

function UiArquivos: TArray<string>;
begin
  Result := TArray<string>.Create(
    'app-ui.html', 'player-ui.html', 'events-ui.html', 'motion-ui.html',
    'login-ui.html', 'player.js', 'vmsreader.js', 'favicon.svg');
end;

function UiFaltando: string;
var
  Nome: string;
begin
  Result := '';
  for Nome in UiArquivos do
  begin
    if TFile.Exists(TPath.Combine(UiDir, Nome)) then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + Nome;
  end;
end;

end.
