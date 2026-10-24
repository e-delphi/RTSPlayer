# Plano — playback com timeline no app

Estado: **fases 1 a 5 implementadas** (índice no rodapé do `.vms`; rotas de
listagem e de mídia na porta 8554; cliente e engine de playback no app; telas de
dia e barra de tempo). Falta a fase 6, de acabamento.

Nota da fase 5: as duas telas novas (`UI.Days`, `UI.Timeline`) são montadas em
**código, sem `.fmx`** — descendem de `TLayout`, não de `TFrame`. Foi o que
permitiu escrevê-las sem abrir o designer; e como não há arquivo de forma, não há
resource para o `TFrame` procurar.

O objetivo: no app, escolher um dia, arrastar uma barra de tempo e ver a gravação
daquele instante, com a mesma tela e o mesmo decodificador que o ao vivo usa.

Três peças, nesta ordem de dependência:

1. **índice tempo → posição gravado no rodapé do `.vms`**, para o servidor achar
   o ponto sem varrer o arquivo;
2. **rotas HTTP no vmsserver, na mesma porta 8554** — que gravações existem, e um
   pedaço de `.vms` a partir de um instante;
3. **engine de playback + UI da timeline no app**, puxando pedaço a pedaço.

---

## Por que puxar `.vms` e não RTSP com `Range`

O servidor **já** sabe fazer seek por `Range: npt=` no caminho de arquivo. Daria
para montar a timeline em cima disso. Não é o melhor caminho aqui:

- cada arrasto na barra vira `PAUSE` + `PLAY` com `Range` novo, e a resposta só
  começa a chegar depois do round-trip RTSP inteiro;
- a mídia sai empacotada em RTP para ser desempacotada do outro lado — trabalho
  puro em cima de dados que já estão em `.vms` dos dois lados;
- atravessar arquivo (uma câmera gera dezenas de `.vms` por dia, ver P3-5) exige
  SDP novo no meio da sessão, que é exatamente o caso que hoje derruba o cliente.

Puxando blocos `.vms` por HTTP: o seek é uma requisição, o app reusa o
`TVmsReader` que já está compilado nele, o pedaço recebido é um `.vms` válido
(dá para salvar e abrir com os scripts de `tools/`), e trocar de arquivo é só
trocar o parâmetro.

---

## Peça 1 — índice no rodapé do `.vms`

### O problema

Hoje o único jeito de achar "onde está o instante T" é `BuildIndex`, que percorre
o arquivo bloco a bloco lendo 20 bytes de cada. Num arquivo de 1 h com blocos de
2 s são ~1800 seeks; num dia, ~43 mil. Serve para o ao vivo (que faz isso uma vez)
e não serve para uma timeline que é arrastada.

O rodapé é o lugar certo: quando a gravação fecha, o writer já sabe o offset e o
`StartUnixMs` de cada bloco que escreveu — é só não jogar fora.

### Formato

Um chunk novo **antes** do `VEOF`, e dois campos novos no `VEOF`:

```
[header VMS1] [blocos BLK...] [chunk VIDX] [rodapé VEOF]
```

**Chunk `VIDX`:**

| campo | bytes | tipo | |
|---|---|---|---|
| magic | 4 | `'V','I','D','X'` | |
| chunkSize | 4 | U32 | tamanho total, incluindo magic e crc |
| count | 4 | U32 | número de entradas |
| entries | count × 17 | | uma por bloco, na ordem do arquivo |
| crc32 | 4 | U32 | sobre tudo antes dele |

Cada entrada (17 bytes):

| campo | bytes | tipo | |
|---|---|---|---|
| offset | 8 | U64 | posição do bloco no arquivo |
| startMs | 8 | I64 | `StartUnixMs` do bloco |
| flags | 1 | U8 | bit0 = o bloco contém keyframe de vídeo |

O fim de cada bloco é o começo do seguinte; o do último sai da duração no rodapé.

**Rodapé `VEOF` v2** — os 28 bytes de hoje mais 12:

| campo | bytes | tipo | |
|---|---|---|---|
| magic | 4 | `'V','E','O','F'` | |
| totalBlocks | 4 | U32 | já existe |
| durationMs | 8 | I64 | já existe |
| lastBlockOffset | 8 | U64 | já existe |
| **indexOffset** | 8 | U64 | **novo** — 0 = sem índice |
| **indexCount** | 4 | U32 | **novo** |
| crc32 | 4 | U32 | |

