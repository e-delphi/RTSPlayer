"""Panorama de um .vms: header, trilhas, blocos, tipos de NAL e PTS.

Compara os parameter sets do header (que vieram do SDP da câmera e viram
sprop-parameter-sets no SDP do vmsserver) com os que o stream traz in-band, e
avisa quando divergem — foi essa divergência que deixou a ayla cinza.

  python vmsdump.py <arquivo.vms> [--samples N]
"""

import argparse
import collections
import sys

import vmslib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('arquivo')
    ap.add_argument('--samples', type=int, default=0,
                    help='lista os N primeiros samples de vídeo')
    args = ap.parse_args()

    header, blocks = vmslib.load(args.arquivo)
    v, a = header.video, header.audio

    print('%s' % args.arquivo)
    print('  uri=%s  header=%dB  crc=%s' % (
        header.uri, header.size, 'ok' if header.crc_ok else 'INVÁLIDO'))
    if v.present:
        print('  vídeo: %s %dx%d timescale=%d extradata=%dB' % (
            v.codec_name, v.width, v.height, v.timescale, len(v.extradata)))
    if a.present:
        print('  áudio: %s %dHz %dch %dbit timescale=%d' % (
            a.codec_name, a.sample_rate, a.channels, a.bits, a.timescale))

    bad_crc = [b.seq for b in blocks if not b.crc_ok]
    wall = vmslib.wall_seconds(blocks)
    print('  blocos=%d  parede=%.1fs  bloco médio=%.2fs  crc inválido=%s' % (
        len(blocks), wall, wall / max(1, len(blocks) - 1),
        bad_crc if bad_crc else 'nenhum'))

    vid = [s for b in blocks for s in b.samples if s.is_video]
    aud = [s for b in blocks for s in b.samples if not s.is_video]
    nal_hist = collections.Counter()
    deltas = collections.Counter()
    prev = None
    inband_ps = None
    for s in vid:
        nals = vmslib.split_annexb(s.data)
        for n in nals:
            nal_hist[vmslib.nal_name(n, v.codec_name).split('(')[0]] += 1
        if inband_ps is None:
            ps = [n for n in nals if vmslib.is_parameter_set(n, v.codec_name)]
            if ps:
                inband_ps = ps
        if prev is not None:
            deltas[s.pts - prev] += 1
        prev = s.pts

    keys = sum(1 for s in vid if s.keyframe)
    print('  samples: vídeo=%d (keyframes=%d)  áudio=%d' % (len(vid), keys, len(aud)))
    print('  NALs de vídeo: %s' % dict(nal_hist))
    print('  deltas de PTS: %s' % deltas.most_common(5))
    if not keys and vid:
        print('  ATENÇÃO: nenhum sample marcado como keyframe — o cliente não tem'
              ' por onde começar a decodificar')

    if v.codec_name == 'H264':
        head = vmslib.describe_h264_ps(vmslib.split_annexb(v.extradata))
        band = vmslib.describe_h264_ps(inband_ps or [])
        print('  parameter sets do header/SDP: %s' % (head or '(nenhum)'))
        print('  parameter sets in-band:       %s' % (band or '(nenhum)'))
        if head and band and head != band:
            print('  ATENÇÃO: divergem. O SDP da câmera anuncia um SPS/PPS que não é o'
                  ' do stream; reinjetá-lo na frente de um slice corrompe a decodificação.')

    if args.samples:
        print('  primeiros %d samples de vídeo:' % args.samples)
        for s in vid[:args.samples]:
            nals = vmslib.split_annexb(s.data)
            print('    pts=%d key=%d %dB  %s' % (
                s.pts, int(s.keyframe), len(s.data),
                ' '.join(vmslib.nal_name(n, v.codec_name) for n in nals)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
