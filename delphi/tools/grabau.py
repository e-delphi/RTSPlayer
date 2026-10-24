# -*- coding: utf-8 -*-
"""Extrai um keyframe REAL de um .vms, para o teste de decodificacao no navegador.

A sondagem de capacidade (src/UI/webcaps.html) responde pela lista de codecs do
aparelho: ela diz que o perfil e o nivel existem. Nao e a mesma pergunta que
"este quadro, nesta resolucao, decodifica aqui" -- e a diferenca importa porque
no Android nao ha decodificador por software atras do MediaCodec (medido: sw=nao
em todos os codecs), entao um decodificador de hardware que engasgue em 1080p
nao tem para onde cair. Foi exatamente esse o defeito que obrigou o app nativo a
ter fallback por software.

Este utilitario tira o quadro de verdade da gravacao e o entrega em base64, para
ser embutido na pagina de teste.

    python tools/grabau.py --json quadros.json  vms/bin/recordings/ayla/*.vms
    python tools/grabau.py --url http://192.168.100.4:8554 --camera frente

Sem --json, so descreve o que achou.

Repare que a resolucao NAO vem do cabecalho do .vms: o gravador deixa 0x0 la.
Ela sai do SPS, que e o unico lugar onde ela e verdade.
"""

import argparse
import base64
import glob
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmslib

try:
    from urllib.request import urlopen
    from urllib.parse import quote
except ImportError:                                    # python 2
    from urllib2 import urlopen
    from urllib import quote

# Quantos caracteres de base64 por linha. Existe por causa do gerador de units:
# cada linha do .html vira UM literal de string Pascal, e um literal de 150 KB
# numa linha so seria pedir problema ao compilador e ao editor.
COLUNAS_B64 = 120


def candidatos_h264(sps):
    """Cadeias de codec a tentar, da mais provavel para a menos.

    A pagina tenta uma a uma e diz qual funcionou. E mais honesto do que deduzir
    so do SPS: quem decide se a cadeia serve e o navegador, nao a nossa leitura
    do cabecalho -- mas a do SPS entra primeiro, por ser a que descreve ESTE
    fluxo.

    So formas avc3/hev1: sao as que significam Annex-B com os parameter sets no
    proprio fluxo, que e como o .vms guarda. As formas avc1/hvc1 exigiriam
    montar o avcC/hvcC, e a sondagem mostrou que nao precisamos.
    """
    padrao = ['avc3.4D401F', 'avc3.64001F', 'avc3.42E01E', 'avc3.640028']
    if not sps:
        return padrao
    exato = 'avc3.%02X%02X%02X' % (sps['profile'], sps['constraint'],
                                   sps['level'])
    return [exato] + [c for c in padrao if c != exato]


# Candidatas de H.265 quando o SPS nao pode ser lido. So entram DEPOIS da cadeia
# exata, e essa ordem foi comprada caro:
#
# a primeira versao mandava `hev1.1.6.L120.B0` (nivel 4.0) para um fluxo de
# 2560x1440, que e nivel 5.0. O nivel 4.0 comporta 2.228.224 amostras e o quadro
# tem 3.686.400. O Chrome do PC ignorou a declaracao e seguiu o SPS; o
# decodificador de HARDWARE do Android acreditou na declaracao, alocou superficie
# do tamanho menor e devolveu 2304x1088 -- sem erro nenhum, so o quadro errado.
#
# A licao: declarar nivel a menos nao da erro, da imagem errada. Por isso a
# cadeia agora sai do SPS, e por isso a pagina de teste confere o tamanho do
# quadro decodificado contra o que o SPS prometeu.
CANDIDATOS_H265 = ['hev1.1.6.L150', 'hev1.1.6.L153', 'hev1.1.6.L120',
                   'hev1.1.6.L93']


def primeiro_keyframe(data):
    """(header, dados do AU, pts) do primeiro keyframe de video."""
    header = vmslib.read_header(data)
    for bloco in vmslib.iter_blocks(data, header):
        for s in bloco.samples:
            if s.is_video and s.keyframe and s.data:
                return header, s.data, s.pts
    return header, None, 0


def quebra(s, n=COLUNAS_B64):
    return [s[i:i + n] for i in range(0, len(s), n)]


