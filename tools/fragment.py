"""Modelo do que /api/media deve devolver, para comparar com o servidor.

Faz o mesmo que o Vms.Server.Media: acha o arquivo pelo instante, recua até o
bloco com keyframe, copia o header cru + N blocos crus, e calcula os cabeçalhos
da resposta. Grava o fragmento em disco para abrir no vmsdump/ffplay.

  python fragment.py <pasta> <camera> <fromMs|cursor> [blocos]
"""

import glob
import os
import struct
import sys

import apimodel
import genvms
import vmslib

ASSUMED_BLOCK_MS = 2000
MAX_FRAGMENT_BYTES = 4 * 1024 * 1024


def scan(folder, camera):
    """(nome, dados, header, entradas do índice) de cada .vms da câmera."""
    out = []
    for path in apimodel.camera_files(folder, camera):
        with open(path, 'rb') as f:
            data = f.read()
        header = vmslib.read_header(data)
        footer = vmslib.read_footer(data)
        try:
            entries = vmslib.read_block_index(data, footer)
        except vmslib.VmsError:
            entries = None
        if entries is None:
            entries = [vmslib.IndexEntry(b.offset, b.start_unix_ms,
                                         1 if any(s.is_video and s.keyframe
                                                  for s in b.samples) else 0)
                       for b in vmslib.iter_blocks(data, header)]
        if not entries:
            continue
        out.append(dict(name=os.path.basename(path), data=data, header=header,
                        blocks=list(vmslib.iter_blocks(data, header)),
                        index=entries, closed=footer is not None,
                        start=entries[0].start_unix_ms,
                        end=entries[-1].start_unix_ms + ASSUMED_BLOCK_MS))
    return sorted(out, key=lambda f: f['start'])


def block_size(data, offset):
    return struct.unpack_from('<I', data, offset + 4)[0]


def index_at_time(entries, ms):
    best = -1
    for i, e in enumerate(entries):
        if e.start_unix_ms <= ms:
            best = i
        else:
            break
    return best


def _wall_of(block, sample, timescale):
    """O instante de parede de um sample, exatamente como o cliente calcula:
    âncora do bloco + distância em PTS até o primeiro sample de vídeo dele."""
    anchor = block.video_anchor_ms or block.start_unix_ms
    first = next(s.pts for s in block.samples if s.is_video)
    return anchor + (sample.pts - first) * 1000 // timescale


def thin_block(block, timescale, step_ms, last_ms):
    """Reescreve um bloco com só os quadros que serão exibidos, como o
    ThinBlock do Vms.Server.Media. Devolve (samples, payload, anchor, last_ms)
    ou None quando nada foi selecionado.

    A âncora do bloco novo é o instante do PRIMEIRO quadro escolhido: é isso que
    faz a conta do cliente continuar dando o horário certo depois de o começo do
    bloco ter sido jogado fora."""
    keep, first_kept = [], None
    for smp in block.samples:
        if not smp.is_video or not smp.keyframe:
            continue
        wall = _wall_of(block, smp, timescale)
        if last_ms is not None and wall - last_ms < step_ms:
            continue
        if first_kept is None:
            first_kept = wall
        keep.append(smp)
        last_ms = wall
    if not keep:
        return None
    return keep, first_kept, last_ms


