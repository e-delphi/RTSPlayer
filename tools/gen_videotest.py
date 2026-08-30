# -*- coding: utf-8 -*-
"""Gera tools/videotest.html: o mesmo fluxo, pelos caminhos que NAO sao WebCodecs.

Motivo: o WebCodecs devolveu 2560x1440 como 1934x1088 num WebView Android, e com
formato RGBA -- sinal de que houve conversao/leitura de textura no meio, enquanto
no PC veio NV12 sem conversao. Isso levanta a hipotese de que o decodificador
esta bom e quem quebra e o caminho de EXPORTAR o quadro para o JavaScript.

O `<video>` nao exporta quadro nenhum: o decodificador renderiza direto numa
surface. Se ele tocar 2560x1440 aqui, a hipotese se confirma e o WebCodecs deixa
de ser o unico caminho possivel para uma pagina.

Duas medidas, porque "tocou" ja provou nao bastar:
  - videoWidth/videoHeight: o tamanho que o navegador diz estar renderizando
  - currentTime andando: prova que ha quadro saindo, e nao so metadado lido

    python tools/gen_videotest.py caminho/para/fragmentado.mp4

Gera um arquivo unico e autossuficiente: copie para o celular e abra no Chrome.
"""

import base64
import io
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
SAIDA = os.path.join(AQUI, 'videotest.html')
COLUNAS = 120

