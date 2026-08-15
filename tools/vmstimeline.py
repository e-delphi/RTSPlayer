"""Compara a linha de tempo do PTS com o relógio de parede, por trilha.

O servidor dá o ritmo do ao vivo pelo PTS: se o PTS de uma trilha andar mais
rápido (ou mais devagar) que o relógio, o cliente recebe aos trancos. Foi assim
que apareceu o PTS da isis a 25 fps declarados num stream de 10 fps reais —
2,44x rápido — e o áudio dela a 0,06x, por chegar em rajadas.

Espere ~1,00x em qualquer trilha saudável.

  python vmstimeline.py <arquivo.vms> [outro.vms ...]
"""

import sys

import vmslib


def report(path):
    header, blocks = vmslib.load(path, with_data=False)
    wall = vmslib.wall_seconds(blocks)
    print('\n%s' % path.replace('\\', '/').split('/')[-1])
    print('  blocos=%d  parede=%.1fs  bloco médio=%.2fs' % (
        len(blocks), wall, wall / max(1, len(blocks) - 1)))
    if wall <= 0:
        print('  arquivo curto demais para comparar')
        return

    for track_id, name, track in ((0, 'vídeo', header.video),
                                  (1, 'áudio', header.audio)):
        pts = [s.pts for b in blocks for s in b.samples if s.track_id == track_id]
        if len(pts) < 2 or not track.timescale:
            continue
        span = (pts[-1] - pts[0]) / track.timescale
        ratio = span / wall
        line = ('  %s: %d samples  timeline=%.1fs  %.1f/s reais  %.1f/s pelo PTS'
                '  -> PTS anda %.2fx o relógio' % (
                    name, len(pts), span, len(pts) / wall,
                    (len(pts) / span) if span else 0, ratio))
        print(line)
        if ratio < 0.9 or ratio > 1.1:
            print('    ATENÇÃO: fora de 1,00x. Se for mais rápido, o pacer esvazia o'
                  ' arquivo antes da hora e engasga; se mais devagar, a latência cresce.')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    for path in sys.argv[1:]:
        try:
            report(path)
        except (OSError, vmslib.VmsError) as e:
            print('\n%s\n  erro: %s' % (path, e))
    return 0


if __name__ == '__main__':
    sys.exit(main())
