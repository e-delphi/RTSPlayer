// O player de gravacao, em JavaScript.
//
// Toca .vms direto: busca fragmentos em /api/media, le o container com o
// vmsreader.js, decodifica o video com WebCodecs e o audio G.711 com Web Audio.
// Nao ha conversao no servidor -- o formato que ja existe e o protocolo.
//
// ## O relogio
//
// O .vms carrega instante de PAREDE (unix ms) em cada sample, e nao cadencia.
// Isso e uma vantagem: o ritmo sai da diferenca entre o carimbo do quadro e o
// carimbo de onde a reproducao comecou, sem precisar saber fps. Um buraco de
// gravacao aparece sozinho como um salto, que e o comportamento certo.
//
//   tempoDeApresentacao = (sample.wallMs - baseMs) / velocidade
//
// ## O audio manda no relogio? Nao.
//
// Em player de midia o normal e o audio ditar o ritmo, porque ele nao pode ter
// buraco. Aqui e o contrario: a gravacao pode simplesmente nao ter audio (a
// isis nao tem), e amarrar o video a um relogio que pode nao existir seria
// frageis por nada. Quem manda e o relogio de parede do proprio navegador, e o
// audio e agendado contra ele.
//
// ## Por que WebCodecs, e nao <video> com MSE
//
// Porque o audio e G.711 A-law, que navegador nenhum toca dentro de MP4. Se o
// audio ja tem de ser decodificado em JavaScript, o MSE deixa de pagar o
// empacotador fMP4 que exigiria. Com WebCodecs os bytes do .vms vao direto ao
// decodificador (Annex-B, sem `description`) -- medido nas duas plataformas.

"use strict";

