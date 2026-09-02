// Confere o caminho de decodificacao no aparelho, do lado da pagina.
//
// Quando o navegador nao decodifica o fluxo (o Chromium do Android 14 recusa
// HEVC acima de 2048 de largura, medido), quem decodifica e o Delphi e a pagina
// recebe JPEG por /api/frame. O que se testa aqui e o que pode dar errado nesse
// bombeamento, e que nao aparece olhando:
//
//   - o quadro so pode ser desenhado na HORA dele, e nao assim que chega;
//   - a velocidade tem de valer, como vale no caminho normal;
//   - a imagem nao anda para tras (os carimbos do .vms nao sao monotonicos);
//   - um seek invalida o quadro que estava em voo;
//   - a fila de samples tem de encolher, ou a pagina nunca busca mais nada.
//
// E, no mesmo assunto -- o que fazer quando o navegador nao da conta --, a
// escolha do motor: trocar para software na hora certa, e nao repetir a
// descoberta a cada abertura.
//
//     node tools/testnativo.js
//
// Sem navegador: o Player e avaliado aqui com o minimo de ambiente que ele
// pede. E o mesmo caminho do tools/testvmsreader.js.

"use strict";

const fs = require("fs");
const path = require("path");

const fonte = fs.readFileSync(
  path.join(__dirname, "..", "src", "UI", "web", "player.js"), "utf8");

// O player.js e feito para o navegador. Estes sao os unicos globais que ele
// toca fora de uma chamada de metodo.
global.window = { isSecureContext: true };
global.performance = { now: () => relogioMs };
global.requestAnimationFrame = () => {};

const Player = eval(fonte + "; Player");

let relogioMs = 0;
let falhas = 0, checagens = 0;

function conferir(nome, obtido, querido) {
  checagens++;
  const a = JSON.stringify(obtido), b = JSON.stringify(querido);
  if (a !== b) {
    falhas++;
    console.log("FALHOU  " + nome + "\n  obtido:  " + a + "\n  querido: " + b);
  }
}

// ---------------------------------------------------------------- ambiente

// Um quadro "decodificado": o teste so precisa saber que foi desenhado e qual.
function fazerQuadro(ms) {
  return { ms: ms, img: { width: 2560, height: 1440, close() { this.fechado = true; } } };
}

function novoPlayer(quadros) {
  const desenhados = [];
  const ctx = { drawImage: (img) => desenhados.push(img), clearRect: () => {} };
  const p = new Player({
    canvas: { width: 0, height: 0, getContext: () => ctx },
    aoEstado: () => {},
    aoPosicao: () => {}
  });
  p.desenhados = desenhados;
  p.camera = "frente";
  p.escopo = () => "";
  p.nativo = true;
  p.aoEstado = () => {};
  p.aoPosicao = (ms) => { p.posicaoAvisada = ms; };
  p.anunciarTamanho = () => {};

  // Em vez da rede: `quadros` e a fila que o /api/frame devolveria, e o pedido
  // se resolve na hora -- o que interessa e QUANDO o quadro e desenhado, nao
  // quanto a rede demorou.
  p.pedirQuadroNativo = function () {
    if (!quadros.length) return;
    this.quadroNativo = quadros.shift();
  };
  return p;
}

// Samples fingidos, so com o wallMs, que e o unico campo que o bombeamento le.
function pendentes(p, lista) {
  p.pendentes = lista.map((ms) => ({ wallMs: ms }));
}

// -------------------------------------------------------- a hora do quadro

(function horaDoQuadro() {
  const p = novoPlayer([fazerQuadro(1000)]);
  p.baseMs = 1000;
  p.baseRelogio = 0;
  p.ultimoMs = 1000;
  p.epochMs = 1000;
  pendentes(p, [1000, 1100, 1200]);

  relogioMs = 0;
  p.bombearNativo(p.relogio());        // busca o quadro de 1000
  conferir("nada desenhado antes de bombear de novo", p.desenhados.length, 0);
  p.bombearNativo(p.relogio());        // 1000 vence agora
  conferir("o primeiro quadro aparece na hora", p.desenhados.length, 1);

  // O de 1100 chegou, mas so vence 100 ms depois.
  p.quadroNativo = fazerQuadro(1100);
  relogioMs = 50;
  p.bombearNativo(p.relogio());
  conferir("quadro adiantado nao e desenhado", p.desenhados.length, 1);
  relogioMs = 100;
  p.bombearNativo(p.relogio());
  conferir("desenhado quando vence", p.desenhados.length, 2);
})();

// ------------------------------------------------------------- velocidade

(function velocidade() {
  const p = novoPlayer([]);
  p.baseMs = 1000;
  p.baseRelogio = 0;
  p.ultimoMs = 1000;
  p.epochMs = 1000;
  p.velocidade = 4;
  pendentes(p, [5000]);

  p.quadroNativo = fazerQuadro(5000);  // 4 s de gravacao adiante
  relogioMs = 900;                     // a 4x, ele vence em 1 s
  p.bombearNativo(p.relogio());
  conferir("a 4x ainda nao venceu", p.desenhados.length, 0);
  relogioMs = 1000;
  p.bombearNativo(p.relogio());
  conferir("a 4x venceu em 1 s", p.desenhados.length, 1);
})();

// ------------------------------------------------------- nao voltar a imagem