def fetch(files, from_ms=None, cursor=None, blocks=4, step_ms=0):
    # 1. arquivo
    if cursor:
        next_ms, blk, newfile, name = cursor.split('-', 3)
        next_ms, blk, newfile = int(next_ms), int(blk), int(newfile)
        cur = next((f for f in files if f['name'] == name), None)
        if cur is None:                      # apagado pela retenção
            cur = next((f for f in files if f['end'] > next_ms), files[-1])
            blk = max(0, index_at_time(cur['index'], next_ms))
        first = blk
        # emenda = cursor marcado como travessia, ou cursor que caducou e caiu
        # noutro arquivo
        disc = bool(newfile) or cur['name'] != name
    else:
        cur = next((f for f in files if f['start'] <= from_ms < f['end']), None)
        if cur is None:
            cur = next((f for f in files if f['start'] >= from_ms), files[-1])
        first = max(0, index_at_time(cur['index'], from_ms))
        while first > 0 and not cur['index'][first].keyframe:
            first -= 1
        disc = True

    idx = cur['index']
    # 2. blocos, limitados por quantidade e por bytes
    span = 0
    last = first
    count = 0
    for i in range(first, len(idx)):
        size = block_size(cur['data'], idx[i].offset)
        if count and span + size > MAX_FRAGMENT_BYTES:
            break
        span += size
        last, last_size = i, size
        count += 1
        if count >= blocks:
            break

    head = cur['data'][:cur['header'].size]
    if step_ms > 0:
        # Varredura: bloco reescrito, não copiado cru.
        ts = cur['header'].video.timescale or 90000
        body, last_kept = b'', None
        for blk in cur['blocks'][first:last + 1]:
            got = thin_block(blk, ts, step_ms, last_kept)
            if got is None:
                continue
            keep, anchor, last_kept = got
            # o gerador serializa igual ao BuildBlockBytes do Delphi
            body += genvms.build_block(
                blk.seq, anchor,
                [(s.track_id, s.flags, s.pts, s.data) for s in keep],
                (anchor, 0))
    else:
        body = cur['data'][idx[first].offset: idx[last].offset + last_size]

    end_ms = (idx[last + 1].start_unix_ms if last + 1 < len(idx)
              else idx[last].start_unix_ms + ASSUMED_BLOCK_MS)
    if last + 1 < len(idx):
        nxt, gap = idx[last + 1].start_unix_ms, 0
        cur_name, cur_blk, cur_new = cur['name'], last + 1, 0
    else:
        pos = files.index(cur)
        if pos + 1 < len(files):
            nf = files[pos + 1]
            nxt, gap = nf['start'], max(0, nf['start'] - end_ms)
            cur_name, cur_blk, cur_new = nf['name'], 0, 1
        else:
            nxt, gap, cur_name, cur_blk, cur_new = -1, 0, None, 0, 0

    return dict(data=head + body, file=cur['name'], first=first, count=count,
                start=idx[first].start_unix_ms, end=end_ms, next=nxt, gap=gap,
                disc=disc, keyframe=idx[first].keyframe, growing=not cur['closed'],
                cursor='' if cur_name is None
                       else '%d-%d-%d-%s' % (nxt, cur_blk, cur_new, cur_name))


def main():
    folder, camera, pos = sys.argv[1], sys.argv[2], sys.argv[3]
    blocks = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    files = scan(folder, camera)
    if not files:
        print('nada em %s para %s' % (folder, camera))
        return 1

    r = fetch(files, from_ms=int(pos), blocks=blocks)
    hop = 1
    while True:
        out = 'frag%d.vms' % hop
        with open(out, 'wb') as f:
            f.write(r['data'])
        print('%s  %d bytes  (arquivo %s, blocos %d..%d)'
              % (out, len(r['data']), r['file'], r['first'], r['first'] + r['count'] - 1))
        print('  X-Vms-Cursor: %s' % r['cursor'])
        print('  X-Vms-Block-Count: %d   X-Vms-Keyframe: %d   X-Vms-Growing: %d'
              % (r['count'], int(r['keyframe']), int(r['growing'])))
        print('  X-Vms-Start-Ms: %d   X-Vms-End-Ms: %d' % (r['start'], r['end']))
        print('  X-Vms-Next-Ms: %d   X-Vms-Gap-Ms: %d   X-Vms-Discontinuity: %d'
              % (r['next'], r['gap'], int(r['disc'])))
        if not r['cursor'] or hop >= 6:
            break
        hop += 1
        r = fetch(files, cursor=r['cursor'], blocks=blocks)
    return 0


if __name__ == '__main__':
    sys.exit(main())
