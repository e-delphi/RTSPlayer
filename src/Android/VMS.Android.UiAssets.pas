unit VMS.Android.UiAssets;

// Deixa a pasta da interface igual à que veio dentro do pacote instalado.
//
// ## O problema que isto resolve
//
// No Android a interface não é lida de dentro do APK: ela é copiada para uma
// pasta gravável (ver Vms.Server.UiFiles) e servida de lá. Quem faz essa cópia
// é a `System.StartUpCopy` da RTL, e ela só CRIA o que falta -- nunca
// sobrescreve o que já existe.
//
// O efeito é traiçoeiro. Instalar uma versão nova por cima leva os arquivos
// novos para dentro do APK, mas o aparelho continua servindo os antigos. A tela
// se comporta como uma versão velha enquanto o Delphi já é o novo, e a procura
// pelo defeito começa no lugar errado -- foi exatamente o que aconteceu: uma
// página de seis dias atrás, sem a folha de estilo comum e sem a PTZ, servida
// por um binário que tinha as duas coisas.
//
// A saída oficial é desinstalar antes de instalar. Isso funciona e é o que
// ninguém faz, porque leva junto o cadastro e as gravações do aparelho.
//
// ## O que fazemos
//
// O APK é um zip, e o caminho dele o próprio Android informa. Na subida, lemos
// as entradas de `assets/internal/ui/` e gravamos todas por cima. Assim a
// interface servida é SEMPRE a do binário que está rodando, e a pergunta "será
// que a página é a nova?" deixa de existir.
//
// Grava sem comparar, de propósito. O conteúdo já está descompactado na mão
// quando a comparação seria feita, e comparar custa ler o arquivo inteiro do
// disco para, no caso comum, concluir que não há nada a fazer -- e no caso
// incomum ainda pagar a gravação depois. São umas dezenas de KB por abertura,
// uma vez só, antes de a primeira tela existir.
//
// E a garantia fica incondicional: a pasta É a do pacote, sem "se".

interface

uses
  VMS.Domain.Logging;

// Chame UMA vez, na subida, antes de o servidor local começar a servir. Fora do
// Android não faz nada: lá a pasta é o próprio fonte.
procedure AtualizarUiDoPacote(const Logger: ILogger);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Zip,
  Vms.Server.UiFiles
{$IFDEF ANDROID}
  , Androidapi.Helpers
  , Androidapi.JNI.JavaTypes
{$ENDIF}
  ;

{$IFDEF ANDROID}
// Onde o Android guarda o APK desta aplicação.
function CaminhoDoPacote: string;
begin
  Result := JStringToString(TAndroidHelper.Context.getPackageCodePath);
end;

{$ENDIF}

procedure AtualizarUiDoPacote(const Logger: ILogger);
{$IFDEF ANDROID}
const
  // O mesmo prefixo que o Deployment do projeto usa como RemoteDir.
  PREFIXO = 'assets/internal/ui/';
var
  Apk, Nome, Alvo, Pasta: string;
  Zip: TZipFile;
  Dados: TBytes;
  Copiados, Bytes: Integer;
{$ENDIF}
begin
{$IFDEF ANDROID}
  // A pasta PADRÃO, e não a de UiDir: a variável de ambiente é para a máquina
  // de quem desenvolve, e sobrescrever o fonte apontado por ela seria o
  // contrário do que ela serve.
  Pasta := UiDirPadrao;
  Copiados := 0;
  Bytes := 0;
  Zip := TZipFile.Create;
  try
    try
      Apk := CaminhoDoPacote;
      if not TFile.Exists(Apk) then
      begin
        if Logger <> nil then
          Logger.Warn('ui', 'nao achei o pacote em ' + Apk);
        Exit;
      end;
      if not TDirectory.Exists(Pasta) then
        TDirectory.CreateDirectory(Pasta);

      Zip.Open(Apk, zmRead);
      for Nome in Zip.FileNames do
      begin
        if not Nome.StartsWith(PREFIXO) then Continue;
        Zip.Read(Nome, Dados);
        Alvo := TPath.Combine(Pasta, Copy(Nome, Length(PREFIXO) + 1, MaxInt));
        TFile.WriteAllBytes(Alvo, Dados);
        Inc(Copiados);
        Inc(Bytes, Length(Dados));
      end;
    except
      // Pacote ilegível ou pasta sem permissão: o app continua com o que já
      // está lá, que é o comportamento de antes desta unit existir. Interface
      // desatualizada é um incômodo; não subir é uma falha.
      on E: Exception do
        if Logger <> nil then
          Logger.Warn('ui', 'nao consegui atualizar a interface pelo pacote: ' +
                            E.Message);
    end;
  finally
    Zip.Free;
  end;
  // Uma linha, e não uma por arquivo: agora que a cópia é incondicional, o que
  // interessa é ela ter acontecido. Nenhum arquivo copiado é que seria notícia.
  if Logger <> nil then
    if Copiados > 0 then
      Logger.Info('ui', Format('interface do pacote: %d arquivos, %d bytes',
                               [Copiados, Bytes]))
    else
      Logger.Warn('ui', 'o pacote nao trouxe interface nenhuma');
{$ENDIF}
end;

end.
