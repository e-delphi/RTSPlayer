# -*- coding: utf-8 -*-
"""Converte um trecho de .vms em .mp4, remuxando (sem recodificar).

Serve para responder uma pergunta que o WebCodecs nao responde: o decodificador
do aparelho da conta deste fluxo, nesta resolucao?

O caminho do `<video>`/MSE e OUTRO: o decodificador renderiza direto numa
surface, sem exportar quadro para o JavaScript. O do WebCodecs precisa entregar
um VideoFrame, e foi ai que um aparelho devolveu 2560x1440 como 1934x1088 --
com formato RGBA, sinal de que houve conversao no meio, enquanto no PC veio NV12
sem conversao. Um .mp4 aberto no navegador testa o primeiro caminho, isolado.

    python tools/vms2mp4.py --url http://192.168.100.4:8554 --camera frente \\
                            --from-ms 1787957000000 --blocks 8 -o frente.mp4
    python tools/vms2mp4.py arquivo.vms -o saida.mp4

Nao recodifica: o video sai bit a bit como foi gravado. Se o navegador tocar,
foi o decodificador dele que deu conta DESTE fluxo, e nao de uma versao
facilitada dele.
"""

import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmslib

try:
    from urllib.request import urlopen
    from urllib.parse import quote
except ImportError:
    from urllib2 import urlopen
    from urllib import quote

# Onde procurar o ffmpeg quando ele nao esta no PATH. O kdenlive traz um.
CANDIDATOS_FFMPEG = [
    r'C:\Program Files\kdenlive\bin\ffmpeg.exe',
    r'C:\Program Files (x86)\kdenlive\bin\ffmpeg.exe',
]


def acha_ffmpeg(dado):
    if dado:
        return dado
    achado = shutil.which('ffmpeg')
    if achado:
        return achado
    for c in CANDIDATOS_FFMPEG:
        if os.path.exists(c):
            return c
    return None


def elementar(data):
    """O fluxo elementar Annex-B do video, pronto para o ffmpeg.

    O extradata do cabecalho entra na frente porque nem toda camera manda os
    parameter sets no fluxo -- a frente nao manda, e sem VPS/SPS/PPS nenhum
    decodificador sabe o que fazer com as fatias.
    """
    header = vmslib.read_header(data)
    partes = []
    if header.video.extradata:
        partes.append(header.video.extradata)

    n, keys = 0, 0
    for bloco in vmslib.iter_blocks(data, header):
        for s in bloco.samples:
            if not s.is_video or not s.data:
                continue
            # Antes do primeiro keyframe nao ha o que decodificar: comecar num
            # quadro P daria erro de referencia no inicio do arquivo.
            if keys == 0 and not s.keyframe:
                continue
            if s.keyframe:
                keys += 1
            partes.append(s.data)
            n += 1
    return header, b''.join(partes), n, keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('arquivo', nargs='?')
    ap.add_argument('--url')
    ap.add_argument('--camera')
    ap.add_argument('--from-ms', type=int, default=0)
    ap.add_argument('--blocks', type=int, default=8)
    ap.add_argument('--fps', type=int, default=15,
                    help='o .vms guarda instante de parede, nao cadencia; o mp4 '
                         'precisa de uma, e ela so afeta a velocidade do teste')
    ap.add_argument('--ffmpeg')
    ap.add_argument('--frag', action='store_true',
                    help='MP4 fragmentado (moof/mdat). Toca igual no <video> e '
                         'e o unico formato que o MSE aceita')
    ap.add_argument('-o', '--saida', required=True)
    a = ap.parse_args()

    ff = acha_ffmpeg(a.ffmpeg)
    if not ff:
        print('ffmpeg nao encontrado; passe --ffmpeg <caminho>')
        return 1

    if a.arquivo:
        data = io.open(a.arquivo, 'rb').read()
    elif a.url and a.camera:
        url = ('%s/api/media?camera=%s&blocks=%d'
               % (a.url.rstrip('/'), quote(a.camera), a.blocks))
        if a.from_ms:
            url += '&fromMs=%d' % a.from_ms
        print('buscando %s' % url)
        data = urlopen(url, timeout=60).read()
    else:
        print('informe um arquivo .vms ou --url com --camera')
        return 2

    header, es, n, keys = elementar(data)
    codec = (header.video.codec_name or '').upper()
    if not es or n == 0:
        print('nenhum quadro de video no trecho')
        return 1
    print('%s: %d quadros (%d keyframes), %d KB de fluxo elementar'
          % (codec, n, keys, len(es) // 1024))

    ext = '.h265' if codec == 'H265' else '.h264'
    tmp = tempfile.mktemp(suffix=ext)
    io.open(tmp, 'wb').write(es)
    try:
        # -c copy: remux puro. A tag hvc1/avc1 e o que faz o Safari e alguns
        # Android reconhecerem a trilha; sem ela alguns tocam so o audio.
        tag = 'hvc1' if codec == 'H265' else 'avc1'
        movflags = ('+frag_keyframe+empty_moov+default_base_moof'
                    if a.frag else '+faststart')
        cmd = [ff, '-y', '-hide_banner', '-loglevel', 'warning',
               '-r', str(a.fps), '-i', tmp,
               '-c:v', 'copy', '-tag:v', tag,
               '-movflags', movflags, a.saida]
        print(' '.join(cmd[:1] + ['...'] + cmd[-6:]))
        r = subprocess.call(cmd)
        if r != 0:
            print('ffmpeg falhou (%d)' % r)
            return r
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass

    print('gerado %s (%d KB)' % (a.saida, os.path.getsize(a.saida) // 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
