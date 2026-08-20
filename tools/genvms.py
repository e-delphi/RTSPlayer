"""Gera um .vms com o mesmo layout de bytes que VMS.Rec.Writer.pas escreve.

Serve para exercitar os leitores (tools/ e, por tabela, a especificação) sem
precisar de câmera nem de build do Delphi.

  python genvms.py saida.vms [--blocos N] [--sem-indice] [--truncado]
"""

import argparse
import struct
import sys
import zlib

MAGIC_FILE = b'VMS1'
MAGIC_BLOCK = b'BLK\x01'
MAGIC_FOOTER = b'VEOF'
MAGIC_INDEX = b'VIDX'
MAGIC_REGION = b'VLIX'
REGION_HEADER_SIZE = 40
REGION_COMMIT_OFS = (12, 24)
REGION_COMMIT_EVERY = 16     # mesmo passo do TFileRecordingWriter
MAGIC_ANCHOR = b'BANC'

u16 = lambda v: struct.pack('<H', v)
u32 = lambda v: struct.pack('<I', v)
i64 = lambda v: struct.pack('<q', v)
u64 = lambda v: struct.pack('<Q', v)

# SPS/PPS mínimos só para o header não ficar vazio (não precisam decodificar)
EXTRADATA = bytes.fromhex('00000001674d401e9a6602803f350100000001680ebc20')


# O formato está em desenvolvimento e não lê layout antigo: existe uma versão só.
VERSAO = 1


def build_header(creation_ms, uri='rtsp://192.0.2.10:554/onvif1'):
    uri_b = uri.encode('utf-8')
    body = (i64(creation_ms) + u16(len(uri_b)) + uri_b
            + b'\x01' + b'\x01' + u32(90000) + u16(1280) + u16(720)
            + u32(len(EXTRADATA)) + EXTRADATA
            + b'\x01' + b'\x04' + u32(8000) + b'\x01' + b'\x10' + u32(8000)
            + u32(0))
    size = 4 + 2 + 4 + len(body) + 4
    head = MAGIC_FILE + u16(VERSAO) + u32(size) + body
    return head + u32(zlib.crc32(head))


def build_block(seq, start_ms, samples, anchors=None):
    """samples: lista de (track_id, flags, pts, data).

    anchors: (video_ms, audio_ms) — a âncora A/V, gravada NO FIM da área de
    índice. Quem lê percorre sample_count entradas e acha o payload por
    index_size, então ela cabe ali sem deslocar nada."""
    index = b''
    payload = b''
    for tid, flags, pts, data in samples:
        index += bytes([tid, flags]) + i64(pts) + u32(len(payload)) + u32(len(data))
        payload += data
    if anchors:
        index += MAGIC_ANCHOR + i64(anchors[0]) + i64(anchors[1])
    total = 28 + len(index) + len(payload) + 4
    body = (MAGIC_BLOCK + u32(total) + u32(seq) + i64(start_ms)
            + u32(len(samples)) + u32(len(index)) + index + payload)
    return body + u32(zlib.crc32(body))


def reserve_region(region_bytes):
    """A região de índice viva, zerada — os dois slots de commit nascem em
    (0 entradas, geração 0), que é 'ainda não commitei nada'."""
    capacity = (region_bytes - REGION_HEADER_SIZE) // 17
    head = MAGIC_REGION + u32(region_bytes) + u32(capacity)
    return bytearray(head + bytes(region_bytes - len(head))), capacity


