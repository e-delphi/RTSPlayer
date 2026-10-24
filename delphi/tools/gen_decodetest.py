# -*- coding: utf-8 -*-
"""Gera src/UI/decodetest.html a partir dos quadros extraidos pelo grabau.py.

    python tools/grabau.py --json quadros.json <fontes...>
    python tools/gen_decodetest.py quadros.json
    (nada mais: o arquivo e servido direto)

A pagina resultante NAO fala com a rede: os quadros vao embutidos em base64.
E de proposito -- o que se quer medir e o decodificador, e uma falha de rede no
meio so produziria duvida sobre qual das duas coisas quebrou.

O .html gerado e ASCII puro, por habito desta base: acento por entidade na
marcacao, e por escape unicode nas strings de JavaScript que vao para
textContent.
"""

import io
import json
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
SAIDA = os.path.join(AQUI, '..', 'src', 'UI', 'decodetest.html')

MOLDE = r'''<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Teste de decodifica&ccedil;&atilde;o</title>
<!--
  GERADO por tools/gen_decodetest.py -- NAO EDITE.

  Decodifica de verdade um keyframe REAL de cada camera, com WebCodecs, e pinta
  o resultado. Existe porque `VideoDecoder.isConfigSupported` responde pela
  LISTA de codecs do aparelho -- ele diz que o perfil e o nivel existem, sem
  instanciar decodificador na resolucao real.

  A diferenca importa neste projeto especificamente: no Android nao ha
  decodificador por software atras do MediaCodec (medido: sw=nao em todos os
  codecs), e o decodificador de hardware deste parque ja falhou em 1080p+ com
  "Released state" -- o defeito que obrigou o app nativo a ter fallback por
  software. Dentro da pagina esse fallback nao existe. Entao aqui o unico teste
  que vale e mandar decodificar e ver sair pixel.

  Os quadros vao embutidos: nenhuma rede no meio, para uma falha nao poder ser
  confundida com problema de conexao.
-->
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#121212; color:#e8e8e8;
         font:15px/1.5 system-ui, "Segoe UI", Roboto, sans-serif; }
  .wrap { max-width:820px; margin:0 auto; padding:14px; }
  h1 { font-size:17px; margin:0 0 4px; font-weight:600; }
  .sub { color:#8a8a8a; font-size:12px; margin-bottom:14px; }
  .card { background:#1e1e1e; border:1px solid #2f2f2f; border-radius:10px;
          padding:12px; margin-bottom:12px; }
  .cab { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap;
         margin-bottom:8px; }
  .cam { font-size:16px; font-weight:600; }
  .meta { color:#8a8a8a; font-size:12px; }
  .vered { border-radius:8px; padding:9px 11px; margin:8px 0; font-size:14px;
           border:1px solid #3a3a3a; background:#181818; }
  .ok  { border-color:#1e6b3a; background:#14251b; color:#4ade80; }
  .nao { border-color:#7a2b25; background:#241615; color:#f87171; }
  .esp { border-color:#7a5b1e; background:#241f12; color:#fbbf24; }
  canvas { width:100%; max-width:100%; background:#000; border-radius:6px;
           display:block; margin-top:8px; }
  .tent { font-size:12px; font-family:ui-monospace, Consolas, monospace;
          padding:3px 0; border-bottom:1px solid #262626; color:#9a9a9a;
          word-break:break-all; }
  .tent:last-child { border-bottom:0; }
  .tent b { color:#e8e8e8; }
  button { background:#2d9cdb; color:#fff; border:0; border-radius:6px;
           padding:9px 16px; font:inherit; cursor:pointer; margin-right:8px; }
  button.sec { background:#333; }
  pre { background:#0d0d0d; border:1px solid #2f2f2f; border-radius:8px;
        padding:10px; font-size:11px; overflow-x:auto; white-space:pre-wrap;
        word-break:break-all; user-select:all; }
</style>

<div class="wrap">
  <h1>Teste de decodifica&ccedil;&atilde;o &mdash; quadros reais</h1>
  <div class="sub">Um keyframe de cada c&acirc;mera, embutido na p&aacute;gina.
    Se aparecer imagem, o caminho WebCodecs est&aacute; provado nesta
    resolu&ccedil;&atilde;o e neste aparelho.</div>

  <div id="lista"></div>

  <button id="denovo" class="sec">Rodar de novo</button>
  <button id="copiar">Copiar resultado</button>
  <pre id="txt">...</pre>
</div>

<script>
"use strict";

// Injetado pelo gerador: um objeto por camera, com o AU em base64 quebrado em
// linhas curtas (linha longa demais viraria um literal Pascal gigante).
var QUADROS = __QUADROS__;

// Quanto esperar por quadro antes de declarar travado. A falha que estamos
// cacando nem sempre vira erro: decodificador de hardware que engasga costuma
// simplesmente nao chamar o output, e sem teto a pagina ficaria pendurada.
var TETO_MS = 6000;

function $(id) { return document.getElementById(id); }

function bytesDe(linhas) {
  var bin = atob(linhas.join(""));
  var out = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function junta(a, b) {
  var o = new Uint8Array(a.length + b.length);
  o.set(a, 0); o.set(b, a.length);
  return o;
}

// Uma tentativa: configura, manda o quadro, espera sair pixel. Resolve SEMPRE,
// com "ok", "erro" ou "travou" -- nunca rejeita, porque uma candidata que falha
// e resultado, e nao acidente.
function tentar(codec, dados, larg, alt) {
  return new Promise(function (resolve) {
    var pronto = false, dec = null;
    var t0 = (performance && performance.now) ? performance.now() : Date.now();
    function agora() {
      return Math.round(((performance && performance.now)
                         ? performance.now() : Date.now()) - t0);
    }
    var timer = setTimeout(function () {
      if (pronto) return;
      pronto = true;
      try { dec.close(); } catch (e) {}
      resolve({ r: "travou", ms: agora() });
    }, TETO_MS);

    try {
      dec = new VideoDecoder({
        output: function (frame) {
          if (pronto) { frame.close(); return; }
          pronto = true; clearTimeout(timer);
          resolve({ r: "ok", frame: frame, dec: dec, ms: agora() });
        },
        error: function (e) {
          if (pronto) return;
          pronto = true; clearTimeout(timer);
          try { dec.close(); } catch (x) {}
          resolve({ r: "erro", ms: agora(),
                    msg: String((e && (e.message || e.name)) || e) });
        }
      });
      var cfg = { codec: codec };
      // Largura e altura sao dicas opcionais. So vao quando saem do SPS: o
      // cabecalho do .vms guarda 0x0, e mandar zero seria pior que omitir.
      if (larg > 0 && alt > 0) { cfg.codedWidth = larg; cfg.codedHeight = alt; }
      dec.configure(cfg);
      dec.decode(new EncodedVideoChunk({ type: "key", timestamp: 0,
                                         data: dados }));
      dec.flush().catch(function () {});
    } catch (e) {
      if (pronto) return;
      pronto = true; clearTimeout(timer);
      resolve({ r: "erro", ms: agora(),
                msg: String((e && (e.message || e.name)) || e) });
    }
  });
}

var texto = [];
function reg(s) { texto.push(s); }

function cartao(q) {
  var d = document.createElement("div");
  d.className = "card";
  var au = bytesDe(q.au);
  var prefixado = false;

  // Sem parameter set no fluxo, o decodificador nao tem do que se configurar.
  // O extradata do cabecalho do .vms tambem e Annex-B, entao basta concatenar
  // -- nada de montar avcC/hvcC nem de usar `description`.
  if (!q.temParameterSet && q.extradata && q.extradata.length) {
    au = junta(bytesDe(q.extradata), au);
    prefixado = true;
  }

  d.innerHTML =
    '<div class="cab"><span class="cam">' + q.camera + '</span>' +
    '<span class="meta">' + q.codecName +
    (q.width > 0 ? "  &middot;  " + q.width + "x" + q.height : "") +
    "  &middot;  " + q.bytes + " bytes  &middot;  " +
    (q.temParameterSet ? "parameter sets no fluxo"
                       : "PS s&oacute; no cabe&ccedil;alho") +
    (prefixado ? " (prefixados aqui)" : "") + "</span></div>" +
    '<div class="vered" id="v_' + q.camera + '">decodificando...</div>' +
    '<div id="t_' + q.camera + '"></div>';
  $("lista").appendChild(d);

  reg("== " + q.camera + " (" + q.codecName + ") " +
      (q.width > 0 ? q.width + "x" + q.height + " " : "") +
      q.bytes + " bytes  ps=" + q.temParameterSet +
      (prefixado ? " +extradata" : ""));

  // As candidatas em ordem, parando na primeira que der pixel.
  var i = 0;
  function proxima() {
    if (i >= q.codecs.length) {
      var v = $("v_" + q.camera);
      v.className = "vered nao";
      v.textContent = "nenhuma cadeia decodificou este quadro no tamanho certo";
      reg("   VEREDITO: NAO DECODIFICOU");
      return Promise.resolve();
    }
    var codec = q.codecs[i++];
    return tentar(codec, au, q.width, q.height).then(function (res) {
      var linha = document.createElement("div");
      linha.className = "tent";
      linha.innerHTML = "<b>" + codec + "</b> &rarr; " + res.r +
        (res.msg ? "  " + res.msg : "") + "  (" + res.ms + " ms)";
      $("t_" + q.camera).appendChild(linha);
      reg("   " + codec + " -> " + res.r + (res.msg ? "  " + res.msg : "") +
          "  (" + res.ms + " ms)");

      if (res.r !== "ok") return proxima();

      var f = res.frame;
      // O tamanho de EXIBICAO, e nao o codificado: o codificado e multiplo do
      // bloco do codec (1080 vira 1104 em H.264), e comparar por ele acusaria
      // erro onde nao ha.
      var lw = f.displayWidth || f.codedWidth;
      var lh = f.displayHeight || f.codedHeight;

      // "Decodificou" nao basta, mas "tamanho diferente" tambem nao e sinonimo
      // de falha -- e essa distincao custou uma conclusao errada.
      //
      // Ha dois casos, e eles se separam pelo ASPECTO:
      //
      //   proporcao mantida  -> o decodificador REDUZIU. E o que decodificador
      //                         de hardware limitado a 1080p faz com um fluxo
      //                         de 1440p: 2560x1440 sai 1934x1088, escala
      //                         uniforme de 0,7555. A imagem esta perfeita, so
      //                         menor. Numa tela de celular nem da para notar.
      //
      //   proporcao quebrada -> ai sim ha algo errado, e o suspeito de sempre e
      //                         nivel declarado a menos do que o fluxo exige.
      var reduzido = "";
      if (q.width > 0 && (lw !== q.width || lh !== q.height)) {
        var aspEsperado = q.width / q.height;
        var aspSaiu = lw / lh;
        var desvio = Math.abs(aspSaiu - aspEsperado) / aspEsperado;
        if (desvio > 0.02) {
          var aviso = document.createElement("div");
          aviso.className = "tent";
          aviso.innerHTML = "&nbsp;&nbsp;&rarr; <b>propor&ccedil;&atilde;o " +
            "errada</b>: saiu " + lw + "x" + lh + ", o SPS promete " +
            q.width + "x" + q.height + " &mdash; cadeia recusada";
          $("t_" + q.camera).appendChild(aviso);
          reg("   " + codec + " -> PROPORCAO ERRADA " + lw + "x" + lh +
              " (SPS promete " + q.width + "x" + q.height + ")");
          f.close();
          try { res.dec.close(); } catch (e) {}
          return proxima();
        }
        reduzido = "  (reduzido de " + q.width + "x" + q.height +
                   ", escala " + (lw / q.width).toFixed(3) + ")";
      }

      var cv = document.createElement("canvas");
      cv.width = lw;
      cv.height = lh;
      try {
        cv.getContext("2d").drawImage(f, 0, 0, lw, lh);
      } catch (e) {
        reg("   (drawImage falhou: " + e + ")");
      }
      var v = $("v_" + q.camera);
      v.className = "vered " + (reduzido ? "esp" : "ok");
      v.textContent = "DECODIFICOU com " + codec + " -- " + lw + "x" + lh +
        reduzido + ", formato " + (f.format || "?") + ", em " + res.ms + " ms";
      $("t_" + q.camera).parentNode.appendChild(cv);
      reg("   VEREDITO: OK  " + codec + "  " + lw + "x" + lh + reduzido +
          "  cod=" + f.codedWidth + "x" + f.codedHeight +
          "  " + (f.format || "?") + "  " + res.ms + " ms");
      f.close();
      try { res.dec.close(); } catch (e) {}
      return Promise.resolve();
    });
  }
  return proxima();
}

function rodar() {
  texto = [];
  $("lista").innerHTML = "";
  if (typeof VideoDecoder === "undefined") {
    $("lista").innerHTML = '<div class="card vered nao">Sem WebCodecs ' +
      'aqui. Se <code>isSecureContext</code> for falso, o problema &eacute; ' +
      'a origem da p&aacute;gina, e n&atilde;o o aparelho &mdash; veja a tela ' +
      'de sondagem.</div>';
    $("txt").textContent = "VideoDecoder ausente; isSecureContext=" +
      window.isSecureContext;
    return;
  }
  reg("== TESTE DE DECODIFICACAO ==");
  reg("isSecureContext : " + window.isSecureContext);
  reg("userAgent       : " + navigator.userAgent);
  reg("");

  // Uma camera por vez, e nao em paralelo: decodificadores de hardware sao
  // recurso escasso, e disputar tres de uma vez produziria falha de contencao
  // que nada tem a ver com a pergunta.
  var p = Promise.resolve();
  QUADROS.forEach(function (q) {
    p = p.then(function () { return cartao(q); });
  });
  p.then(function () { $("txt").textContent = texto.join("\n"); });
}

$("denovo").onclick = rodar;
$("copiar").onclick = function () {
  var t = $("txt").textContent;
  if (navigator.clipboard && navigator.clipboard.writeText)
    navigator.clipboard.writeText(t).then(function () {
      $("copiar").textContent = "Copiado";
      setTimeout(function () { $("copiar").textContent = "Copiar resultado"; },
                 1500);
    }).catch(function () { alert(t); });
  else alert(t);
};
rodar();
</script>
'''


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    quadros = json.loads(io.open(sys.argv[1], encoding='utf-8').read())
    if not quadros:
        print('nenhum quadro no json')
        return 1

    # indent=1 mantem as linhas do base64 curtas (uma por elemento do array),
    # que e o que o gerador de units precisa.
    dados = json.dumps(quadros, indent=1)
    html = MOLDE.replace('__QUADROS__', dados)

    ruins = [(i + 1, l) for i, l in enumerate(html.split('\n'))
             if any(ord(c) > 126 for c in l)]
    if ruins:
        print('ERRO: caractere nao-ASCII gerado:')
        for n, l in ruins[:5]:
            print('   linha %d: %s' % (n, l.strip()[:70]))
        return 1

    io.open(SAIDA, 'w', encoding='utf-8', newline='\n').write(html)
    print('gerado %s' % os.path.normpath(SAIDA))
    print('  %d quadros, %d linhas, %d KB'
          % (len(quadros), html.count('\n'), len(html) // 1024))
    for q in quadros:
        print('   %-8s %-5s %sx%s  %d bytes  ps=%s'
              % (q['camera'], q['codecName'], q['width'], q['height'],
                 q['bytes'], q['temParameterSet']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
