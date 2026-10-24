package app.rtsplayer;

/**
 * A ponte com a biblioteca Rust ({@code android/rust}). O app inteiro mora lá:
 * aqui só se sobe, se pergunta se a página pediu para sair, e se derruba.
 */
final class Native {
    static {
        System.loadLibrary("rtsplayer_android");
    }

    private Native() {}

    /** Sobe o app com o cadastro em {@code dataDir}. Devolve a porta em 127.0.0.1, ou -1. */
    static native int start(String dataDir);

    /** A página pediu {@code /api/app/sair}. */
    static native boolean wantsExit();

    /** Derruba o ao vivo e o servidor. */
    static native void stop();
}