Tamanho: **40 bytes** (v1 tem 28).

Custo: 17 bytes por bloco ≈ 30 KB por hora de gravação, ~730 KB num arquivo de
24 h. Irrelevante perto dos GB de mídia.

### Compatibilidade

> **Decidido depois (16/08/2026):** o formato está em desenvolvimento e **não
> carrega compatibilidade**. O rodapé de 28 bytes e a leitura por versão saíram
> do código, `VMS_FORMAT_VERSION` voltou a **1**, e mudança de layout se resolve
> apagando as gravações. O texto abaixo é o raciocínio da época, mantido porque
> explica por que o `VIDX` e a `BANC` moram onde moram.

- **Leitor antigo lendo arquivo novo:** hoje ninguém lê o rodapé — o
  `ReadNextBlock` só reconhece o magic `VEOF` e para. Vai encontrar `VIDX` antes,
  não reconhecer, e parar igual. Nenhum arquivo novo quebra leitor velho.
- **Leitor novo lendo arquivo antigo:** procura `VEOF` em `Size-40`; não achando,
  em `Size-28` (v1); não achando nenhum, o arquivo está truncado ou em gravação →
  cai no `BuildIndex`.
- `VMS_FORMAT_VERSION` vai a **2**. Nenhum leitor do repositório recusa versão
  desconhecida (nem o `tools/vmslib.py`), mas os scripts passam a saber ler o
  índice.

### Arquivo ainda em gravação

Não tem rodapé — é o caso do dia corrente, justamente o mais consultado. Aí vale o
`BuildIndex`, **uma vez**, com o resultado guardado no cache do servidor (peça 2)
e estendido incrementalmente conforme o arquivo cresce: a cada consulta, retoma da
última posição conhecida em vez de varrer de novo.

### Keyframe no meio do bloco

`TBlockBuilder` fecha bloco por nº de samples, duração ou tamanho — **nunca por
keyframe**. Um keyframe cai no meio do bloco, e é por isso que a entrada do índice
tem o bit "contém keyframe": o servidor acha o bloco anterior com keyframe, manda
a partir dele, e o cliente descarta os samples de vídeo até o keyframe (ele tem o
índice de samples do bloco na mão).

Decidido **não** alinhar bloco por keyframe no gravador: o flag resolve, e o
gravador é a peça que menos se quer mexer.

### Arquivos e mudanças

| arquivo | o que muda |
|---|---|
| `src/Recording/VMS.Rec.Format.pas` | magic `VMS_MAGIC_INDEX`, `TVmsIndexEntry`, versão 2 |
| `src/Recording/VMS.Rec.Writer.pas` | acumular a entrada por bloco no `WriteBlock`; escrever `VIDX` + `VEOF` v2 no `Close` |
| `src/Recording/VMS.Rec.Reader.pas` | `ReadFooter`, `TryLoadIndexFromFooter`, `BuildIndex` como plano B; `Index` passa a expor o flag de keyframe |
| `tools/vmslib.py`, `tools/vmsdump.py` | ler e mostrar o índice; conferir contra a varredura |

**Como verificar:** gravar alguns minutos, parar o servidor (Ctrl+C fecha os
arquivos), e rodar `vmsdump` no arquivo — o índice do rodapé tem que bater
entrada por entrada com o que a varredura acha. É o teste que pega erro de
formato antes de ele virar bug de playback.

---

## Peça 2 — rotas HTTP na porta 8554

### Como HTTP e RTSP dividem a mesma porta

Sai mais barato do que parece, porque as peças já estão prontas:

- `ParseRtspRequest` **já guarda a versão** da linha do pedido, então
  `GET /api/days?… HTTP/1.1` entra pelo mesmo caminho e chega com
  `Req.Version = 'HTTP/1.1'`;
- `TRtspResponse` **já tem `Version` gravável** e o `Serialize` usa o que estiver
  lá, além de acrescentar `Content-Length` sozinho. Uma resposta HTTP é o mesmo
  objeto com `Version := 'HTTP/1.1'`.

Então o roteamento é uma linha no `HandleExecute`: se a versão começa com
`HTTP/`, vai para o roteador da API; senão, segue para a sessão RTSP como hoje.

