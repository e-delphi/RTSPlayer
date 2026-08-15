"""Agrega as linhas `parser:` do log de uma câmera DVRIP.

O log do vmsserver traz, a cada 5 s, quantos bytes a sessão entregou ao parser
(`in=`) e quantos frames/bytes saíram por marcador (`fc`=I-frame, `fd`=P-frame,
`fa`=áudio, e qualquer outro que apareça). Com isso dá para responder duas
coisas que só o log não responde:

  a conta fecha?      se `in=` for bem maior que a soma dos frames, há byte
                      sumindo antes dos contadores.
  falta áudio por     cruza a contagem de `fa` com o bitrate do vídeo. Foi assim
  que motivo?         que apareceu que a isis perde áudio justamente quando o
                      vídeo satura o teto de bitrate configurado na câmera.

  python dvripstats.py <logs/isis_2026-08-13.log>
"""

import re
import statistics
import sys

LINE = re.compile(
    r'stats (\d+)s: vid I=(\d+) P=(\d+) \((\d+) kbps\) \| audio=(\d+) frames'
    r' \| parser: in=(\d+)B(.*)')
TYPE = re.compile(r'([0-9A-Fa-f]{2})=(\d+)\((\d+)B\)')

# G711 a 8 kHz, frame de 320 B = 40 ms -> 25 frames/s
AUDIO_FRAMES_PER_WINDOW = 125
FAIXAS = [(0, 600), (600, 800), (800, 950), (950, 1100), (1100, 10 ** 9)]


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
        text = f.read()

    rows = []
    for m in LINE.finditer(text):
        secs, _i, _p, kbps, aud, fed, rest = m.groups()
        if int(secs) != 5:
            continue  # janela alongada (sessão travada): distorce a média
        types = {t.lower(): (int(n), int(b)) for t, n, b in TYPE.findall(rest)}
        rows.append((int(kbps), int(aud), int(fed), types))

    if not rows:
        print('nenhuma linha "parser:" no log — o build é anterior à instrumentação'
              ' do parser DVRIP')
        return 1

    seen = sorted({t for *_, ts in rows for t in ts})
    fed = sum(r[2] for r in rows)
    framed = sum(sum(b for _, b in r[3].values()) for r in rows)
    print('janelas de 5s: %d (%.0f min)' % (len(rows), len(rows) * 5 / 60))
    print('marcadores vistos: %s' % ' '.join(seen))
    print('bytes entregues=%.1f MB  somados nos frames=%.1f MB  (%.1f%%)' % (
        fed / 1e6, framed / 1e6, 100 * framed / fed if fed else 0))
    if fed and framed / fed < 0.95:
        print('  ATENÇÃO: sobra byte não contabilizado. Se não for frame parcial na'
              ' virada da janela, tem mensagem sendo descartada antes do parser.')
    extras = [t for t in seen if t not in ('fa', 'fc', 'fd')]
    if extras:
        print('  ATENÇÃO: marcador não-mídia no fluxo (%s). Confira no log a linha'
              ' "frame 00 00 01 xx descartado" para ver se leva áudio dentro.'
              % ' '.join(extras))

    fa = sum(r[3].get('fa', (0, 0))[0] for r in rows)
    esperado = len(rows) * AUDIO_FRAMES_PER_WINDOW
    print('\náudio: %d frames de %d esperados se contínuo -> %.0f%%' % (
        fa, esperado, 100 * fa / esperado if esperado else 0))

    com = [r[0] for r in rows if r[1] > 0]
    sem = [r[0] for r in rows if r[1] == 0]
    if com and sem:
        print('  janelas COM áudio: %d, bitrate de vídeo mediano %.0f kbps' % (
            len(com), statistics.median(com)))
        print('  janelas SEM áudio: %d, bitrate de vídeo mediano %.0f kbps' % (
            len(sem), statistics.median(sem)))
        print('\n  bitrate do vídeo    janelas   %% com áudio   frames/janela')
        for lo, hi in FAIXAS:
            sel = [r for r in rows if lo <= r[0] < hi]
            if not sel:
                continue
            ca = [r for r in sel if r[1] > 0]
            print('   %5d-%-5s kbps    %5d   %9.0f%%   %10.1f' % (
                lo, hi if hi < 10 ** 9 else '+', len(sel),
                100 * len(ca) / len(sel), sum(r[1] for r in sel) / len(sel)))
        if statistics.median(sem) > statistics.median(com) * 1.1:
            print('\n  O áudio cai quando o vídeo sobe: a câmera está sacrificando o'
                  ' áudio para caber no teto de bitrate dela. Ajuste na câmera'
                  ' (BitRate/Quality), não no código.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
