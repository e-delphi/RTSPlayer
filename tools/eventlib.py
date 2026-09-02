"""Modelo do formato `.vev` e das duas decisões da análise de imagem.

Mesma disciplina do `vmslib`: não é uma tradução do Delphi, é o CONTRATO que o
Delphi tem de cumprir, escrito uma segunda vez de forma independente e conferido
sobre os mesmos bytes. Quando os dois discordam, um dos dois está errado — e é
essa discordância que o selftest existe para achar, já que o `dcc` deste
ambiente não compila por linha de comando.

O que está modelado aqui:

  * `.vev`  — cabeçalho de 32 bytes + registros de 64, com CRC nos dois
              (Vms.Analytics.Store)
  * motion  — a grade 64x36, o fundo exponencial e a regra de cena nova
              (Vms.Analytics.Motion)
  * merge   — a agregação de avistamentos em eventos
              (Vms.Analytics.Analyzer)
"""

import struct
import zlib

VEV_MAGIC = b'VEV1'
VEV_VERSION = 1
HEADER_SIZE = 32
RECORD_SIZE = 64
NAME_OFFSET = 32
NAME_SIZE = 28

KIND_MOTION = 0
KIND_OBJECT = 1

# --------------------------------------------------------------- formato


def crc(data, offset, count):
    return zlib.crc32(data[offset:offset + count]) & 0xFFFFFFFF


def build_header(created_ms):
    b = bytearray(HEADER_SIZE)
    b[0:4] = VEV_MAGIC
    struct.pack_into('<H', b, 4, VEV_VERSION)
    struct.pack_into('<H', b, 6, RECORD_SIZE)
    struct.pack_into('<q', b, 8, created_ms)
    struct.pack_into('<I', b, 28, crc(bytes(b), 0, 28))
    return bytes(b)


def _box_u16(v):
    if v <= 0:
        return 0
    if v >= 1:
        return 0xFFFF
    return int(round(v * 65535))


def build_record(start_ms, end_ms, kind, name, score=1.0, count=1,
                 box=(0.0, 0.0, 0.0, 0.0)):
    b = bytearray(RECORD_SIZE)
    struct.pack_into('<q', b, 0, start_ms)
    struct.pack_into('<q', b, 8, end_ms)
    b[16] = kind
    b[17] = max(0, min(255, count))
    struct.pack_into('<H', b, 18, max(0, min(10000, int(round(score * 10000)))))
    for i, v in enumerate(box):
        struct.pack_into('<H', b, 20 + i * 2, _box_u16(v))
    raw = name.encode('utf-8')[:NAME_SIZE]
    b[NAME_OFFSET:NAME_OFFSET + len(raw)] = raw
    struct.pack_into('<I', b, 60, crc(bytes(b), 0, 60))
    return bytes(b)


def parse_record(data, offset):
    """Devolve o evento, ou None se o registro não fecha (CRC ou truncado)."""
    if offset + RECORD_SIZE > len(data):
        return None
    r = data[offset:offset + RECORD_SIZE]
    if struct.unpack_from('<I', r, 60)[0] != crc(r, 0, 60):
        return None
    name = r[NAME_OFFSET:NAME_OFFSET + NAME_SIZE].split(b'\x00')[0]
    ev = {
        'start_ms': struct.unpack_from('<q', r, 0)[0],
        'end_ms': struct.unpack_from('<q', r, 8)[0],
        'kind': r[16],
        'count': r[17],
        'score': struct.unpack_from('<H', r, 18)[0] / 10000.0,
        'name': name.decode('utf-8', 'replace'),
        'box': tuple(struct.unpack_from('<H', r, 20 + i * 2)[0] / 65535.0
                     for i in range(4)),
    }
    if ev['start_ms'] <= 0 or ev['end_ms'] < ev['start_ms'] or not ev['name']:
        return None
    return ev


def read_file(data):
    """Todos os registros que fecham. Rabo truncado e registro corrompido saem
    de fora sem levar o resto junto — é a razão de o registro ser de tamanho
    fixo e ter CRC próprio."""
    if len(data) < HEADER_SIZE or data[0:4] != VEV_MAGIC:
        return None
    if struct.unpack_from('<I', data, 28)[0] != crc(data, 0, 28):
        return None
    if struct.unpack_from('<H', data, 6)[0] != RECORD_SIZE:
        return None
    out = []
    off = HEADER_SIZE
    while off + RECORD_SIZE <= len(data):
        ev = parse_record(data, off)
        if ev is not None:
            out.append(ev)
        off += RECORD_SIZE
    return out


def query(events, from_ms, to_ms, name=None, kind=None, min_score=0.0):
    """A regra da API: SOBREPOSIÇÃO com a janela, não continência. Quem abre a
    barra às 14h quer ver a passagem que começou às 13h58 e ainda estava
    acontecendo."""
    out = []
    for ev in events:
        if ev['end_ms'] < from_ms or ev['start_ms'] > to_ms:
            continue
        if kind is not None and ev['kind'] != kind:
            continue
        if name is not None and ev['name'].lower() != name.lower():
            continue
        if ev['score'] < min_score:
            continue
        out.append(ev)
    out.sort(key=lambda e: e['start_ms'])
    return out


