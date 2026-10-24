"""Nível do áudio gravado: separa "não vem nada" de "vem silêncio".

As duas coisas parecem iguais no player e têm causas opostas. Se os frames não
chegam, o problema é de transporte (câmera não manda, ou nós descartamos). Se
chegam cheios de silêncio digital, o transporte está bom e o problema é
microfone, ganho ou o ambiente.

Referência do que é o quê em G711 A-law: byte 0xD5 é o zero exato (decodifica
para RMS 8). Microfone vivo, mesmo num ambiente quieto, tem ruído de fundo e
aparece com RMS na casa das centenas.

  python vmsaudio.py <arquivo.vms> [outro.vms ...] [--janela 10]
"""

import argparse
import statistics
import sys

import vmslib

ALAW_ZERO = 0xD5
MUTE_RMS = 100  # abaixo disso não é ruído de fundo, é silêncio


def _build_alaw_table():
    """G.711 A-law -> PCM 16 bits. Tabela própria porque o módulo audioop da
    biblioteca padrão saiu no Python 3.13."""
    table = []
    for a in range(256):
        v = a ^ 0x55
        t = (v & 0x0F) << 4
        seg = (v & 0x70) >> 4
        if seg == 0:
            t += 8
        elif seg == 1:
            t += 0x108
        else:
            t = (t + 0x108) << (seg - 1)
        table.append(t if (v & 0x80) else -t)
    return table


ALAW = _build_alaw_table()


def _build_ulaw_table():
    """G.711 mu-law -> PCM 16 bits."""
    table = []
    for u in range(256):
        v = ~u & 0xFF
        t = ((v & 0x0F) << 3) + 0x84
        t <<= (v & 0x70) >> 4
        t -= 0x84
        table.append(-t if (v & 0x80) else t)
    return table


ULAW = _build_ulaw_table()


def rms(data, table):
    if not data:
        return 0
    acc = 0
    for b in data:
        s = table[b]
        acc += s * s
    return int((acc / len(data)) ** 0.5)


def report(path, janela):
    header, blocks = vmslib.load(path)
    a = header.audio
    if not a.present:
        print('\n%s: arquivo sem trilha de áudio' % path)
        return
    if a.codec_name == 'G711A':
        table, zero = ALAW, ALAW_ZERO
    elif a.codec_name == 'G711U':
        table, zero = ULAW, 0xFF
    else:
        print('\n%s: %s não é G711; este utilitário só mede G711' % (path, a.codec_name))
        return

    frames = [s for b in blocks for s in b.samples if not s.is_video]
    if not frames:
        print('\n%s: nenhum frame de áudio gravado -> problema é de transporte,'
              ' não de microfone' % path.replace('\\', '/').split('/')[-1])
        return

    levels = [rms(s.data, table) for s in frames]
    total = sum(len(s.data) for s in frames)
    zeros = sum(s.data.count(bytes([zero])) for s in frames)
    ordered = sorted(levels)
    mute = sum(1 for r in levels if r < MUTE_RMS)
    wall = vmslib.wall_seconds(blocks)
    esperado = int(wall * a.sample_rate / 320) if a.sample_rate else 0

    print('\n%s  (%s %dHz)' % (path.replace('\\', '/').split('/')[-1],
                               a.codec_name, a.sample_rate))
    print('  frames=%d em %.0fs de parede%s' % (
        len(frames), wall,
        '  (%.0f%% do contínuo)' % (100.0 * len(frames) / esperado) if esperado else ''))
    print('  byte de silêncio exato (0x%02X): %.1f%% dos bytes' % (
        zero, 100.0 * zeros / total))
    print('  RMS por frame: mín=%d  p50=%d  p90=%d  máx=%d' % (
        ordered[0], ordered[len(ordered) // 2],
        ordered[int(len(ordered) * 0.9)], ordered[-1]))
    print('  frames em silêncio (RMS<%d): %.0f%%' % (
        MUTE_RMS, 100.0 * mute / len(levels)))

    if mute == len(levels):
        print('  -> só silêncio. O transporte está entregando; procure microfone,'
              ' ganho ou mudo na câmera.')
    elif mute > len(levels) * 0.9:
        print('  -> quase tudo silêncio, com algum som esparso.')
    else:
        print('  -> tem sinal de áudio de verdade.')

    if janela:
        print('  nível por janela de %ds (RMS máximo / frames):' % janela)
        t0 = blocks[0].start_unix_ms
        buckets = {}
        for b in blocks:
            k = int((b.start_unix_ms - t0) / 1000 / janela)
            for s in b.samples:
                if s.is_video:
                    continue
                cur = buckets.setdefault(k, [0, 0])
                cur[0] = max(cur[0], rms(s.data, table))
                cur[1] += 1
        for k in sorted(buckets):
            top, n = buckets[k]
            bar = '#' * min(40, top // 25) if top >= MUTE_RMS else ''
            print('    %4ds  RMS=%5d  frames=%3d %s' % (k * janela, top, n, bar))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('arquivos', nargs='+')
    ap.add_argument('--janela', type=int, default=0,
                    help='detalha o nível em janelas de N segundos')
    args = ap.parse_args()
    for path in args.arquivos:
        try:
            report(path, args.janela)
        except (OSError, vmslib.VmsError) as e:
            print('\n%s\n  erro: %s' % (path, e))
    return 0


if __name__ == '__main__':
    sys.exit(main())
