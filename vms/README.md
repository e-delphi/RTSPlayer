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

**Uma pasta por câmera**, dentro de `storageDir`:

```
recordings/
├── ayla/    ayla_2026-08-16_18-37-57.vms  …
├── frente/  frente_2026-08-16_18-37-56.vms  …
└── isis/    isis_2026-08-16_18-38-21.vms  …
```

O nome do arquivo continua trazendo o nome da câmera: ele é o que identifica a
gravação fora do disco (log, API, cursor de playback). O nome da pasta sai do
nome da câmera com tudo fora de `[A-Za-z0-9._-]` virando `_` (ver
`src/Recording/VMS.Rec.Paths.pas`) — é o mesmo alfabeto que a API aceita, então
nada que venha do cliente sai da pasta de gravações.

Os dois caminhos gravam o mesmo `.vms`, por vias diferentes:

- `rtsp://` — o próprio `TCameraSession` grava (`SessionCfg.RecordEnabled`).
- `dvrip://` — `TDvripSession` não tem writer, só alimenta o `IMediaSink`; então
  entra o `TRecordingSink`, que usa as mesmas peças (`TBlockBuilder` +
  `TFileRecordingWriter`) para gerar um `.vms` idêntico.

Cada gravação **roda de arquivo** a cada `rotateMinutes` (60), sempre esperando um
keyframe para o arquivo novo começar por um ponto de entrada do decodificador.

### O índice, e o que acontece numa queda de energia

> Desenhado, byte a byte: [docs/anatomia-vms.html](../docs/anatomia-vms.html).

Enquanto grava, cada `.vms` tem um `.vms.idx` ao lado com o índice tempo →
posição, escrito em lotes a cada 16 blocos. É o que permite buscar um instante na
gravação de agora sem varrer o arquivo. Fechando direito, esse índice vai para o
fim do `.vms` (chunk `VIDX`) e o sidecar é apagado.

Caiu a energia no meio? O `.vms` fica sem rodapé e o `.vms.idx` fica no disco. Na
**subida seguinte do servidor** — depois da varredura de retenção e antes de as
câmeras começarem a gravar — o `Vms.Server.Repair` termina o serviço: monta o
índice, descarta o pedaço de bloco que a queda deixou pela metade, escreve `VIDX`
e rodapé, e apaga o sidecar. O resultado é indistinguível de uma gravação que
fechou normalmente:

```
[INFO ] repair: isis_2026-08-16_18-38-21.vms fechado: 1794 blocos indexados, 91320 bytes de cauda incompleta descartados
[INFO ] repair: 1 gravacao(oes) que ficaram abertas foram fechadas
```

Arquivo em uso por outra instância do servidor é pulado (o handle é aberto em
modo exclusivo), e arquivo sem sidecar não é tocado — fechá-lo custaria uma
varredura completa, e isso não pode segurar a subida do servidor.

## Como o ao vivo é publicado

O mesmo sample que vai para a gravação vai também para um buffer circular em
memória, um por câmera (`src/Live/Vms.Server.LiveHub.pas`), e é **de lá** que o
`/live/<camera>` sai. O cliente recebe o quadro no instante em que ele chega da
câmera, sem esperar o bloco de gravação fechar no disco.

Quando a câmera ainda não publicou nada nesta execução (desligada, ou servidor
recém-subido), o `DESCRIBE` cai no caminho antigo: acha o arquivo mais recente
dela (`FindMostRecentVmsForCamera`, o mais recente da pasta dela) e o segue em modo live,
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

## API de gravações

Na **mesma porta 8554** do RTSP. Quem chega com `HTTP/1.1` na linha do pedido cai
na API; quem chega com `RTSP/1.0` segue para o player de sempre. É a versão que
decide, nunca o método — `OPTIONS` existe nos dois protocolos.

| rota | o que devolve |
|---|---|
| `GET /api/cameras` | as câmeras configuradas, quantos arquivos e bytes cada uma tem, e quem está publicando **agora** |
| `GET /api/days?camera=X` | os dias com gravação: quanto foi gravado, quantas faixas, e a fração do dia coberta |
| `GET /api/segments?camera=X&day=YYYY-MM-DD` | as faixas contínuas daquele dia, prontas para desenhar |
| `GET /api/media?camera=X&fromMs=…` | a mídia a partir daquele instante |
| `GET /api/media?camera=X&cursor=…` | a continuação, sem busca |
| `GET /api/recordings?camera=X` | a lista crua, arquivo por arquivo — diagnóstico |
| `GET /api/index?file=…` | o índice de blocos, cru — diagnóstico |

```bash
curl "http://localhost:8554/api/days?camera=isis"
curl -D- -o trecho.vms "http://localhost:8554/api/media?camera=isis&fromMs=1786846215000&blocks=5"
```

