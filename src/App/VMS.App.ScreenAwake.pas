unit VMS.App.ScreenAwake;

// Mantém a tela acesa enquanto uma câmera está sendo exibida. No Android liga o
// FLAG_KEEP_SCREEN_ON na janela da Activity: não exige permissão (ao contrário
// do WakeLock) e o próprio sistema deixa a tela apagar de novo quando o app sai
// de foco. Nas outras plataformas é no-op.

interface

// True impede a tela de apagar; False devolve o controle ao sistema.
procedure SetKeepScreenOn(AOn: Boolean);

implementation

{$IFDEF ANDROID}

uses
  Androidapi.Helpers,
  Androidapi.JNI.App,
  Androidapi.JNI.GraphicsContentViewText,
  FMX.Helpers.Android;

procedure SetKeepScreenOn(AOn: Boolean);
begin
  // addFlags/clearFlags só podem ser chamados na UI thread do Android.
  CallInUIThread(
    procedure
    var
      W: JWindow;
    begin
      if TAndroidHelper.Activity = nil then Exit;
      W := TAndroidHelper.Activity.getWindow;
      if W = nil then Exit;
      if AOn then
        W.addFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON)
      else
        W.clearFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON);
    end);
end;

{$ELSE}

procedure SetKeepScreenOn(AOn: Boolean);
begin
  // sem efeito fora do Android
end;

{$ENDIF}

end.
