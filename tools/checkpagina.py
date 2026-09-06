# -*- coding: utf-8 -*-
"""Confere a pagina: todo $("id") existe no markup, toda funcao chamada existe.

Sem navegador, e o que pega os dois enganos que uma reescrita como esta costuma
deixar -- um id que sobrou de um controle que saiu, e uma funcao que ficou sendo
chamada depois de removida.
"""
from __future__ import print_function

import io
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
P = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    AQUI, '..', 'src', 'UI', 'web', 'motion-ui.html')

s = io.open(P, encoding='utf-8').read()
scripts = '\n'.join(re.findall(r'<script[^>]*>(.*?)</script>', s, re.S))
markup = re.sub(r'<script[^>]*>.*?</script>', '', s, flags=re.S)

ids_markup = set(re.findall(r'\bid="([^"]+)"', markup))
ids_usados = set(re.findall(r'\$\("([^"]+)"\)', scripts))
ids_usados |= set(re.findall(r'getElementById\("([^"]+)"\)', scripts))

falta = sorted(ids_usados - ids_markup)
sobra = sorted(ids_markup - ids_usados)

nomes_def = re.findall(r'\bfunction\s+([A-Za-z_$][\w$]*)', scripts)
definidas = set(nomes_def)

# Duas funcoes com o MESMO nome: a ultima declarada vence e a outra some,
# sem erro nenhum. Foi assim que um `escolherPasso` de eixo engoliu um
# `escolherPasso` de formulario, e o ajuste do servidor deixou de ser
# carregado -- em silencio, que e o pior jeito de quebrar.
# So as do NIVEL DE CIMA: funcoes aninhadas vivem em escopos separados e
# podem repetir nome sem se atrapalhar. As de coluna zero, nao -- a
# ultima declarada apaga a anterior.
nomes_topo = re.findall(r'^function\s+([A-Za-z_$][\w$]*)',
                        scripts, re.M)
repetidas = sorted(set(n for n in nomes_topo if nomes_topo.count(n) > 1))
definidas |= set(re.findall(r'\bvar\s+([A-Za-z_$][\w$]*)\s*=\s*function', scripts))
chamadas = set(re.findall(r'(?<![.\w$])([A-Za-z_$][\w$]*)\s*\(', scripts))

# O que vem do navegador, do vmsreader ou do proprio bloco do detector.
CONHECIDAS = set('''
if for while switch catch return typeof function new delete void in of do else
Math JSON Date Object Array String Number Boolean Promise Error Uint8Array
Int32Array URLSearchParams parseInt parseFloat isNaN encodeURIComponent fetch
setTimeout setInterval clearTimeout requestAnimationFrame createImageBitmap
VideoDecoder EncodedVideoChunk VMS Deteccao performance console document window
navigator alert Set Map WeakMap Uint8ClampedArray Float32Array
'''.split())

sem_definicao = sorted(c for c in chamadas
                       if c not in definidas and c not in CONHECIDAS)

print('ids usados sem existir no markup: %s' % (falta or 'nenhum'))
print('ids no markup que ninguem usa:    %s' % (sobra or 'nenhum'))
print('chamadas sem funcao conhecida:    %s' % (sem_definicao or 'nenhuma'))
print('funcoes declaradas duas vezes:    %s' % (repetidas or 'nenhuma'))
sys.exit(1 if (falta or repetidas) else 0)
