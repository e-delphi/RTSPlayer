# Ferramentas de diagnóstico

Scripts Python 3 que leem as gravações `.vms` e os logs do vmsserver. Nasceram
de depuração real: quase todo defeito difícil desta base foi resolvido lendo a
gravação, não o log — a gravação mostra o que a câmera entregou de fato.

Há dois grupos aqui. Os primeiros **leem gravação real** e servem para diagnosticar
o que aconteceu; os quatro do fim **modelam** o que o Delphi deveria fazer, e
servem para conferir formato e API sem câmera e sem build — foi com eles que
saíram quatro bugs desta última leva antes de qualquer compilação:

| script | modela |
|---|---|
| `genvms.py` | gera `.vms` sintético (com índice, sem índice, truncado, com região de índice viva) para usar de fixture |
| `apimodel.py` | o que `/api/days` e `/api/segments` devem responder para uma pasta de gravações |
| `fragment.py` | o que `/api/media` devolve, incluindo cursor e travessia de arquivo |
| `pacemodel.py` | o ritmo do playback (1×/2×/4×, borrão do seek) com relógio virtual |
| `selftest.py` | roda tudo acima sobre fixtures e diz passou/falhou |

O `selftest.py` amarra os quatro numa suíte que roda em segundos e responde
passou/falhou, sem Delphi, sem câmera e sem servidor:

```bash
cd tools
python selftest.py
```

São 33 verificações sobre fixtures geradas na hora: formato e âncora A/V,
enquadramento do bloco (a âncora não pode deslocar um byte de payload), índice do
rodapé — inclusive um índice **mentiroso com CRC refeito**, que tem de ser pego —,
CRC de bloco com um byte trocado, colagem de segmentos, a caminhada do
`/api/media` atravessando arquivo, e o ritmo em 1×/2× com o borrão do seek.

Ela não cobre o código Delphi: cobre o **contrato** que ele tem de cumprir, as
mesmas contas sobre os mesmos bytes. Depois de mexer no formato ou na API, rode
antes de compilar.

Não têm dependência externa. `vmslib.py` é o único lugar que conhece o formato
`.vms`; os outros são casca fina em cima dele.

```bash
cd tools
python vmsdump.py     ../vms/bin/recordings/ayla/ayla_2026-08-15_04-45-10.vms --samples 3
python vmstimeline.py ../vms/bin/recordings/ayla/*.vms
python vmscheck.py    ../vms/bin/recordings/isis/isis_2026-08-15_04-45-33.vms
python vmspipeline.py ../vms/bin/recordings/ayla/ayla_2026-08-15_04-45-10.vms
python dvripstats.py  ../vms/bin/logs/isis_2026-08-15.log
```

## Qual usar

| ferramenta | pergunta que responde |
|---|---|
| `vmsdump.py` | O que tem nesse arquivo? Trilhas, blocos, tipos de NAL, deltas de PTS, e se os parameter sets do SDP batem com os do stream. |
| `vmstimeline.py` | O PTS anda no mesmo passo que o relógio? Fora de 1,00x, o ao vivo sai aos trancos. |
| `vmscheck.py` | Tem corrupção ou erro de enquadramento? CRC dos blocos, marcador DVRIP dentro do vídeo, NAL inválido, intervalo de keyframes, distribuição do áudio. |
| `vmsaudio.py` | Não vem nada ou vem silêncio? Mede o nível do G711 gravado, frame a frame, e mostra o nível ao longo do tempo. |
| `vmspipeline.py` | O cliente recebe o bitstream certo? Roda packetizer do servidor + depacketizer do player sobre a gravação e mostra o que chega ao decodificador. |
| `dvripstats.py` | Cadê o áudio dessa câmera DVRIP? Agrega as linhas `parser:` do log por marcador e cruza com o bitrate do vídeo. |

## Casos que essas ferramentas fecharam

Servem como exemplo do que procurar:

- **Imagem cinza numa câmera só pelo servidor.** `vmsdump` mostrou que o SDP anunciava `Baseline/CAVLC` e o stream era `Main/CABAC` com o mesmo `sps_id`; `vmspipeline` mostrou o SPS do SDP entrando colado na frente do slice IDR e sobrescrevendo o bom.
- **Reprodução aos saltos.** `vmstimeline` apontou PTS a 0,41x do relógio numa câmera DVRIP: incremento fixo de 25 fps num stream de 10 fps.
- **Áudio faltando.** `dvripstats` fechou a conta de bytes (99,7% contabilizados) e mostrou o áudio caindo justamente nas janelas em que o vídeo satura o teto de bitrate.
- **Áudio recusado pelo nosso próprio código.** Os pulos de enquadramento no log eram múltiplos exatos de 348 bytes — o tamanho de uma mensagem de áudio. Múltiplo exato não é lixo: é mensagem legítima sendo descartada.
- **"O áudio não funciona" que não era transporte.** `vmsaudio` mostrou 100% dos bytes em `0xD5`, o zero exato do A-law: a câmera entrega silêncio digital puro, enquanto outra câmera no mesmo teste dá RMS 226 de ruído de fundo. Frame chegando e silêncio dentro são problemas opostos.

