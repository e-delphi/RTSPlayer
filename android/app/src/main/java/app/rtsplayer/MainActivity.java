package app.rtsplayer;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

/**
 * Uma Activity, um WebView em tela cheia, apontado para o servidor que a
 * biblioteca Rust sobe em 127.0.0.1 — a mesma interface do app Windows e do
 * vmsserver.
 *
 * <p>O que é só do Android fica aqui: a permissão do microfone (pedida em
 * tempo de execução e repassada ao {@code getUserMedia} da página), a tela
 * acesa enquanto o app está na frente, e o botão voltar.</p>
 */
public class MainActivity extends Activity {
    private static final int PEDIDO_MICROFONE = 1;

    private WebView web;
    private String base;
    private PermissionRequest pendente;
    private final Handler handler = new Handler(Looper.getMainLooper());

    /** A página pede para sair pelo {@code /api/app/sair}; quem fecha é a Activity. */
    private final Runnable vigia = new Runnable() {
        @Override
        public void run() {
            if (Native.wantsExit()) {
                finish();
                return;
            }
            handler.postDelayed(this, 500);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        // Quem olha uma câmera não quer a tela apagando no meio.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        int porta = Native.start(getFilesDir().getAbsolutePath());
        if (porta <= 0) {
            Toast.makeText(this, "Não consegui iniciar o RTSPlayer", Toast.LENGTH_LONG).show();
            finish();
            return;
        }
        base = "http://127.0.0.1:" + porta;

        web = new WebView(this);
        web.setBackgroundColor(Color.BLACK);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        // Segurar o botão de falar não pode virar seleção de texto nem menu.
        web.setLongClickable(false);
        web.setOnLongClickListener(v -> true);
        web.setHapticFeedbackEnabled(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                Uri u = req.getUrl();
                if (u.toString().startsWith(base)) {
                    return false;
                }
                // Link de fora abre no navegador do sistema.
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, u));
                } catch (Exception ignored) {
                }
                return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(PermissionRequest req) {
                runOnUiThread(() -> concederMicrofone(req));
            }
        });

        setContentView(web);
        web.loadUrl(base + "/");
        handler.post(vigia);
    }

    /** Só o microfone, e só da própria página. */
    private void concederMicrofone(PermissionRequest req) {
        boolean querAudio = false;
        for (String r : req.getResources()) {
            if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(r)) {
                querAudio = true;
            }
        }
        if (!querAudio || !req.getOrigin().toString().startsWith(base)) {
            req.deny();
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            req.grant(new String[] {PermissionRequest.RESOURCE_AUDIO_CAPTURE});
            return;
        }
        // Pede ao Android primeiro; a página espera a resposta.
        if (pendente != null) {
            pendente.deny();
        }
        pendente = req;
        requestPermissions(new String[] {Manifest.permission.RECORD_AUDIO}, PEDIDO_MICROFONE);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        if (code != PEDIDO_MICROFONE || pendente == null) {
            return;
        }
        if (res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED) {
            pendente.grant(new String[] {PermissionRequest.RESOURCE_AUDIO_CAPTURE});
        } else {
            pendente.deny();
            Toast.makeText(this, "Sem permissão de microfone, não dá para falar pela câmera", Toast.LENGTH_LONG).show();
        }
        pendente = null;
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(vigia);
        if (web != null) {
            web.destroy();
        }
        // Saindo de verdade (não girando a tela): derruba câmera e servidor.
        if (isFinishing()) {
            Native.stop();
        }
        super.onDestroy();
    }
}
