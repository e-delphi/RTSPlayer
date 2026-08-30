unit VMS.Win.Edge;

// Faz o TWebBrowser do Windows usar o Edge (WebView2), e nao o Internet
// Explorer.
//
// ## Por que isto precisa existir
//
// O FMX tem suporte a WebView2 embutido, mas o padrao dele nao e esse: em
// FMX.WebBrowser.pas o campo nasce como `TWindowsEngine.IEOnly`. Sem trocar,
// o app roda no Trident — que nao tem WebCodecs, nem canvas moderno, nem nada
// do que a interface em HTML depende.
//
// O NoOBS chega no mesmo motor por outro caminho: ele fala COM direto com o
// WebView2Loader.dll. Aqui nao vale repetir isso — o FMX ja faz essa plumbing,
// e o que faltava era uma linha de configuracao.
//
// ## A pasta de dados
//
// O WebView2 precisa de uma pasta gravavel para cache, cookies e estado. Sem
// dizer qual, ele tenta criar ao lado do executavel, e falha quando o app esta
// em Program Files. Por isso a escolha e explicita, em LOCALAPPDATA — o mesmo
// lugar que o NoOBS usa.

interface

uses
  FMX.WebBrowser;   // TWindowsEngine, comum a todas as plataformas

// Chame UMA vez, antes de criar qualquer TWebBrowser. Em plataforma que nao e
// Windows nao faz nada, e por isso pode ser chamada sem IFDEF em volta.
procedure ConfigurarEdge;

// O motor que o TWebBrowser deve usar. Devolve `None` fora do Windows, que e o
// valor que o FMX espera nas outras plataformas. O tipo vem do FMX.WebBrowser,
// que e comum a todas elas -- so o TGlobalEdgeBrowserSettings e do Windows.
function MotorPreferido: TWindowsEngine;

implementation

uses
  System.SysUtils,
  System.IOUtils
{$IFDEF MSWINDOWS}
  , FMX.WebBrowser.Win
{$ENDIF}
  ;

function MotorPreferido: TWindowsEngine;
begin
{$IFDEF MSWINDOWS}
  // EdgeIfAvailable, e nao EdgeOnly: sem o runtime do WebView2 instalado, o
  // EdgeOnly levanta excecao e o app morre na abertura. Assim ele cai para o
  // IE, a interface avisa que nao ha WebCodecs, e o usuario tem o que ler em
  // vez de um app que fecha sozinho.
  Result := TWindowsEngine.EdgeIfAvailable;
{$ELSE}
  Result := TWindowsEngine.None;
{$ENDIF}
end;

procedure ConfigurarEdge;
{$IFDEF MSWINDOWS}
var
  Dir: string;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Dir := TPath.Combine(TPath.GetHomePath, 'RTSPlayer');
  Dir := TPath.Combine(Dir, 'WebView2');
  try
    if not TDirectory.Exists(Dir) then
      TDirectory.CreateDirectory(Dir);
    TGlobalEdgeBrowserSettings.UserDataFolder := Dir;
  except
    // Sem pasta gravavel o WebView2 usa o padrao dele. Pode dar certo; se nao
    // der, o FMX cai para o IE sozinho. Em nenhum dos casos vale derrubar o
    // app por causa de cache.
  end;
{$ENDIF}
end;

end.
