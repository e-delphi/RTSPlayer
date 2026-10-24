# -*- coding: utf-8 -*-
"""Descreve arquivos .vms em JSON, para servir de referencia ao leitor JS.

O vmslib.py e a fonte da verdade sobre o formato -- ele ja e exercitado pelo
selftest e leu certo tudo que apareceu ate hoje. Este utilitario congela o que
ele ve, e o tools/testvmsreader.js confere se o porte para JavaScript concorda.

    python tools/dumpvms.py a.vms b.vms > esperado.json
    node tools/testvmsreader.js esperado.json
"""

import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmslib


def cadeia(codec, sps):
    """A mesma cadeia que o cadeiaCodec() do vmsreader.js deve produzir."""
    if codec == 'H264':
        if not sps:
            return 'avc3.4D401F'
        return 'avc3.%02X%02X%02X' % (sps['profile'], sps['constraint'],
                                      sps['level'])
    if codec == 'H265':
        if not sps:
            return 'hev1.1.6.L150'
        return vmslib.h265_codec_string(sps)
    return ''


def achar_sps(au, extradata, codec):
    alvo = 33 if codec == 'H265' else 7
    for fonte in (au, extradata):
        if not fonte:
            continue
        for n in vmslib.split_annexb(fonte):
            if vmslib.nal_type(n, codec) != alvo:
                continue
            try:
                return (vmslib.parse_h265_sps(n) if codec == 'H265'
                        else vmslib.parse_h264_sps(n))
            except Exception:
                pass
    return None


def wall_ms(blocos, header):
    """Relogio de parede de cada sample, pela regra do VMS.Play.Engine.pas.

    wallMs = ancora[trilha] + (pts - primeiroPts[trilha]) * 1000 / timescale

    A origem reinicia A CADA BLOCO e a ancora e por trilha. O pts nao e unix ms:
    e a escala da trilha (video costuma ser 90 kHz, audio a taxa de amostragem).
    """
    escalas = [header.video.timescale or 1000,
               header.audio.timescale or header.audio.sample_rate or 1000]
    fora = []
    for b in blocos:
        ancoras = [b.video_anchor_ms or b.start_unix_ms,
                   b.audio_anchor_ms or b.start_unix_ms]
        primeiro, tem = [0, 0], [False, False]
        for s in b.samples:
            t = s.track_id
            if t > 1:
                continue
            if not tem[t]:
                primeiro[t], tem[t] = s.pts, True
            fora.append((t, ancoras[t] + round(
                (s.pts - primeiro[t]) * 1000 / escalas[t])))
    return fora


def descreve(caminho):
    data = io.open(caminho, 'rb').read()
    h = vmslib.read_header(data)
    codec = (h.video.codec_name or '').upper()

    blocos = list(vmslib.iter_blocks(data, h))
    v = [s for b in blocos for s in b.samples if s.is_video]
    a = [s for b in blocos for s in b.samples if not s.is_video]

    d = {
        'arquivo': os.path.basename(caminho),
        'caminho': os.path.abspath(caminho),
        'version': h.version,
        'headerSize': h.size,
        'creationMs': h.creation_unix_ms,
        'uri': h.uri,
        'video': {'codecName': codec,
                  'timescale': h.video.timescale,
                  'extradataLen': len(h.video.extradata)},
        'audio': {'present': h.audio.present,
                  'codecName': h.audio.codec_name,
                  'sampleRate': h.audio.sample_rate,
                  'channels': h.audio.channels},
        'blocos': len(blocos),
        'videoSamples': len(v),
        'audioSamples': len(a),
        'keyframes': sum(1 for s in v if s.keyframe),
        'videoBytes': sum(len(s.data) for s in v),
        'audioBytes': sum(len(s.data) for s in a),
        'primeiroPts': v[0].pts if v else None,
        'ultimoPts': v[-1].pts if v else None,
        'primeiraAncoraVideo': blocos[0].video_anchor_ms if blocos else None,
    }

    # O relogio de parede e o que o player usa para acertar o ritmo. Foi aqui
    # que o porte errou primeiro -- tratando pts como unix ms --, entao ele e
    # conferido amostra a amostra, e nao so no resumo.
    paredes = wall_ms(blocos, h)
    pv = [w for (t, w) in paredes if t == 0]
    pa = [w for (t, w) in paredes if t == 1]
    d['wallVideoPrimeiro'] = pv[0] if pv else None
    d['wallVideoUltimo'] = pv[-1] if pv else None
    d['wallVideoSoma'] = sum(pv) if pv else 0
    d['wallAudioPrimeiro'] = pa[0] if pa else None
    d['wallAudioUltimo'] = pa[-1] if pa else None
    d['wallAudioSoma'] = sum(pa) if pa else 0

    kf = next((s for s in v if s.keyframe), None)
    if kf:
        sps = achar_sps(kf.data, h.video.extradata, codec)
        nals = vmslib.split_annexb(kf.data)
        d['spsAchado'] = sps is not None
        d['sps'] = ({'width': sps['width'], 'height': sps['height'],
                     'level': sps['level']} if sps else None)
        d['cadeia'] = cadeia(codec, sps)
        d['psNoAu'] = any(vmslib.is_parameter_set(n, codec) for n in nals)
        d['nalsDoKeyframe'] = len(nals)
        d['bytesDasNals'] = sum(len(n) for n in nals)
    return d


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    saida = []
    for c in sys.argv[1:]:
        try:
            saida.append(descreve(c))
        except Exception as e:
            sys.stderr.write('%s: %s\n' % (c, e))
    sys.stdout.write(json.dumps(saida, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