O corpo de `/api/media` é **um `.vms` completo**: header do arquivo de origem,
copiado byte a byte, mais N blocos crus. O formato que já existe é o protocolo, e
o app reusa o mesmo `TVmsReader` que já está compilado nele. O trecho baixado
abre no `tools/vmsdump.py`; para assistir, extraia o vídeo do container antes
(`.vms` é formato nosso, o ffplay não conhece):

```bash
python -c "import sys;sys.path.insert(0,'tools');import vmslib;h,b=vmslib.load('trecho.vms');open('trecho.264','wb').write(b''.join(s.data for k in b for s in k.samples if s.is_video))"
ffplay trecho.264
```

A mídia começa sempre num bloco com keyframe **anterior** ao instante pedido
(senão a tela ficaria preta até o próximo), então o pedaço pode conter até um GOP
antes do que se pediu.

Os cabeçalhos da resposta dizem como continuar:

| header | |
|---|---|
| `X-Vms-Cursor` | opaco; devolva em `cursor=` para pegar o pedaço seguinte |
| `X-Vms-Block-Count` | quantos blocos vieram |
| `X-Vms-Start-Ms` / `X-Vms-End-Ms` | faixa de tempo coberta |
| `X-Vms-Next-Ms` | instante do próximo pedaço, ou `-1` se acabou |
| `X-Vms-Gap-Ms` | buraco entre este pedaço e o próximo (0 = contínuo) |
| `X-Vms-Discontinuity` | `1` quando este pedaço começa outro arquivo: header e base de PTS mudaram |
| `X-Vms-Keyframe` | `1` se o primeiro bloco tem keyframe |
| `X-Vms-Growing` | `1` se o arquivo ainda está sendo gravado |

`X-Vms-Discontinuity` é o cabeçalho que importa para quem está tocando: ali o
cliente reanuncia o formato ao decodificador e re-ancora o ritmo pelo tempo de
parede do primeiro bloco novo, em vez de continuar a conta de PTS do arquivo
anterior. É o mesmo tratamento que a sessão ao vivo faz quando a câmera
reconecta.

O cliente também **descarta vídeo até o primeiro keyframe** depois de um seek ou
de uma emenda: como o gravador fecha bloco por tempo/tamanho e não por keyframe,
o primeiro bloco do trecho traz P-frames cuja referência não veio junto.

Tempo é sempre **ms Unix UTC**; a resposta traz `tz` com o fuso do servidor, que é
o fuso em que os dias são recortados. O app converte para hora local na tela.

**O cliente não sabe que existem arquivos.** Cada reconexão de câmera abre um
`.vms` novo — um dia normal tem dezenas — e a API entrega isso colado: arquivos
separados por menos de `gapMs` (5 s por padrão) viram uma faixa só, e o que sobra
de buraco é câmera realmente fora do ar. O `/api/days` mede o tempo gravado
**sem** essa folga (encostar não é preencher) e conta as faixas **com** ela, para
o número bater com o que o `/api/segments` desenha.

O primeiro acesso a uma câmera lê os arquivos da pasta; depois disso as respostas
saem de cache, revalidado por tamanho e data. O arquivo que ainda está sendo
gravado é o único que continua sendo varrido — e só os blocos novos, retomando de
onde parou.

> ⚠️ **Não há autenticação**, e a API amplia o que um vizinho de rede alcança:
> quem chega na porta passa a poder *baixar* gravação, não só assistir ao vivo. A
> trava é o `bindAddress` — deixe-o no IP `100.x` do Tailscale. O servidor avisa
> na partida quando a API está no ar sem essa trava.

## Configuração

`vmsserver.json`, ao lado do executável (ou passado como primeiro argumento).
É o mesmo formato do gravador, mais cinco chaves:

- `rtspPort` — porta única onde tudo é publicado (padrão 8554).
- `bindAddress` — IP onde escutar. **Vazio = 0.0.0.0**, ou seja, a LAN inteira
  enxerga. Coloque aqui o IP `100.x` do Tailscale desta máquina para que só o
  tailnet alcance o servidor.
- `retention` — limpeza automática das gravações. **Sem ela o disco enche**: são
  ~7 GB por dia por câmera a 1 Mbps.
- `live` — buffer em memória do ao vivo. Vem **ligado** por omissão; ao
  contrário da retenção, ele não apaga nem altera nada.
- `api` — as rotas de gravação acima, na mesma porta do RTSP. Também vem
  **ligada** por omissão: `"api": { "enabled": false }` desliga, e
  `maxBlocksPerRequest` (32) limita o quanto de mídia sai por requisição.

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
  "maxTotalGB": 50,      // tamanho somado dos .vms (todas as pastas de câmera)
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
  vira caminho na URL RTSP, pasta e nome de arquivo no disco.
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
