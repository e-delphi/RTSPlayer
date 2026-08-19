unit VMS.App.Share;

// Entregar e receber texto pela bandeja do sistema.
//
// Existe para a exportação/importação de câmeras: no Android o texto sai pelo
// ACTION_SEND — a mesma janela de compartilhar de qualquer app —, e quem
// escolhe o destino (WhatsApp, e-mail, arquivo, bloco de notas) é o usuário.
// Não gravamos arquivo nenhum: gravar exigiria SAF, permissão de
// armazenamento e uma tela de "onde salvar" que o próprio Android já tem.
//
// A área de transferência é o caminho de volta: o texto colado do WhatsApp no
// outro aparelho entra por ela.
//
// Fora do Android não há bandeja: compartilhar cai para a área de transferência,
// e quem chamou avisa isso na tela.

interface

uses
  System.SysUtils,
  System.Classes;

// True quando o texto foi entregue à bandeja do sistema (só Android). False
// significa "não há bandeja aqui" — o chamador decide o que dizer.
function ShareText(const ASubject, AText: string): Boolean;

function ClipboardSetText(const AText: string): Boolean;
function ClipboardGetText(out AText: string): Boolean;

implementation

uses
  System.Rtti,
  FMX.Platform
  {$IFDEF ANDROID}
  , Androidapi.Helpers
  , Androidapi.Jni.App
  , Androidapi.JNIBridge
  , Androidapi.JNI.JavaTypes
  , Androidapi.JNI.GraphicsContentViewText
  {$ENDIF};

{$IFDEF ANDROID}
function ShareText(const ASubject, AText: string): Boolean;
var
  Intent: JIntent;
begin
  Result := False;
  try
    if TAndroidHelper.Context = nil then Exit;
    Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_SEND);
    Intent.setType(StringToJString('text/plain'));
    Intent.putExtra(TJIntent.JavaClass.EXTRA_SUBJECT, StringToJString(ASubject));
    Intent.putExtra(TJIntent.JavaClass.EXTRA_TEXT, StringToJString(AText));
    // createChooser força a lista de apps mesmo quando o usuário já escolheu um
    // padrão para "enviar texto" — aqui o destino muda a cada uso.
    TAndroidHelper.Activity.startActivity(
      TJIntent.JavaClass.createChooser(Intent, StrToJCharSequence(ASubject)));
    Result := True;
  except
    on E: Exception do
      Result := False;
  end;
end;
{$ELSE}
function ShareText(const ASubject, AText: string): Boolean;
begin
  // Windows não tem bandeja de compartilhamento acessível daqui.
  Result := False;
end;
{$ENDIF}

function ClipboardSetText(const AText: string): Boolean;
var
  Svc: IFMXClipboardService;
begin
  Result := False;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then Exit;
  try
    Svc.SetClipboard(AText);
    Result := True;
  except
    on E: Exception do
      Result := False;
  end;
end;

function ClipboardGetText(out AText: string): Boolean;
var
  Svc: IFMXClipboardService;
  V: TValue;
begin
  AText := '';
  Result := False;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, Svc) then Exit;
  try
    V := Svc.GetClipboard;
    if V.IsEmpty then Exit;
    AText := V.ToString;
    Result := AText <> '';
  except
    on E: Exception do
      Result := False;
  end;
end;

end.