# ---------------------------------------------------------------- motion

GRID_W, GRID_H = 64, 36
GRID_CELLS = GRID_W * GRID_H
GRID_MIN_W, GRID_MIN_H = 8, 5
BG_ALPHA = 26
CELL_DELTA = 14


def gray_frame(w, h, value=100):
    """Um quadro RGB24 chapado, como TRgbImage: stride = w*3, sem alinhamento."""
    return bytearray([value] * (w * h * 3))


def paint(buf, w, h, x0, y0, x1, y1, value):
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            p = (y * w + x) * 3
            buf[p] = buf[p + 1] = buf[p + 2] = value


def grade_de(escala):
    """O lado da grade para uma escala, com o mesmo piso do detector."""
    gw, gh = GRID_W, GRID_H
    if 0 < escala < 1:
        gw = int(round(GRID_W * escala))
        gh = int(round(GRID_H * escala))
    return max(gw, GRID_MIN_W), max(gh, GRID_MIN_H)


def _downsample(buf, w, h, gw=GRID_W, gh=GRID_H):
    n = gw * gh
    somas = [0] * n
    contas = [0] * n
    for y in range(h):
        gy = min(gh - 1, (y * gh) // h)
        base = gy * gw
        for x in range(w):
            gx = min(gw - 1, (x * gw) // w)
            p = (y * w + x) * 3
            luma = (77 * buf[p] + 150 * buf[p + 1] + 29 * buf[p + 2]) >> 8
            somas[base + gx] += luma
            contas[base + gx] += 1
    return [(somas[i] // contas[i]) if contas[i] else 0 for i in range(n)]


class Motion(object):
    """O TFrameDiffMotionDetector, escrito de novo a partir do contrato."""

    def __init__(self, threshold=0.012, scene=0.55, max_gap_ms=8000,
                 grid_scale=1.0, cell_delta=0):
        self.threshold = threshold
        self.scene = scene
        self.max_gap_ms = max_gap_ms
        # Os dois filtros, contra coisas diferentes: a grade contra movimento
        # pequeno, o delta contra deslocamento de brilho. Ver o cabecalho de
        # Vms.Analytics.Motion.
        self.gw, self.gh = grade_de(grid_scale)
        self.cells = self.gw * self.gh
        self.cell_delta = cell_delta if 0 < cell_delta <= 255 else CELL_DELTA
        self.bg = None
        self.last_ms = 0

    def reset(self):
        self.bg = None
        self.last_ms = 0

    def feed(self, ms, buf, w, h):
        saltou = self.last_ms > 0 and abs(ms - self.last_ms) > self.max_gap_ms
        self.last_ms = ms
        cur = _downsample(buf, w, h, self.gw, self.gh)

        if self.bg is None or saltou:
            self.bg = [c << 8 for c in cur]
            return {'moved': False, 'score': 0.0, 'scene': False, 'box': None}

        movidas = []
        for i, c in enumerate(cur):
            if abs(c - (self.bg[i] >> 8)) >= self.cell_delta:
                movidas.append(i)
        frac = len(movidas) / float(self.cells)

        if frac >= self.scene:
            self.bg = [c << 8 for c in cur]
            return {'moved': False, 'score': frac, 'scene': True, 'box': None}

        for i, c in enumerate(cur):
            self.bg[i] = self.bg[i] + ((c << 8) - self.bg[i]) * BG_ALPHA // 256

        if frac < self.threshold:
            return {'moved': False, 'score': frac, 'scene': False, 'box': None}

        xs = [i % self.gw for i in movidas]
        ys = [i // self.gw for i in movidas]
        box = (min(xs) / self.gw, min(ys) / self.gh,
               (max(xs) + 1) / self.gw, (max(ys) + 1) / self.gh)
        return {'moved': True, 'score': frac, 'scene': False, 'box': box}


# ----------------------------------------------------------- agregação


class Merger(object):
    """A regra do TFrameAnalyzer: um evento ABERTO por rótulo, estendido por
    avistamento novo dentro de merge_gap_ms e fechado depois disso. Score e
    caixa guardados são os do quadro de PICO."""

    def __init__(self, merge_gap_ms=8000):
        self.gap = merge_gap_ms
        self.open = {}
        self.closed = []

    def _close(self, name):
        self.closed.append(self.open.pop(name))

    def note(self, ms, name, kind=KIND_MOTION, score=1.0, count=1,
             box=(0, 0, 0, 0)):
        self.close_stale(ms)
        o = self.open.get(name)
        if o is None:
            self.open[name] = {'start_ms': ms, 'end_ms': ms, 'kind': kind,
                               'name': name, 'score': score, 'count': count,
                               'box': box}
            return
        o['end_ms'] = ms
        if score > o['score']:
            o['score'] = score
            o['box'] = box
        if count > o['count']:
            o['count'] = count

    def close_stale(self, ms):
        for name in [n for n, o in self.open.items()
                     if ms - o['end_ms'] > self.gap]:
            self._close(name)

    def flush(self):
        for name in list(self.open):
            self._close(name)
        self.closed.sort(key=lambda e: e['start_ms'])
        return self.closed