MOLDE = r'''<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Teste de v&iacute;deo &mdash; 2560x1440 HEVC</title>
<!--
  GERADO por tools/gen_videotest.py -- NAO EDITE.

  O mesmo fluxo da camera "frente", bit a bit como foi gravado (remux, sem
  recodificar), pelos dois caminhos que NAO passam pelo WebCodecs.

  Copie este arquivo para o celular e abra no Chrome. file:// e contexto seguro,
  entao nada aqui depende de servidor.
-->
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#121212; color:#e8e8e8;
         font:15px/1.5 system-ui, "Segoe UI", Roboto, sans-serif; }
  .wrap { max-width:820px; margin:0 auto; padding:14px; }
  h1 { font-size:17px; margin:0 0 4px; }
  .sub { color:#8a8a8a; font-size:12px; margin-bottom:14px; }
  .card { background:#1e1e1e; border:1px solid #2f2f2f; border-radius:10px;
          padding:12px; margin-bottom:12px; }
  h2 { font-size:14px; margin:0 0 8px; }
  video { width:100%; background:#000; border-radius:6px; display:block; }
  .vered { border-radius:8px; padding:9px 11px; margin:8px 0; font-size:14px;
           border:1px solid #3a3a3a; background:#181818; }
  .ok  { border-color:#1e6b3a; background:#14251b; color:#4ade80; }
  .nao { border-color:#7a2b25; background:#241615; color:#f87171; }
  .esp { border-color:#7a5b1e; background:#241f12; color:#fbbf24; }
  .lin { font-size:12px; font-family:ui-monospace, Consolas, monospace;
         color:#9a9a9a; padding:2px 0; word-break:break-all; }
  button { background:#2d9cdb; color:#fff; border:0; border-radius:6px;
           padding:9px 16px; font:inherit; cursor:pointer; margin-right:8px; }
  pre { background:#0d0d0d; border:1px solid #2f2f2f; border-radius:8px;
        padding:10px; font-size:11px; white-space:pre-wrap; word-break:break-all;
        user-select:all; }
</style>

<div class="wrap">
  <h1>V&iacute;deo 2560x1440 HEVC &mdash; c&acirc;mera frente</h1>
  <div class="sub">Fluxo original remuxado, sem recodificar. O que importa n&atilde;o
    &eacute; "tocou": &eacute; o tamanho relatado bater com <b>2560x1440</b>.</div>

  <div class="card">
    <h2>1. &lt;video&gt; direto</h2>
    <div class="vered" id="v1">carregando...</div>
    <video id="vid1" controls muted playsinline preload="auto"></video>
    <div class="lin" id="l1"></div>
  </div>

  <div class="card">
    <h2>2. MediaSource (o caminho de um player em p&aacute;gina)</h2>
    <div class="vered" id="v2">carregando...</div>
    <video id="vid2" controls muted playsinline></video>
    <div class="lin" id="l2"></div>
  </div>

  <button id="copiar">Copiar resultado</button>
  <pre id="txt">...</pre>
</div>

<script>
"use strict";

var LARGURA = __W__, ALTURA = __H__;
var MIME = '__MIME__';
var B64 = [
__B64__
].join("");

function $(id) { return document.getElementById(id); }

var texto = [];
function reg(s) { texto.push(s); document.getElementById("txt").textContent =
                  texto.join("\n"); }

function bytes() {
  var bin = atob(B64);
  var a = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
  return a;
}

// O veredito de um <video>: nao basta o evento disparar, o tamanho tem de bater.
// Um decodificador que engasga costuma relatar tamanho menor em vez de dar erro,
// e foi exatamente assim que o WebCodecs mentiu neste mesmo fluxo.
function julgar(v, el, nome) {
  var w = el.videoWidth, h = el.videoHeight;
  reg(nome + ": videoWidth=" + w + " videoHeight=" + h +
      " readyState=" + el.readyState + " currentTime=" +
      el.currentTime.toFixed(2));
  if (!w || !h) {
    v.className = "vered nao";
    v.textContent = "sem dimens" + "ã" + "o: n" + "ã" + "o decodificou";
    return false;
  }
  // Tamanho diferente NAO e sinonimo de falha. Quem separa os dois casos e o
  // ASPECTO:
  //
  //   proporcao mantida  -> o decodificador REDUZIU, e a imagem esta perfeita,
  //                         so menor. Decodificador de hardware limitado a
  //                         1080p faz isso com fluxo de 1440p: 2560x1440 vira
  //                         1934x1088, escala uniforme de 0,7555. Numa tela de
  //                         celular nem da para notar.
  //   proporcao quebrada -> ai sim ha algo errado.
  if (w !== LARGURA || h !== ALTURA) {
    var desvio = Math.abs((w / h) - (LARGURA / ALTURA)) / (LARGURA / ALTURA);
    if (desvio > 0.02) {
      v.className = "vered nao";
      v.textContent = "PROPOR" + "Ç" + "ÃO ERRADA: " + w + "x" + h +
                      ", esperado " + LARGURA + "x" + ALTURA;
      return false;
    }
    v.className = "vered esp";
    v.textContent = "OK, mas REDUZIDO: " + w + "x" + h + " (de " + LARGURA +
      "x" + ALTURA + ", escala " + (w / LARGURA).toFixed(3) +
      ") -- proporcao mantida, imagem utiliz" + "á" + "vel";
    return true;
  }
  v.className = "vered ok";
  v.textContent = "OK: " + w + "x" + h + " renderizando";
  return true;
}

// currentTime andando e a prova de que sai QUADRO, e nao so metadado. Um
// <video> pode anunciar dimensoes corretas e nunca apresentar imagem.
function vigiar(el, v, nome) {
  var t0 = el.currentTime, tentativas = 0;
  var iv = setInterval(function () {
    tentativas++;
    if (el.currentTime > t0 + 0.15) {
      clearInterval(iv);
      reg(nome + ": reproduzindo, currentTime=" + el.currentTime.toFixed(2));
      if (v.className.indexOf("ok") >= 0)
        v.textContent += "  --  e avan" + "ç" + "ando";
      return;
    }
    if (tentativas > 25) {
      clearInterval(iv);
      reg(nome + ": NAO avancou (currentTime parado em " +
          el.currentTime.toFixed(2) + ")");
      v.className = "vered esp";
      v.textContent += "  --  mas o tempo n" + "ã" + "o avan" +
                       "ç" + "a: sem quadro";
    }
  }, 200);
}

function erroDe(el) {
  var e = el.error;
  if (!e) return "sem detalhe";
  var nomes = { 1: "ABORTED", 2: "NETWORK", 3: "DECODE",
                4: "SRC_NOT_SUPPORTED" };
  return (nomes[e.code] || e.code) + "  " + (e.message || "");
}

// ---------------------------------------------------------------- teste 1
function teste1(dados) {
  var el = $("vid1"), v = $("v1");
  el.src = URL.createObjectURL(new Blob([dados], { type: "video/mp4" }));
  el.onloadedmetadata = function () { julgar(v, el, "video"); };
  el.oncanplay = function () {
    if (julgar(v, el, "video")) { el.play().catch(function () {}); vigiar(el, v, "video"); }
  };
  el.onerror = function () {
    v.className = "vered nao";
    v.textContent = "erro: " + erroDe(el);
    reg("video: ERRO " + erroDe(el));
  };
}

// ---------------------------------------------------------------- teste 2
function teste2(dados) {
  var el = $("vid2"), v = $("v2");
  if (typeof MediaSource === "undefined") {
    v.className = "vered nao"; v.textContent = "sem MediaSource";
    return;
  }
  if (!MediaSource.isTypeSupported(MIME)) {
    v.className = "vered nao";
    v.textContent = "isTypeSupported diz n" + "ã" + "o para " + MIME;
    reg("mse: isTypeSupported(" + MIME + ") = false");
    return;
  }
  var ms = new MediaSource();
  el.src = URL.createObjectURL(ms);
  ms.addEventListener("sourceopen", function () {
    var sb;
    try {
      sb = ms.addSourceBuffer(MIME);
    } catch (e) {
      v.className = "vered nao";
      v.textContent = "addSourceBuffer falhou: " + e;
      reg("mse: addSourceBuffer " + e);
      return;
    }
    sb.addEventListener("updateend", function () {
      try { if (ms.readyState === "open") ms.endOfStream(); } catch (e) {}
    });
    sb.addEventListener("error", function () {
      v.className = "vered nao"; v.textContent = "erro no SourceBuffer";
      reg("mse: erro no SourceBuffer");
    });
    try {
      sb.appendBuffer(dados);
    } catch (e) {
      v.className = "vered nao";
      v.textContent = "appendBuffer falhou: " + e;
      reg("mse: appendBuffer " + e);
    }
  });
  el.oncanplay = function () {
    if (julgar(v, el, "mse")) { el.play().catch(function () {}); vigiar(el, v, "mse"); }
  };
  el.onerror = function () {
    v.className = "vered nao";
    v.textContent = "erro: " + erroDe(el);
    reg("mse: ERRO " + erroDe(el));
  };
}

reg("== TESTE DE VIDEO (fora do WebCodecs) ==");
reg("esperado        : " + LARGURA + "x" + ALTURA + "  " + MIME);
reg("isSecureContext : " + window.isSecureContext);
reg("userAgent       : " + navigator.userAgent);
reg("");
var DADOS = bytes();
reg("mp4 embutido    : " + DADOS.length + " bytes");
teste1(DADOS);
teste2(DADOS);

$("copiar").onclick = function () {
  var t = $("txt").textContent;
  if (navigator.clipboard && navigator.clipboard.writeText)
    navigator.clipboard.writeText(t).then(function () {
      $("copiar").textContent = "Copiado";
    }).catch(function () { alert(t); });
  else alert(t);
};
</script>
'''


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    caminho = sys.argv[1]
    dados = io.open(caminho, 'rb').read()
    b64 = base64.b64encode(dados).decode('ascii')
    linhas = [b64[i:i + COLUNAS] for i in range(0, len(b64), COLUNAS)]

    largura = sys.argv[2] if len(sys.argv) > 2 else '2560'
    altura = sys.argv[3] if len(sys.argv) > 3 else '1440'
    mime = 'video/mp4; codecs="hvc1.1.6.L150"'

    html = (MOLDE
            .replace('__W__', largura)
            .replace('__H__', altura)
            .replace('__MIME__', mime)
            .replace('__B64__', ',\n'.join("'%s'" % l for l in linhas)))

    io.open(SAIDA, 'w', encoding='utf-8', newline='\n').write(html)
    print('gerado %s' % os.path.normpath(SAIDA))
    print('  mp4 de %d KB, pagina de %d KB' % (len(dados) // 1024,
                                               len(html) // 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
