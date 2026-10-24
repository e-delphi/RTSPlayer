unit VMS.App.Encerrar;

// Encerra o PROCESSO, e não só a janela.
//
// No Android as duas coisas não são a mesma. Fechar o formulário termina a
// Activity, mas o sistema mantém o processo vivo por um tempo — é a otimização
// que faz o app reabrir depressa quando alguém sai e volta logo em seguida.
//
// Só que o app não sobrevive a isso. O `Application.Run` do FMX já retornou, o
// formulário já foi destruído e com ele o servidor local, o WebView e o
// cadastro. Quando o sistema reaproveita o processo para a Activity nova, não
// há mais nada do lado Delphi para desenhar: a janela abre em branco e fica.
// Medido no aparelho: mesmo pid nas duas aberturas, nenhuma linha nossa no
// logcat depois da segunda, e um `Activity destroy timeout` da anterior.
//
// Não dá para consertar do outro lado. Nada no FMX reconstrói o formulário para
// uma segunda Activity — a aplicação roda uma vez e acabou. Então quando é para
// sair, sai de verdade, e a próxima abertura começa do zero.
//
// Fora do Android fechar a janela já encerra o programa, e aqui é no-op.

interface

// Só depois de tudo que este app tinha a fazer já ter sido feito: isto não
// volta.
procedure EncerrarProcesso;

implementation

{$IFDEF ANDROID}

uses
  Posix.Unistd;

procedure EncerrarProcesso;
begin
  // `_exit`, e não `exit` nem `Halt`: sai na hora, sem rodar finalização de
  // unit nem handler de atexit. O que este app tinha para gravar já foi gravado
  // no momento em que mudou (servers.json, cameras.json); não há buffer
  // esperando descarga. E travar na finalização seria trocar a tela branca por
  // um processo pendurado, que é pior.
  _exit(0);
end;

{$ELSE}

procedure EncerrarProcesso;
begin
  // sem efeito fora do Android
end;

{$ENDIF}

end.
