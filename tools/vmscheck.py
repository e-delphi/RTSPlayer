"""Procura corrupção e erro de enquadramento numa gravação.

O que ele checa e por quê:

  crc            bloco e header têm CRC-32 gravado (e que o leitor do Delphi
                 ainda não confere) — aqui confere.
  marcador DVRIP dentro do payload de vídeo não pode existir 00 00 01 F8..FE:
                 se existir, o parser DVRIP engoliu frames de áudio/info dentro
                 do quadro de vídeo, e é aí que o áudio está sumindo.
  NAL inválido   start code seguido de byte com forbidden_zero_bit=1 não é H.264
                 legal: sinal de que entrou byte que não é do vídeo.
  keyframes      distância entre keyframes; sem eles o cliente não abre imagem.
  áudio/bloco    distribuição do áudio, para ver se vem contínuo ou em rajada.

  python vmscheck.py <arquivo.vms>
"""

import collections
import sys

import vmslib

DVRIP_MARKERS = range(0xF8, 0xFF)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    header, blocks = vmslib.load(path)
    codec = header.video.codec_name

    print('%s  (%s)' % (path, codec))
    problems = 0

    if not header.crc_ok:
        print('  CRC do header INVÁLIDO')
        problems += 1
    bad = [b.seq for b in blocks if not b.crc_ok]
    if bad:
        print('  CRC inválido em %d bloco(s): %s' % (len(bad), bad[:20]))
        problems += 1

    markers = collections.Counter()
    forbidden = collections.Counter()
    vbytes = 0
    vid = 0
    key_gaps = []
    last_key = None
    audio_per_block = []

    for b in blocks:
        na = 0
        for s in b.samples:
            if not s.is_video:
                na += 1
                continue
            vid += 1
            vbytes += len(s.data)
            if s.keyframe:
                if last_key is not None:
                    key_gaps.append(vid - last_key)
                last_key = vid
            d = s.data
            i = 0
            while i + 3 < len(d):
                if d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 1:
                    nb = d[i + 3]
                    if nb & 0x80:  # forbidden_zero_bit
                        forbidden['0x%02x' % nb] += 1
                        if nb in DVRIP_MARKERS:
                            markers['0x%02x' % nb] += 1
                    i += 3
                else:
                    i += 1
        audio_per_block.append(na)

    print('  vídeo: %d samples, %.1f MB' % (vid, vbytes / 1e6))
    if forbidden:
        print('  start codes com forbidden_zero_bit=1: %s' % dict(forbidden))
        problems += 1
    else:
        print('  start codes: todos com header de NAL válido')
    if markers:
        print('  MARCADOR DVRIP dentro do vídeo: %s — o length de algum frame está'
              ' errado e engoliu o frame seguinte' % dict(markers))
        problems += 1
    else:
        print('  nenhum marcador DVRIP dentro do payload de vídeo')

    keys = sum(1 for b in blocks for s in b.samples if s.is_video and s.keyframe)
    if not keys:
        print('  NENHUM keyframe marcado')
        problems += 1
    else:
        print('  keyframes=%d  intervalo em quadros: min=%d médio=%.1f max=%d' % (
            keys, min(key_gaps or [0]),
            sum(key_gaps) / len(key_gaps) if key_gaps else 0,
            max(key_gaps or [0])))

    if header.audio.present:
        total = sum(audio_per_block)
        vazios = sum(1 for n in audio_per_block if n == 0)
        print('  áudio: %d samples, %d de %d blocos sem nenhum' % (
            total, vazios, len(audio_per_block)))
        print('  áudio por bloco: %s' % audio_per_block)
        if vazios > len(audio_per_block) // 10:
            print('    ATENÇÃO: áudio vem em rajada. A linha de tempo dele não'
                  ' representa os silêncios, então não dá para sincronizar com o vídeo.')

    print('  -> %s' % ('nada suspeito' if not problems
                       else '%d problema(s) acima' % problems))
    return 0


if __name__ == '__main__':
    sys.exit(main())
