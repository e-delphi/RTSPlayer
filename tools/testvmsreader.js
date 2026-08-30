// Confere o leitor de .vms em JavaScript contra o de Python, sobre os MESMOS
// arquivos reais.
//
// O vmslib.py e a referencia: ele ja e exercitado pelo tools/selftest.py e leu
// certo tudo que apareceu ate hoje. Aqui a pergunta e so uma -- o porte para
// JavaScript concorda com ele, byte a byte?
//
//     python tools/dumpvms.py <arquivos...> > esperado.json
//     node tools/testvmsreader.js esperado.json
//
// Divergencia aqui e defeito no porte, nao no formato.

"use strict";

const fs = require("fs");
const path = require("path");

// O vmsreader.js e feito para o navegador: ele so declara `var VMS`. Avaliar o
// texto num escopo e a forma de usa-lo aqui sem sujar o arquivo com um
// module.exports que nao serve para nada na pagina.
const fonte = fs.readFileSync(
  path.join(__dirname, "..", "vms", "src", "Api", "vmsreader.js"), "utf8");
const VMS = eval(fonte + "; VMS");

const esperadoPath = process.argv[2];
if (!esperadoPath) {
  console.error("uso: node tools/testvmsreader.js <esperado.json>");
  process.exit(2);
}
const esperado = JSON.parse(fs.readFileSync(esperadoPath, "utf8"));

let falhas = 0, checagens = 0;

function conferir(nome, obtido, querido) {
  checagens++;
  const a = JSON.stringify(obtido), b = JSON.stringify(querido);
  if (a !== b) {
    falhas++;
    console.log(`  FALHOU  ${nome}\n            js=${a}\n            py=${b}`);
  }
}

for (const alvo of esperado) {
  console.log(`\n== ${alvo.arquivo}`);
  const buf = fs.readFileSync(alvo.caminho);
  // Copia para um ArrayBuffer proprio: o Buffer do Node compartilha um pool, e
  // um subarray dele traria bytes de outro arquivo junto.
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  const frag = VMS.ler(ab);
  const h = frag.header;

  conferir("version", h.version, alvo.version);
  conferir("headerSize", h.size, alvo.headerSize);
  conferir("creationMs", h.creationMs, alvo.creationMs);
  conferir("uri", h.uri, alvo.uri);
  conferir("video.codecName", h.video.codecName, alvo.video.codecName);
  conferir("video.timescale", h.video.timescale, alvo.video.timescale);
  conferir("video.extradataLen", h.video.extradata.length,
           alvo.video.extradataLen);
  conferir("audio.present", h.audio.present, alvo.audio.present);
  conferir("audio.codecName", h.audio.codecName, alvo.audio.codecName);
  conferir("audio.sampleRate", h.audio.sampleRate, alvo.audio.sampleRate);
  conferir("audio.channels", h.audio.channels, alvo.audio.channels);

  conferir("blocos", frag.blocos.length, alvo.blocos);
  const v = VMS.samplesDeVideo(frag);
  const a = VMS.samplesDeAudio(frag);
  conferir("samples de video", v.length, alvo.videoSamples);
  conferir("samples de audio", a.length, alvo.audioSamples);
  conferir("keyframes", v.filter(s => s.keyframe).length, alvo.keyframes);
  conferir("bytes de video", v.reduce((t, s) => t + s.data.length, 0),
           alvo.videoBytes);
  conferir("bytes de audio", a.reduce((t, s) => t + s.data.length, 0),
           alvo.audioBytes);
  conferir("pts do 1o video", v.length ? v[0].pts : null, alvo.primeiroPts);
  conferir("pts do ultimo video", v.length ? v[v.length - 1].pts : null,
           alvo.ultimoPts);
  // O relogio de parede, amostra a amostra. A soma pega qualquer divergencia
  // no meio que o primeiro e o ultimo esconderiam.
  const wv = v.map(s => s.wallMs), wa = a.map(s => s.wallMs);
  conferir("wall video 1o", wv.length ? wv[0] : null, alvo.wallVideoPrimeiro);
  conferir("wall video ultimo", wv.length ? wv[wv.length - 1] : null,
           alvo.wallVideoUltimo);
  conferir("wall video soma", wv.reduce((t, x) => t + x, 0), alvo.wallVideoSoma);
  conferir("wall audio 1o", wa.length ? wa[0] : null, alvo.wallAudioPrimeiro);
  conferir("wall audio ultimo", wa.length ? wa[wa.length - 1] : null,
           alvo.wallAudioUltimo);
  conferir("wall audio soma", wa.reduce((t, x) => t + x, 0), alvo.wallAudioSoma);

  conferir("ancora de video", frag.blocos.length ?
           frag.blocos[0].videoAnchorMs : null, alvo.primeiraAncoraVideo);

  // O que realmente importa para o player: o SPS e a cadeia de codec.
  const kf = v.find(s => s.keyframe);
  if (kf) {
    const sps = VMS.acharSps(kf.data, h.video.extradata, h.video.codecName);
    conferir("sps achado", sps !== null, alvo.spsAchado);
    if (sps && alvo.sps) {
      conferir("sps.width", sps.width, alvo.sps.width);
      conferir("sps.height", sps.height, alvo.sps.height);
      conferir("sps.level", sps.level, alvo.sps.level);
    }
    conferir("cadeia de codec",
             VMS.cadeiaCodec(h.video.codecName, sps), alvo.cadeia);
    conferir("parameter sets no AU",
             VMS.temParameterSet(kf.data, h.video.codecName), alvo.psNoAu);
    // Confere tambem a soma dos bytes das NALs, que so bate se a separacao
    // Annex-B achou os mesmos limites que o Python.
    const nals = VMS.separarAnnexB(kf.data);
    conferir("nals do keyframe", nals.length, alvo.nalsDoKeyframe);
    conferir("bytes das nals", nals.reduce((t, n) => t + n.length, 0),
             alvo.bytesDasNals);
  }
}

console.log(`\n${falhas ? falhas + " FALHAS" : "passou"}: ${checagens} verificacoes`);
process.exit(falhas ? 1 : 0);
