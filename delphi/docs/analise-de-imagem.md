# Análise de imagem: movimento, objetos e eventos

Como o `vmsserver` olha para a gravação, decide que algo aconteceu, e como esse
"algo" chega até a linha do tempo do app.

---

## O caminho inteiro, de uma vez

```
        .vms no disco
             │
   IKeyframeSource ──► o quadro comprimido do instante  (busca binária no índice)
             │                                           Vms.Thumb.Keyframe
   IFrameGrabber  ──► RGB 24, no máximo 640x640          Vms.Thumb.FFmpeg
             │
             ▼
      IFrameAnalyzer                                     Vms.Analytics.Analyzer
        ├─ IMotionDetector   mexeu?     grade 64x36      Vms.Analytics.Motion
        └─ IObjectDetector   o que é?   YOLO / ONNX      Vms.Analytics.Onnx
             │
             ▼  (agregação: um evento aberto por rótulo)
        IEventStore  ──►  <camera>/events/2026-08-23.vev Vms.Analytics.Store
             │
        IEventSource ──►  GET /api/events                Vms.Server.Api
             │
             ▼
   faixa de marcas na barra  +  tela "Eventos"           UI.Timeline / UI.Events
```

As duas primeiras caixas **já existiam**: são exatamente as interfaces que as
miniaturas usam. Foi por elas existirem que este subsistema coube em sete
units — nada aqui sabe o que é um `.vms` nem o que é H.264.

---

## Movimento: por que não é diferença entre quadros

A análise anda de 2 em 2 segundos de gravação. Nesse intervalo, a luz do dia
muda o suficiente para o quadro inteiro "mexer". Comparar com o quadro anterior
acusaria movimento a tarde toda.

A referência é um **fundo** que se adapta devagar (média exponencial, α ≈ 10%
por análise). Ele acompanha a luz e ignora o que é permanente, deixando só o que
é transitório — que é a definição operacional de movimento aqui.

Três regras que vieram de como câmera de vigilância se comporta de verdade:

| situação | o que acontece |
|---|---|
| ≥ 55% das células mudaram | **cena nova**, não movimento: luz acesa, IR comutando, câmera reposicionada. O fundo é refeito na hora e nenhum evento sai. |
| salto > 4 passos no tempo | buraco de gravação ou troca de arquivo. A referência é zerada — senão toda retomada viraria um evento. |
| célula mudou < 14 níveis de luma | ruído de compressão, não movimento. Um H.264 a bitrate baixo oscila alguns níveis com a cena parada. |

A grade é 64×36 (2.304 células), com **média de caixa**, não amostragem: amostrar
deixa o ruído de sensor passar inteiro, e aí o limiar teria de subir tanto que
uma pessoa ao longe deixaria de acender célula nenhuma.

---

## Objetos: quando a rede roda

Movimento custa microssegundos. A rede custa centenas de milissegundos — ou
segundos, dependendo do modelo. Numa câmera de rua com movimento contínuo, rodar
a rede em todo quadro faz a análise andar **mais devagar que a gravação cresce**,
e ela nunca alcança o presente.

Por isso a rede só entra quando:

1. houve movimento naquele quadro, **e**
2. passou `objectIntervalMs` desde a última passada.

Entre duas passadas, o movimento continua sendo registrado normalmente.

### Quanto custa, medido

`yolo26x.onnx` nesta máquina (16 núcleos, 8 threads para o ORT, só CPU):

| | |
|---|---|
| entrada | `[1, 3, 640, 640]` |
| saída | `[1, 300, 6]` — detect **end-to-end**, sem NMS |
| carregar o modelo | 0,5 s, uma vez na subida |
| **inferência** | **430 ms por quadro** |

A saída `[1, 300, 6]` é a primeira linha da tabela de formatos do vendor, e o
`task: detect` está nos metadados junto com os 80 nomes do COCO — ou seja, o
`Vision.Decoder.Detect` reconhece isto sozinho, sem configuração.

Com `objectIntervalMs: 5000`, cada câmera gasta 430 ms de rede a cada 5 s de
gravação analisada: **~9% de tempo real por câmera**. Três câmeras dão ~26%,
compartilhando um detector só (serializado por lock) — folgado numa máquina
destas. Recuperar 6 horas de histórico de uma câmera leva algo como 20 minutos.

Se apertar, o caminho é subir `objectIntervalMs` antes de trocar de modelo. E se
precisar mesmo de mais folga, exportar um `yolo26n`/`yolo26s` dá a mesma cabeça e
as mesmas classes bem mais barato — nada no código muda, porque `Vision.Model` lê
os nomes das classes do próprio `.onnx`.

---

## Agregação: por que um evento e não oito

