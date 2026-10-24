# -*- coding: utf-8 -*-
"""Acha identificador usado sem a unit dele no `uses`.

Existe porque aqui nao ha build por linha de comando: o compilador so aparece
quando o usuario abre a IDE, e devolver erro em conta-gotas custa uma rodada
inteira por vez. Este script faz a parte mecanica da conferencia antes disso.

    python tools/checkuses.py                 # o app
    python tools/checkuses.py vms             # o servidor

Como funciona: para cada unit, monta o que as OUTRAS units exportam na interface
(tipos, funcoes, procedimentos, constantes) e procura esses nomes no corpo dela.
Achou um nome que so existe numa unit que nao esta no `uses`, reclama.

Falso positivo acontece quando duas units exportam o MESMO nome -- ai o nome e
listado com as duas origens e cabe olhar. Falso NEGATIVO acontece com
identificador de unit da RTL/FMX, que este script nao le.
"""

import io
import os
import re
import sys

RAIZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# Nomes curtos demais dao ruido (aparecem dentro de outras palavras e em
# comentario). Oito e o ponto onde a lista para de ser util.
MIN_NOME = 6


def units(pastas):
    mapa = {}
    for base in pastas:
        for d, _, fs in os.walk(os.path.join(RAIZ, base)):
            if '__history' in d or '__recovery' in d:
                continue
            for f in fs:
                if f.endswith('.pas'):
                    mapa.setdefault(f[:-4], os.path.join(d, f))
    return mapa


def texto(p):
    return io.open(p, encoding='utf-8-sig', errors='replace').read()


def sem_comentario(t):
    t = re.sub(r'//[^\n]*', '', t)
    t = re.sub(r'\{[^}]*\}', '', t)
    return re.sub(r'\(\*.*?\*\)', '', t, flags=re.S)


def exportados(p):
    t = sem_comentario(texto(p)).split('\nimplementation', 1)[0]
    n = set(re.findall(r'^(?:function|procedure)\s+(\w+)', t, re.M))
    n |= set(re.findall(r'^\s{2}(\w+)\s*=\s*(?:class|interface|record|packed)',
                        t, re.M))
    n |= set(re.findall(r'^\s{2}(\w+)\s*=\s*\(', t, re.M))
    n |= set(re.findall(r'^\s{2}(\w+)\s*=\s*[^\n=]+;', t, re.M))
    return {x for x in n if len(x) >= MIN_NOME}


def usados(p):
    t = sem_comentario(texto(p))
    fora = set()
    for m in re.finditer(r'\buses\b(.*?);', t, re.S | re.I):
        fora |= set(re.findall(r'[\w.]+', m.group(1)))
    return fora


def campos_fora_de_ordem(p):
    """Campo declarado depois de metodo/propriedade na MESMA secao.

    O Delphi recusa com E2169. A contagem reinicia a cada `private`/`public`/
    etc., e e justamente esse detalhe que faz o erro passar despercebido numa
    leitura rapida: o campo parece estar junto dos outros, mas caiu depois de um
    metodo dentro da mesma secao.
    """
    t = sem_comentario(texto(p))
    fora, metodo = [], False
    for linha in t.split(chr(10)):
        l = linha.strip()
        if re.match(r'^(strict\s+)?(private|protected|public|published)', l):
            metodo = False
            continue
        if re.match(r'^(type|implementation)', l):
            metodo = False
            continue
        if re.match(r'^(procedure|function|constructor|destructor|property)', l):
            metodo = True
        elif metodo and re.match(r'^F[A-Z]\w*\s*:', l):
            fora.append(l)
    return fora


def main():
    pastas = ['vms/src'] if (len(sys.argv) > 1 and sys.argv[1] == 'vms') \
        else ['src', 'vms/src/Api']
    mapa = units(pastas)
    exporta = {u: exportados(p) for u, p in mapa.items()}

    faltas = []
    for u, p in mapa.items():
        corpo = sem_comentario(texto(p))
        # so o que nao e declaracao propria: tira a lista de uses do texto
        corpo_sem_uses = re.sub(r'\buses\b.*?;', '', corpo, flags=re.S | re.I)
        meus = usados(p)
        proprios = exporta[u]
        for outra, nomes in exporta.items():
            if outra == u or outra in meus:
                continue
            for n in sorted(nomes):
                if n in proprios:
                    continue
                if re.search(r'\b' + re.escape(n) + r'\b', corpo_sem_uses):
                    faltas.append((u, n, outra))

    # agrupa por (unit, nome): varias origens = provavel falso positivo
    porcaso = {}
    for u, n, o in faltas:
        porcaso.setdefault((u, n), []).append(o)

    ordem = []
    for u, p in sorted(mapa.items()):
        for l in campos_fora_de_ordem(p):
            ordem.append((u, l))
    if ordem:
        print('campo depois de metodo na mesma secao (E2169):')
        for u, l in ordem:
            print('    %-24s %s' % (u, l))
        print('')

    if not porcaso:
        if ordem:
            return 1
        print('nenhum identificador orfao')
        return 0

    print('identificadores sem a unit no uses (%d):' % len(porcaso))
    for (u, n), origens in sorted(porcaso.items()):
        marca = '  ?' if len(origens) > 1 else '   '
        print('%s %-24s usa %-24s de %s' % (marca, u, n, ', '.join(origens)))
    print('\n"?" = o nome existe em mais de uma unit; provavel falso positivo.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