## Formato do `.vms`

O bastante para escrever ferramenta nova; a referência é `VMS.Rec.Format.pas` e
`VMS.Rec.Writer.pas`.

```
header: 'VMS1' | version(2) | header_size(4) | creation_unix_ms(8)
        | uri_len(2) + uri
        | video_present(1) codec(1) timescale(4) width(2) height(2)
        + extradata_len(4) + extradata
        | audio_present(1) codec(1) sample_rate(4) channels(1) bits(1)
        + timescale(4) + extradata_len(4) + extradata
        | crc32(4)

bloco:  'BLK\x01' | block_size(4) | seq(4) | start_unix_ms(8)
        | sample_count(4) | index_size(4) | índice | payload | crc32(4)

índice: track_id(1) flags(1) pts(8) payload_offset(4) payload_size(4)   [18B]

BANC:   'BANC' | video_anchor_ms(8) | audio_anchor_ms(8)               [20B]
        (no FIM da área de índice, contado dentro de index_size)

VLIX:   'VLIX' | region_size(4) | capacity(4)
        | slot A(count(4) gen(4) crc(4)) | slot B(idem) | reserva(4)  [40B]
        | capacity × (offset(8) start_unix_ms(8) flags(1))            [17B]
        (logo depois do header; os blocos começam DEPOIS dela)

VIDX:   'VIDX' | chunk_size(4) | count(4)
        | count × (offset(8) start_unix_ms(8) flags(1))                 [17B]
        | crc32(4)

rodapé: 'VEOF' | total_blocks(4) | duration_ms(8) | last_block_offset(8)
        | index_offset(8) index_count(4) | crc32(4)          [40 bytes]
```

Little-endian. `track_id` 0 = vídeo, 1 = áudio. `flags` bit 0 = keyframe.
`payload_offset` é relativo ao início do payload do bloco. Vídeo é Annex-B
(start code de 4 bytes); áudio é o payload cru do codec. Arquivo em gravação não
tem rodapé e o último bloco pode estar cortado — as ferramentas param no
primeiro bloco incompleto, sem reclamar.

A `BANC` é a âncora A/V do bloco: o instante de parede em que cada trilha começou
ali. Sem ela, as duas trilhas só têm PTS em bases diferentes e quem toca precisa
supor que começam juntas, congelando na saída a defasagem real. Ela mora no fim da
área de índice porque ali não atrapalha: quem lê percorre exatamente
`sample_count` entradas e acha o payload por `index_size`, então esses 20 bytes
não deslocam nada — verificado no `selftest`.

O `VIDX` é o índice tempo → posição, uma entrada por bloco, escrito quando a
gravação fecha; nele `flags` bit 0 diz que aquele bloco contém keyframe de vídeo,
que é o que permite achar por onde começar a decodificar sem varrer o arquivo. É
o que a timeline do app usa (ver [PLANO-TIMELINE.md](../docs/PLANO-TIMELINE.md)).
Arquivo fechado sem índice continua válido: quem precisar varre.

O `VLIX` é o **mesmo índice, do arquivo ainda em gravação**: uma região de tamanho
fixo reservada na criação, entre o header e o primeiro bloco, e atualizada no
lugar a cada 16 blocos. Vale o slot de commit de geração mais alta cujo CRC bate
(o CRC cobre as `count` primeiras entradas); o outro slot é o seguro contra queda
de energia no meio da atualização. O que ficou depois do último commit sai de uma
varredura da cauda — dezenas de blocos, não o arquivo inteiro. Quando a região
enche, o gravador **roda de arquivo**: é por isso que não existe encadeamento de
índices, e é o tamanho da região que decide o tamanho do segmento.

A região fica FORA do header (e não dentro) porque o header é copiado byte a byte
para dentro de cada fragmento servido pela `/api/media`: um índice ali viajaria
para o celular a cada pedaço de reprodução. Fragmento da API, portanto, não tem
região — e os leitores tratam os dois casos.

O formato está **em desenvolvimento e não lê layout antigo**: a versão do header é
sempre 1, não há caminho de leitura para arquivo de layout anterior, e mudança de
layout se resolve apagando as gravações.

O `vmsdump` confere o índice contra a varredura, entrada por entrada — é o teste
que pega erro de formato antes de ele virar bug de playback.
