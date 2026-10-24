"""Modelo em Python do que /api/days e /api/segments devem responder.

Lê os .vms de uma câmera com a mesma regra do servidor (a pasta dela dentro do
storageDir; início e fim vindos dos blocos) e aplica a mesma colagem. Serve para
comparar com o curl depois de compilar o vmsserver: se divergir, o bug está no
Delphi, não no entendimento do formato.

  python apimodel.py <pasta> <camera>
"""

import json
import sys
import time
from datetime import datetime, timedelta

import glob
import os
import struct

import vmslib

ASSUMED_LAST_BLOCK_MS = 2000
GAP_MS = 5000
MS_PER_DAY = 86400000


def camera_files(folder, camera):
    """Os .vms de uma câmera, na mesma regra do servidor.

    Cada câmera grava na SUA pasta (<storage>/<camera>/), então lá dentro tudo
    é dela. O glob antigo, por prefixo na raiz, continua valendo para dump de
    gravação anterior a essa mudança."""
    sub = os.path.join(folder, camera)
    if os.path.isdir(sub):
        return sorted(glob.glob(os.path.join(sub, '*.vms')))
    return sorted(glob.glob(os.path.join(folder, camera + '_*.vms')))


def file_info(path):
    """Descreve um arquivo SEM montar índice, como o Vms.Server.IndexCache.

    Arquivo fechado responde pelo rodapé; arquivo em gravação, pelas pontas do
    `.vms.idx` ao lado. A varredura só sobra para arquivo recém-aberto (antes do
    primeiro lote) e para gravação de build sem sidecar."""
    with open(path, 'rb') as f:
        data = f.read()
    header = vmslib.read_header(data)
    footer = vmslib.read_footer(data)

    o = header.size
    if data[o:o + 4] != vmslib.MAGIC_BLOCK:
        return None
    start = struct.unpack_from('<q', data, o + 12)[0]

    indexed = True
    if footer is not None:
        blocks = footer.total_blocks
        end = header.creation_unix_ms + footer.duration_ms + ASSUMED_LAST_BLOCK_MS
        if end < start:
            end = start
    else:
        sidecar = None
        try:
            sidecar = vmslib.read_sidecar(path, header.creation_unix_ms)
        except vmslib.VmsError:
            sidecar = None
        if sidecar:
            start = sidecar[0][0].start_unix_ms
            end = sidecar[0][-1].start_unix_ms + ASSUMED_LAST_BLOCK_MS
            blocks = len(sidecar[0])
        else:
            blks = list(vmslib.iter_blocks(data, header, with_data=False))
            if not blks:
                return None
            start = blks[0].start_unix_ms
            end = blks[-1].start_unix_ms + ASSUMED_LAST_BLOCK_MS
            blocks = len(blks)
            indexed = False
    if blocks == 0:
        return None
    return dict(file=os.path.basename(path), startMs=start, endMs=end,
                blocks=blocks, closed=footer is not None,
                indexed=indexed, bytes=len(data))


def merge(files, gap_ms):
    out = []
    for f in sorted(files, key=lambda x: x['startMs']):
        if out and f['startMs'] - out[-1]['endMs'] <= gap_ms:
            out[-1]['endMs'] = max(out[-1]['endMs'], f['endMs'])
        else:
            out.append(dict(startMs=f['startMs'], endMs=f['endMs']))
    return out


def clip(ranges, a, b):
    out = []
    for r in ranges:
        s, e = max(r['startMs'], a), min(r['endMs'], b)
        if e > s:
            out.append(dict(startMs=s, endMs=e))
    return out


def local_day_bounds(day):
    """[início, fim) do dia local, em ms unix — via time.mktime, que aplica o
    fuso e o horário de verão da máquina, igual ao TTimeZone do Delphi."""
    start = time.mktime(day.timetuple()) * 1000
    nxt = time.mktime((day + timedelta(days=1)).timetuple()) * 1000
    return int(start), int(nxt)


def main():
    folder, camera = sys.argv[1], sys.argv[2]
    files = [i for i in (file_info(p) for p in
                         sorted(glob.glob(os.path.join(folder, camera + '_*.vms'))))
             if i]
    if not files:
        print('nenhum arquivo de %s em %s' % (camera, folder))
        return 1

    print('# arquivos (o que /api/recordings deve listar)')
    for f in files:
        print('  %-38s %s .. %s  %d blocos  fechado=%s indexado=%s'
              % (f['file'],
                 datetime.fromtimestamp(f['startMs'] / 1000).strftime('%H:%M:%S'),
                 datetime.fromtimestamp(f['endMs'] / 1000).strftime('%H:%M:%S'),
                 f['blocks'], f['closed'], f['indexed']))

    ranges_exact = merge(files, 0)        # /api/days mede sem folga
    ranges_glued = merge(files, GAP_MS)   # /api/segments desenha com folga

    days = []
    first = datetime.fromtimestamp(ranges_exact[0]['startMs'] / 1000).date()
    last = datetime.fromtimestamp(ranges_exact[-1]['endMs'] / 1000).date()
    day = first
    while day <= last:
        a, b = local_day_bounds(datetime(day.year, day.month, day.day))
        part = clip(ranges_exact, a, b)
        if part:
            # tempo gravado sem folga; nº de faixas com folga, para bater com o
            # que o /api/segments desenha
            rec = sum(r['endMs'] - r['startMs'] for r in part)
            days.append(dict(day=day.isoformat(), startMs=part[0]['startMs'],
                             endMs=part[-1]['endMs'], recordedMs=rec,
                             coverage=round(rec / MS_PER_DAY, 6),
                             segments=len(clip(ranges_glued, a, b))))
        day += timedelta(days=1)

    print('\n# GET /api/days?camera=%s' % camera)
    print(json.dumps(dict(camera=camera, days=days), indent=2))

    for d in days:
        a, b = local_day_bounds(datetime.fromisoformat(d['day']))
        segs = clip(ranges_glued, a, b)
        print('\n# GET /api/segments?camera=%s&day=%s' % (camera, d['day']))
        print(json.dumps(dict(camera=camera, day=d['day'], segments=segs), indent=2))
        for s in segs:
            print('  # %s .. %s (%.1f min)'
                  % (datetime.fromtimestamp(s['startMs'] / 1000).strftime('%H:%M:%S'),
                     datetime.fromtimestamp(s['endMs'] / 1000).strftime('%H:%M:%S'),
                     (s['endMs'] - s['startMs']) / 60000))
    return 0


if __name__ == '__main__':
    sys.exit(main())
