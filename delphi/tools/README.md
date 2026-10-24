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
| `genvms.py` | gera `.vms` sintético (com índice, sem índice, truncado, com sidecar `.vms.idx`) para usar de fixture |
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

VIDX:   'VIDX' | chunk_size(4) | count(4)
        | count × (offset(8) start_unix_ms(8) flags(1))                 [17B]
        | crc32(4)

rodapé: 'VEOF' | total_blocks(4) | duration_ms(8) | last_block_offset(8)
        | index_offset(8) index_count(4) | crc32(4)          [40 bytes]

.vms.idx (arquivo ao lado, só enquanto a gravação corre)
cabeç.: 'VIDS' | versão(2) | reservado(2) | creation_unix_ms(8) | crc32(4) [20B]
lote:   'IDXB' | count(4) | valid_up_to(8)
        | count × (offset(8) start_unix_ms(8) flags(1)) | crc32(4)
```

O mesmo layout, desenhado e com as ligações entre os dois arquivos, está em
[anatomia-vms.html](../docs/anatomia-vms.html).

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

O `.vms.idx` é o **mesmo índice, do arquivo ainda em gravação**, num arquivo ao
lado. Escrita só em append: a cada 16 blocos sai um lote com as entradas novas e
o `valid_up_to`, que é o ponto até onde o `.vms` já está coberto. O CRC de cada
lote cobre o cabeçalho dele E as entradas, então um lote cortado ou torto (queda
de energia no meio da escrita) é descartado na leitura e vale tudo que veio
antes; o que ficou depois do último lote válido sai de uma varredura da cauda a
partir do `valid_up_to` — dezenas de blocos, não o arquivo inteiro.

O `creation_unix_ms` amarra o sidecar ao `.vms`: sidecar que não casa é de outra
gravação e se ignora. Fechando a gravação direito, o `VIDX` vai para o fim do
`.vms` e o sidecar é apagado — gravação terminada é auto-suficiente. Fechando
torto (queda de energia), não há `VIDX` e o sidecar FICA, que é o que evita que
aquele arquivo custe uma varredura para sempre. A retenção apaga os dois juntos.

O corpo do `.vms` não muda em nada com isso: os blocos continuam começando
imediatamente depois do header, e o fragmento servido pela `/api/media` (header
copiado byte a byte + blocos crus) continua sendo lido pelo mesmo leitor.

O formato está **em desenvolvimento e não lê layout antigo**: a versão do header é
sempre 1, não há caminho de leitura para arquivo de layout anterior, e mudança de
layout se resolve apagando as gravações.

O `vmsdump` confere o índice contra a varredura, entrada por entrada — é o teste
que pega erro de formato antes de ele virar bug de playback.

## Onde a interface mora

O HTML e o JavaScript das telas são **fonte**, moram em `src/UI/web`, e o que os
servidores servem é o arquivo — não uma cópia dele embutida no executável.

Já foi ao contrário: um gerador convertia as páginas em units Pascal, compiladas
junto. O programa ficava um arquivo só, e cada linha de CSS custava gerar a
unit, recompilar e reabrir. Pior, havia duas verdades possíveis para a mesma
tela — o arquivo e a cópia da última compilação — e nada avisava quando
divergiam. Agora há uma verdade só; o preço é a pasta ter de acompanhar o
executável.

Quem lê é o `Vms.Server.UiFiles`, e vale para os dois servidores. Faltando a
pasta, ou um arquivo dela, o servidor diz isso no log ao subir e a rota responde
404 com o nome do arquivo e o caminho onde ele era esperado — tela em branco sem
explicação seria o pior desfecho.

A pasta é procurada em duas ordens:

| ordem | onde | para quê |
|---|---|---|
| 1 | o que a variável `VMS_UI_DIR` apontar | a máquina de quem desenvolve |
| 2 | `ui` ao lado do executável (Windows) ou a pasta interna do app (Android) | todo o resto |

**A variável** aponta direto para `src/UI/web`, e aí a interface servida é o
fonte: editar e recarregar, sem cópia no meio e sem compilar. Ela ganha da pasta
de propósito — fosse ao contrário, nunca valeria na máquina de desenvolvimento,
que é justamente onde a pasta sempre existe. E como é da máquina, e não do
projeto, quem instala o programa não tem nada a desligar.

```powershell
setx VMS_UI_DIR "C:\caminho\do\repo\src\UI\web"
```

O `setx` só vale para processos abertos DEPOIS dele: fechar e reabrir a IDE faz
parte. Apontando para uma pasta que não existe, ela é ignorada e o servidor diz
isso no log da subida — um erro de digitação não pode trocar a interface inteira
em silêncio.

Uma variável serve aos dois programas: o vmsserver e o rtsplayer rodando no
Windows leem a mesma.

**A pasta `ui`** é o que vale em qualquer outra máquina. No vmsserver ela é
preenchida pelo pós-build a cada compilação, com `robocopy /MIR` — espelho, e
não acréscimo: arquivo que sumiu da origem some do destino também, e não fica
sendo servido depois de renomeado.

```
rmdir "$(OUTPUTDIR)ui" 2>nul
robocopy "$(PROJECTDIR)\..\src\UI\web" "$(OUTPUTDIR)ui" /MIR /NJH /NJS /NDL /NFL /NP
if errorlevel 8 exit /b 1
exit /b 0
```

Três detalhes que parecem sobra e não são: as duas barras (`$(OUTPUTDIR)` sempre
termina em barra e `$(PROJECTDIR)` nunca); o `rmdir` **sem** `/S`, que desfaz uma
junção antiga sem tocar no alvo — com `/S` ele poderia levar os fontes junto; e o
`if errorlevel 8`, porque o robocopy devolve 1 quando copia algo, e sem
normalizar isso uma cópia bem-sucedida reprovaria o build.

No **Android** a pasta é a interna do app (`TPath.GetDocumentsPath` +
`\ui`), e quem coloca os arquivos lá é o *Deployment* do projeto: adicione os
oito de `src/UI/web` com **Remote Path** `assets\internal\ui\`. O
Delphi os deposita na instalação, e é de lá que a leitura acima os pega. Os
arquivos continuam sendo arquivos -- não há identificador para manter, e a fonte
continua sendo `src/UI/web`.

Ao lado do executável, no Android, seria uma pasta do sistema onde nada se
escreve -- por isso o mecanismo simplesmente não existia no aparelho antes
disto.

A leitura é **arquivo a arquivo**: uma pasta com só o `motion-ui.html` dentro
vale para ele e deixa os outros virem de onde vinham.