Uma pessoa atravessando o quintal aparece em oito quadros seguidos. Oito eventos
de `person` na linha do tempo não descrevem melhor o que houve do que **um**
evento de 16 segundos — descrevem pior, porque escondem que foi uma passagem só.

Cada rótulo tem, no máximo, um evento **aberto** por vez:

- avistamento novo do mesmo rótulo **estende** o evento aberto;
- passado `mergeGapMs` sem ver de novo, o evento **fecha** e vai para o disco;
- `score` e caixa guardados são os do quadro de **pico** — a união das caixas
  seria o quintal inteiro depois de três passagens.

Três pessoas no mesmo quadro são **um** evento `person` com `count = 3`, e não
três eventos que a barra desenharia empilhados no mesmo lugar.

---

## O arquivo `.vev`

```
<storage>/<camera>/events/2026-08-23.vev
<storage>/<camera>/events/progress.txt
```

Cabeçalho de 32 bytes, seguido de registros de 64, sempre anexados:

```
 cabeçalho (32 B)                    registro (64 B, tamanho fixo)
 +0   'VEV1'            4 B          +0   startUnixMs         i64
 +4   versão = 1        u16          +8   endUnixMs           i64
 +6   tamanhoReg = 64   u16          +16  tipo (0=mov 1=obj)  u8
 +8   criadoUnixMs      i64          +17  quantidade          u8
 +16  reservado        12 B          +18  score × 10000       u16
 +28  crc32(0..27)      u32          +20  caixa L,T,R,B    4× u16
                                     +28  reservado           u32
                                     +32  rótulo UTF-8       28 B
                                     +60  crc32(0..59)        u32
```

Registro de tamanho fixo, e não JSON por linha, por três razões nesta ordem:

1. **Queda no meio de um append** deixa um rabo truncado. Com passo fixo mais CRC
   por registro, o leitor descarta exatamente o que ficou pela metade e aproveita
   todo o resto — a mesma disciplina do `.vms.idx`.
2. **Anexar é uma escrita**, sem reler nem reescrever o arquivo do dia.
3. Um dia cheio são alguns milhares de registros, umas centenas de KB. Ler o dia
   e filtrar em memória é mais barato que qualquer índice por cima.

A caixa vai **normalizada 0..1**, e não em pixels: o app desenha sobre um vídeo
que pode estar em qualquer resolução, e a mesma câmera muda de perfil sem avisar.
1/65535 de um quadro 1080p é um centésimo de pixel — a perda é invisível.

O rótulo cabe em 28 bytes porque nome de classe de modelo de detecção é curto
(o mais longo do COCO tem 13 caracteres). Mais longo que isso é truncado.

O dia é o **local**, igual ao das miniaturas, para quem abrir a pasta entender o
que está vendo. Evento que atravessa a meia-noite fica no arquivo do dia em que
**começou**; a consulta cobre isso lendo também o dia anterior à janela.

`progress.txt` é texto puro, um número: até onde a análise chegou. **Apagá-lo é a
forma de mandar reanalisar tudo** — a operação que se quer no dia em que se troca
o modelo ou baixa o limiar.

---

## A rota HTTP

```
GET /api/events?camera=frente&fromMs=…&toMs=…
               [&kind=motion|object] [&name=person]
               [&minScorePct=50] [&limit=500]
```

```json
{
  "camera": "frente", "tz": "-03:00",
  "fromMs": 1755950000000, "toMs": 1756036400000, "count": 2,
  "events": [
    { "startMs": 1755951200000, "endMs": 1755951214000,
      "kind": "object", "name": "person", "score": 0.87, "count": 3,
      "box": { "l": 0.31, "t": 0.22, "r": 0.48, "b": 0.91 } }
  ]
}
```

Entra o evento que **se sobrepõe** à janela, não só o que começa dentro dela:
quem abre a barra às 14h quer ver a passagem que começou às 13h58 e ainda estava
acontecendo. A janela é obrigatória e limitada a 7 dias — sem teto, um cliente
com erro de fuso pediria "de 1970 até agora".

`/api/cameras` ganhou dois booleanos de capacidade do **servidor**: `events` e
`thumbs`. O app usa para não oferecer uma tela que nunca teria conteúdo.

---

## Configuração (`vmsserver.json`)

```json
"analytics": {
  "enabled": true,
  "stepMs": 2000,
  "motionThreshold": 0.012,
  "sceneChangeThreshold": 0.55,
  "mergeGapMs": 8000,
  "backfillHours": 6,
  "lagMs": 30000,
  "modelPath": "C:/.../yolo26x.onnx",
  "onnxDll": "onnxruntime.dll",
  "objectIntervalMs": 15000,
  "objectThreshold": 0.35,
  "classes": ["person", "car", "motorcycle", "truck", "bus", "bicycle", "dog", "cat"]
}
```

