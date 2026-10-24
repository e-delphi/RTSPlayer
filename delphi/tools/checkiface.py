# -*- coding: utf-8 -*-
"""Toda classe declara os metodos das interfaces que promete implementar?

Existe porque aqui nao ha compilador: o Delphi so reprova isto na hora do build,
na maquina do usuario, com um E2291 seco no meio de um projeto grande. Adicionar
um metodo a uma interface e esquecer de declarar na classe e um erro de dois
segundos que custa um ciclo inteiro de ida e volta.

    python tools/checkiface.py

O que ele NAO faz: nao entende heranca (classe que herda a implementacao de uma
ancestral), nao confere assinaturas, e nao resolve `implements`. Por isso um
apontamento aqui e um AVISO para conferir, e nao um veredito -- e o programa
sai com 0 mesmo tendo achado algo. O que ele pega, pega cedo.
"""
from __future__ import print_function

import io
import os
import re
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `NomeDaInterface = interface` ... ate o `end` daquele nivel.
RE_IFACE = re.compile(r'^\s*(I[A-Za-z0-9_]*)\s*=\s*interface\b', re.M)
# `TClasse = class(Ancestral, IUma, IOutra)`
RE_CLASSE = re.compile(r'^\s*(T[A-Za-z0-9_]*)\s*=\s*class\s*\(([^)]*)\)', re.M)
# `function Foo(...)` / `procedure Bar;` / `property Baz`
RE_METODO = re.compile(
    r'^\s*(?:function|procedure)\s+([A-Za-z_][A-Za-z0-9_]*)', re.M)
RE_PROP = re.compile(r'^\s*property\s+([A-Za-z_][A-Za-z0-9_]*)', re.M)

# O que abre e o que fecha um bloco de declaracao de tipo.
#
# As fronteiras de palavra sao essenciais: sem elas `end` casa dentro de
# "Append" e "Send", e o bloco fecharia no meio de um nome -- foi assim que uma
# primeira versao deste script acusou 161 faltas inexistentes.
RE_BLOCO = re.compile(r"""(?x)
    \b(?P<end>end)\b
  | =\s*(?P<cls>class)\b(?!\s*of\b)\s*(?:\([^)]*\))?\s*(?P<vazia>;)?
  | =\s*(?P<iface>interface)\b
  | \b(?P<rec>record)\b""")


def unidades():
    for base, dirs, arqs in os.walk(RAIZ):
        dirs[:] = [d for d in dirs
                   if d not in ('__history', '__recovery', '.git', 'Win32',
                                'Win64', 'Android64', 'Debug', 'Release')]
        for a in arqs:
            if a.lower().endswith('.pas'):
                yield os.path.join(base, a)


def texto(caminho):
    with io.open(caminho, 'rb') as f:
        return f.read().decode('utf-8-sig', 'replace').replace('\r\n', '\n')


def corpo(fonte, inicio):
    """Do inicio ate o `end` que fecha ESTE bloco.

    Contar aninhamento importa: uma classe pode declarar tipos dentro dela --
    o TDbQueue declara duas classes internas --, e parar no primeiro `end`
    devolveria um corpo truncado, fazendo o resto dos metodos parecer ausente.

    Nao contam como aninhamento: `class function`/`class var` (nao abrem bloco),
    `class of` (nao tem corpo), classe sem corpo (`E = class(Exception);`), e o
    `case` da parte variante de um record, que fecha junto com o record.
    """
    resto = fonte[inicio:]
    nivel = 0
    for m in RE_BLOCO.finditer(resto):
        if m.group('end'):
            if nivel == 0:
                return resto[:m.start()]
            nivel -= 1
        elif m.group('cls'):
            if not m.group('vazia'):
                nivel += 1
        else:
            nivel += 1
    return resto


def nomes(bloco):
    return set(RE_METODO.findall(bloco)) | set(RE_PROP.findall(bloco))


def main():
    interfaces = {}
    classes = []
    for caminho in unidades():
        fonte = texto(caminho)
        for m in RE_IFACE.finditer(fonte):
            interfaces[m.group(1)] = nomes(corpo(fonte, m.end()))
        for m in RE_CLASSE.finditer(fonte):
            heranca = [x.strip() for x in m.group(2).split(',')]
            ifaces = [x for x in heranca[1:] if x.startswith('I')]
            # `class(IAlgo)` sem ancestral tambem conta.
            if heranca and heranca[0].startswith('I'):
                ifaces = [x for x in heranca if x.startswith('I')]
            if not ifaces:
                continue
            classes.append((caminho, m.group(1), ifaces,
                            nomes(corpo(fonte, m.end())),
                            heranca[0] if heranca else ''))

    faltando = []
    for caminho, classe, ifaces, tem, ancestral in classes:
        for i in ifaces:
            if i not in interfaces:
                continue                  # de fora do projeto: nao da para saber
            for metodo in sorted(interfaces[i] - tem):
                faltando.append((caminho, classe, i, metodo, ancestral))

    rel = os.path.relpath
    if faltando:
        print('metodos de interface sem declaracao na classe (%d):'
              % len(faltando))
        for caminho, classe, i, metodo, ancestral in faltando:
            print('    %-38s %s.%s  de %s%s'
                  % (rel(caminho, RAIZ), classe, metodo, i,
                     '   [herda de ' + ancestral + ']'
                     if ancestral not in ('TObject', 'TInterfacedObject',
                                          'TComponent', '') else ''))
        print('')
        print('"herda de" = pode estar na ancestral; os demais sao erro certo.')
    else:
        print('nenhuma classe deve metodo as suas interfaces')
    print('%d interfaces, %d classes que as implementam'
          % (len(interfaces), len(classes)))


if __name__ == '__main__':
    main()
    sys.exit(0)
