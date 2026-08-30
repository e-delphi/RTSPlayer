"""Copia a interface para uma pasta `ui` ao lado de um executavel.

Existindo essa pasta, os dois servidores servem o que estiver nela no lugar do
que esta embutido (ver vms/src/Api/Vms.Server.UiFiles.pas). Serve para mexer em
html, css e js sem gerar unit nem recompilar: salvar e recarregar a pagina.

    python tools/ui_dev.py <pasta do executavel>
    python tools/ui_dev.py Win64/Debug          # o rtsplayer
    python tools/ui_dev.py vms/Win64/Debug      # o vmsserver

Sem argumento, so lista os arquivos que a pasta aceita.

Para voltar ao embutido, apague a pasta `ui`. Nao ha ajuste a lembrar: a
existencia dela e o interruptor inteiro.
"""

import io
import os
import re
import shutil
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.join(AQUI, '..')
FONTE = os.path.join(RAIZ, 'vms', 'src', 'Api')

# Os nomes saem DO PASCAL, e nao de uma lista aqui.
#
# Duas listas do mesmo conjunto divergem: alguem acrescenta uma pagina de um
# lado e esquece do outro, e o arquivo copiado nunca e lido -- sem erro nenhum,
# so nao funciona. Lendo as rotas, nao ha o que esquecer.
ROTEADORES = [
    os.path.join(RAIZ, 'vms', 'src', 'Api', 'Vms.Server.Api.pas'),
    os.path.join(RAIZ, 'src', 'Api', 'VMS.Local.Server.pas'),
]

PADROES = [
    re.compile(r"UiTexto\('([^']+)'"),
    re.compile(r"ServirPagina\(AResponseInfo, '([^']+)'"),
    re.compile(r"ServirJs\(AResponseInfo, '([^']+)'"),
]


def arquivos_servidos():
    nomes = set()
    for caminho in ROTEADORES:
        if not os.path.exists(caminho):
            continue
        texto = io.open(caminho, encoding='utf-8').read()
        for p in PADROES:
            nomes.update(p.findall(texto))
    return sorted(nomes)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print('arquivos servidos de disco quando presentes:')
        for a in arquivos_servidos():
            print('   ', a)
        return 0

    destino = os.path.join(os.path.abspath(sys.argv[1]), 'ui')
    if not os.path.isdir(os.path.dirname(destino)):
        print('ERRO: nao existe a pasta', os.path.dirname(destino))
        return 1
    os.makedirs(destino, exist_ok=True)

    for a in arquivos_servidos():
        origem = os.path.join(FONTE, a)
        if not os.path.exists(origem):
            print('  (sem)', a)
            continue
        shutil.copy2(origem, os.path.join(destino, a))
        print('  ok   ', a)

    print()
    print('pronto:', destino)
    print('edite os arquivos ai e recarregue a pagina; para voltar ao')
    print('embutido, apague a pasta.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
