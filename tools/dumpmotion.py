# -*- coding: utf-8 -*-
"""O que o modelo do detector ve, para o lado JavaScript ser conferido contra.

O tools/eventlib.py e o modelo de Vms.Analytics.Motion, e o tools/selftest.py o
exercita. A tela de sintonia tem um TERCEIRO detector -- o da pagina, que roda
sobre os quadros que o player desenha --, e se ele divergir dos outros dois a
tela passa a ajustar numeros que nao valem na producao, em silencio.

Este script gera o caso de prova:

    python tools/dumpmotion.py > esperado.json
    node tools/testmotion.js esperado.json

O que vai no arquivo sao as GRADES FINAS de cada quadro (64x36 lumas) e o que o
modelo conclui para varias combinacoes de grade, delta e limiar. O JavaScript
recebe as mesmas grades e tem de chegar nos mesmos numeros.

Repare que os dois lados chegam la por caminhos DIFERENTES, de proposito: o
modelo reduz a imagem direto para a grade grossa, e a pagina agrupa a grade
fina. Se as duas coincidirem, esta provado que agrupar equivale a reduzir -- que
e o que permite a pagina guardar so a grade fina e reclassificar tudo sem rede.
"""
from __future__ import print_function

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eventlib

# 320x180 da exatamente 5x5 pixels por celula da grade fina, e 10x10 na de
# 32x18: as duas divisoes fecham sem sobra, entao a comparacao mede o detector e
# nao arredondamento de grade.
W, H = 320, 180
BASE = 1756000000000


def quadro_de_fundo(nivel=100):
    return eventlib.gray_frame(W, H, nivel)


def com_vulto(x0, y0, x1, y1, valor, fundo=100):
    q = eventlib.gray_frame(W, H, fundo)
    eventlib.paint(q, W, H, x0, y0, x1, y1, valor)
    return q


# A sequencia: parado, vulto grande, vulto pequeno e discreto, vulto pequeno e
# berrante, a cena inteira clareando (o ganho do infravermelho), e um salto no
# tempo. Cada um exercita uma decisao diferente do detector.
QUADROS = [
    (0,     quadro_de_fundo()),
    (2000,  quadro_de_fundo()),
    (4000,  com_vulto(120, 60, 200, 130, 220)),
    (6000,  quadro_de_fundo()),
    (8000,  com_vulto(160, 88, 170, 98, 140)),
    (10000, quadro_de_fundo()),
    (12000, com_vulto(160, 88, 170, 98, 250)),
    (14000, quadro_de_fundo(118)),
    (16000, quadro_de_fundo(118)),
    (3600000, quadro_de_fundo(118)),
]

# As combinacoes que a tela oferece.
CASOS = [
    {'escala': 1.0,  'delta': 14, 'limiar': 0.006, 'cena': 0.85},
    {'escala': 0.5,  'delta': 14, 'limiar': 0.006, 'cena': 0.85},
    {'escala': 0.25, 'delta': 14, 'limiar': 0.006, 'cena': 0.85},
    {'escala': 1.0,  'delta': 24, 'limiar': 0.006, 'cena': 0.85},
    {'escala': 1.0,  'delta': 6,  'limiar': 0.020, 'cena': 0.50},
    {'escala': 0.5,  'delta': 30, 'limiar': 0.002, 'cena': 0.85},
]

PASSO_MS = 2000


def main():
    # As grades finas, que sao o que o JavaScript recebe.
    grades = []
    for ms, buf in QUADROS:
        grades.append({
            'ms': BASE + ms,
            'cel': list(eventlib._downsample(buf, W, H,
                                             eventlib.GRID_W, eventlib.GRID_H)),
        })

    casos = []
    for c in CASOS:
        m = eventlib.Motion(threshold=c['limiar'], scene=c['cena'],
                            max_gap_ms=PASSO_MS * 4,
                            grid_scale=c['escala'], cell_delta=c['delta'])
        saidas = []
        for ms, buf in QUADROS:
            r = m.feed(BASE + ms, buf, W, H)
            saidas.append({
                'ms': BASE + ms,
                'score': r['score'],
                'moved': bool(r['moved']),
                'scene': bool(r['scene']),
                'box': list(r['box']) if r['box'] else None,
            })
        gw, gh = eventlib.grade_de(c['escala'])
        casos.append({'params': dict(c, maxGapMs=PASSO_MS * 4),
                      'grade': [gw, gh], 'saidas': saidas})

    json.dump({'largura': W, 'altura': H, 'gradeFina': [eventlib.GRID_W,
                                                       eventlib.GRID_H],
               'quadros': grades, 'casos': casos},
              sys.stdout)


if __name__ == '__main__':
    main()