(function naoVoltar() {
  // A virada de bloco no .vms pode trazer carimbo ANTERIOR ao que ja passou na
  // tela. Redesenhar aquilo e o "loop" que aparecia no historico acelerado.
  const p = novoPlayer([]);
  p.baseMs = 1000;
  p.baseRelogio = 0;
  p.ultimoMs = 1000;
  p.epochMs = 1000;
  pendentes(p, [2000, 1800]);

  relogioMs = 5000;                    // tudo ja venceu
  p.quadroNativo = fazerQuadro(2000);
  p.bombearNativo(p.relogio());
  conferir("desenhou o de 2000", p.desenhados.length, 1);
  p.quadroNativo = fazerQuadro(1800);  // veio de tras
  p.bombearNativo(p.relogio());
  conferir("nao redesenha o que ja passou", p.desenhados.length, 1);
  conferir("a posicao tambem nao volta", p.posicaoAvisada, 2000);
})();

// ------------------------------------------------------------- a fila encolhe

(function filaEncolhe() {
  const p = novoPlayer([]);
  p.baseMs = 1000;
  p.baseRelogio = 0;
  p.ultimoMs = 1000;
  p.epochMs = 1000;
  pendentes(p, [1000, 1100, 1200, 1300]);

  relogioMs = 5000;
  p.quadroNativo = fazerQuadro(1200);
  p.bombearNativo(p.relogio());
  // Tudo ate 1200 ja saiu do outro lado: so 1300 continua esperando.
  conferir("a fila encolhe ate o quadro exibido",
           p.pendentes.map((s) => s.wallMs), [1300]);
})();

// --------------------------------------------------------------- apos o seek

(function seek() {
  const p = novoPlayer([]);
  p.baseMs = 1000;
  p.baseRelogio = 0;
  p.ultimoMs = 1000;
  p.epochMs = 1000;
  pendentes(p, [1000]);
  p.quadroNativo = fazerQuadro(1000);

  p.reiniciarEstado();
  conferir("o seek larga o quadro em maos", p.quadroNativo, null);
  conferir("e manda reiniciar o decodificador do aparelho", p.resetNativo, true);
})();

// ------------------------------------------------------- ancora do primeiro

(function ancora() {
  // O servidor nao devolve necessariamente o instante pedido: ele comeca no
  // keyframe anterior, e limita ao que existe gravado. Ancorar no PEDIDO faria
  // cada quadro vencer daqui a decadas -- nada apareceria.
  const p = novoPlayer([]);
  p.baseMs = 1000;                     // pedido
  p.baseRelogio = 0;
  p.ultimoMs = 1000;
  pendentes(p, [900000000]);
  p.quadroNativo = fazerQuadro(900000000);   // o que existe, bem longe

  relogioMs = 0;
  p.bombearNativo(p.relogio());
  conferir("reancorou no que chegou", p.baseMs, 900000000);
  conferir("e desenhou em vez de esperar decadas", p.desenhados.length, 1);
})();

// ----------------------------------------------- a troca de motor no erro

// O decodificador de hardware que recusa o fluxo erra de novo e de novo. Antes,
// a decisao de trocar para software olhava so a RAJADA -- dois erros em dois
// segundos --, e um decodificador que errava mais devagar zerava a contagem a
// cada erro e nunca chegava a dois: ficava para sempre em "trecho ilegivel".
(function trocaDeMotor() {
  const p = novoPlayer([]);
  p.nativo = false;
  p.cadeia = "avc3.4D0033";
  p.spsLargura = 1920;
  p.spsAltura = 1080;
  p.abrirDecodificador = () => {};
  let trocou = 0;
  p.trocarParaSoftware = () => { trocou++; };

  relogioMs = 0;
  p.recuperarDoErro();
  conferir("o primeiro erro so refaz do proximo keyframe", trocou, 0);

  relogioMs = 10000;                 // dez segundos depois: fora da rajada
  p.recuperarDoErro();
  conferir("o segundo erro troca de motor, ainda que devagar", trocou, 1);
})();

// ------------------------------------------- nao repetir o que ja se aprendeu

(function lembraDoFormato() {
  Player.softwareNecessario = {};
  const p = novoPlayer([]);
  p.cadeia = "avc3.4D0033";
  p.spsLargura = 1920;
  p.spsAltura = 1080;

  p.adotarOQueJaSeSabe();
  conferir("sem historico, comeca no hardware", p.usandoSoftware, false);

  Player.softwareNecessario["avc3.4D0033|1920x1080"] = true;
  const q = novoPlayer([]);
  q.cadeia = "avc3.4D0033";
  q.spsLargura = 1920;
  q.spsAltura = 1080;
  q.adotarOQueJaSeSabe();
  conferir("sabendo que o hardware falha, ja abre em software",
           q.usandoSoftware, true);

  // Outro tamanho e outro caso: nao herda o veredito.
  const r = novoPlayer([]);
  r.cadeia = "avc3.4D0033";
  r.spsLargura = 1280;
  r.spsAltura = 720;
  r.adotarOQueJaSeSabe();
  conferir("o veredito nao vaza para outro tamanho", r.usandoSoftware, false);
  Player.softwareNecessario = {};
})();

console.log((falhas ? "FALHOU" : "passou") + ": " + checagens +
            " verificacoes, " + falhas + " falha(s)");
process.exit(falhas ? 1 : 0);