Cuidados que precisam entrar no código:

- **A resposta sai pelo `SendResponse` da própria sessão**, que já serializa sob
  o `FWriteLock`. É o que impede a resposta da API de se intercalar com os
  pacotes RTP interleaved caso o cliente use a mesma conexão para as duas coisas.
- **Query string**: o `Uri` chega inteiro, com `?a=b&c=d`. Precisa de um parser
  de query (helper pequeno, sem dependência).
- **Keep-alive**: o Indy chama `OnExecute` em laço na mesma conexão, então
  responder e voltar já é keep-alive, que é o padrão do HTTP/1.1. `Connection:
  close` no pedido → desconectar depois de responder.
- **Corpo binário grande**: o `Serialize` concatena cabeçalho + corpo num único
  `TBytes`. Para uma resposta de mídia de ~2 MB vale escrever cabeçalho e corpo
  em duas escritas (mesmo lock), sem a cópia.
- **Métodos**: `GET` e `HEAD`. Um `OPTIONS` com versão HTTP responde a lista de
  métodos HTTP, não a do RTSP — por isso o roteamento olha a versão, nunca o
  método.

Nova config (a porta continua sendo a `rtspPort`):

```json
"api": { "enabled": true, "maxBlocksPerRequest": 32 }
```

### Rotas

Tudo em UTC, milissegundos Unix (`startMs`, `endMs`) — é o que os blocos já
guardam. A conversão para hora local é da UI.

**`GET /api/cameras`** — o que existe para tocar.

```json
{ "cameras": [
  { "name": "isis", "live": true, "firstMs": 1755200000000,
    "lastMs": 1755290000000, "files": 37, "bytes": 21590000000 } ] }
```

`live` = a câmera está publicando no hub agora (o `TLiveHub` já sabe).

**`GET /api/days?camera=isis`** — a lista que abre a tela de playback.

```json
{ "camera": "isis", "tz": "-03:00", "days": [
  { "day": "2026-08-15", "startMs": …, "endMs": …,
    "recordedMs": 71300000, "coverage": 0.83, "files": 37 } ] }
```

`coverage` é a fração do dia com gravação — dá para pintar a força de cada dia na
lista sem baixar os segmentos. O dia é fatiado em **hora local do servidor**
(`tz` vai na resposta para o app não ter que adivinhar).

`recordedMs` é medido **sem** a folga da colagem (encostar não é preencher), e
`segments` é contado **com** ela — senão este número não bateria com o que o
`/api/segments` desenha, e cada reconexão de câmera apareceria como uma faixa a
mais.

**`GET /api/segments?camera=isis&day=2026-08-15&gapMs=5000`** — as faixas
contínuas do dia, prontas para desenhar.

```json
{ "camera": "isis", "day": "2026-08-15", "segments": [
  { "startMs": …, "endMs": … } ] }
```

A colagem é a razão de esta rota existir: cada reconexão abre arquivo novo (P3-5,
11 arquivos em 24 min na isis), então sem colar a barra viraria confete com
dezenas de buracos de 200 ms que não são ausência de gravação. Junta o que se
encosta dentro de `gapMs`; o que sobra de buraco é câmera realmente fora do ar.
Fica no servidor porque só ele enumera os arquivos, e assim a regra mora num
lugar só.

**`GET /api/recordings?camera=isis&fromMs=…&toMs=…`** — a lista crua, um item por
arquivo. Não é o que a UI usa; serve para diagnóstico e para o dia em que a UI
precisar mostrar arquivo por arquivo.

```json
{ "camera": "isis", "files": [
  { "file": "isis_2026-08-15_04-45-01.vms",
    "startMs": …, "endMs": …, "durationMs": 3600000,
    "bytes": 812000000, "blocks": 1801, "closed": true, "indexed": true,
    "video": { "codec": "H264", "width": 1920, "height": 1080 },
    "audio": { "codec": "G711A", "rate": 8000, "channels": 1 } } ] }
```

**`GET /api/media?camera=isis&fromMs=…&blocks=4`** — a mídia.

- `camera` — de quem. **Nome de arquivo não entra aqui**: o cliente pede um
  instante da linha do tempo da câmera, e é o servidor que sabe em qual `.vms`
  aquilo cai;
- `fromMs` — instante pedido, **ou** `cursor=<opaco>` devolvido pela resposta
  anterior (continuação, sem busca);
