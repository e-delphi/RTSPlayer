"""Modelo da ancoragem de blocos do gravador (VMS.Rec.Block.AncoraDe).

Mesma regra, em Python, para poder exercitar o que o Delphi faz sem compilar.

O leitor calcula o instante de parede de cada sample assim:

    wallMs = ancora do bloco + (pts - primeiro pts do bloco) * 1000 / timescale

ou seja, DENTRO do bloco quem manda e o pts, e na virada quem manda e a ancora.
Enquanto a ancora foi o relogio de CHEGADA, os dois nao andavam no mesmo passo:
camera que segura quadros e depois os despeja faz o pts avancar mais que a
parede, o bloco se estende alem de onde o seguinte foi ancorado, e os dois
passam a cobrir o mesmo intervalo -- que na reproducao e a imagem voltando.

  python anchormodel.py
"""

MAX_DESVIO_ANCORA_MS = 10000


class Ancora(object):
    __slots__ = ('valida', 'wall_ms', 'pts', 'timescale', 'fim_ms')

    def __init__(self, timescale):
        self.valida = False
        self.wall_ms = 0
        self.pts = 0
        self.timescale = timescale
        self.fim_ms = 0


def _div(a, b):
    """div do Delphi: trunca em direcao a zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def ancora_por_chegada(_a, _pts, chegou_ms):
    """A regra antiga: cada bloco salta para o relogio de quem grava."""
    return chegou_ms


def ancora_derivada(a, pts, chegou_ms):
    """A regra nova: derivada de uma referencia unica da gravacao."""
    if a.timescale == 0 or not a.valida:
        a.valida = True
        a.wall_ms = chegou_ms
        a.pts = pts
        return chegou_ms

    derivada = a.wall_ms + _div((pts - a.pts) * 1000, a.timescale)
    if abs(derivada - chegou_ms) <= MAX_DESVIO_ANCORA_MS:
        return derivada

    # O pts deixou de falar do mesmo relogio. Refaz pela parede, nunca para tras
    # do fim do bloco anterior.
    novo = max(chegou_ms, a.fim_ms)
    a.wall_ms = novo
    a.pts = pts
    return novo


def montar(amostras, timescale, por_bloco, regra):
    """Fecha blocos de `por_bloco` samples e devolve (ancora, pts) de cada um.

    `amostras` e uma lista de (pts, chegou_ms), na ordem em que o gravador as
    recebeu.
    """
    a = Ancora(timescale)
    blocos = []
    for i in range(0, len(amostras), por_bloco):
        lote = amostras[i:i + por_bloco]
        pts0, chegou0 = lote[0]
        anc = regra(a, pts0, chegou0)
        pts_max = max(p for p, _ in lote)
        blocos.append({'ancora': anc, 'pts0': pts0, 'ptsmax': pts_max,
                       'chegou': chegou0, 'n': len(lote)})
        # Fim do bloco pela MESMA conta do leitor.
        a.fim_ms = anc + (_div((pts_max - pts0) * 1000, timescale)
                          if timescale else 0)
    return blocos


def parede(bloco, pts, timescale):
    """A conta do leitor, para um sample qualquer do bloco."""
    return bloco['ancora'] + _div((pts - bloco['pts0']) * 1000, timescale)


def analisar(blocos, timescale):
    """Sobreposicoes e buracos entre blocos consecutivos, em ms."""
    sobrepostos, buracos = [], []
    for i in range(1, len(blocos)):
        fim = parede(blocos[i - 1], blocos[i - 1]['ptsmax'], timescale)
        inicio = blocos[i]['ancora']
        if inicio < fim:
            sobrepostos.append(fim - inicio)
        elif inicio - fim > 1000:
            buracos.append(inicio - fim)
    return {'sobrepostos': sobrepostos, 'buracos': buracos,
            'maiorSobreposicao': max(sobrepostos) if sobrepostos else 0,
            'maiorBuraco': max(buracos) if buracos else 0}


# --------------------------------------------------------------- as cenas

def cena_rajada(ts=90000, fps=10, n=400, travada_s=4):
    """A cada 10 s a rede trava alguns segundos; depois os quadros vem juntos.

    E o caso medido em disco. Os quadros segurados foram capturados no ritmo
    normal -- o pts deles esta espacado dos mesmos 100 ms --, so que chegam
    quase colados. Passada a rajada, a entrega volta ao horario: buffer de
    camera nao cresce para sempre.

    A rajada cobre mais de um bloco de proposito: e entre dois blocos DE DENTRO
    dela que a ancora por chegada erra -- o primeiro se estende pelo pts e o
    segundo e ancorado poucos milissegundos adiante.
    """
    passo_pts = ts // fps
    passo_ms = 1000 // fps
    rajada = travada_s * fps           # quantos quadros ficaram represados
    amostras = []
    base = 1700000000000
    for i in range(n):
        ciclo = i % 100
        pontual = base + i * passo_ms
        if i >= 100 and ciclo < rajada:
            # Ficaram represados durante a travada e saem colados, 5 ms entre
            # eles, a partir do instante em que a rede voltou.
            volta = base + (i - ciclo) * passo_ms + travada_s * 1000
            chegou = volta + ciclo * 5
        else:
            chegou = pontual
        amostras.append((i * passo_pts, chegou))
    return amostras


def cena_jitter(ts=90000, fps=10, n=400, tremor=180):
    """Chegada tremendo alguns decimos de segundo em torno do certo."""
    passo_pts = ts // fps
    amostras = []
    base = 1700000000000
    semente = 12345
    for i in range(n):
        semente = (semente * 1103515245 + 12345) & 0x7fffffff
        d = (semente % (2 * tremor)) - tremor
        amostras.append((i * passo_pts, base + i * (1000 // fps) + d))
    return amostras


def cena_reinicio(ts=90000, fps=10, n=400, em=200):
    """No meio, a camera reconecta e o pts recomeca do zero -- 40 s depois."""
    passo_pts = ts // fps
    amostras = []
    base = 1700000000000
    for i in range(n):
        if i < em:
            pts, chegou = i * passo_pts, base + i * (1000 // fps)
        else:
            pts = (i - em) * passo_pts
            chegou = base + em * (1000 // fps) + 40000 + (i - em) * (1000 // fps)
        amostras.append((pts, chegou))
    return amostras


def relatorio(nome, amostras, ts=90000, por_bloco=20):
    velho = analisar(montar(amostras, ts, por_bloco, ancora_por_chegada), ts)
    novo = analisar(montar(amostras, ts, por_bloco, ancora_derivada), ts)
    print('%-26s antes: %2d sobrepostos (max %5d ms)   depois: %2d (max %d ms)'
          % (nome, len(velho['sobrepostos']), velho['maiorSobreposicao'],
             len(novo['sobrepostos']), novo['maiorSobreposicao']))
    return velho, novo


if __name__ == '__main__':
    relatorio('rajada da camera', cena_rajada())
    relatorio('tremor de chegada', cena_jitter())
    relatorio('reconexao com pts zerado', cena_reinicio())
