# RTSPlayer

Player de câmeras IP para **Android** e **Windows**, escrito em Delphi/FireMonkey.

O protocolo é implementado direto no socket — RTSP e DVRIP falados na mão, sem
libVLC, sem wrapper, sem componente de terceiro. Só a decodificação de vídeo e
áudio é delegada à plataforma: MediaCodec no Android, FFmpeg no Windows.

[![Delphi](https://img.shields.io/badge/Delphi-12%20Athens-red)](https://www.embarcadero.com/products/delphi)
[![Framework](https://img.shields.io/badge/framework-FireMonkey-blue)](https://docwiki.embarcadero.com/RADStudio/en/FireMonkey)
[![License](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)

## Telas

| Início | Configurar |
|:--:|:--:|
| ![Tela inicial com a lista vazia e o botão de adicionar câmera](docs/app-inicio.png) | ![Cadastro da câmera: protocolo, host, porta, credenciais, transporte e o resultado do teste de conexão](docs/app-configurar.png) |
| **Listagem** | **Vídeo ao vivo** |
| ![Lista de câmeras cadastradas, mostrando URL e transporte de cada uma](docs/app-listagem.png) | ![Player exibindo o stream ao vivo de uma câmera](docs/app-video.png) |

## Recursos

- **RTSP** com autenticação Basic e Digest, `DESCRIBE`/`SETUP`/`PLAY`, keep-alive
  por `GET_PARAMETER` ou `OPTIONS`
- **Transporte TCP (interleaved) ou UDP**, com ordem de preferência configurável
  e fallback automático por timeout (`auto`, `tcp,udp`, `udp,tcp`, `tcp`, `udp`)
- **DVRIP / Sofia** (DVRs e câmeras Xiongmai/XM, porta 34567) — login, `OPMonitor`
  e demux do fluxo de mídia
- **Reconexão automática** com backoff exponencial, supervisionada por câmera,
  com limite opcional de tentativas
- **Fallback de decoder no Android**: quando o decoder de hardware falha (comum em
  1080p+ com drivers problemáticos), a sessão migra para o decoder de software
- **Teste de conexão** na tela de cadastro: faz só o handshake e informa o
  resultado, sem abrir o stream
- **Gravação `.vms`** (formato próprio: blocos indexados com CRC32) — a engine
  suporta, o app roda com a gravação desligada
- **Playback de gravação** quando a câmera está atrás de um vmsserver: o app puxa
  a mídia pela API do servidor e toca no mesmo decodificador do ao vivo, com
  ritmo próprio (nenhum dos dois renderers apresenta por PTS)
- **Log em tela**, útil para diagnosticar câmera que não abre

## Codecs

| Vídeo | Áudio |
|---|---|
| H.264 | AAC |
| H.265 / HEVC | PCM |
| MJPEG | G.711 (µ-law e A-law) |
| | G.726 (16/24/32/40 kbps) |

## Plataformas

| Plataforma | Decodificação | Observação |
|---|---|---|
| Android / Android64 | MediaCodec via JNI | fallback automático para decoder de software |
| Win64 | FFmpeg | DLLs incluídas em `bin/Win64/Release` |

## Estrutura

```
src/
├── Net/          sockets TCP e UDP atrás de uma interface
├── Rtsp/         cliente RTSP: mensagens, URL, autenticação, transporte
├── Sdp/          parser de SDP
├── Rtp/          pacote RTP e demux por canal interleaved ou payload type
├── Depacketizer/ RTP → frames (H264, H265, MJPEG, AAC, PCM, G711, G726)
├── Api/          cliente das rotas de gravação do vmsserver
├── Playback/     engine que toca gravação: busca, fila e ritmo
├── Dvrip/        protocolo Sofia/DVRIP: handshake, comandos e mídia
├── Domain/       sessão, supervisor, política de reconexão, tipos e portas
├── Recording/    escrita e leitura do formato .vms
├── Media/        fachada do renderer (escolhe o backend por plataforma)
├── Android/      backend MediaCodec (vídeo, áudio, JNI)
├── Win/          backend FFmpeg
├── App/          composition root, configuração, logger, clock
└── UI/           shell FMX + frames de lista, player e edição
```

A separação é intencional: `Domain` e os protocolos não conhecem FMX nem
plataforma. A UI conversa com a sessão através de `IMediaSink`, e
`VMS.Media.Renderer` decide em tempo de compilação qual backend entra.

## Compilando

Requer **Delphi 12 Athens** (FireMonkey). Não há dependência externa além das
DLLs do FFmpeg, que já estão no repositório.

1. Abra `rtsplayer.dproj` no RAD Studio
2. Escolha a plataforma (`Win64`, `Android` ou `Android64`)
3. Compile e execute

No Windows, os DLLs precisam estar ao lado do executável — é o caso ao rodar a
partir de `bin/Win64/Release`. No Android eles não são usados: a decodificação
vai por MediaCodec.

## Configuração

As câmeras são cadastradas pela própria interface (protocolo, host, porta,
caminho, usuário, senha, transporte e atrasos de sincronismo A/V). A lista é
gravada em `cameras.json`, na pasta Documentos do dispositivo:

```json
[
  {
    "name": "Portaria",
    "url": "rtsp://192.0.2.10:554/onvif1",
    "user": "admin",
    "password": "",
    "transport": "tcp,udp",
    "maxRetries": 0,
    "audioDelayMs": 200,
    "videoDelayMs": 200
  }
]
```

- `transport` aceita `auto`, `tcp`, `udp`, `tcp,udp` ou `udp,tcp` — a ordem é a
  de preferência, e a troca acontece por timeout
- `maxRetries` igual a `0` reconecta indefinidamente
- `audioDelayMs` / `videoDelayMs` ajustam o jitter buffer de cada trilha
- para DVRIP, use `dvrip://host:34567` como URL

### Vários caminhos até a mesma câmera

A mesma câmera costuma ter mais de um endereço: o IP dela na LAN, o servidor que
a republica em casa, e o mesmo servidor pela tailnet. Em vez de três cadastros
iguais, **uma câmera com uma lista de caminhos**, em ordem de prioridade:

```json
{
  "name": "Frente",
  "endpoints": [
    { "name": "Local",  "url": "rtsp://192.168.100.9:8554/live/frente" },
    { "name": "Online", "url": "rtsp://100.102.246.119:8554/live/frente",
      "tailscale": true },
    { "name": "Direto", "url": "rtsp://192.168.100.2:555",
      "user": "admin", "password": "…", "transport": "tcp,udp" }
  ],
  "maxRetries": 0, "audioDelayMs": 200, "videoDelayMs": 200
}
```

Antes de **cada** tentativa de conexão o app testa os caminhos na ordem (um TCP
connect com 700 ms) e usa o primeiro que responder. Isso vale também nas
reconexões, que é o que faz sair de casa trocar de caminho sozinho. Nenhum
respondendo, ele tenta o marcado como `tailscale` (o túnel pode estar caído, e é
a sessão dele que sabe pedir para subir) ou o primeiro da lista.

No caminho `tailscale`, se a rota não existe o app abre o Tailscale e espera até
30 s a rota aparecer, mostrando **"Aguardando a VPN"** — que é diferente de
"Conectando", porque a ação que falta está no outro app. Quem liga a VPN é o
usuário: o Android não deixa um app subir o `VpnService` de outro. Com o túnel
já de pé e a câmera muda, ele nem abre o Tailscale — o problema ali é a câmera.

Pela interface, isso fica no topo da tela de cadastro: **"+ caminho"** cria mais
um, as abas numeradas escolhem qual está sendo editado (os campos de baixo —
protocolo, host, porta, credenciais, transporte, Tailscale — são **do caminho
selecionado**), e o **x** apaga o caminho atual. O nome da câmera é um só; o
campo logo abaixo das abas é o nome daquele caminho ("Local", "Online"...).

Cadastro no formato antigo (uma `url` por câmera) continua valendo: vira uma
câmera de um caminho só. Os campos `url`/`user`/`password`/`transport` fora da
lista são o espelho do primeiro caminho.

### Levar o cadastro para outro aparelho

Na lista de câmeras, os dois ícones à esquerda do **+**:

- **Exportar** (seta saindo) manda o cadastro inteiro — o mesmo texto do
  `cameras.json` — para a **bandeja de compartilhar do Android**. Dali vai para
  WhatsApp, e-mail, arquivo, o que você escolher. No Windows, vai para a área de
  transferência.
- **Importar** (seta entrando) abre uma caixa onde se cola esse texto. O botão
  **Colar** puxa da área de transferência num toque. Câmera de mesmo nome é
  atualizada; as demais entram no fim da lista — o que só existe no aparelho de
  destino não é apagado.

O texto **leva as senhas em claro** (é o mesmo conteúdo do arquivo), e o app
avisa isso antes de exportar. Mande só para você mesmo e apague a mensagem
depois de importar.

> ⚠️ As senhas ficam em texto puro nesse arquivo, como acontece na maioria dos
> clientes RTSP (o protocolo precisa da senha em claro para calcular o Digest).
> Ele vive na área privada do app, mas não é um cofre — trate o dispositivo como
> parte da superfície de ataque das suas câmeras.

## Formato .vms

Container próprio, pensado para gravação contínua com perda mínima em caso de
queda de energia:

- **Header** `VMS1` com metadados das trilhas (codec, resolução, extradata)
- **Blocos** `BLK` com índice de samples + payload e um CRC32 ao final —
  cada bloco é fechado a cada N samples, N ms ou N bytes, o que vier primeiro
- **Âncora A/V** `BANC` no fim do índice de cada bloco: o instante de parede em
  que cada trilha começou ali, que é o que relaciona dois PTS em bases diferentes
- **Índice** `VIDX` com tempo, posição e "tem keyframe" de cada bloco, escrito
  quando a gravação fecha: achar um instante vira uma busca binária em vez de
  uma varredura do arquivo
- **Footer** `VEOF` com total de blocos, duração, offset do último bloco e
  ponteiro para o índice

Um arquivo truncado continua legível até o último bloco completo: o leitor para
quando faltam bytes, em vez de falhar o arquivo inteiro. Ele também tem um modo
"live", que aguarda o escritor em vez de terminar no fim do arquivo. O CRC de cada
bloco é conferido na leitura: bloco corrompido é pulado com aviso, em vez de
envenenar o decodificador.

O formato está em desenvolvimento e **não carrega compatibilidade**: existe um
layout só. Mudou o layout, as gravações antigas se apagam.

## Licença

[AGPL-3.0](LICENSE).