- `blocks` — quantos blocos (padrão 4, teto `maxBlocksPerRequest`).

Há também `file=<nome>` como parâmetro de **diagnóstico** — serve para o `curl`
da fase 3 e para depurar um arquivo específico. O app nunca usa.

Resposta `application/x-vms`: **header `VMS1` + N blocos**, sem rodapé. Sempre com
header, mesmo na continuação — custa ~100 bytes e faz de toda resposta um `.vms`
válido, que o `TVmsReader` do app abre sem caso especial e que se salva em disco
para depurar.

Cabeçalhos da resposta:

| header | |
|---|---|
| `X-Vms-Cursor` | opaco; devolver como `cursor=` para continuar de onde parou |
| `X-Vms-Block-Count` | quantos blocos foram |
| `X-Vms-Start-Ms` / `X-Vms-End-Ms` | faixa de tempo coberta |
| `X-Vms-Next-Ms` | instante do próximo bloco, ou `-1` se acabou a gravação |
| `X-Vms-Gap-Ms` | buraco entre o fim desta resposta e o `Next-Ms` (0 = contínuo) |
| `X-Vms-Discontinuity` | `1` quando este pedaço começa outro arquivo (header e base de PTS novos) |
| `X-Vms-Keyframe` | `1` se o primeiro bloco tem keyframe |
| `X-Vms-Growing` | `1` se o arquivo ainda está sendo gravado |

É o `X-Vms-Cursor` que atende ao "o cliente já sabe onde está o próximo": depois
da primeira busca por tempo, ele nunca mais procura, só devolve o cursor. Quem
quiser desenhar keyframes na barra pode buscar o índice inteiro em
**`GET /api/index?file=…`** (diagnóstico, corpo binário = as entradas `VIDX`).

### Travessia de arquivo, invisível para o cliente

O cliente pede tempo e recebe mídia; que a câmera tenha gerado 37 arquivos
naquele dia é assunto do servidor. Isso muda três coisas no desenho:

- **O cursor não pode ser "arquivo + bloco".** Ele é opaco, mas por dentro
  carrega o instante do próximo bloco além da dica de arquivo/bloco: se a
  varredura de retenção apagou aquele arquivo entre uma requisição e a seguinte,
  o servidor descarta a dica e resolve pelo tempo — o cliente nem percebe.
  Carrega também uma marca de **travessia**: como o cursor aponta para onde se
  vai (e não para onde se estava), sem essa marca o servidor que o recebe não
  teria como saber que aquele pedaço começa outro arquivo. O formato ficou
  `<nextMs>-<bloco>-<novoArquivo>-<arquivo>`, tudo em caracteres que passam numa
  query sem escapar.
- **Uma resposta nunca atravessa arquivo.** Ela termina no fim do `.vms`
  corrente, e a próxima começa no seguinte, com `X-Vms-Discontinuity: 1`. Cada
  fragmento continua sendo um `.vms` válido com um header só, que é o que
  permite ao cliente usar o `TVmsReader` sem caso especial.
- **O que muda na travessia** e que o cliente precisa tratar ao ver a
  descontinuidade: o **header pode ser outro** (resolução/extradata da câmera
  depois de reconectar) → reanunciar formato ao renderer; e o **PTS recomeça
  noutra base** → re-ancorar o ritmo pelo `StartUnixMs` do primeiro bloco novo,
  em vez de tentar continuar a conta do arquivo anterior. As duas coisas são o
  mesmo tratamento que a sessão ao vivo já faz quando a câmera reconecta.

Reescrever os PTS no servidor para uma linha contínua foi considerado e
descartado: seria trabalho por sample, com duas timescales diferentes, para
resolver algo que a re-ancoragem no cliente já resolve — e destruiria o PTS
original, que é o que os `tools/` usam para diagnosticar.

### Cache de índice

`TVmsIndexCache`, guardado por caminho de arquivo:

- arquivo fechado com `VIDX` → lê o rodapé, guarda, pronto;
- arquivo em gravação → `BuildIndex` uma vez e **estende** a partir do último
  offset conhecido quando o tamanho muda;
- invalidação por tamanho/`LastWriteTime`, e teto de entradas (a varredura de
  retenção apaga arquivo: entrada some no próximo acesso).

