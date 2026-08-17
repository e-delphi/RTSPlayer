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

> **Decidido:** fica aberto, e a próxima ação é **na câmera** — não em código.
> Nesta ordem: (1) fazer barulho perto dela e rodar `vmsaudio --janela 10`; se o
> RMS continuar em 8, o microfone não está sendo lido e o ajuste é ganho/entrada
> no iCSee; (2) subir `BitRate` do MainFormat de 1024 para 2048 e comparar com
> `dvripstats`. Sem essa medição, mexer no parser é chute.

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

> **Decidido:** fica na fila **atrás do P1-1**, exatamente por isso — mensagem de
> áudio recusada aparece como escorregão e contamina a contagem. Sem sintoma
> visível hoje (o resync recupera e a sessão não cai), não há pressa.

### P1-4 · Tailscale: falta a verificação em campo

Fechados nesta leva (o porquê ficou nos comentários de `VMS.Net.Tailscale`):
estado próprio na tela ("Aguardando a VPN", laranja, enquanto `TailnetWaiting`),
leitura da VPN pelo `ConnectivityManager`/`TRANSPORT_VPN` — com túnel de pé e
câmera muda, a sessão **não** abre mais o Tailscale nem espera 30 s à toa —,
volta automática para o app quando a rota aparece, e convite para instalar o
Tailscale (`market://`) quando o app não existe.

**O limite da plataforma continua valendo:** o Android não deixa um app ligar a
VPN de outro — só o dono do `VpnService` sobe o túnel, com consentimento do
usuário. Então quem liga é o usuário; o app só leva ele até lá e sabe esperar.
A volta automática também é melhor-esforço: Android 10+ bloqueia início de
activity em segundo plano na maioria dos casos, e aí o usuário volta na mão (o
supervisor reconecta sozinho no retorno).

**O que falta:** verificar em campo pelo 4G — com o túnel caindo e subindo, com
a troca de caminho no retorno do segundo plano, e com um aparelho sem o Tailscale
instalado para ver a oferta da loja.

### P2-4 · Gravações antigas com carimbo de tempo adiantado

O relógio do sistema (`TSystemClock.NowUtcMs`) convertia o fuso **duas vezes**: o
`ToUniversalTime` já entregava UTC e o `DateTimeToUnix` era chamado com
`AInputIsUTC = False`, convertendo de novo. Todo carimbo saía adiantado pelo
tamanho do fuso — 4 h aqui —, e a timeline mostrava UTC no lugar da hora do
vídeo. **Corrigido**, mas o erro está *dentro* dos arquivos já gravados: eles
continuam 4 h à frente. Os nomes dos arquivos sempre estiveram certos (passam por
uma conversão só), então dá para ver a diferença a olho.

**Decidido: não consertar.** A retenção (`maxTotalGB: 50`, ~2,5 dias com três
câmeras) apaga esses arquivos sozinha em poucos dias. Escrever um script que mexe
em gravação existente não se paga por um histórico que vai expirar. Enquanto
durarem, a timeline mostra 4 h a mais nelas — os nomes dos arquivos, não.

Este item se fecha sozinho: quando não houver mais `.vms` gravado antes da
correção, apague-o daqui.

### P3-1 · vmsserver não tem autenticação

Qualquer um na rede assiste a qualquer câmera em `rtsp://host:8554/live/<nome>`, e o nome é adivinhável. Falta Digest no lado servidor (o cliente já tem a implementação, dá para reusar).

**Subiu de importância com a API de gravações**: na mesma porta, sem senha, quem
alcança o servidor agora **baixa** gravação (`/api/media`), não só assiste ao
vivo. A trava continua sendo o `bindAddress` no IP do Tailscale, e a partida
avisa quando ela não está posta. Resolver aqui cobre os dois protocolos de uma
vez, que foi a razão de pôr a API na mesma porta.

> **Decidido: fica na fila, sem prazo.** A trava enquanto isso é o `bindAddress`
> no IP `100.x` — com ele vazio, o servidor está aberto para a LAN inteira, e é
> por isso que o aviso na partida existe. Quando vier, o desenho provável é
> Digest no RTSP (reusando o do cliente) e token na API.

### P3-2 · Senhas de câmera em texto claro no JSON

`vmsserver.json` e a config do app guardam usuário e senha em claro. No mínimo, tirar do log e cifrar em repouso.

> **Decidido: fica na fila, sem prazo.** Note que o `cameras.json` passou a ter
> mais senhas por câmera (uma por caminho). E que só dá para cifrar em repouso:
> o Digest do RTSP precisa da senha em claro para calcular o hash, então guardar
> só um hash não é opção.

### P3-4 · Sem RTCP em nenhuma ponta

O player descarta o RTCP que recebe e não manda RR; o servidor não manda SR. Sem isso não há estatística de rede padrão, nem keep-alive de sessão UDP, nem base para relógio comum entre trilhas.

> **Decidido: fica na fila.** As três razões perderam força: o keep-alive já vem
> do `GET_PARAMETER`, o relógio comum entre trilhas sai pelo P2-3 (âncora dentro
> do `.vms`, sem depender de RTCP) e a estatística de rede o log de sessão já dá
> (pacotes, perda, bitrate). O motivo que sobraria é câmera que encerra a sessão
> por falta de RR — se aparecer queda inexplicada, é aqui que se olha.

### P3-5 · Um `.vms` novo por reconexão

Cada queda da câmera fecha o arquivo e abre outro — na sessão da isis foram 11 arquivos em 24 min. Quem assiste ao vivo não sente mais (a mídia vem da memória, e o caminho de arquivo ainda segue o arquivo novo sozinho), mas o histórico fica picado. Continuar o mesmo arquivo quando a reconexão é rápida (ou consolidar depois).

> **Decidido: fica na fila.** As duas dores foram resolvidas por outros caminhos —
> o ao vivo vem da memória e a timeline cola os segmentos, atravessando os
> arquivos sozinha. O que sobra é custo de inventário, que o cache de índice
> absorve. Reabrir só se o número de arquivos por dia começar a pesar na tela de
> dias.

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

- ~~**Playback com timeline no app**~~ — **implementado** (fases 1 a 5 de
  [PLANO-TIMELINE.md](PLANO-TIMELINE.md)): índice no rodapé do `.vms`, API HTTP na
  porta 8554, engine de playback no app, telas de dia e barra de tempo. Falta a
  fase 6 (acabamento) e a validação em uso real.
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
