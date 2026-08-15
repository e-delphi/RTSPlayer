# Ferramentas de diagnóstico

Scripts Python 3 que leem as gravações `.vms` e os logs do vmsserver. Nasceram
de depuração real: quase todo defeito difícil desta base foi resolvido lendo a
gravação, não o log — a gravação mostra o que a câmera entregou de fato.

Não têm dependência externa. `vmslib.py` é o único lugar que conhece o formato
`.vms`; os outros são casca fina em cima dele.

```bash
cd tools
python vmsdump.py     ../vms/bin/recordings/ayla_2026-08-15_04-45-10.vms --samples 3
python vmstimeline.py ../vms/bin/recordings/*.vms
python vmscheck.py    ../vms/bin/recordings/isis_2026-08-15_04-45-33.vms
python vmspipeline.py ../vms/bin/recordings/ayla_2026-08-15_04-45-10.vms
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

rodapé: 'VEOF' | total_blocks(4) | duration_ms(8) | last_block_offset(8) | crc32(4)
```

Little-endian. `track_id` 0 = vídeo, 1 = áudio. `flags` bit 0 = keyframe.
`payload_offset` é relativo ao início do payload do bloco. Vídeo é Annex-B
(start code de 4 bytes); áudio é o payload cru do codec. Arquivo em gravação não
tem rodapé e o último bloco pode estar cortado — as ferramentas param no
primeiro bloco incompleto, sem reclamar.
