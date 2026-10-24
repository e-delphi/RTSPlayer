// O detector da tela de sintonia concorda com o do servidor?
//
// A tela de detecção de movimento analisa NA PÁGINA, sobre os quadros que o
// player já está desenhando -- é o que faz cada ajuste responder na hora, sem
// devolver um trecho inteiro ao servidor para decodificar de novo. O preço disso
// é ter um terceiro detector: o Pascal (Vms.Analytics.Motion), o modelo em
// Python (tools/eventlib.py, conferido pelo selftest) e este, em JavaScript.
//
// Se ele divergir, a tela passa a ajustar números que não valem na produção --
// e em silêncio, que é o pior jeito de errar. Aqui os dois recebem as MESMAS
// grades e têm de chegar aos mesmos números.
//
//     python tools/dumpmotion.py > esperado.json
//     node tools/testmotion.js esperado.json
//
// Os dois lados chegam lá por caminhos diferentes, de propósito: o modelo reduz
// a imagem direto para a grade grossa, e a página agrupa a grade fina que
// guardou. Concordarem prova que agrupar equivale a reduzir -- que é o que
// permite a página guardar só a grade fina e reclassificar tudo sem rede.

"use strict";

const fs = require("fs");
const path = require("path");

// O detector mora num bloco <script id="detector"> da própria página, sem tocar
// em nada do DOM justamente para poder ser avaliado aqui. Mesmo caminho do
// tools/testvmsreader.js.
const html = fs.readFileSync(
  path.join(__dirname, "..", "src", "UI", "web", "motion-ui.html"), "utf8");
const m = html.match(/<script id="detector">([\s\S]*?)<\/script>/);
if (!m) {
  console.error('não achei o bloco <script id="detector"> em motion-ui.html');
  process.exit(2);
}
const Deteccao = eval(m[1] + "; Deteccao");

const esperadoPath = process.argv[2];
if (!esperadoPath) {
  console.error("uso: node tools/testmotion.js <esperado.json>");
  process.exit(2);
}
const esperado = JSON.parse(fs.readFileSync(esperadoPath, "utf8"));

let falhas = 0, checagens = 0;

function conferir(nome, obtido, querido) {
  checagens++;
  const a = JSON.stringify(obtido), b = JSON.stringify(querido);
  if (a !== b) {
    falhas++;
    console.log("FALHOU  " + nome + "\n  obtido:  " + a + "\n  querido: " + b);
  }
}

// Frações vindas de divisões inteiras diferentes podem diferir no último bit.
function perto(nome, obtido, querido, tol) {
  checagens++;
  if (Math.abs(obtido - querido) > (tol || 1e-9)) {
    falhas++;
    console.log("FALHOU  " + nome + "\n  obtido:  " + obtido +
                "\n  querido: " + querido);
  }
}

conferir("a grade fina é a mesma dos dois lados",
         [Deteccao.GRADE_W, Deteccao.GRADE_H], esperado.gradeFina);

esperado.casos.forEach(function (caso) {
  const p = caso.params;
  const rot = "grade " + caso.grade[0] + "x" + caso.grade[1] +
              ", delta " + p.delta + ", limiar " + p.limiar;

  conferir(rot + ": o agrupamento leva à mesma grade",
           [Deteccao.GRADE_W / Deteccao.agrupamento(p.escala),
            Deteccao.GRADE_H / Deteccao.agrupamento(p.escala)],
           caso.grade);

  // Cada rodada começa do zero: o fundo é história, e reaproveitar as amostras
  // de um caso no seguinte esconderia justamente um erro de estado.
  const amostras = esperado.quadros.map(function (q) {
    return { ms: q.ms, cel: Uint8Array.from(q.cel) };
  });
  Deteccao.rodar(amostras, p);

  amostras.forEach(function (a, i) {
    const e = caso.saidas[i];
    const quando = rot + " @ " + i;
    perto(quando + ": score", a.score, e.score, 1e-9);
    conferir(quando + ": mexeu", !!a.moved, e.moved);
    conferir(quando + ": cena nova", !!a.scene, e.scene);
    conferir(quando + ": caixa",
             a.box ? [a.box.l, a.box.t, a.box.r, a.box.b] : null, e.box);
  });
});

console.log((falhas ? "FALHOU" : "passou") + ": " + checagens +
            " verificacoes, " + falhas + " falha(s)");
process.exit(falhas ? 1 : 0);
