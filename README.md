# RTSPlayer + vmsserver (Rust)

Porte para Rust do RTSPlayer e do vmsserver. O código Delphi antigo está em
`delphi/`, só como referência.

```
shared/   vms-core — a biblioteca comum aos dois
server/   vmsserver — grava as câmeras, publica em RTSP, serve a API e a interface
client/   rtsplayer — janela Win32 + WebView2 com a mesma interface web
```

## Pacotes

```
build-dist.bat              (ou: build-dist.bat sem-android)
```

Gera uma pasta por plataforma em `dist\`, cada uma com tudo o que precisa:

- `windows-servidor\`: `vmsserver.exe` com as DLLs do FFmpeg, o ONNX Runtime,
  o runtime do VC++ que essas DLLs usam, o modelo `yolo26s.onnx` e um
  `LEIA-ME.txt`. As DLLs e o modelo vêm de `server\runtime\`;
- `windows-cliente\`: só o `rtsplayer.exe`. Ele usa o WebView2 Runtime, que já
  vem no Windows 10/11 atualizado;
- `android\`: `RTSPlayer.apk`.

Os dois executáveis levam o runtime do C embutido (`.cargo\config.toml`), então
não precisam do Visual C++ Redistributable.

## O que é compartilhado (`shared/`)

Tudo o que os dois lados fazem igual mora uma vez só:

- formato `.vms` (header, blocos, índice, rodapé, sidecar `.vms.idx`), leitor e gravador;
- RTSP cliente, RTP, SDP, depacketizadores (H.264, H.265, MJPEG, AAC, G.711…);
- DVRIP (Sofia): sessão de mídia, sessão só de comando, PTZ, fala (OPTalk);
- ONVIF (PTZ por SOAP com WS-Security);
- sessão de câmera e supervisor com reconexão e escolha de caminho (LAN/tailnet);
- anel do ao vivo em memória e o fragmento de `/api/live`;
- atendimento de `/api/ptz` e `/api/fala` (DVRIP pela sessão viva, senão ONVIF);
- servidor/cliente HTTP mínimo, leitura do cadastro de câmeras em JSON;
- a interface web (`shared/ui/`), embutida nos dois executáveis.

Para editar a interface sem recompilar, aponte `VMS_UI_DIR` para `shared/ui`:
as páginas passam a ser lidas do disco a cada pedido.

## vmsserver

```
cargo run --release -p vmsserver [caminho\vmsserver.json]
```

- O banco (`vmsserver.db`, SQLite) fica **ao lado do executável**. Na primeira
  subida o `vmsserver.json` (o mesmo do Delphi) é importado uma vez; depois vale
  o banco, editado pela interface (`/ui/cameras`, `/api/settings`).
- Uma porta só (`rtspPort`, 8554): RTSP para players (`rtsp://host:8554/live/<câmera>`)
  e HTTP para a API e a interface (`http://host:8554/`).
- Autenticação: instalação nova só aceita o próprio computador até definir a
  senha em `/ui/login`. A senha gravada pelo Delphi continua valendo (mesmo
  PBKDF2-SHA256).
- Caminhos relativos (`storageDir`, `analytics.modelPath`) resolvem a partir do
  executável, não do diretório de trabalho (serviço do Windows roda em System32).
- Miniaturas e análise de movimento precisam das DLLs do FFmpeg
  (`avcodec-61.dll`, `avutil-59.dll`, `swscale-8.dll`) ao lado do exe; sem elas
  o servidor sobe igual, sem esses recursos.
- Detecção de objetos (YOLO em ONNX): `analytics.modelPath` aponta o `.onnx`
  (YOLO26 end-to-end, YOLOv8/11 ou YOLOv5) e `analytics.onnxDll` o
  `onnxruntime.dll` (com o runtime do VC++ na mesma pasta). Sem um dos dois a
  análise segue só com movimento. `analytics.classes` filtra os rótulos.

## rtsplayer

```
cargo run --release -p rtsplayer
```

- Cadastro em `Documentos\cameras.json` e `Documentos\servers.json` (os mesmos
  arquivos do app Delphi). `RTSPLAYER_DATA_DIR` troca a pasta.
- A interface e a API saem do origin `https://rtsplayer.app`, servido da
  memória. Pedidos com `server=<nome>` vão para o vmsserver cadastrado
  (http ou https, com o usuário e a senha do cadastro).
- Ao vivo: uma câmera por vez, pela mesma sessão do servidor.
- O microfone do WebView é liberado para a fala (push-to-talk).

## Android

```
android\build-apk.bat
```

Gera o release assinado em `android\app\build\outputs\apk\release\app-release.apk`:
Android 9 (API 28) ou mais novo, com armv7 e arm64 no mesmo APK (o Android
instala a biblioteca do aparelho; os celulares que só rodam 64 bits, como o
Pixel 7 em diante, usam a arm64).

É o MESMO app do Windows (`client/`: roteador, cadastro, ao vivo, PTZ, fala e
encaminhamento), compilado como biblioteca (`android/rust`). A biblioteca sobe
um servidor em `127.0.0.1` e a Activity mostra a interface num WebView, como o
app Delphi fazia no Android (o `shouldInterceptRequest` do WebView não entrega
o corpo dos POSTs). A fala usa o `getUserMedia` da página, com a permissão de
microfone pedida em tempo de execução; a tela fica acesa enquanto o app está na
frente. Log: `adb logcat -s RTSPlayer`.

Precisa:
- `rustup target add armv7-linux-androideabi aarch64-linux-android` e
  `cargo install cargo-ndk`;
- o SDK do Android em `%LOCALAPPDATA%\Android\Sdk` (o lugar padrão; outro
  caminho vai em `ANDROID_SDK`) com platform 34, build-tools 34.0.0 e
  NDK 27.2.12479018:
  `sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" "ndk;27.2.12479018"`;
- o JDK 17.

**Assinatura.** A chave de release é `android\rtsplayer-release.jks`, e a senha
está em `android\keystore.properties`. Os dois ficam fora do git: guarde uma
cópia. Atualizações só instalam por cima se forem assinadas com a mesma chave.

## Testes

```
cargo test --workspace
```

Os testes incluem câmeras falsas de verdade (RTSP e DVRIP em sockets locais),
o servidor RTSP tocado pelo cliente do próprio projeto, e a API inteira.

Fora da suíte padrão, a detecção com o modelo de verdade:

```
set VMS_TEST_BIN=pasta com onnxruntime.dll, o .onnx e as DLLs do FFmpeg
set VMS_TEST_IMG=uma foto .jpg com pessoas
cargo test --release -p vmsserver -- --ignored modelo_de_verdade
```

## O que não veio do Delphi

- **Android, ainda não portado**: a decodificação nativa de H.265 (MediaCodec,
  `/api/decode`/`/api/frame`) e a abertura automática do app do Tailscale para
  a câmera marcada como "rede Tailscale". O microfone nativo (AudioRecord) do
  Delphi também ficou de fora: a fala usa o `getUserMedia` do WebView, com a
  permissão repassada pela Activity — ainda não testado num aparelho.
- **Windows**: "sempre à frente" só existe no Windows.
