# Pendências e roadmap

Estado do projeto em **13/08/2026**. Cobre os dois executáveis do repositório:

- **rtsplayer** — app FMX (Android + Windows) que conecta em câmera RTSP/DVRIP ou no vmsserver.
- **vmsserver** — grava cada câmera em `.vms` e republica como `rtsp://host:8554/live/<camera>`.

Este arquivo é a fonte da verdade das pendências. Ao fechar um item, apague-o daqui e deixe o "porquê" no comentário do código, não no histórico deste documento.

---

## Estado atual

Verificado em teste com três câmeras, conectando **direto** e **pelo vmsserver**:

| câmera | protocolo | vídeo | áudio | situação |
|---|---|---|---|---|
| ayla | RTSP/UDP, ONVIF | H.264 1280×720 @10 fps | G711A 16 kHz | OK nos dois caminhos |
| frente | RTSP/TCP+UDP | H.265 @13,6 fps | G711A 8 kHz | OK nos dois caminhos |
| isis | DVRIP (Sofia/XM) | H.264 1080p @10 fps | G711A 8 kHz | vídeo OK; **áudio ~6%** |

Base que já está de pé: RTSP (TCP interleaved e UDP, Digest, keep-alive, fallback de transporte), DVRIP com login Sofia e OPMonitor, depacketizers H264/H265/AAC/G711/G726/MJPEG/PCM, gravação `.vms` em blocos com limpeza automática por idade/tamanho/espaço livre, republicação ao vivo por buffer em memória (o arquivo só entra no playback histórico e quando a câmera não está publicando), decodificação por MediaCodec (Android) e FFmpeg (Windows).

---

## Pendências

Prioridade pelo impacto em uso real: **P1** atrapalha o uso hoje, **P2** é defeito real sem sintoma visível ainda, **P3** é dívida técnica.

### P1-1 · Áudio da isis (DVRIP): dois problemas separados

São duas coisas independentes, e cada uma resolve num lugar diferente.

**(a) O que chega é silêncio digital puro.** `vmsaudio` mediu 100% dos bytes em `0xD5` — o zero exato do A-law — em todos os 3.296 frames de uma sessão de 4 min. Nem ruído de fundo. Para comparar, no mesmo teste a frente deu 2,7% de `0xD5` e RMS mediano 226, com picos de 5023. Ou seja: mesmo entregando 100% dos frames, não haveria o que ouvir.

Isso descarta a hipótese de a câmera só transmitir quando há barulho: ela transmite o silêncio. E `AudioEnable` está `true` no Encode config. Silêncio *exato* (e não ruído baixo) aponta para o firmware preenchendo silêncio, isto é, microfone não amostrado — ganho/volume em zero, entrada de áudio desligada ou mudo na câmera.

**Próximo passo:** fazer barulho perto da isis e rodar `vmsaudio --janela 10`. Se o RMS continuar exatamente 8, o microfone não está sendo lido, e o ajuste é na câmera (volume/ganho de entrada, tipo de entrada), não aqui. Conferir também o que o iCSee mostra de configuração de áudio dessa câmera.

**(b) Nem todos os frames chegam, e isso acompanha o bitrate do vídeo.** Medido em três sessões:

| sessão | bitrate do vídeo | áudio entregue |
|---|---|---|
| 13/08 21:00 | ~970 kbps | 6% |
| 15/08 04:45 | ~970 kbps | 0% (era o byte 3, ver abaixo) |
| 15/08 05:27 | 89–160 kbps | 55% |

O teto configurado na câmera é 1024 kbps para o MainFormat. Com o vídeo ocupando ~15% do orçamento, o áudio passou de 6% para 55%; com o vídeo saturando, o áudio quase desaparece. A leitura que fecha com os dois lados é orçamento **compartilhado** entre as trilhas.

**O byte 3 do header, que nós mesmos quebramos.** Mensagem DVRIP de áudio tem 348 bytes: header de 20 + frame `00 00 01 FA` de 8 + 320 bytes de G711. O header é legítimo — `MsgID=1412` (mídia), SessionID da sessão, `DataLen=0x148`:

```
ff 01 00 80 | f3 00 00 00 | 00 00 00 00 | 00 00 | 84 05 | 48 01 00 00
 0  1  2  3     SessionID     sequence    tot/cur  MsgID     DataLen
```

O byte 3 vale `0x80` no áudio e `0x00` no vídeo — **não é reservado, é flag**. Exigir zero ali descartava todo o áudio (6% → 0%); corrigido, e o mapa do header na unit está atualizado. Quem filtra header falso é o SessionID, que não depende disso.