O mesmo cache serve `/api/days` e `/api/segments`, que senão abririam todos os
arquivos da pasta a cada consulta.

### Segurança

- **Travessia de caminho**: `file` e `camera` vêm do cliente. Aceitar só
  `[A-Za-z0-9._-]+` (e `.vms` no fim, no caso do arquivo), recusar qualquer `/`,
  `\` ou `..`, e conferir que o caminho resolvido está dentro de `storageDir`.
  Sem isso a rota lê qualquer arquivo da máquina.
- **Sem autenticação** — decidido. Vale o mesmo que hoje vale para o RTSP, mas
  com um alcance maior: quem chega na porta passa a poder **baixar** gravação, e
  não só assistir ao vivo. A trava continua sendo o `bindAddress` no IP do
  Tailscale, e isso precisa estar dito no README e no log de partida. O P3-1,
  quando vier, cobre os dois protocolos de uma vez — que é uma vantagem de
  estarem na mesma porta.
- Teto por requisição (`maxBlocksPerRequest`) para ninguém pedir um dia inteiro
  numa tacada.

### Arquivos e mudanças

| arquivo | |
|---|---|
| `vms/src/Api/Vms.Server.Api.pas` | roteador: rota → (status, headers, corpo). Sem socket, sem estado. O JSON é montado aqui mesmo — a unit separada que este plano previa não se pagou |
| `vms/src/Api/Vms.Server.IndexCache.pas` | cache de índice por arquivo, e o inventário por câmera/dia |
| `vms/src/Server/Tx.Server.Listener.pas` | desvio por versão HTTP no `HandleExecute` |
| `vms/src/Server/Tx.Server.Session.pas` | `HandleHttpRequest`, escrita do corpo binário sob o `FWriteLock` |
| `vms/src/App/Vms.Server.Config.pas` | bloco `api` |
| `vms/vmsserver.dpr`, `.dproj` | units novas |

**Como verificar:** `curl` nas rotas JSON na mesma 8554 que o VLC usa para o ao
vivo (as duas coisas convivendo é metade do teste); e salvar uma resposta de
`/api/media` em `.vms` para abrir com `tools/vmsdump.py` e tocar no `ffplay`. Se
o pedaço sozinho toca, o app vai tocar.

---

## Peça 3 — app: engine de playback e timeline

### O que a investigação mostrou (e que decide o desenho)

**Nenhum dos dois renderers apresenta por PTS.** No Android o `SetDelays` é no-op
declarado — quem manda é o MediaCodec/AudioTrack, e o frame decodificado vai para
a tela na hora. No Windows a fila usa o *tick de chegada* mais um atraso fixo, não
o PTS. Consequência direta: **se o playback despejar os samples, o vídeo passa
acelerado**. Quem ritma tem que ser a engine, e a lógica certa já existe pronta e
testada no servidor (`RunFilePacerOnce`): o vídeo dita o ritmo, o áudio sai na
posição em que foi gravado, e re-ancora quando o desvio passa do limite.

### `VMS.Play.Engine`

```
src/Playback/VMS.Play.Engine.pas
```

- recebe o `IMediaSink` (o renderer, o mesmo do ao vivo) e a câmera;
- **thread de rede**: mantém ~8 s de mídia na fila e pede o próximo pedaço
  devolvendo o `X-Vms-Cursor` quando cai abaixo de ~4 s. Não conhece arquivo:
  quando vem `X-Vms-Discontinuity: 1`, reanuncia o formato ao renderer (se o
  header mudou) e marca o ponto de re-ancoragem para o ritmo; quando vem
  `X-Vms-Gap-Ms > 0`, a barra mostra buraco e o playback pula para o instante
  seguinte; `X-Vms-Next-Ms: -1` é o fim da gravação;
- **thread de ritmo**: tira sample da fila e entrega ao sink no tempo do PTS,
  multiplicado pela velocidade;
- `SeekTo(unixMs)`: cancela o que está em voo, limpa a fila, `OnStreamStopped` no
  renderer (que faz `FlushReset` nos decodificadores), reanuncia
  `OnVideoFormat`/`OnAudioFormat` a partir do header do fragmento e recomeça do
  keyframe;
- `Play`/`Pause`/`SetSpeed`/`OnPosition(unixMs)` para a UI.

Detalhes que vão morder se ficarem para depois:

- **o keyframe vem antes do instante pedido** (até um GOP). Na v1: entregar os
  samples anteriores ao alvo **sem ritmo** (passam num borrão de fração de
  segundo) e só então começar a ritmar. Esconder de verdade exigiria o renderer
  saber decodificar sem apresentar.
- **áudio só em 1×**. Em 2× ou 4× o AudioTrack não acompanha; mudo e pronto.
- **sincronia A/V herda o P2-3**: o `.vms` não tem base de tempo comum entre as
  trilhas, então o que estiver torto na gravação continua torto no playback.
- **o renderer é único e compartilhado com o ao vivo**: entrar no playback tem que
  parar o supervisor antes (`StopPlay` no shell), senão duas fontes alimentam o
  mesmo decodificador.

### `VMS.Api.Client`

```
src/Api/VMS.Api.Client.pas   (System.Net.HttpClient)
src/Api/VMS.Api.Types.pas    (os DTOs das rotas)
```

`THTTPClient` é cross-platform e já funciona no Android com a permissão de
internet que o app tem. Nada de Indy no cliente.

**De onde sai a URL da API:** da própria URL da câmera. Com a API na mesma porta
do RTSP, `rtsp://host:8554/live/isis` vira `http://host:8554/api/…` — mesmo host,
mesma porta, nenhum campo novo na configuração. Câmera apontada direto para o
equipamento não responde `/api/cameras`: sem resposta, o botão da timeline não
aparece.

