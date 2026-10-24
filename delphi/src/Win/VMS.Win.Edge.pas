unit VMS.Win.Edge;

// O que o app precisa pedir ao Windows e que nao existe nas outras
// plataformas: o motor do WebView e o tema da moldura da janela. Fora do
// Windows tudo aqui e chamada vazia, e por isso nao precisa de IFDEF em volta
// de quem chama.
//
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
  FMX.Forms,        // TCommonCustomForm, para achar a janela nativa
  FMX.WebBrowser;   // TWindowsEngine, comum a todas as plataformas

// Chame UMA vez, antes de criar qualquer TWebBrowser. Em plataforma que nao e
// Windows nao faz nada, e por isso pode ser chamada sem IFDEF em volta.
procedure ConfigurarEdge;

// O motor que o TWebBrowser deve usar. Devolve `None` fora do Windows, que e o
// valor que o FMX espera nas outras plataformas. O tipo vem do FMX.WebBrowser,
// que e comum a todas elas -- so o TGlobalEdgeBrowserSettings e do Windows.
function MotorPreferido: TWindowsEngine;

// Poe a moldura da janela no tema escuro. Chame depois que o formulario existe.
//
// A moldura -- barra de titulo, botoes de fechar, borda -- nao e desenhada pelo
// FMX e sim pelo Windows, entao pintar o fundo do formulario nao alcanca ela.
// Uma faixa clara em volta de uma interface escura era o que restava.
procedure EscurecerJanela(const Janela: TCommonCustomForm);

// Deixa a janela acima de todas as outras, ou devolve ao normal.
//
// Pelo Windows direto, e nao pelo FormStyle do FMX: trocar o FormStyle em tempo
// de execucao recria a janela nativa (TCommonCustomForm.SetFormStyle chama
// Recreate), e o WebView2 que mora dentro dela seria destruido junto. O
// SetWindowPos so muda a janela de faixa na pilha, sem tocar no que ha dentro.
//
// Fora do Windows nao faz nada, e PodeFicarNaFrente responde False para a tela
// nem oferecer o botao.
function PodeFicarNaFrente: Boolean;
procedure FicarNaFrente(const Janela: TCommonCustomForm; Ligar: Boolean);

implementation

uses
  System.SysUtils,
  System.IOUtils
{$IFDEF MSWINDOWS}
  , FMX.WebBrowser.Win
  , FMX.Platform.Win     // FormToHWND
  , Winapi.Windows
  , Winapi.DwmApi
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

procedure EscurecerJanela(const Janela: TCommonCustomForm);
{$IFDEF MSWINDOWS}
const
  // A Microsoft trocou o numero deste atributo no meio do Windows 10: 19 antes
  // da build 18985, 20 dali em diante. Tentar os dois sai mais barato do que
  // descobrir a build, e o que nao vale e simplesmente ignorado.
  DARK_ANTIGO = 19;
  DARK = 20;
var
  Ligado: BOOL;
  H: HWND;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  if Janela = nil then Exit;
  try
    H := FormToHWND(Janela);
    if H = 0 then Exit;
    Ligado := True;
    if DwmSetWindowAttribute(H, DARK, @Ligado, SizeOf(Ligado)) <> S_OK then
      DwmSetWindowAttribute(H, DARK_ANTIGO, @Ligado, SizeOf(Ligado));
  except
    // Moldura clara e um defeito de aparencia; derrubar o app por causa dela
    // seria trocar um incomodo por uma falha.
  end;
{$ENDIF}
end;

function PodeFicarNaFrente: Boolean;
begin
{$IFDEF MSWINDOWS}
  Result := True;
{$ELSE}
  Result := False;
{$ENDIF}
end;

procedure FicarNaFrente(const Janela: TCommonCustomForm; Ligar: Boolean);
{$IFDEF MSWINDOWS}
var
  H: HWND;
  Faixa: HWND;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  if Janela = nil then Exit;
  try
    H := FormToHWND(Janela);
    if H = 0 then Exit;
    if Ligar then Faixa := HWND_TOPMOST else Faixa := HWND_NOTOPMOST;
    // NOACTIVATE: fixar nao e motivo para roubar o foco de quem esta
    // digitando em outro programa.
    SetWindowPos(H, Faixa, 0, 0, 0, 0,
                 SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  except
    // Mesma regra da moldura escura: e conforto, e nao vale derrubar o app.
  end;
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