**Cuidado com a conta de bytes:** o `in=` do log conta o que a sessão **entrega** ao parser, então mensagem recusada no resync é invisível ali. Foi o furo que levou à conclusão errada de que os bytes de áudio não chegavam.

A mesma correlação dentro de uma sessão só, por janela de 5 s:

| bitrate do vídeo | janelas | % com áudio | frames/janela |
|---|---|---|---|
| < 600 kbps | 6 | 100% | 26,5 |
| 600–800 | 31 | 90% | 15,3 |
| 800–950 | 62 | 58% | 8,5 |
| 950–1100 | 76 | 21% | 2,5 |
| > 1100 | 43 | 30% | 4,1 |

**Próximo passo:** subir `BitRate` do MainFormat (1024 → 2048) ou baixar `Quality`, e comparar com `dvripstats`. Não toca em código. Se não bastar, o substream tem folga (QVGA, 512 kbps), mas o caminho dele hoje pede `CombinMode = NONE`, que é vídeo **sem** áudio — testar por ali exige `CONNECT_ALL` no `Extra1`.

### P1-2 · Origem do escorregão de enquadramento DVRIP

**Sintoma.** A cada 1–3 min o fluxo DVRIP sai de sincronia. O resync recupera, mas a causa da **primeira** perda é desconhecida.

**O que já está tratado.** Header falso não passa mais: além do marcador `0xFF`, exige-se bytes 2–3 reservados em zero, SessionID da sessão (ou 0) e `DataLen` ≤ 4 MB. Antes, um `0xFF` 14 bytes antes de um header real fazia o `DataLen` ser lido em cima do SessionID do header seguinte (`0x00BF0000` = 12,4 MB) e a sessão morria. **Resultado medido: 10 quedas em 24 min viraram 0 em 21 min.** O payload também tem prazo total de 5 s, então tamanho impossível falha rápido em vez de travar ~100 s.

**O que continua aberto.** O enquadramento ainda escorrega — 20+ vezes em 21 min, e o `vmscheck` acha 13 marcadores `0xFD` dentro do payload de vídeo, o que é length de frame errado engolindo o frame seguinte. Agora recupera sem derrubar a sessão, mas a causa da primeira perda segue desconhecida. Parte disso é o próprio P1-1 (mensagem de áudio recusada aparece como escorregão).

**Próximo passo.** Depois de fechar o P1-1, ver o que sobra de escorregão e instrumentar a mensagem **anterior** ao primeiro resync (MsgID e DataLen). Se for sempre o mesmo MsgID, é tamanho mal calculado naquele tipo de mensagem.

### P1-3 · `storageDir` dentro de pasta sincronizada

A retenção automática já está implementada (`retention` no `vmsserver.json`), mas o `storageDir` do exemplo aponta para `recordings` ao lado do executável, que aqui está **dentro do OneDrive**. Cada bloco gravado entra na fila de sincronização, e com ~21 GB/dia isso é upload contínuo e sem propósito.

**Próximo passo.** Apontar `storageDir` para uma pasta fora de qualquer pasta sincronizada (ex.: `D:\vms\recordings`) e, no código, avisar na partida quando o caminho estiver sob OneDrive/Dropbox/Google Drive.

### P1-4 · Tailscale: o que falta depois da primeira versão

Já implementado (`VMS.Net.Tailscale`, campo `tailscale` por câmera, switch no editor): antes de cada tentativa de conexão, se a câmera está marcada, o app testa a porta real da câmera; se não responde, abre o app do Tailscale e espera até 30 s a rota aparecer, testando de 500 em 500 ms. Vale também nas reconexões e no botão *Testar conexão*.

**O limite da plataforma, que não tem como contornar por Intent:** o Android não deixa um app ligar a VPN de outro app — só o dono do `VpnService` sobe o túnel, e com consentimento do usuário. Então o app do Tailscale vai para a frente e **quem liga é o usuário**, a menos que ele já esteja configurado para conectar ao abrir. O que ficou em aberto por causa disso:

1. **Feedback na tela.** Hoje a espera aparece só como "Conectando" mais as linhas no log de depuração. Falta um estado próprio — "aguardando a VPN" é diferente de "conectando na câmera", e o usuário precisa saber que tem que tocar em algo no outro app.
2. **Saber se a VPN está de pé, e não só se a câmera responde.** Com `ConnectivityManager` + `NetworkCapabilities.TRANSPORT_VPN` dava para distinguir "túnel caído" de "túnel de pé e câmera desligada", e evitar jogar o usuário no Tailscale quando o problema é a câmera. Ficou de fora para não depender de classes JNI que talvez não estejam declaradas nesta versão do Delphi — precisa testar.
3. **Voltar para o app sozinho** depois de o túnel subir. Hoje o usuário volta na mão.
4. **Tailscale ausente.** Se o app não está instalado, o log avisa e a conexão falha normalmente; não há convite para instalar.
5. **Detecção automática não liga nada.** `LooksLikeTailnetHost` (CGNAT `100.64.0.0/10` e `*.ts.net`) só emite aviso no log quando o host parece da tailnet e a opção está desligada. É de propósito: ligar sozinho mudaria o comportamento de quem não pediu. Se na prática o aviso sempre significar "esqueci de marcar", vale pré-marcar o switch no editor quando o host casar.
6. **Verificar em campo pelo 4G** — o caminho todo foi escrito, mas ainda não foi exercitado fora da LAN.

### P2-1 · SDP do servidor propaga parameter sets falsos

O SDP do vmsserver monta `sprop-parameter-sets` a partir do extradata do `.vms`, que veio do SDP da câmera. Na ayla esse SPS/PPS **não bate com o stream** (SDP diz Baseline/CAVLC, o stream é Main/CABAC, ambos com `sps_id=0`).

O player já ignora parameter sets do SDP quando o stream traz os seus in-band, então o caminho nosso está OK. Mas VLC, ffplay e o `csd-0` do MediaCodec continuam recebendo o SPS/PPS errado.

**Próximo passo.** No `HandleDescribe`, extrair SPS/PPS do primeiro keyframe do arquivo e preferi-los ao extradata do header. Fecha junto o item P2-2.

### P2-2 · Android recebe `csd-0` do SDP, não do stream

`TVideoDecoder.DoConfigure` passa o extradata do SDP como `csd-0` ao MediaCodec. Na ayla funciona por sorte — o SPS falso declara a resolução certa (1280×720). Com outra câmera mentindo a resolução, o decoder configura errado. Resolvido por P2-1, ou lendo o SPS in-band antes de configurar.

### P2-3 · Sincronia A/V sem base de tempo comum

O `.vms` guarda PTS por trilha, cada uma na sua timescale, e nada que relacione as duas. O pacer ancora as duas trilhas no mesmo instante de parede, então a defasagem que existir **dentro** do primeiro bloco fica congelada na saída. Com áudio regular (ayla, frente) o erro é de dezenas de ms; com áudio esburacado (isis) não há sincronia possível.

Vale para o caminho de arquivo — playback e o ao vivo de reserva. No ao vivo pela memória o sample sai na ordem e com o PTS que a câmera mandou, sem âncora nossa no meio.

**Próximo passo.** Gravar o instante de parede de chegada por sample (ou uma âncora A/V por bloco) e usá-lo como base comum no pacer.

### P2-5 · `AVPacket` sem padding no backend FFmpeg

`DecodeSample` aponta `FPkt.data` direto para um `TBytes` sem os `AV_INPUT_BUFFER_PADDING_SIZE` (64) bytes zerados que a API do FFmpeg exige. Funciona na prática, mas é leitura fora do buffer por contrato — decodificador pode ler lixo no fim do último NAL. Alocar com folga zerada.

### P2-6 · CRC32 é gravado e nunca verificado

O writer calcula e grava CRC no header e em cada bloco; o leitor nem olha. Bloco corrompido (queda de energia, disco cheio) é lido como válido.

Junto: em `ReadNextBlock`, `PayloadLen` é calculado 4 bytes maior do que o payload real — inclui o CRC. Hoje é inofensivo, porque cada sample é endereçado por offset/tamanho, mas conserta-se no mesmo lugar.

### P3-1 · vmsserver não tem autenticação

Qualquer um na rede assiste a qualquer câmera em `rtsp://host:8554/live/<nome>`, e o nome é adivinhável. Falta Digest no lado servidor (o cliente já tem a implementação, dá para reusar).

### P3-2 · Senhas de câmera em texto claro no JSON

`vmsserver.json` e a config do app guardam usuário e senha em claro. No mínimo, tirar do log e cifrar em repouso.

### P3-3 · Caminho UDP do servidor pouco exercitado

O `SETUP` em UDP é aceito, mas o servidor responde `server_port=0-0` (cliente que valide a porta de origem pode recusar) e não manda RTCP SR. Nos testes o player sempre fechou em TCP interleaved, então esse caminho nunca rodou de verdade.

### P3-4 · Sem RTCP em nenhuma ponta

