"""Simula gravação -> packetizer do servidor -> depacketizer do player e mostra
o que chegaria ao decodificador.

Serve para responder "o cliente recebe o bitstream certo?" sem subir servidor,
câmera nem app. Reproduz três coisas do código Delphi:

  Tx.Pkt.H264 (servidor)   quebra o sample em NALs e manda cada uma como pacote
                           único ou em FU-A conforme a MTU.
  VMS.Depk.H264 (player)   remonta os FU-A e emite um sample por NAL.
  VMS.Win.VideoDecoder     prefixa o extradata do SDP no 1º AU e nos keyframes
                           — mas só enquanto o stream não tiver mandado os seus
                           parameter sets in-band.

O caso da ayla cinza aparece assim: sem a última regra, o SPS/PPS do SDP entra
colado na frente do slice IDR e sobrescreve o SPS/PPS bom que acabou de chegar
em pacote separado. Use --legado para ver o comportamento antigo.

  python vmspipeline.py <arquivo.vms> [--mtu 1400] [--pacotes N] [--legado]
"""

import argparse
import collections
import sys

import vmslib

FUA_TYPE = 28


def packetize_h264(sample, mtu):
    """Tx.Pkt.H264.PushSample: um RTP por NAL, FU-A acima da MTU. Devolve
    (payload_rtp, marker)."""
    out = []
    nals = vmslib.split_annexb(sample.data)
    for i, n in enumerate(nals):
        last_nal = (i == len(nals) - 1)
        if len(n) <= mtu:
            out.append((n, last_nal))
            continue
        hdr = n[0]
        fu_ind = (hdr & 0x80) | (hdr & 0x60) | FUA_TYPE
        ntype = hdr & 0x1F
        off = 1
        while off < len(n):
            chunk = min(len(n) - off, mtu - 2)
            start = off == 1
            end = (off + chunk) >= len(n)
            fu_hdr = ntype | (0x80 if start else 0) | (0x40 if end else 0)
            out.append((bytes([fu_ind, fu_hdr]) + n[off:off + chunk],
                        end and last_nal))
            off += chunk
    return out


class Depacketizer:
    """VMS.Depk.H264: emite um sample (Annex-B) por NAL remontada."""

    def __init__(self):
        self.buf = bytearray()
        self.started = False
        self.out = []

    def feed(self, payload, marker):
        if not payload:
            return
        t = payload[0] & 0x1F
        if 1 <= t <= 23:
            self._emit(payload)
        elif t == 24:  # STAP-A
            off = 1
            while off + 2 <= len(payload):
                ln = (payload[off] << 8) | payload[off + 1]
                off += 2
                if ln == 0:
                    continue
                if off + ln > len(payload):
                    break
                self._emit(payload[off:off + ln])
                off += ln
        elif t == FUA_TYPE:
            if len(payload) < 2:
                return
            fi, fh = payload[0], payload[1]
            if fh & 0x80:  # start
                self.started = True
                self.buf = bytearray([(fi & 0xE0) | (fh & 0x1F)])
            if not self.started:
                return
            self.buf += payload[2:]
            if (fh & 0x40) or marker:  # end
                if self.buf:
                    self._emit(bytes(self.buf))
                self.buf = bytearray()
                self.started = False

    def _emit(self, nal):
        self.out.append((self._is_key(nal), b'\x00\x00\x00\x01' + bytes(nal)))

    @staticmethod
    def _is_key(nal):
        """VMS.Depk.H264.UnitIsKeyframe: IDR, ou unidade que abre com parameter
        set e contém slice (câmera que manda o AU inteiro numa NAL só)."""
        if not nal:
            return False
        t = nal[0] & 0x1F
        if t == 5:
            return True
        if t not in (7, 8):
            return False
        for i in range(len(nal) - 4):
            if nal[i] == 0 and nal[i + 1] == 0:
                if nal[i + 2] == 1:
                    t2 = nal[i + 3] & 0x1F
                elif nal[i + 2] == 0 and nal[i + 3] == 1:
                    t2 = nal[i + 4] & 0x1F
                else:
                    continue
                if t2 in (1, 5):
                    return True
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('arquivo')
    ap.add_argument('--mtu', type=int, default=1400)
    ap.add_argument('--pacotes', type=int, default=10,
                    help='quantos pacotes mostrar (a partir do 1º keyframe)')
    ap.add_argument('--legado', action='store_true',
                    help='prefixa o extradata do SDP mesmo com parameter sets in-band')
    args = ap.parse_args()

    header, blocks = vmslib.load(args.arquivo)
    if header.video.codec_name != 'H264':
        print('só simula H264 (este arquivo é %s)' % header.video.codec_name)
        return 1

    vid = [s for b in blocks for s in b.samples if s.is_video]
    first_key = next((i for i, s in enumerate(vid) if s.keyframe), None)
    if first_key is None:
        print('arquivo sem keyframe marcado; nada para simular')
        return 1
    vid = vid[first_key:]  # equivale ao SeekToLastKeyframe do servidor

    depk = Depacketizer()
    for s in vid:
        for payload, marker in packetize_h264(s, args.mtu):
            depk.feed(payload, marker)

    extradata = header.video.extradata
    print('%s' % args.arquivo)
    print('  samples de vídeo a partir do keyframe: %d' % len(vid))
    print('  unidades entregues ao decoder: %d' % len(depk.out))
    hist = collections.Counter(
        vmslib.nal_name(vmslib.split_annexb(d)[0], 'H264').split('(')[0]
        for _, d in depk.out if vmslib.split_annexb(d))
    print('  por tipo: %s' % dict(hist))
    print('  extradata do SDP: %dB  %s' % (
        len(extradata), vmslib.describe_h264_ps(vmslib.split_annexb(extradata))))

    print('  primeiros pacotes montados para o decoder:')
    need_prepend = True
    saw_inband = False
    risco = 0
    for i, (key, d) in enumerate(depk.out[:args.pacotes]):
        nals = vmslib.split_annexb(d)
        has_ps = any(vmslib.is_parameter_set(n, 'H264') for n in nals)
        if has_ps:
            saw_inband = True
        prepend = bool(extradata) and (need_prepend or key)
        if saw_inband and not args.legado:
            prepend = False
        shown = (vmslib.split_annexb(extradata) if prepend else []) + nals
        print('    %2d key=%d prefixo=%d -> %s' % (
            i, int(key), int(prepend),
            ' '.join(vmslib.nal_name(n, 'H264') for n in shown)))
        if prepend and saw_inband and not has_ps:
            risco += 1
        if prepend:
            need_prepend = False

    if risco:
        print('  ATENÇÃO: em %d pacote(s) o parameter set do SDP entrou na frente de'
              ' um slice depois de o stream já ter mandado o seu. Se os dois usarem o'
              ' mesmo sps_id/pps_id, o do SDP vence e o slice é decodificado com os'
              ' parâmetros errados (imagem cinza).' % risco)
    return 0


if __name__ == '__main__':
    sys.exit(main())
