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
| `src/Live/` | buffer em memória de onde o ao vivo é publicado |
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

## Como o ao vivo é publicado

O mesmo sample que vai para a gravação vai também para um buffer circular em
memória, um por câmera (`src/Live/Vms.Server.LiveHub.pas`), e é **de lá** que o
`/live/<camera>` sai. O cliente recebe o quadro no instante em que ele chega da
câmera, sem esperar o bloco de gravação fechar no disco.

Quando a câmera ainda não publicou nada nesta execução (desligada, ou servidor
recém-subido), o `DESCRIBE` cai no caminho antigo: acha o arquivo mais recente
dela (`FindMostRecentVmsForCamera`, casa `<nome>_*.vms`) e o segue em modo live,
ritmado pelo PTS. É também o que acontece com `live.enabled: false`.

O que ainda pesa na latência, com o disco fora do caminho:

- **o GOP da câmera** — o cliente entra no keyframe mais recente do buffer, para
  não ficar com a tela preta; num GOP de 2 s isso pode custar até 2 s. Encurtar o
  intervalo de keyframe na câmera é o que resolve.
- **o jitter buffer do player** (`audioDelayMs`/`videoDelayMs`, 200 ms).

O buffer guarda alguns segundos e descarta o mais antigo. Cliente que não
consome no ritmo da câmera é reposicionado no keyframe mais recente — perde o
intervalo, mas volta ao vivo em vez de acumular atraso; sai no log como
`reposicionado no keyframe mais recente`.

## Configuração

`vmsserver.json`, ao lado do executável (ou passado como primeiro argumento).
É o mesmo formato do gravador, mais quatro chaves:

- `rtspPort` — porta única onde tudo é publicado (padrão 8554).
- `bindAddress` — IP onde escutar. **Vazio = 0.0.0.0**, ou seja, a LAN inteira
  enxerga. Coloque aqui o IP `100.x` do Tailscale desta máquina para que só o
  tailnet alcance o servidor.
- `retention` — limpeza automática das gravações. **Sem ela o disco enche**: são
  ~7 GB por dia por câmera a 1 Mbps.
- `live` — buffer em memória do ao vivo. Vem **ligado** por omissão; ao
  contrário da retenção, ele não apaga nem altera nada.

```json
"live": {
  "enabled": true,     // false volta a publicar lendo o .vms em gravação
  "bufferMs": 4000,    // quanto de mídia recente fica guardado, por câmera
  "maxBufferMB": 32    // teto de memória por câmera; o mais antigo é descartado
}
```

`bufferMs` precisa cobrir com folga o GOP da câmera — é dele que sai o keyframe
onde o cliente entra. Os dois tetos valem por câmera, e vale o que estourar
primeiro.

```json
"retention": {
  "maxDays": 7,          // idade máxima do arquivo
  "maxTotalGB": 50,      // tamanho somado dos .vms da pasta
  "minFreeGB": 20,       // espaço que deve continuar livre no disco
  "intervalMinutes": 5   // de quanto em quanto tempo varre
}
```

Cada limite é opcional; `0` desliga aquele limite, e o bloco ausente desliga a
limpeza inteira (nada apaga gravação velha). Vale o que estourar primeiro, e
apaga-se sempre o arquivo **mais antigo** — com três câmeras a 21 GB/dia, o
`maxTotalGB: 50` acima dá ~2 dias e meio de histórico, então é ele que manda, não
o `maxDays`. A gravação em curso e qualquer arquivo aberto por uma sessão ao vivo
nunca são apagados: ficam para a varredura seguinte. A partida loga o regime em
vigor e o espaço livre:

```
[INFO ] main: Espaco livre: 184.2 GB | retencao: 7 dia(s), max 50.0 GB gravados, min 20.0 GB livres; varredura a cada 5 min
[INFO ] retencao: apagado ayla_2026-08-13_19-12-38.vms (3.2 MB, limite de tamanho)
```

O campo `transport` é uma **string separada por vírgula**: `"tcp"`, `"udp"`,
`"tcp,udp"` — o mesmo formato que o app RTSPlayer grava no `cameras.json`, então
dá para copiar as câmeras de um arquivo para o outro sem traduzir nada. Array
(`["tcp"]`, formato antigo do gravador) não é aceito e cai no default `tcp,udp`.

`logLevel` não vale para o servidor: ele grava todos os níveis (ver Logs).

`tailscale: true` numa câmera faz o servidor esperar rota até ela antes de
conectar (útil se a câmera só existe dentro da tailnet). No Windows isso é só
espera: o Tailscale é serviço do sistema, não app que se abra — quem abre o app é
o RTSPlayer no Android.

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

A lista com prioridade e o que já foi medido está em
[`docs/PENDENCIAS.md`](../docs/PENDENCIAS.md) — é a fonte da verdade. Do lado do
servidor, o que mais aparece no uso:

- Não há autenticação: quem alcança a porta assiste a qualquer câmera.
- Cada reconexão da câmera começa um `.vms` novo, então o histórico fica picado
  (o ao vivo não sente: ele vem da memória).