def descreve(data, rotulo, camera):
    header, au, pts = primeiro_keyframe(data)
    v = header.video
    if au is None:
        return None

    codec = (v.codec_name or '').upper()
    nals = vmslib.split_annexb(au)
    tipos = [vmslib.nal_name(n, codec) for n in nals]
    tem_ps = any(vmslib.is_parameter_set(n, codec) for n in nals)

    # A resolucao NAO vem do cabecalho do .vms (ele guarda 0x0): sai do SPS, que
    # e o unico lugar onde ela e verdade. Sem ela nao daria para saber se o
    # quadro decodificado saiu do tamanho certo -- e foi exatamente assim que um
    # decodificador de hardware devolveu quadro menor sem acusar erro.
    #
    # O SPS pode estar no proprio AU (ayla) ou so no extradata do cabecalho
    # (frente). Procurar nos dois e o que faz isto valer para as duas.
    largura, altura, sps, codecs = 0, 0, None, None
    for n in nals + vmslib.split_annexb(v.extradata):
        t = vmslib.nal_type(n, codec)
        try:
            if codec == 'H264' and t == 7:
                sps = vmslib.parse_h264_sps(n)
                largura, altura = sps['width'], sps['height']
                codecs = candidatos_h264(sps)
                break
            if codec == 'H265' and t == 33:
                sps = vmslib.parse_h265_sps(n)
                largura, altura = sps['width'], sps['height']
                exata = vmslib.h265_codec_string(sps)
                codecs = [exata] + [c for c in CANDIDATOS_H265 if c != exata]
                break
        except Exception:
            pass
    if codecs is None:
        codecs = candidatos_h264(None) if codec == 'H264' else CANDIDATOS_H265
    if largura <= 0:
        largura, altura = v.width, v.height

    return {
        'rotulo': rotulo,
        'camera': camera,
        'codecName': codec,
        'width': largura,
        'height': altura,
        'ptsMs': pts,
        'bytes': len(au),
        'nals': tipos,
        # Nem toda camera manda os parameter sets no fluxo. A ayla manda (e por
        # isso NAO se deve reinjetar o do SDP nela, que vem errado); a frente
        # nao manda -- o AU dela e so a fatia IRAP, e VPS/SPS/PPS vivem no
        # extradata do cabecalho do .vms.
        #
        # Como o extradata tambem e Annex-B (start code 00 00 00 01), resolver
        # isso e concatenar: extradata + AU. Nao e preciso montar hvcC nem usar
        # `description`, e a forma hev1/avc3 continua valendo.
        'temParameterSet': tem_ps,
        'extradataBytes': len(v.extradata),
        'extradata': quebra(base64.b64encode(v.extradata).decode('ascii')),
        'codecs': codecs,
        'au': quebra(base64.b64encode(au).decode('ascii')),
    }


def da_rede(base, camera, from_ms):
    url = ('%s/api/media?camera=%s&blocks=1' % (base.rstrip('/'), quote(camera)))
    if from_ms:
        url += '&fromMs=%d' % from_ms
    print('buscando %s' % url)
    return urlopen(url, timeout=30).read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('arquivos', nargs='*', help='.vms locais (aceita curinga)')
    ap.add_argument('--url', help='base do vmsserver, ex. http://192.168.100.4:8554')
    ap.add_argument('--camera', action='append', default=[],
                    help='camera a buscar por --url (pode repetir)')
    ap.add_argument('--from-ms', type=int, default=0)
    ap.add_argument('--json', help='onde gravar o resultado')
    a = ap.parse_args()

    saida = []

    for padrao in a.arquivos:
        achados = sorted(glob.glob(padrao))
        if not achados:
            print('nada casou com %s' % padrao)
        for c in achados:
            camera = os.path.basename(os.path.dirname(c))
            try:
                d = descreve(io.open(c, 'rb').read(), os.path.basename(c), camera)
            except Exception as e:
                print('%-40s ERRO: %s' % (os.path.basename(c), e))
                continue
            if d is None:
                print('%-40s sem keyframe de video' % os.path.basename(c))
                continue
            saida.append(d)

    if a.url:
        for cam in a.camera:
            try:
                d = descreve(da_rede(a.url, cam, a.from_ms), a.url, cam)
            except Exception as e:
                print('%-40s ERRO: %s' % (cam, e))
                continue
            if d is None:
                print('%-40s sem keyframe de video' % cam)
                continue
            saida.append(d)

    for d in saida:
        print('%-8s %-5s %4dx%-4d %7d bytes  ps=%-5s  %s'
              % (d['camera'], d['codecName'], d['width'], d['height'],
                 d['bytes'], d['temParameterSet'], ','.join(d['nals'][:6])))
        print('%-8s candidatas: %s' % ('', ', '.join(d['codecs'])))

    if a.json:
        io.open(a.json, 'w', encoding='utf-8').write(json.dumps(saida, indent=1))
        kb = sum(sum(len(l) for l in d['au']) for d in saida) // 1024
        print('\ngravado %s  (%d quadros, %d KB de base64)'
              % (a.json, len(saida), kb))
    return 0


if __name__ == '__main__':
    sys.exit(main())