| chave | o que faz |
|---|---|
| `enabled` | vem **desligada** por omissão, ao contrário do ao vivo e da API: é a única coisa que consome CPU continuamente numa máquina que também está gravando. |
| `stepMs` | de quanto em quanto tempo **de gravação** um quadro é analisado. Mínimo 500 ms. |
| `motionThreshold` | fração do quadro que precisa mudar para valer movimento. |
| `sceneChangeThreshold` | acima disto é cena nova, não evento. |
| `objectIntervalMs` | teto de passadas da rede. É o que separa o custo barato do caro. |
| `mergeGapMs` | dois avistamentos do mesmo rótulo separados por menos que isto são o mesmo evento. |
| `backfillHours` | quanto de passado analisar na primeira subida. `0` = tudo o que houver. |
| `lagMs` | distância mínima do agora. O arquivo mais recente está sendo escrito. |
| `modelPath` | vazio = **só movimento**. Relativo resolve contra o executável, não contra o diretório de trabalho (o servidor costuma subir como serviço). |
| `classes` | vazio ou ausente = todos os rótulos do modelo. |

### O que precisa estar ao lado do `vmsserver.exe`

Tudo já está em `vms/bin`, que fica fora do git:

```
vmsserver.exe / vmsserver.json
onnxruntime.dll                          15 MB
yolo26x.onnx                            223 MB   ← modelPath aponta para cá
MSVCP140.dll  MSVCP140_1.dll                     ┐ importadas pelo onnxruntime
VCRUNTIME140.dll  VCRUNTIME140_1.dll             ┘ (VC++ 2015-2022)
avcodec-61  avutil-59  swscale-8                 ┐ decodificação, as mesmas
swresample-5  libx264-164  zlib                  ┘ que as miniaturas já usavam
```

Todos os binários são **x64**, como o `vmsserver.exe`. `modelPath` e `onnxDll`
relativos resolvem contra o executável, então a pasta é auto-contida: dá para
copiá-la inteira para outra máquina.

**Ausência não é erro.** Sem o modelo (ou sem a DLL, ou se o modelo não carregar),
o servidor sobe igual e a análise roda **só com movimento**. Sem FFmpeg não há
quadro para analisar, e aí a análise não sobe — com um aviso no log, porque nesse
caso o usuário pediu algo que não vai acontecer.

---

## No app

**Faixa na barra do tempo.** Uma tira fina logo acima da tira de gravação.
Laranja = movimento; vermelho = objeto reconhecido, desenhado por cima — onde os
dois coincidem (quase sempre, já que a rede só roda com movimento), o que se vê é
a informação mais específica das duas.

**Tela "Eventos"** (botão na barra, que só aparece quando o servidor tem análise).
Um item por evento, do mais recente para o mais antigo, agrupado por hora, com a
miniatura do momento, o rótulo em português, a duração e a confiança. Abas
`Objetos` / `Movimento` / `Tudo` — começa em *Objetos*, porque movimento numa rua
é quase contínuo e a pergunta que se faz é "o que passou aqui".

Tocar num item leva a reprodução para **2 segundos antes** do começo do evento:
cair no primeiro quadro faria a coisa já estar acontecendo. Voltar retoma a
gravação exatamente onde se estava.

As miniaturas vêm pelo **mesmo** `IThumbProvider` da barra — sem cache novo, sem
thread nova, sem rota nova. O provedor aceita um assinante só, então quem assina
o aviso de "chegou imagem" é o formulário, que repassa para a tela visível.

---

## Onde cada decisão mora

| unit | responsabilidade única |
|---|---|
| `Vms.Analytics.Types` | o vocabulário: evento, caixa, configuração. Não depende de nada. |
| `Vms.Analytics.Intf` | as fronteiras: detectar, guardar, consultar, analisar. |
| `Vms.Analytics.Motion` | mexeu? Aritmética de inteiros, sem dependência nenhuma. |
| `Vms.Analytics.Onnx` | o que é? **A única unit que fala com o vendor.** |
| `Vms.Analytics.Analyzer` | quadro vira evento (agregação). Não conhece nenhum detector por dentro. |
| `Vms.Analytics.Store` | bytes e pastas. Escreve e lê o `.vev`. |
| `Vms.Analytics.Worker` | a thread que percorre a gravação. |
| `Vms.Server.Composition` | **o único lugar que conhece implementação concreta.** |

Trocar YOLO por outra coisa — ou por um serviço remoto — é escrever outra classe
que implemente `IObjectDetector`. Nada mais é tocado.

O código de terceiro está em `vendor/onnx-pascal`, cópia literal, sem uma vírgula
de diferença: comparar com o original continua sendo um `diff` limpo, e uma
correção lá em cima chega aqui com um `cp`.