var Player = (function () {

  // Quanto de midia manter a frente do ponto de reproducao. Abaixo disto, pede
  // o proximo fragmento. Nao pode ser curto demais (engasga em rede lenta) nem
  // longo demais (o seek fica caro e a memoria cresce).
  var ALVO_BUFFER_MS = 6000;
  // Teto de quadros decodificados esperando exibicao. Decodificador de hardware
  // reclama se a fila crescer sem limite, e segurar 100 quadros de 1440p seria
  // memoria a toa.
  var MAX_FILA = 8;
  // Silencio maior que isto entre dois samples de audio e buraco de gravacao,
  // e nao atraso: nao se tenta emendar.
  var MAX_GAP_AUDIO_MS = 500;
  // Distancia tolerada entre o instante PEDIDO e o que realmente chegou. Dentro
  // dela o cronograma fica ancorado no pedido, e o trecho anterior (do keyframe
  // ate o ponto pedido) passa depressa, que e o certo. Fora dela, reancora.
  // Quantas vezes seguidas vale reabrir o decodificador antes de desistir.
  var MAX_RECUPERACOES = 3;

  var MAX_DESVIO_MS = 60000;

  // ------------------------------------------------------------- G.711

  // A-law -> PCM16. Tabela montada uma vez: sao 256 entradas, e fazer a conta
  // por amostra a 8000 Hz seria desperdicio puro.
  var TAB_ALAW = (function () {
    var t = new Int16Array(256);
    for (var i = 0; i < 256; i++) {
      var a = i ^ 0x55;
      var mant = a & 0x0F, exp = (a & 0x70) >> 4;
      var v = (mant << 4) + 8;
      if (exp > 0) v = (v + 256) << (exp - 1);
      t[i] = (a & 0x80) ? v : -v;
    }
    return t;
  })();

  // mu-law -> PCM16, para as cameras que mandam G711U.
  var TAB_ULAW = (function () {
    var t = new Int16Array(256);
    for (var i = 0; i < 256; i++) {
      var u = ~i & 0xFF;
      var mant = u & 0x0F, exp = (u & 0x70) >> 4;
      var v = ((mant << 3) + 0x84) << exp;
      v -= 0x84;
      t[i] = (u & 0x80) ? -v : v;
    }
    return t;
  })();

  function decodificarG711(bytes, tabela) {
    var out = new Float32Array(bytes.length);
    for (var i = 0; i < bytes.length; i++)
      out[i] = tabela[bytes[i]] / 32768;
    return out;
  }

  // ------------------------------------------------------------- player

  function Player(opcoes) {
    this.base = opcoes.base || "";          // http://127.0.0.1:porta
    // De qual servidor vem a midia. E uma funcao, e nao um valor, porque o
    // escopo muda enquanto o player vive: entrar noutro servidor nao deveria
    // exigir construir um player novo.
    this.escopo = opcoes.escopo || function () { return ""; };
    this.canvas = opcoes.canvas;
    this.ctx = this.canvas.getContext("2d");
    this.aoEstado = opcoes.onEstado || function () {};
    this.aoPosicao = opcoes.onPosicao || function () {};

    this.camera = "";
    this.velocidade = 1;
    this.tocando = false;
    this.mudo = false;

    this.reiniciarEstado();
  }

  Player.prototype.reiniciarEstado = function () {
    this.fecharDecodificador();
    this.fila = [];              // quadros decodificados esperando a hora
    this.pendentes = [];         // samples de video ainda nao mandados
    this.audioPend = [];         // samples de audio ainda nao agendados
    this.cursor = "";
    this.buscando = false;
    this.fim = false;
    this.baseMs = 0;             // instante do .vms onde a reproducao comecou
    this.baseRelogio = 0;        // performance.now() correspondente
    this.ultimoMs = 0;
    // Carimbo do ultimo quadro que foi de fato DESENHADO. Zero = nenhum ainda.
    // Serve de piso: ver o descarte no laco.
    //
    // Zerado SO aqui -- ou seja, ao abrir e ao saltar. Em particular nao se
    // zera na troca de arquivo: medido, um arquivo comecava 2,1 s antes do fim
    // do anterior, e aquilo e cobertura repetida, nao material novo. Zerar ali
    // era exatamente o que ainda deixava a imagem voltar na virada.
    this.exibidoMs = 0;
    this.audioProxSeg = 0;       // proximo instante livre no relogio do audio
    this.audioUltimoMs = 0;
    this.header = null;
    this.cadeia = "";
    // Origem dos carimbos mandados ao decodificador. E o pts do PRIMEIRO sample
    // entregue depois de abrir ou saltar -- e nao o instante pedido, que pode
    // ser posterior a ele: /api/media comeca no keyframe ANTERIOR ao pedido.
    //
    // Antes disto o codigo usava baseMs e cortava negativos em zero, e ai todos
    // os quadros do trecho anterior ao pedido voltavam com carimbo 0. A posicao
    // nunca saia do lugar e o player buscava fragmento sem parar.
    this.epochMs = 0;
    // O primeiro quadro decodificado ainda nao foi medido. O SPS diz o tamanho
    // que o fluxo ANUNCIA; o decodificador pode entregar outro, e e o dele que
    // aparece na tela.
    this.mediuQuadro = false;
    this.esperandoChave = true;
    this.quadroLargura = 0;
    this.quadroAltura = 0;
    this.tamanhosDoQuadro = "";
    // Camera nova, decisao nova: o que valeu para uma nao vale para outra, que
    // pode ter resolucao e codec diferentes.
    // DOIS estados, e nao um.
    //
    // "ja avaliei se ha software" e "estou usando software" pareciam a mesma
    // coisa e nao sao. Com uma flag so, o aparelho que NAO tem decodificador de
    // software para a cadeia deixava a marca ligada mesmo depois de recusar --
    // e dali em diante toda reconfiguracao pedia software e levava
    // "Unsupported configuration". Bastava sair do video e voltar para cair
    // nisso, porque a volta refaz o decodificador.
    this.tentouSoftware = false;
    this.usandoSoftware = false;
    // Apaga o que estava desenhado. Sem isto, fechar uma camera e abrir outra
    // mostrava o ultimo quadro da PRIMEIRA ate o primeiro quadro da segunda ser
    // decodificado -- e por um segundo a tela dizia estar em outro lugar.
    if (this.ctx && this.canvas)
      this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.aoVivo = false;
    this.cursorLive = 0;
    // Antes deste instante do relogio nao se pede nada ao vivo de novo.
    //
    // Sem isto, uma rota que responde 404 -- ou um 204 de "ainda nao ha nada"
    // -- vira uma requisicao por quadro: sessenta por segundo, para sempre. Foi
    // exatamente o que aconteceu com a pagina servida pelo vmsserver, que nao
    // tinha /api/live: o erro aparecia na tela e o pedido nunca parava.
    this.esperaAte = 0;
    this.geracao = (this.geracao || 0) + 1;   // invalida respostas em voo
  };

  Player.prototype.fecharDecodificador = function () {
    if (this.dec) {
      try { this.dec.close(); } catch (e) {}
      this.dec = null;
    }
    if (this.fila) this.fila.forEach(function (f) { try { f.close(); } catch (e) {} });
    this.fila = [];
  };

  // ------------------------------------------------------------- rede

  // Acrescenta o servidor a uma URL de api, quando ha um.
  Player.prototype.comEscopo = function (u) {
    var sv = this.escopo();
    if (!sv) return u;
    return u + (u.indexOf("?") >= 0 ? "&" : "?") +
           "server=" + encodeURIComponent(sv);
  };

  Player.prototype.pedirFragmento = function (ms) {
    var self = this, ger = this.geracao;
    if (this.buscando || this.fim) return Promise.resolve();
    this.buscando = true;

    var u = this.base + "/api/media?camera=" + encodeURIComponent(this.camera);
    if (this.cursor) u += "&cursor=" + encodeURIComponent(this.cursor);
    else u += "&fromMs=" + ms;

    return fetch(this.comEscopo(u)).then(function (r) {
      if (!r.ok) throw new Error("media " + r.status);
      // O cursor vem em cabecalho, e nao no corpo: o corpo e um .vms valido, e
      // enfiar metadado dentro dele quebraria essa propriedade.
      var cur = r.headers.get("X-Vms-Cursor");
      var desc = r.headers.get("X-Vms-Discontinuity") === "1";
      return r.arrayBuffer().then(function (buf) {
        return { buf: buf, cursor: cur, descontinuidade: desc };
      });
    }).then(function (res) {
      self.buscando = false;
      if (ger !== self.geracao) return;      // houve seek: resposta velha
      self.cursor = res.cursor || "";
      if (!res.buf || res.buf.byteLength === 0) { self.fim = true; return; }
      self.engolir(res.buf, res.descontinuidade);
    }).catch(function (e) {
      self.buscando = false;
      if (ger === self.geracao) self.aoEstado("erro", String(e));
    });
  };

  Player.prototype.engolir = function (buf, descontinuidade) {
    var frag;
    try { frag = VMS.ler(buf); }
    catch (e) { this.aoEstado("erro", "fragmento ilegivel: " + e); return; }

    // Cada fragmento traz o header do arquivo de onde veio. Trocar de arquivo
    // significa poder trocar de resolucao ou ate de codec, e ai o decodificador
    // tem de ser refeito -- e isso que a descontinuidade avisa.
    if (!this.header || descontinuidade) {
      this.header = frag.header;
      this.configurarVideo(frag);
    }

    var self = this;
    VMS.samplesDeVideo(frag).forEach(function (s) { self.pendentes.push(s); });
    if (frag.header.audio.present)
      VMS.samplesDeAudio(frag).forEach(function (s) { self.audioPend.push(s); });
  };

  // ------------------------------------------------------------- video

  Player.prototype.configurarVideo = function (frag) {
    var v = frag.header.video;
    var kf = VMS.samplesDeVideo(frag).find(function (s) { return s.keyframe; });
    var sps = VMS.acharSps(kf ? kf.data : null, v.extradata, v.codecName);
    this.cadeia = VMS.cadeiaCodec(v.codecName, sps);
    this.spsLargura = sps ? sps.width : v.width;
    this.spsAltura = sps ? sps.height : v.height;

    // Sem parameter set no fluxo, o extradata do header entra na frente de cada
    // keyframe. A frente e assim; a ayla nao precisa.
    this.prefixar = kf ? !VMS.temParameterSet(kf.data, v.codecName) : false;

    this.abrirDecodificador(this.usandoSoftware);
  };

  // Cria e configura o decodificador a partir do que ja foi lido do SPS.
  // Separado do configurarVideo porque tambem se refaz SEM fragmento novo:
  // quando o quadro chega menor do que o anunciado, o decodificador e trocado
  // por um de software com a mesma cadeia.
  Player.prototype.abrirDecodificador = function (preferirSoftware) {
    this.fecharDecodificador();
    this.mediuQuadro = false;
    // Decodificador novo comeca sem referencia nenhuma: so keyframe serve.
    this.esperandoChave = true;

    // A geracao entra nos dois callbacks, como ja entrava nos fetches.
    //
    // Trocar de camera ou sair do ao vivo fecha o decodificador, e o close()
    // pode disparar o error do que ainda estava na fila DELE. Sem a guarda,
    // esse erro chegava depois da troca e aparecia como falha da sessao nova:
    // "decodificador: Decoding error." numa reproducao que estava comecando bem.
    var self = this, ger = this.geracao;
    this.dec = new VideoDecoder({
      output: function (quadro) {
        // Quadro de sessao anterior nao entra na fila -- e nao vaza: VideoFrame
        // segura memoria ate ser fechado.
        if (ger !== self.geracao) { try { quadro.close(); } catch (e) {} return; }
        // Nunca descartar o da sessao atual: o trabalho de decodificar ja foi
        // feito, e jogar fora produziria salto na imagem. Quem segura o ritmo e
        // o alimentarDecodificador, que so entrega enquanto a fila tem espaco.
        self.fila.push(quadro);
      },
      error: function (e) {
        if (ger !== self.geracao) return;
        self.aoEstado("erro", "decodificador: " + e.message);
        self.recuperarDoErro();
      }
    });
    // A dimensao vai no configure, e nao so no fluxo.
    //
    // Com avc3/hev1 os parameter sets chegam DENTRO do video, entao nao ha
    // `description` e o configure ia sem dizer o tamanho. O decodificador tem
    // de escolher uma superficie de saida antes de ver o primeiro SPS, e um
    // decodificador de hardware que escolhe 1280x720 por padrao passa a
    // ESCALAR todo quadro para dentro dela em vez de realocar -- 2560x1440
    // entra e sai 1280x720, sem erro nenhum.
    //
    // Dizer o tamanho aqui tira a adivinhacao. O numero vem do SPS, que ja foi
    // lido para montar a cadeia do codec.
    var cfg = { codec: this.cadeia };
    if (this.spsLargura && this.spsAltura) {
      cfg.codedWidth = this.spsLargura;
      cfg.codedHeight = this.spsAltura;
      // E a proporcao de exibicao junto: sem ela o displayWidth sai da
      // proporcao sinalizada no fluxo, que nem sempre esta la.
      cfg.displayAspectWidth = this.spsLargura;
      cfg.displayAspectHeight = this.spsAltura;
    }
    if (preferirSoftware) cfg.hardwareAcceleration = "prefer-software";
    try {
      this.dec.configure(cfg);
      this.anunciarTamanho();
    } catch (e) {
      this.aoEstado("erro", "codec " + this.cadeia + ": " + e);
      this.dec = null;
    }
  };

  // Erro de decodificacao nao pode ser o fim da reproducao.
  //
  // O decodificador FECHA sozinho quando erra, e dali em diante nada mais
  // aparece: a tela congela sem dizer que parou. A causa costuma ser local --
  // um trecho gravado com defeito --, entao refazer o decodificador e retomar
  // do proximo keyframe pula o trecho ruim e o video volta.
  //
  // (O caso que trouxe isto: um sample marcado como keyframe com DOIS access
  // units grudados e um NAL de enquadramento de RTP no meio. O decodificador
  // recusa, e com razao; o player e que nao devia desistir por causa de um
  // GOP.)
  //
  // Com limite: erro que se repete depressa nao e trecho ruim, e o fluxo
  // inteiro -- e ai reabrir sem parar so gastaria bateria.
  Player.prototype.recuperarDoErro = function () {
    // Se estava em software e deu erro, o hardware e a aposta melhor para a
    // proxima: insistir no que acabou de falhar so queima as tentativas.
    this.usandoSoftware = false;
    var agora = this.relogio();
    if (agora - (this.ultimaRecuperacao || 0) < 2)
      this.recuperacoes = (this.recuperacoes || 0) + 1;
    else
      this.recuperacoes = 1;
    this.ultimaRecuperacao = agora;
    if (this.recuperacoes > MAX_RECUPERACOES) return;
    this.aoEstado("aviso", "trecho ilegivel; seguindo do proximo keyframe");
    this.abrirDecodificador(this.usandoSoftware);
  };

  // O que a tela mostra sobre o formato.
  //
  // Dois numeros quando eles divergem: o que o fluxo ANUNCIA (SPS) e o que o
  // decodificador ENTREGA. Mostrar so o do SPS -- como era antes -- fazia a
  // tela afirmar 2560x1440 enquanto exibia outra coisa, e nao havia de onde
  // desconfiar.
  Player.prototype.anunciarTamanho = function () {
    var t = this.spsLargura + "x" + this.spsAltura;
    if (this.quadroLargura &&
        (this.quadroLargura !== this.spsLargura ||
         this.quadroAltura !== this.spsAltura))
      t += " \u2192 " + this.quadroLargura + "x" + this.quadroAltura +
           (this.usandoSoftware ? " (sw)" : "");
    // So quando os tres nao batem. Num fluxo normal isso nunca aparece.
    if (this.tamanhosDoQuadro)
      t += "   [" + this.tamanhosDoQuadro + "]";
    this.aoEstado("codec", this.cadeia + "  " + t);
  };

  // O decodificador entregou menos do que o SPS anuncia. Tenta uma vez em
  // software, que e onde o recorte costuma nao acontecer -- decodificador de
  // hardware as vezes reduz para caber no que ele suporta.
  //
  // So tenta se o navegador disser que ha software para esta cadeia: no Android
  // nao ha, e insistir trocaria video que funciona por tela preta.
  Player.prototype.tentarSoftware = function () {
    if (this.tentouSoftware) return;
    // Avaliar uma vez so; a resposta nao muda no meio da sessao.
    this.tentouSoftware = true;
    var self = this, ger = this.geracao;
    var cfg = { codec: this.cadeia, hardwareAcceleration: "prefer-software" };
    VideoDecoder.isConfigSupported(cfg).then(function (r) {
      // Nao ha software para esta cadeia (o Android nao tem para HEVC): fica
      // no hardware e NADA muda -- em especial, nao se marca que se esta
      // usando software.
      if (ger !== self.geracao || !r || !r.supported) return;
      self.usandoSoftware = true;
      self.aoEstado("aviso", "quadro menor que o anunciado; tentando decodificar" +
                             " em software");
      self.abrirDecodificador(true);
    }).catch(function () {});
  };

  Player.prototype.alimentarDecodificador = function () {
    if (!this.dec || this.dec.state !== "configured") return;
    while (this.pendentes.length &&
           this.fila.length + this.dec.decodeQueueSize < MAX_FILA) {
      var s = this.pendentes.shift();

      // Depois de configurar o decodificador, o PRIMEIRO quadro tem de ser
      // keyframe.
      //
      // O servidor volta ao keyframe anterior ao instante pedido, mas o bloco
      // que ele devolve pode COMECAR no meio do GOP anterior -- o keyframe vem
      // alguns samples adiante. Mandar esses delta primeiro nao decodifica, e o
      // erro nao chega como excecao do decode(): chega no callback de erro, que
      // derruba a sessao inteira. Era o "decodificador: Decoding error." ao
      // abrir um evento no meio do dia.
      //
      // Descartar ate o keyframe custa uma fracao de segundo de video que nao
      // daria imagem de qualquer jeito.
      if (this.esperandoChave) {
        if (!s.keyframe) continue;
        this.esperandoChave = false;
      }

      if (!this.epochMs) {
        this.epochMs = s.wallMs;
        // O servidor NAO devolve necessariamente o instante pedido: ele comeca
        // no keyframe anterior, e limita ao intervalo gravado quando o pedido
        // cai fora dele -- respondendo 200 com video valido, e nao um erro.
        //
        // Ancorar o cronograma no pedido, nesse caso, faz cada quadro vencer
        // daqui a decadas: nada aparece, e a tela fica em "abrindo..." para
        // sempre. Foi exatamente o que aconteceu com um ms fora da faixa.
        // Quem manda e o que chegou.
        if (Math.abs(s.wallMs - this.baseMs) > MAX_DESVIO_MS) {
          this.baseMs = s.wallMs;
          this.baseRelogio = this.relogio();
          this.ultimoMs = s.wallMs;
          this.aoEstado("reancorado", s.wallMs);
        }
      }
      var dados = s.data;
      if (this.prefixar && s.keyframe)
        dados = VMS.concatenar(this.header.video.extradata, dados);
      try {
        this.dec.decode(new EncodedVideoChunk({
          type: s.keyframe ? "key" : "delta",
          // timestamp em MICROssegundos, e relativo ao inicio: passar unix ms
          // direto estoura a faixa util e alguns decodificadores rejeitam.
          timestamp: Math.max(0, (s.wallMs - this.epochMs) * 1000),
          data: dados
        }));
      } catch (e) {
        // Quadro delta antes do primeiro keyframe, logo apos um seek: e
        // esperado, e o proximo keyframe conserta.
      }
    }
  };

  // ------------------------------------------------------------- audio

  Player.prototype.garantirAudio = function () {
    if (this.ac) return;
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    this.ac = new AC();
  };

  Player.prototype.agendarAudio = function () {
    if (this.mudo || !this.audioPend.length) return;
    this.garantirAudio();
    if (!this.ac || this.ac.state === "suspended") return;

    var a = this.header ? this.header.audio : null;
    if (!a || !a.present) { this.audioPend.length = 0; return; }
    var tabela = a.codecName === "G711U" ? TAB_ULAW :
                 a.codecName === "G711A" ? TAB_ALAW : null;
    if (!tabela) { this.audioPend.length = 0; return; }   // codec que nao sei

    while (this.audioPend.length) {
      var s = this.audioPend[0];
      // Nao agendar muito a frente: se o usuario der seek, o que ja entrou na
      // fila do Web Audio nao volta atras.
      var quando = this.instanteDe(s.wallMs);
      if (quando > this.relogio() + 1.0) break;
      this.audioPend.shift();

      var pcm = decodificarG711(s.data, tabela);
      if (!pcm.length) continue;
      var buf = this.ac.createBuffer(1, pcm.length, a.sampleRate || 8000);
      buf.copyToChannel(pcm, 0);
      var src = this.ac.createBufferSource();
      src.buffer = buf;
      src.connect(this.ac.destination);

      // Emenda no fim do anterior enquanto o carimbo confirmar continuidade.
      // Buraco de gravacao reinicia a emenda, senao o audio ficaria empilhando
      // atrasado para sempre depois do primeiro salto.
      var t = this.ac.currentTime;
      if (this.audioProxSeg < t ||
          Math.abs(s.wallMs - this.audioUltimoMs) > MAX_GAP_AUDIO_MS)
        this.audioProxSeg = t + 0.05;
      src.start(this.audioProxSeg);
      this.audioProxSeg += buf.duration / this.velocidade;
      this.audioUltimoMs = s.wallMs + Math.round(
        1000 * pcm.length / (a.sampleRate || 8000));
    }
  };

  // ------------------------------------------------------------- relogio

  Player.prototype.relogio = function () {
    return performance.now() / 1000;
  };

  // Em que instante do relogio este carimbo do .vms deve aparecer.
  Player.prototype.instanteDe = function (ms) {
    return this.baseRelogio + (ms - this.baseMs) / 1000 / this.velocidade;
  };

  Player.prototype.laco = function () {
    if (!this.tocando) return;
    var self = this;

    this.alimentarDecodificador();
    this.agendarAudio();

    // Mostra o quadro cuja hora ja chegou, descartando os atrasados: preferir o
    // mais novo mantem a reproducao junto do relogio depois de um engasgo, em
    // vez de acumular atraso.
    var agora = this.relogio();
    var mostrar = null;
    while (this.fila.length) {
      var q = this.fila[0];
      var ms = this.epochMs + q.timestamp / 1000;
      if (this.instanteDe(ms) > agora) break;
      var quadro = this.fila.shift();
      // O relogio da reproducao nao anda para tras.
      //
      // Os carimbos do .vms nao sao monotonicos: cada BLOCO tem a ancora dele
      // (wallMs = ancora + (pts - primeiroPts)/timescale, ver vmsreader.js), e o
      // relogio de quem gravou nao anda no mesmo passo do pts da camera. Na
      // virada de bloco a correcao aparece como salto -- as vezes para a frente
      // (um buraco) e as vezes para tras. Medido numa gravacao real: 7 de 39
      // fragmentos comecavam ANTES do fim do anterior, ate 2,1 s de
      // sobreposicao, e a queda caia sempre na fronteira de bloco.
      //
      // Exibir esse trecho de novo e voltar a imagem. A 1x quase nao se nota,
      // porque em um segundo se atravessa um segundo de gravacao; a 16x se
      // atravessa dezesseis, encontra-se dezesseis vezes mais fronteiras, e
      // vira aquele repique constante de "voltou um pedaco e tocou de novo".
      //
      // Descartar, e nao reancorar: o trecho ja passou na tela, e o que vem
      // depois dele continua valendo. Decodificar tudo e obrigatorio (os
      // quadros seguintes dependem destes); o que nao se faz e DESENHAR.
      if (this.exibidoMs && ms <= this.exibidoMs) { quadro.close(); continue; }
      if (mostrar) mostrar.close();
      mostrar = quadro;
      this.ultimoMs = ms;
    }
    if (mostrar) {
      this.exibidoMs = this.ultimoMs;
      // Um VideoFrame tem TRES tamanhos, e usar o errado joga resolucao fora:
      //
      //   codedWidth   o que foi decodificado, alinhado a macrobloco. Pode ter
      //                padding invisivel (1080 vira 1088);
      //   visibleRect  a parte valida desse quadro, ja sem o padding. E ESTE o
      //                numero de pixels reais que existem;
      //   displayWidth o tamanho de EXIBICAO -- o visibleRect ajustado pela
      //                proporcao de pixel sinalizada no fluxo. Pode vir menor
      //                que o visibleRect, e ai o canvas nasce menor e o
      //                drawImage encolhe um quadro que estava inteiro.
      //
      // O canvas segue o visibleRect: e a resolucao que de fato chegou.
      var vr = mostrar.visibleRect;
      var lw = (vr && vr.width) || mostrar.displayWidth || mostrar.codedWidth;
      var lh = (vr && vr.height) || mostrar.displayHeight || mostrar.codedHeight;
      if (!this.mediuQuadro) {
        this.mediuQuadro = true;
        this.quadroLargura = lw;
        this.quadroAltura = lh;
        // Guardado para a tela poder mostrar os tres quando divergirem: sem
        // isso nao ha como saber QUAL deles esta reduzindo.
        this.tamanhosDoQuadro = "";
        var cw = mostrar.codedWidth, ch = mostrar.codedHeight;
        var dw = mostrar.displayWidth, dh = mostrar.displayHeight;
        // So quando o DISPLAY difere da parte visivel, que e o caso em que se
        // perde resolucao. Coded maior que visivel e o padding de macrobloco --
        // 1080 vira 1088 ou 1104 --, acontece em todo H.264 1080p e nao diz
        // nada; anunciar isso encheria a tela de ruido normal.
        if (dw !== lw || dh !== lh)
          this.tamanhosDoQuadro = "coded " + cw + "x" + ch +
            (vr ? "  vis " + vr.width + "x" + vr.height : "") +
            "  disp " + dw + "x" + dh;
        this.anunciarTamanho();
        // 5% de folga: divergencia de um ou dois pixels e arredondamento de
        // macrobloco, e nao reducao.
        if (this.spsLargura && lw < this.spsLargura * 0.95)
          this.tentarSoftware();
      }
      if (this.canvas.width !== lw || this.canvas.height !== lh) {
        this.canvas.width = lw;
        this.canvas.height = lh;
      }
      try { this.ctx.drawImage(mostrar, 0, 0, lw, lh); } catch (e) {}
      mostrar.close();
      this.aoPosicao(this.ultimoMs);
    }

    // Buscar mais quando o que resta a frente encolhe.
    var restaMs = this.pendentes.length
      ? this.pendentes[this.pendentes.length - 1].wallMs - this.ultimoMs : 0;
    if (this.aoVivo) {
      // Ao vivo se pede sempre que o que resta encolhe, e tambem quando nada
      // resta: e assim que a sessao continua depois de um 204. A espera e o que
      // impede que "nada resta" vire uma rajada de pedidos.
      if (restaMs < ALVO_BUFFER_MS && this.relogio() >= this.esperaAte)
        this.pedirAoVivo();
    }
    else if (!this.fim && restaMs < ALVO_BUFFER_MS)
      this.pedirFragmento(this.ultimoMs || this.baseMs);

    requestAnimationFrame(function () { self.laco(); });
  };

  // ------------------------------------------------------------- controle

  // ------------------------------------------------------------- ao vivo

  // O ao vivo usa o MESMO caminho da gravacao: os bytes que chegam sao .vms, e
  // o engolir/decodificar nao muda em nada. O que muda e a rota e o cursor --
  // aqui um numero de bloco, la um cursor opaco -- e o fato de nao haver fim.
  Player.prototype.abrirAoVivo = function (camera) {
    var motivo = Player.motivoIndisponivel();
    if (motivo) { this.aoEstado("erro", motivo); return; }
    this.camera = camera;
    this.reiniciarEstado();
    this.aoVivo = true;
    this.cursorLive = 0;
    this.baseMs = 0;          // so o primeiro bloco diz onde estamos no tempo
    this.baseRelogio = 0;
    this.tocando = true;
    this.aoEstado("abrindo", camera);
    var self = this;
    this.pedirAoVivo().then(function () { self.laco(); });
  };

  Player.prototype.pedirAoVivo = function () {
    var self = this, ger = this.geracao;
    if (this.buscando) return Promise.resolve();
    this.buscando = true;

    var u = this.base + "/api/live?camera=" + encodeURIComponent(this.camera) +
            "&cursor=" + encodeURIComponent(this.cursorLive);
    return fetch(this.comEscopo(u)).then(function (r) {
      var cur = r.headers.get("X-Vms-Cursor");
      // 204 = camera conectando, ou nada novo desde o ultimo bloco. Nao e erro,
      // e nao e fim: ao vivo nao acaba.
      if (r.status === 204) {
        // Meio segundo: o bloco leva alguns segundos para fechar, entao voltar
        // antes disso e so gastar viagem.
        self.esperaAte = self.relogio() + 0.5;
        return { vazio: true, cursor: cur };
      }
      if (!r.ok) throw new Error("live " + r.status);
      // O ao vivo do servidor troca de arquivo quando a gravacao troca, e ai o
      // cabecalho muda -- pode mudar ate a resolucao. E o mesmo aviso da
      // reproducao, e vale aqui pelo mesmo motivo.
      var desc = r.headers.get("X-Vms-Discontinuity") === "1";
      return r.arrayBuffer().then(function (buf) {
        return { buf: buf, cursor: cur, descontinuidade: desc };
      });
    }).then(function (res) {
      self.buscando = false;
      if (ger !== self.geracao) return;
      if (res.cursor !== null && res.cursor !== undefined)
        self.cursorLive = res.cursor;
      if (res.vazio || !res.buf || !res.buf.byteLength) return;

      // Cada resposta do ao vivo traz o cabecalho de novo. Reconfigurar o
      // decodificador a cada uma seria jogar fora o estado dele; so a primeira
      // configura, e a troca de formato limpa o anel do lado do servidor.
      var primeiro = !self.header;
      self.engolir(res.buf, primeiro || res.descontinuidade);
      if (primeiro && self.pendentes.length) {
        // O relogio do ao vivo nasce no primeiro bloco que chegou.
        self.baseMs = self.pendentes[0].wallMs;
        self.baseRelogio = self.relogio();
        self.ultimoMs = self.baseMs;
      }
    }).catch(function (e) {
      self.buscando = false;
      // Dois segundos antes de tentar de novo. O erro continua aparecendo na
      // tela, mas uma rota que nao existe deixa de ser martelada.
      self.esperaAte = self.relogio() + 2;
      if (ger === self.geracao) self.aoEstado("erro", String(e));
    });
  };

  // Por que nao da para decodificar aqui, ou "" quando da.
  //
  // VideoDecoder so existe em CONTEXTO SEGURO: https, ou localhost. Numa origem
  // http comum a API simplesmente nao esta la -- e a mensagem antiga, "sem
  // WebCodecs neste navegador", acusava o culpado errado: o navegador TEM
  // WebCodecs, o que falta e o https. Quem le aquilo vai procurar defeito no
  // aparelho em vez de no endereco.
  //
  // Metodo de classe porque a casca precisa dele antes de existir player, e
  // porque a resposta e do ambiente, nao da sessao.
  Player.motivoIndisponivel = function () {
    if (typeof VideoDecoder !== "undefined") return "";
    if (window.isSecureContext === false)
      return "esta p\u00e1gina precisa de HTTPS para decodificar v\u00eddeo. " +
             "Abra por https:// (o Tailscale faz isso), ou no pr\u00f3prio " +
             "computador do servidor por http://localhost" +
             (location.port ? ":" + location.port : "");
    return "este navegador n\u00e3o tem WebCodecs";
  };

  Player.prototype.abrir = function (camera, ms) {
    // Parar aqui, com o motivo, em vez de deixar o `new VideoDecoder` estourar
    // um ReferenceError cru la dentro.
    var motivo = Player.motivoIndisponivel();
    if (motivo) { this.aoEstado("erro", motivo); return; }
    this.camera = camera;
    this.reiniciarEstado();
    this.baseMs = ms;
    this.baseRelogio = this.relogio();
    this.ultimoMs = ms;
    this.audioProxSeg = 0;
    this.tocando = true;
    this.aoEstado("abrindo", camera);
    var self = this;
    this.pedirFragmento(ms).then(function () { self.laco(); });
  };

  Player.prototype.irPara = function (ms) {
    if (!this.camera) return;
    this.abrir(this.camera, ms);
  };

  Player.prototype.pausar = function () {
    this.tocando = false;
    if (this.ac && this.ac.suspend) this.ac.suspend();
  };

  Player.prototype.retomar = function () {
    if (this.tocando) return;
    // Reancora o relogio no ponto onde parou: sem isso a pausa viraria atraso,
    // e todos os quadros guardados apareceriam de uma vez.
    this.baseMs = this.ultimoMs;
    this.baseRelogio = this.relogio();
    this.tocando = true;
    if (this.ac && this.ac.resume) this.ac.resume();
    this.laco();
  };

  Player.prototype.setVelocidade = function (v) {
    this.baseMs = this.ultimoMs;
    this.baseRelogio = this.relogio();
    this.velocidade = v;
  };

  Player.prototype.setMudo = function (m) {
    this.mudo = m;
    if (m) this.audioPend.length = 0;
  };

  Player.prototype.destruir = function () {
    this.tocando = false;
    this.fecharDecodificador();
    if (this.ac && this.ac.close) { try { this.ac.close(); } catch (e) {} }
    this.ac = null;
  };

  // Expostas para o tools/testplayer.js conferir contra os valores da norma
  // G.711. Nao sao usadas fora daqui.
  Player.G711 = { alaw: TAB_ALAW, ulaw: TAB_ULAW, decodificar: decodificarG711 };

  return Player;
})();
