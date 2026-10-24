unit UI.Shell;

// A casca do app em HTML, ocupando a tela inteira.
//
// É o passo onde o app deixa de desenhar interface: câmeras, dias e reprodução
// passam a vir de `/ui/app`, servida pelo servidor local (ver VMS.Local.Server).
// O Delphi por baixo continua fazendo o que só ele faz — RTSP, DVRIP, leitura
// do `.vms`, reconexão — e entrega por HTTP.
//
// ## Nada de FMX por cima
//
// No Android o TWebBrowser é uma view nativa colocada ACIMA da superfície onde
// o FMX desenha. Aqui isso deixa de ser um problema, porque não há nada do FMX
// para ficar por cima: a tela é o browser e mais nada.
//
// ## O botão voltar
//
// O sistema manda o "voltar" para o app, e não para a página. Quem sabe se há
// para onde voltar é a página — ela tem três telas dentro de si. Então o app
// pergunta, por EvaluateJavaScript, e só trata como "sair" quando ela responde
// que já está na raiz.
//
// A resposta não volta pelo EvaluateJavaScript (o FMX não devolve valor), então
// a página avisa pelo canal que ela já usa para tudo: uma requisição ao servidor
// local, em /api/app/sair.
//
// Antes o aviso era uma navegação para um esquema inventado (`vmsapp://sair`),
// interceptada no OnShouldStartLoadWithRequest. Não servia: o FMX não deixa
// cancelar navegação nenhuma — shouldOverrideUrlLoading devolve False fixo, em
// FMX.WebBrowser.Android — então o WebView tentava abrir aquilo de verdade e
// pintava a página de erro dele, branca e com a URL escrita. No Android dava
// para ver essa faixa sobrando na tela depois que o app já tinha saído.

interface

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  FMX.Types,
  FMX.Controls,
  FMX.Objects,
  FMX.Layouts,
  FMX.StdCtrls,
  FMX.Graphics,
  FMX.WebBrowser,
  UI.Common;

type
  TFrameShell = class(TLayout)
  private
    FWeb: TWebBrowser;
    FFundo: TRectangle;
    FAviso: TLabel;
    FBase: string;
    FCarregada: Boolean;
    FOnSair: TNotifyEvent;
    procedure WebPronto(ASender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    // Aponta para o servidor local. Base vazia = ele não subiu, e a tela avisa
    // em vez de abrir um browser em branco.
    procedure Abrir(const ABase: string);
    procedure Encerrar;
    // Chamado quando o sistema manda voltar. A resposta é assíncrona: se a
    // página estiver na raiz, ela avisa pelo /api/app/sair.
    procedure Voltar;
    // Só para quando a página nem chegou a carregar: aí não há a quem perguntar.
    property OnSair: TNotifyEvent read FOnSair write FOnSair;
  end;

implementation

uses
  VMS.Win.Edge;   // MotorPreferido: o Windows tem de usar o Edge

constructor TFrameShell.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Name := '';

  // O que se vê quando não há WebView: no começo, e de novo no fim, quando ele
  // é destruído antes de o app terminar de fechar. Sem isto o que aparecia era
  // o branco do formulário — e é essa a "tela branca" de quem fecha o app.
  FFundo := TRectangle.Create(Self);
  FFundo.Parent := Self;
  FFundo.Align := TAlignLayout.Contents;
  FFundo.Fill.Color := COLOR_BG;
  FFundo.Stroke.Kind := TBrushKind.None;
  FFundo.HitTest := False;

  FAviso := TLabel.Create(Self);
  FAviso.Parent := Self;
  FAviso.Align := TAlignLayout.Client;
  FAviso.StyledSettings := [];
  FAviso.TextSettings.FontColor := COLOR_DIM;
  FAviso.TextSettings.Font.Size := 13;
  FAviso.TextSettings.HorzAlign := TTextAlign.Center;
  FAviso.TextSettings.VertAlign := TTextAlign.Center;
  FAviso.TextSettings.WordWrap := True;
  FAviso.Margins.Left := 20;
  FAviso.Margins.Right := 20;
  FAviso.Text := '';
end;

procedure TFrameShell.Abrir(const ABase: string);
begin
  FBase := ABase;
  FCarregada := False;

  if FBase = '' then
  begin
    FAviso.Text := 'A interface local n'#$E3'o subiu: o servidor interno n'#$E3'o ' +
      'conseguiu abrir porta. O app continua funcionando pela interface antiga.';
    FAviso.Visible := True;
    Exit;
  end;

  FAviso.Text := 'carregando...';
  FAviso.Visible := True;

  if FWeb = nil then
  begin
    FWeb := TWebBrowser.Create(Self);
    FWeb.Parent := Self;
    FWeb.Align := TAlignLayout.Client;
    // O FMX nasce com TWindowsEngine.IEOnly: sem isto, o Windows roda
    // no Trident, que nao tem WebCodecs nem nada do que a interface
    // depende. Ver VMS.Win.Edge.
    FWeb.WindowsEngine := MotorPreferido;
    FWeb.OnDidFinishLoad := WebPronto;

    // WebView sem cache.
    //
    // No Android isto vira LOAD_NO_CACHE, e o WebView passa a nao LER do
    // cache. E a defesa que faltava: duas falhas seguidas foram resposta velha
    // sendo repetida sem tocar no servidor -- uma lista de cameras que dizia
    // "sem servidor configurado" e um ao vivo que exibia um segundo de video de
    // meia hora antes e congelava. Nos dois casos o log do servidor ficava
    // mudo, porque a requisicao nunca chegava.
    //
    // O servidor local ja manda no-store em tudo, mas isso so vale para
    // resposta NOVA: entrada guardada por uma versao anterior continua no
    // disco e seria usada. Com o cache desligado ela vira inerte, e ninguem
    // precisa limpar nada na mao ao atualizar o app.
    //
    // Nao se perde nada: tudo aqui vem de 127.0.0.1 e e estado que muda.
    // No Windows a propriedade e so guardada pelo FMX, sem efeito no WebView2.
    //
    // Depois do Parent, que e onde o servico nativo nasce -- antes dele o FMX
    // guardaria o valor sem repassar (ver SetEnableCaching em FMX.WebBrowser).
    FWeb.EnableCaching := False;
  end;
  FWeb.Navigate(FBase + '/ui/app');
end;

procedure TFrameShell.WebPronto(ASender: TObject);
begin
  FCarregada := True;
  FAviso.Visible := False;
end;

procedure TFrameShell.Voltar;
begin
  if (FWeb = nil) or (not FCarregada) then
  begin
    if Assigned(FOnSair) then FOnSair(Self);
    Exit;
  end;
  // A página decide. Devolvendo False (já está na raiz), ela avisa o servidor
  // local, que é quem chama o fechamento na thread principal.
  FWeb.EvaluateJavaScript(
    'if(window.vmsVoltar && !window.vmsVoltar())' +
    '{fetch("/api/app/sair",{method:"POST"});}');
end;

procedure TFrameShell.Encerrar;
begin
  FCarregada := False;
  if FWeb <> nil then
  begin
    FWeb.Parent := nil;
    FreeAndNil(FWeb);
  end;
end;

end.