O player descarta o RTCP que recebe e não manda RR; o servidor não manda SR. Sem isso não há estatística de rede padrão, nem keep-alive de sessão UDP, nem base para relógio comum entre trilhas.

### P3-5 · Um `.vms` novo por reconexão

Cada queda da câmera fecha o arquivo e abre outro — na sessão da isis foram 11 arquivos em 24 min. Quem assiste ao vivo não sente mais (a mídia vem da memória, e o caminho de arquivo ainda segue o arquivo novo sozinho), mas o histórico fica picado. Continuar o mesmo arquivo quando a reconexão é rápida (ou consolidar depois).

### P3-6 · Ordem de notificação no primeiro pacote

No `TCameraSession`, o primeiro RTP é despachado dentro do `ValidateFirstRtp`, antes de `NotifySinkFormat`. Se esse pacote completar um sample, ele chega ao sink antes do `OnVideoFormat` — hoje os dois sinks descartam sem estragar nada, mas a ordem está errada.

### P3-7 · Nenhum teste automatizado

Não há teste no repositório. As partes mais testáveis são justamente as que mais quebraram: formato `.vms`, depacketizers, packetizers, parser DVRIP. Os scripts Python de análise usados no diagnóstico desta rodada são um bom ponto de partida (ver "Ferramentas").

---

## Recursos futuros

Ordenados por valor para quem usa, com a dependência técnica quando existe.

### Câmera e protocolo

- **PTZ** — mover, zoom e presets. DVRIP tem `OPPTZControl`; nas RTSP/ONVIF exige o serviço PTZ (SOAP), que o projeto ainda não fala.
- **Áudio bidirecional (falar pela câmera)** — DVRIP `OPTalk`. Precisa de captura de microfone e encoder G711 no app, que hoje só decodifica.
- **Eventos e alarmes** — detecção de movimento e alarme da câmera (mensagens de alarme DVRIP, eventos ONVIF), para notificar e disparar gravação.
- **Descoberta automática** — WS-Discovery (ONVIF) e broadcast DVRIP, para achar câmera na rede em vez de digitar IP.
- **ONVIF de verdade** — hoje a URL RTSP é fixa na config; o serviço Media daria perfis, resoluções e URIs sem chute.

### Gravação e playback

- **Playback com timeline no app** — o `.vms` já tem índice de blocos e `SeekToTime`; falta a UI (barra de tempo, arrastar, velocidade).
- **Gravação por evento** — pré e pós-alarme, em vez de gravar 24 h.
- **Exportar trecho em MP4** — o `.vms` é formato interno; exportar recorte para compartilhar. Precisa de muxer (dá para reusar as DLLs do FFmpeg no Windows).
- **Snapshot JPEG** — do frame exibido (`Tx.Pkt.MJPEG` e o encoder JPEG já existem no lado Windows).
- **Cota por câmera na retenção** — hoje a limpeza apaga o mais antigo da pasta, sem olhar de quem é. Uma câmera muito mais movimentada encurta o histórico das outras.

### App

- **Mosaico** — 2×2 / 3×3 com várias câmeras ao vivo. Depende de rever o uso de memória e decoders simultâneos no Android.
- **Notificação push de evento** — depende de eventos e alarmes.
- **Perfis de qualidade** — alternar Main/Sub por câmera na UI (o suporte a substream já existe no DVRIP via URL).

### Servidor

- **Autenticação e usuários** — ver P3-1, com permissão por câmera.
- **API HTTP de status** — câmeras conectadas, bitrate, quedas, espaço em disco; hoje só o log em arquivo.
- **UI de configuração** — o `vmsserver.json` é editado à mão, sem validação.
- **Serviço do Windows** — rodar sem console aberto, com início automático.

### Qualidade

- **Testes de formato e protocolo** — ver P3-7. Fixtures a partir de gravações reais: um `.vms` de cada câmera é um caso de teste pronto.
- **Build por linha de comando** — o Delphi instalado bloqueia `msbuild`/`dcc32` neste ambiente, então todo build passa pela IDE. Sem isso não há CI.

---

## Ferramentas de diagnóstico

Estão em [`tools/`](../tools/README.md), com o formato do `.vms` documentado ali: `vmsdump` (panorama e conferência dos parameter sets), `vmstimeline` (PTS × relógio), `vmscheck` (corrupção e enquadramento), `vmsaudio` (nível do áudio: silêncio × nada), `vmspipeline` (simula servidor + player sobre uma gravação) e `dvripstats` (agrega as linhas `parser:` do log).

Um `.vms` de cada câmera é um caso de teste pronto — é o caminho mais curto para o P3-7.
