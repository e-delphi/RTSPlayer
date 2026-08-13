# vmsserver

Servidor que roda na máquina que enxerga as câmeras. Ele conecta em cada
câmera, grava em `.vms` e publica todas em **uma porta RTSP só**, uma rota por
câmera:

```
rtsp://<host>:8554/live/<nome-da-camera>
```

Feito para ser acessado pelo celular via Tailscale — o celular fala só com esta
máquina (que já é um nó do tailnet), então não é preciso subnet router nem
liberar rota para a LAN das câmeras.

## Organização

| Parte | O que faz |
|---|---|
| `src/Server/Tx.*` | servidor RTSP: listener, sessão (DESCRIBE/SETUP/PLAY) e SDP |
| `src/Packetizer/Tx.*` | empacotamento em RTP (H264, H265, AAC, MJPEG) |
| `src/Recording/`, `src/App/` | gravação ao vivo, config e composição deste app |
| `VMS.*`, em `..\src` | cliente (rtsp e dvrip), depacketizers, gravação e domínio |

As units `VMS.*` são as mesmas do app RTSPlayer, no mesmo repositório — o
servidor não duplica nada disso, só acrescenta o que é dele.

## Como as câmeras são gravadas

Os dois caminhos gravam o mesmo `.vms`, por vias diferentes:

- `rtsp://` — o próprio `TCameraSession` grava (`SessionCfg.RecordEnabled`).
- `dvrip://` — `TDvripSession` não tem writer, só alimenta o `IMediaSink`; então
  entra o `TRecordingSink`, que usa as mesmas peças (`TBlockBuilder` +
  `TFileRecordingWriter`) para gerar um `.vms` idêntico.

O servidor então acha o arquivo mais recente de cada câmera
(`FindMostRecentVmsForCamera`, casa `<nome>_*.vms`) e o segue em modo live.

## Configuração

`vmsserver.json`, ao lado do executável (ou passado como primeiro argumento).
É o mesmo formato do gravador, mais duas chaves:

- `rtspPort` — porta única onde tudo é publicado (padrão 8554).
- `bindAddress` — IP onde escutar. **Vazio = 0.0.0.0**, ou seja, a LAN inteira
  enxerga. Coloque aqui o IP `100.x` do Tailscale desta máquina para que só o
  tailnet alcance o servidor.

O campo `transport` é uma **string separada por vírgula**: `"tcp"`, `"udp"`,
`"tcp,udp"` — o mesmo formato que o app RTSPlayer grava no `cameras.json`, então
dá para copiar as câmeras de um arquivo para o outro sem traduzir nada. Array
(`["tcp"]`, formato antigo do gravador) não é aceito e cai no default `tcp,udp`.

`logLevel` não vale para o servidor: ele grava todos os níveis (ver Logs).

Dois cuidados na hora de preencher:

- **Use nomes ASCII e minúsculos** para as câmeras (`isis`, não `Ísis`): o nome
  vira caminho na URL RTSP e nome de arquivo no disco.
- `storageDir` relativo é resolvido contra o diretório atual, não o do
  executável. Rodando como serviço/atalho, prefira caminho absoluto.

## Logs

Um arquivo por câmera, em `logDir`:

```
logs/ayla_2026-08-12.log        só o que é da ayla
logs/frente_2026-08-12.log
logs/isis_2026-08-12.log
logs/vmsserver_2026-08-12.log   main, composition, listener
```

Grava **todos os níveis** (debug incluso), sem corte por verbosidade — as
chamadas `Debug` do VMS são de handshake e requisição, nada por pacote.

O roteamento é pela tag do log (`session.ayla`, `dvrip.isis`,
`supervisor.frente`, `recsink.isis`, `tx.session.ayla`): o que termina em nome
de câmera vai para o arquivo dela, o resto para o geral. O console recebe tudo,
para acompanhar ao vivo.

Os arquivos são abertos na subida do processo, com a data daquele momento. Um
processo que fica dias no ar continua escrevendo no arquivo do dia em que
começou — se isso incomodar, reinicie ou peça a rotação por data.

## Rodar

```bash
cd bin && vmsserver.exe
```

Ctrl+C encerra (para os supervisores e o listener).

No app Android, cadastre as câmeras apontando para o servidor, com transporte
**tcp** — obrigatório: o WireGuard do Tailscale usa MTU 1280, e RTP em UDP com
pacotes de ~1400 bytes é descartado no túnel.

## Pendências conhecidas

- **Retenção**: nada apaga `.vms` antigo. Três câmeras a ~2 Mbps gravando 24/7
  passam de 60 GB/dia. Antes de deixar rodando direto, defina uma política
  (apagar por idade ou por espaço livre, nunca o arquivo mais recente de cada
  câmera, que é o que está sendo gravado e servido).
- Cada reconexão da câmera começa um `.vms` novo; um cliente que estava
  assistindo fica preso ao arquivo anterior até reconectar (o supervisor do app
  faz isso sozinho pelo `noRtpTimeoutMs`).
- Latência mínima é a do bloco de gravação (`block.maxDurationMs`, 2 s por
  padrão), porque o vídeo passa por disco.