### UI

```
src/UI/UI.Days.pas       lista de dias
src/UI/UI.Timeline.pas   barra do dia escolhido, sobre o player
```

Dois passos, como decidido:

1. **Lista de dias** — um item por dia com gravação, do mais recente para o mais
   antigo: data, quanto foi gravado, e uma barrinha de `coverage` para bater o
   olho e ver onde há buraco. Vem de `/api/days`.
2. **Timeline do dia** — escolhido o dia, o player abre com a barra na base:
   faixas contínuas de `/api/segments`, régua de horários, zoom (dia/4h/1h/15min/
   3min), play/pause, velocidade (1×/2×/4×), relógio em hora local e botão **ao
   vivo** que volta para o `rtsp://…/live/…` de sempre.

   A interação da barra separa duas coisas que a v1 misturava: **arrastar navega**
   a janela no tempo sem tocar no player (é como se olha o resto do dia sem
   interromper o que está tocando) e **um toque simples posiciona** o player. Uma
   janela movida na mão para de seguir a reprodução até o próximo toque, zoom ou
   dia novo — senão ela seria puxada de volta a cada meio segundo.

Entrada: botão novo na barra de cima do `UI.Player` (o `layTop`), ao lado do log e
do mudo. `Inicio.pas` ganha o estado "modo playback" e o roteamento entre o
supervisor (ao vivo) e a engine (gravação), além das duas telas novas no mesmo
esquema de frames que já existe.

### Níveis de menu

Voltar sobe **um** nível, sempre pelo mesmo caminho. Nenhuma tela devolve para
quem a abriu por atalho — foi o que fez o player e a lista de dias ficarem se
empurrando um para o outro.

```
Câmeras (raiz)                     voltar = minimiza o app
├── Editor de câmera               voltar = Câmeras
├── Player AO VIVO                 voltar = Câmeras (para o ao vivo)
│     └── [relógio] ────────┐      atalho para o galho de gravação
└── Gravações (dias) ◄──────┘      voltar = Câmeras (para tudo)
      └── Player GRAVAÇÃO          voltar = Gravações
            └── [ao vivo]          volta para o Player AO VIVO
```

O relógio e o botão "ao vivo" são os atalhos que cruzam de um galho para o outro;
o voltar nunca cruza.

---

## Fases

Cada fase fecha num ponto verificável. A ordem é de dependência, e as três
primeiras não tocam no app.