def commit_region(out, region_at, capacity, entries, committed, gen, slot, crc):
    """Grava na região as entradas que faltam e commita, como o writer faz: as
    entradas primeiro, o slot depois, alternando os slots."""
    new = min(len(entries), capacity)
    if new <= committed:
        return committed, gen, slot, crc
    blob = b''
    for off, ms, flags in entries[committed:new]:
        blob += i64(off) + i64(ms) + bytes([flags])
    at = region_at + REGION_HEADER_SIZE + committed * 17
    out[at:at + len(blob)] = blob
    crc = zlib.crc32(blob, crc)
    gen += 1
    rec = u32(new) + u32(gen) + u32(crc)
    at = region_at + REGION_COMMIT_OFS[slot]
    out[at:at + len(rec)] = rec
    return new, gen, (slot + 1) % 2, crc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('saida')
    ap.add_argument('--blocos', type=int, default=12)
    ap.add_argument('--sem-indice', action='store_true')
    ap.add_argument('--truncado', action='store_true',
                    help='corta o último bloco no meio, como gravação em curso')
    ap.add_argument('--inicio', type=int, default=1755229501000,
                    help='instante do primeiro bloco, em ms unix')
    ap.add_argument('--sem-ancora', action='store_true',
                    help='grava blocos sem a âncora A/V (bloco degenerado)')
    ap.add_argument('--defasagem', type=int, default=0,
                    help='ms entre o início do vídeo e o do áudio dentro do bloco')
    ap.add_argument('--regiao-kb', type=int, default=0,
                    help='reserva região de índice viva (VLIX) deste tamanho; '
                         '0 = arquivo sem região, como os fragmentos da API')
    args = ap.parse_args()

    creation = args.inicio
    out = bytearray(build_header(creation))
    region_at = capacity = 0
    committed = gen = slot = crc = 0
    if args.regiao_kb > 0:
        region_at = len(out)
        region, capacity = reserve_region(args.regiao_kb * 1024)
        out += region

    entries = []          # (offset, start_ms, flags)
    start_ms = creation
    pts = 0
    apts = 0
    last_offset = 0
    for b in range(args.blocos):
        samples = []
        for f in range(20):                     # 20 quadros de vídeo a 10 fps
            key = (f == 0) and (b % 3 == 0)     # keyframe a cada 3 blocos
            samples.append((0, 0x01 if key else 0x00, pts,
                            bytes([0, 0, 0, 1, 0x65 if key else 0x41]) + b'\xaa' * (300 if key else 60)))
            pts += 9000
            if f % 2 == 0:                      # áudio intercalado
                samples.append((1, 0x00, apts, b'\xd5' * 320))
                apts += 320
        has_key = any(s[0] == 0 and (s[1] & 1) for s in samples)
        last_offset = len(out)
        entries.append((last_offset, start_ms, 1 if has_key else 0))
        anchors = None if args.sem_ancora else (start_ms, start_ms + args.defasagem)
        out += build_block(b, start_ms, samples, anchors)
        start_ms += 2000
        # Commit a cada REGION_COMMIT_EVERY blocos: o fim do arquivo fica FORA da
        # região de propósito, que é o estado real de uma gravação em curso.
        if capacity and (len(entries) - committed >= REGION_COMMIT_EVERY):
            committed, gen, slot, crc = commit_region(
                out, region_at, capacity, entries, committed, gen, slot, crc)

    if args.truncado:
        del out[-40:]
        with open(args.saida, 'wb') as f:
            f.write(out)
        print('%s: %d bytes, %d blocos (último cortado, sem rodapé)'
              % (args.saida, len(out), args.blocos))
        return 0

    # Fechando o arquivo, a região passa a descrever tudo (é o que o Close faz).
    if capacity:
        committed, gen, slot, crc = commit_region(
            out, region_at, capacity, entries, committed, gen, slot, crc)

    index_offset = 0
    if not args.sem_indice:
        index_offset = len(out)
        body = MAGIC_INDEX + u32(12 + len(entries) * 17 + 4) + u32(len(entries))
        for off, ms, flags in entries:
            body += i64(off) + i64(ms) + bytes([flags])
        out += body + u32(zlib.crc32(body))

    duration = start_ms - 2000 - creation
    foot = (MAGIC_FOOTER + u32(args.blocos) + i64(duration) + u64(last_offset)
            + u64(index_offset) + u32(len(entries) if index_offset else 0))
    out += foot + u32(zlib.crc32(foot))

    with open(args.saida, 'wb') as f:
        f.write(out)
    print('%s: %d bytes, %d blocos, índice em %s'
          % (args.saida, len(out), args.blocos, index_offset or '(nenhum)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