| # | o que entra | tamanho | como se verifica |
|---|---|---|---|
| **1** | `VIDX` + `VEOF` v2 no writer, leitura no reader, `tools/` lendo o índice | P | `vmsdump` mostra o índice; ele bate com a varredura, entrada por entrada |
| **2** | desvio HTTP na 8554, cache de índice, `/api/cameras`, `/api/days`, `/api/segments`, `/api/recordings` | M | `curl` devolve o que a pasta tem, com o VLC assistindo ao vivo na mesma porta ao mesmo tempo |
| **3** | `/api/media` (+ `/api/index`) | M | resposta salva como `.vms` abre no `vmsdump`; extraído o vídeo do container, toca no `ffplay` |
| **4** | `VMS.Api.Client` + `VMS.Play.Engine`, sem UI (disparado por botão de teste: "tocar a última hora") | G | vídeo sai na velocidade certa, com áudio, e o seek cai no lugar |
| **5** | `UI.Days` + `UI.Timeline` e a integração no shell | G | escolher dia, arrastar a barra, voltar ao vivo |
| **6** | acabamento: prefetch fino, buracos entre arquivos, velocidade, retomar onde parou | M | uso real, um dia inteiro de gravação |

**Fase 6 — decidido fazer inteira.** Estado por parte, para não refazer o que já
saiu junto das outras fases:

| parte | estado |
|---|---|
| velocidade 1×/2×/4× | pronto na fase 5 |
| retomar onde parou | pronto (volta do segundo plano retoma a posição da gravação) |
| buracos entre arquivos | o servidor sinaliza `X-Vms-Gap-Ms` e a engine pula, mas **a tela não avisa** |
| prefetch fino | falta: hoje é fixo em 8 s de fila e 4 blocos por pedido, sem olhar o bitrate |

Depois da fase 3 já dá para assistir gravação pelo VLC/ffplay apontando para um
arquivo baixado — o que serve de rede de segurança antes de mexer no app.

---

## Riscos e limitações conhecidas

- **Seek cai até um GOP antes** do instante pedido (blocos não são alinhados por
  keyframe). Mitigado pelo borrão sem ritmo.
- **Retenção apaga debaixo do playback**: a varredura pode remover o arquivo que
  está sendo tocado (a API não segura handle). Como o cursor sabe voltar a
  resolver pelo tempo, o servidor responde com o próximo pedaço disponível e um
  `X-Vms-Gap-Ms`; o cliente segue, e o trecho some da barra na consulta seguinte.
- **A travessia de arquivo é o ponto frágil do playback**: header diferente e PTS
  em outra base, no meio de uma reprodução em andamento. É o caso a exercitar de
  propósito na fase 4 — derrubar a câmera durante a gravação para gerar a
  emenda, e depois tocar por cima dela.
- **Uma conexão servindo os dois protocolos**: resolvido mandando a resposta da
  API pelo `SendResponse` da sessão, que serializa sob o `FWriteLock` já
  existente. Se isso for esquecido, uma resposta HTTP no meio de um `PLAY`
  corrompe o fluxo RTP interleaved daquele cliente.
- **Muitos arquivos por dia** (P3-5): dezenas por câmera. `/api/segments` esconde
  isso da UI, mas o inventário cresce — daí o cache por arquivo e a consulta
  sempre recortada por dia.
- **Memória no Android**: um pedaço de 8 s a 2 Mbps são ~2 MB por requisição; com
  fila de 8 s e prefetch, o pico fica em poucos MB. É o primeiro lugar a olhar se
  o app morrer em 1080p.
- **Sem autenticação**: quem alcança a 8554 baixa gravação. `bindAddress` é a
  única trava até o P3-1.

---

## Decisões tomadas

1. **Mesma porta 8554** para RTSP e API, com desvio pela versão da linha do
   pedido. Sem porta nova para liberar, e o P3-1 depois protege as duas coisas de
   uma vez.
2. **Flag de keyframe no índice**, sem alinhar bloco no gravador.
3. **Colagem de segmentos no servidor** (`/api/segments`), junto com `/api/days` —
   é o servidor que enumera os arquivos, então a regra mora num lugar só. Mais
   que isso: **o cliente não sabe que existem arquivos**. Ele pede instante e
   recebe mídia; nome de arquivo não aparece em nenhuma rota que o app use, e a
   travessia é sinalizada por `X-Vms-Discontinuity`.
4. **Sem autenticação** nesta etapa; `bindAddress` continua sendo a trava, e isso
   fica escrito no README e no log de partida.
5. **UI em dois passos**: lista de dias e, escolhido o dia, a timeline dele. Fica
   de fora da v1: miniatura ao arrastar (exige decodificar no servidor), exportar
   trecho e timeline de vários dias numa tela só.
