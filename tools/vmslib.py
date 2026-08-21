"""Leitura de .vms e do bitstream que ele carrega.

Um lugar só sabe o formato; as ferramentas em volta ficam curtas. O formato está
descrito em VMS.Rec.Format.pas / VMS.Rec.Writer.pas — se mudar lá, muda aqui.

  header: 'VMS1' | version(2) | header_size(4) | creation_unix_ms(8)
          | uri_len(2) + uri | video_present(1) codec(1) timescale(4) w(2) h(2)
          + extradata_len(4) + extradata
          | audio_present(1) codec(1) sample_rate(4) channels(1) bits(1)
          + timescale(4) + extradata_len(4) + extradata | crc32(4)
  bloco:  'BLK\\x01' | block_size(4) | seq(4) | start_unix_ms(8)
          | sample_count(4) | index_size(4) | index | payload | crc32(4)
  índice: track_id(1) flags(1) pts(8) payload_offset(4) payload_size(4)
  BANC:   'BANC' | video_anchor_ms(8) | audio_anchor_ms(8)   [no fim do índice]
  VIDX:   'VIDX' | chunk_size(4) | count(4)
          | count × (offset(8) start_unix_ms(8) flags(1)) | crc32(4)
  VEOF:   'VEOF' | total_blocks(4) | duration_ms(8) | last_block_offset(8)
          | index_offset(8) index_count(4) | crc32(4)

Inteiros são little-endian. track_id 0 = vídeo, 1 = áudio. flags bit 0 =
keyframe, 1 = início de quadro, 2 = fim de quadro. O CRC é o CRC-32 padrão
(polinômio 0xEDB88320), igual ao do zlib.

O VIDX é o índice tempo → posição, escrito quando a gravação fecha; nele, flags
bit 0 = o bloco contém keyframe de vídeo.

Enquanto a gravação corre não há VIDX (ele só é escrito no fechamento), e quem
responde por ela é o arquivo lateral `<gravação>.vms.idx`:

  cabeçalho: 'VIDS' | versão(2) | reservado(2) | creation_unix_ms(8) | crc32(4)
  lote:      'IDXB' | count(4) | valid_up_to(8)
             | count × (offset(8) start_unix_ms(8) flags(1)) | crc32(4)

`creation_unix_ms` amarra o sidecar ao `.vms`; `valid_up_to` é o primeiro offset
que aquele lote ainda não cobre, de onde se retoma a varredura. Escrita só em
append: lote cortado no fim é descartado pelo crc, e vale o que veio antes.
Fechando a gravação direito, o VIDX entra no fim do `.vms` e o sidecar é apagado.

O formato está em desenvolvimento e não carrega compatibilidade: existe um layout
só, e gravação de layout antigo se apaga.
"""

import os
import struct
import sys
import zlib
from dataclasses import dataclass, field

# O stdout do Windows sai em cp1252 por padrão e engole os acentos das mensagens.
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except (AttributeError, OSError):  # stdout redirecionado para algo sem reconfigure
    pass

MAGIC_FILE = b'VMS1'
MAGIC_BLOCK = b'BLK\x01'
MAGIC_FOOTER = b'VEOF'
MAGIC_INDEX = b'VIDX'
MAGIC_ANCHOR = b'BANC'
MAGIC_SIDECAR = b'VIDS'
MAGIC_BATCH = b'IDXB'

# Versão única do formato: o Delphi recusa arquivo com outra (ver ReadHeader).
FORMAT_VERSION = 1

VIDEO_CODECS = {0: 'nenhum', 1: 'H264', 2: 'H265', 3: 'MJPEG'}
AUDIO_CODECS = {0: 'nenhum', 1: 'PCM', 2: 'AAC', 3: 'G711U', 4: 'G711A',
                5: 'G726-16', 6: 'G726-24', 7: 'G726-32', 8: 'G726-40'}

FLAG_KEYFRAME = 0x01
INDEX_ENTRY_SIZE = 18          # entrada do índice de samples, dentro do bloco
BLOCK_HEADER_SIZE = 28
BLOCK_INDEX_ENTRY_SIZE = 17    # entrada do VIDX, uma por bloco
INDEX_HEADER_SIZE = 12
ANCHOR_SIZE = 20            # 'BANC' + âncora de vídeo(8) + de áudio(8)
FOOTER_SIZE = 40
SIDECAR_HEADER_SIZE = 20    # cabeçalho do .vms.idx
BATCH_HEADER_SIZE = 16      # cabeçalho de um lote; o crc fica no fim dele
SIDECAR_VERSION = 1


class VmsError(Exception):
    pass


def _u16(b, o): return struct.unpack_from('<H', b, o)[0]
def _u32(b, o): return struct.unpack_from('<I', b, o)[0]
def _i64(b, o): return struct.unpack_from('<q', b, o)[0]
def _u64(b, o): return struct.unpack_from('<Q', b, o)[0]


@dataclass
class Track:
    present: bool = False
    codec: int = 0
    codec_name: str = 'nenhum'
    timescale: int = 0
    width: int = 0          # só vídeo
    height: int = 0         # só vídeo
    sample_rate: int = 0    # só áudio
    channels: int = 0       # só áudio
    bits: int = 0           # só áudio
    extradata: bytes = b''


@dataclass
class Header:
    version: int
    size: int
    creation_unix_ms: int
    uri: str
    video: Track
    audio: Track
    crc_ok: bool


@dataclass
class Sample:
    track_id: int
    flags: int
    pts: int
    data: bytes

    @property
    def keyframe(self):
        return bool(self.flags & FLAG_KEYFRAME)

    @property
    def is_video(self):
        return self.track_id == 0


@dataclass
class Block:
    seq: int
    start_unix_ms: int
    offset: int
    size: int
    crc_ok: bool
    samples: list = field(default_factory=list)
    # âncora A/V (formato v3): instante de parede do primeiro sample de cada
    # trilha neste bloco. 0 = arquivo anterior à v3, ou trilha ausente aqui.
    video_anchor_ms: int = 0
    audio_anchor_ms: int = 0


def read_header(data):
    if data[:4] != MAGIC_FILE:
        raise VmsError('não é um .vms (magic %r)' % data[:4])
    version = _u16(data, 4)
    size = _u32(data, 6)
    if size > len(data):
        raise VmsError('header truncado (%d bytes declarados)' % size)
    o = 10
    creation = _i64(data, o); o += 8
    uri_len = _u16(data, o); o += 2
    uri = data[o:o + uri_len].decode('utf-8', 'replace'); o += uri_len

    v = Track()
    v.present = data[o] != 0; o += 1
    v.codec = data[o]; o += 1
    v.codec_name = VIDEO_CODECS.get(v.codec, '?%d' % v.codec)
    v.timescale = _u32(data, o); o += 4
    v.width = _u16(data, o); o += 2
    v.height = _u16(data, o); o += 2
    n = _u32(data, o); o += 4
    v.extradata = data[o:o + n]; o += n

    a = Track()
    a.present = data[o] != 0; o += 1
    a.codec = data[o]; o += 1
    a.codec_name = AUDIO_CODECS.get(a.codec, '?%d' % a.codec)
    a.sample_rate = _u32(data, o); o += 4
    a.channels = data[o]; o += 1
    a.bits = data[o]; o += 1
    a.timescale = _u32(data, o); o += 4
    n = _u32(data, o); o += 4
    a.extradata = data[o:o + n]; o += n

    crc_ok = (o + 4 <= len(data)) and (zlib.crc32(data[:o]) == _u32(data, o))
    return Header(version, size, creation, uri, v, a, crc_ok)


def iter_blocks(data, header, with_data=True):
    """Percorre os blocos. Para no rodapé, no primeiro magic inválido ou num
    bloco cortado — é o que acontece com arquivo ainda sendo gravado."""
    o = header.size
    while o + BLOCK_HEADER_SIZE <= len(data):
        if data[o:o + 4] == MAGIC_FOOTER:
            break
        if data[o:o + 4] != MAGIC_BLOCK:
            break
        size = _u32(data, o + 4)
        if size < BLOCK_HEADER_SIZE or o + size > len(data):
            break  # bloco incompleto: gravação em curso
        seq = _u32(data, o + 8)
        start = _i64(data, o + 12)
        count = _u32(data, o + 20)
        index_size = _u32(data, o + 24)
        crc_ok = zlib.crc32(data[o:o + size - 4]) == _u32(data, o + size - 4)
        blk = Block(seq, start, o, size, crc_ok)
        p = o + BLOCK_HEADER_SIZE
        payload = p + index_size
        # A âncora fica DEPOIS das entradas de sample, ainda dentro da área de
        # índice: quem não a conhece percorre só `count` entradas e acha o
        # payload por index_size, ignorando estes bytes.
        anchor_at = p + count * INDEX_ENTRY_SIZE
        if (index_size >= count * INDEX_ENTRY_SIZE + ANCHOR_SIZE
                and data[anchor_at:anchor_at + 4] == MAGIC_ANCHOR):
            blk.video_anchor_ms = _i64(data, anchor_at + 4)
            blk.audio_anchor_ms = _i64(data, anchor_at + 12)
        for _ in range(count):
            if p + INDEX_ENTRY_SIZE > o + size:
                break
            tid = data[p]
            flags = data[p + 1]
            pts = _i64(data, p + 2)
            off = _u32(data, p + 10)
            sz = _u32(data, p + 14)
            p += INDEX_ENTRY_SIZE
            blk.samples.append(Sample(
                tid, flags, pts,
                data[payload + off:payload + off + sz] if with_data else b''))
        yield blk
        o += size


@dataclass
class Footer:
    total_blocks: int
    duration_ms: int
    last_block_offset: int
    index_offset: int       # 0 = arquivo fechado sem índice
    index_count: int
    crc_ok: bool


@dataclass
class IndexEntry:
    offset: int
    start_unix_ms: int
    flags: int

    @property
    def keyframe(self):
        return bool(self.flags & FLAG_KEYFRAME)


def read_footer(data):
    """O rodapé, ou None se o arquivo não tem (truncado ou em gravação).

    Num arquivo em gravação o fim é o meio de um bloco; é o CRC que impede
    confundir esses bytes com um rodapé."""
    if len(data) < FOOTER_SIZE:
        return None
    f = data[-FOOTER_SIZE:]
    if f[:4] != MAGIC_FOOTER:
        return None
    if zlib.crc32(f[:FOOTER_SIZE - 4]) != _u32(f, FOOTER_SIZE - 4):
        return None
    return Footer(_u32(f, 4), _i64(f, 8), _u64(f, 16),
                  _u64(f, 24), _u32(f, 32), True)


def read_block_index(data, footer=None):
    """As entradas do VIDX, ou None se o arquivo não tem índice.

    Levanta VmsError quando o índice existe mas está corrompido — silenciar isso
    esconderia justamente o bug que se está procurando."""
    if footer is None:
        footer = read_footer(data)
    if footer is None or not footer.index_offset:
        return None
    o = footer.index_offset
    if o + INDEX_HEADER_SIZE > len(data) or data[o:o + 4] != MAGIC_INDEX:
        raise VmsError('rodapé aponta para %d, onde não há VIDX' % o)
    size = _u32(data, o + 4)
    count = _u32(data, o + 8)
    expected = INDEX_HEADER_SIZE + count * BLOCK_INDEX_ENTRY_SIZE + 4
    if size != expected:
        raise VmsError('VIDX com tamanho %d, esperado %d para %d entradas'
                       % (size, expected, count))
    if o + size > len(data):
        raise VmsError('VIDX truncado')
    if count != footer.index_count:
        raise VmsError('VIDX diz %d entradas, rodapé diz %d' % (count, footer.index_count))
    if zlib.crc32(data[o:o + size - 4]) != _u32(data, o + size - 4):
        raise VmsError('crc do VIDX inválido')
    out = []
    p = o + INDEX_HEADER_SIZE
    for _ in range(count):
        out.append(IndexEntry(_u64(data, p), _i64(data, p + 8), data[p + 16]))
        p += BLOCK_INDEX_ENTRY_SIZE
    return out


def sidecar_path(vms_path):
    return vms_path + '.idx'


def read_sidecar(vms_path, creation_unix_ms=None):
    """(entradas, valid_up_to) do `.vms.idx`, ou None se não há sidecar legível.

    Percorre os lotes e para no primeiro incompleto ou com crc quebrado — que é
    o que a gravação em curso deixa no fim do arquivo. Levanta VmsError quando o
    cabeçalho existe mas não presta: silenciar isso esconderia o bug."""
    path = sidecar_path(vms_path)
    if not os.path.exists(path):
        return None
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) < SIDECAR_HEADER_SIZE or data[:4] != MAGIC_SIDECAR:
        raise VmsError('%s não começa com VIDS' % os.path.basename(path))
    if zlib.crc32(data[:SIDECAR_HEADER_SIZE - 4]) != _u32(data, SIDECAR_HEADER_SIZE - 4):
        raise VmsError('crc do cabeçalho do sidecar inválido')
    version = _u16(data, 4)
    if version != SIDECAR_VERSION:
        raise VmsError('sidecar em versão %d, esperada %d' % (version, SIDECAR_VERSION))
    creation = _i64(data, 8)
    if creation_unix_ms is not None and creation != creation_unix_ms:
        # sidecar de outra gravação: não é índice deste arquivo
        return None

    out, valid_up_to = [], 0
    o = SIDECAR_HEADER_SIZE
    while o + BATCH_HEADER_SIZE <= len(data):
        if data[o:o + 4] != MAGIC_BATCH:
            break
        count = _u32(data, o + 4)
        need = count * BLOCK_INDEX_ENTRY_SIZE + 4
        if count == 0 or o + BATCH_HEADER_SIZE + need > len(data):
            break                                  # lote cortado: gravação em curso
        body = o + BATCH_HEADER_SIZE
        if zlib.crc32(data[o:body + need - 4]) != _u32(data, body + need - 4):
            break                                  # lote torto: vale o que veio antes
        p = body
        for _ in range(count):
            out.append(IndexEntry(_u64(data, p), _i64(data, p + 8), data[p + 16]))
            p += BLOCK_INDEX_ENTRY_SIZE
        valid_up_to = _i64(data, o + 8)
        o = body + need
    if not out:
        return None
    return out, valid_up_to


def check_index(blocks, entries):
    """Compara o índice do rodapé com a varredura. Devolve a lista de
    divergências (vazia = confere). É o teste do formato: o índice só vale se
    disser exatamente o que está no arquivo."""
    problems = []
    if len(entries) != len(blocks):
        problems.append('índice tem %d entradas, o arquivo tem %d blocos'
                        % (len(entries), len(blocks)))
    for i, (e, b) in enumerate(zip(entries, blocks)):
        if e.offset != b.offset:
            problems.append('bloco %d: índice aponta offset %d, o bloco está em %d'
                            % (i, e.offset, b.offset))
        if e.start_unix_ms != b.start_unix_ms:
            problems.append('bloco %d: índice diz start %d, o bloco diz %d'
                            % (i, e.start_unix_ms, b.start_unix_ms))
        real_key = any(s.is_video and s.keyframe for s in b.samples)
        if e.keyframe != real_key:
            problems.append('bloco %d: índice diz keyframe=%s, o bloco tem %s'
                            % (i, e.keyframe, real_key))
    return problems


def load(path, with_data=True):
    """(header, [blocos]) de um arquivo."""
    with open(path, 'rb') as f:
        data = f.read()
    header = read_header(data)
    return header, list(iter_blocks(data, header, with_data))


def wall_seconds(blocks):
    """Tempo de parede coberto pelos blocos, pelo StartUnixMs de cada um."""
    if len(blocks) < 2:
        return 0.0
    return (blocks[-1].start_unix_ms - blocks[0].start_unix_ms) / 1000.0


# ---------------------------------------------------------------- bitstream

def split_annexb(d):
    """Separa NALs de um sample Annex-B (aceita start code de 3 e 4 bytes)."""
    out = []
    i = 0
    start = -1
    while i + 3 < len(d):
        if d[i] == 0 and d[i + 1] == 0:
            if d[i + 2] == 1:
                skip = 3
            elif d[i + 2] == 0 and d[i + 3] == 1:
                skip = 4
            else:
                i += 1
                continue
            if start >= 0:
                out.append(d[start:i])
            i += skip
            start = i
            continue
        i += 1
    if 0 <= start < len(d):
        out.append(d[start:])
    return out


H264_NAMES = {1: 'slice', 5: 'IDR', 6: 'SEI', 7: 'SPS', 8: 'PPS', 9: 'AUD',
              12: 'filler'}
H265_NAMES = {32: 'VPS', 33: 'SPS', 34: 'PPS', 35: 'AUD', 39: 'SEI'}


def nal_type(nal, codec_name):
    if not nal:
        return -1
    if codec_name == 'H265':
        return (nal[0] >> 1) & 0x3F
    return nal[0] & 0x1F


def nal_name(nal, codec_name):
    t = nal_type(nal, codec_name)
    if codec_name == 'H265':
        base = H265_NAMES.get(t, 'nal%d' % t)
        if t <= 31:
            base = 'IRAP' if 16 <= t <= 21 else 'slice'
    else:
        base = H264_NAMES.get(t, 'nal%d' % t)
    return '%s(%dB)' % (base, len(nal))


def is_parameter_set(nal, codec_name):
    t = nal_type(nal, codec_name)
    return t in (32, 33, 34) if codec_name == 'H265' else t in (7, 8)


class _Bits:
    """Leitor de bits com remoção do emulation prevention (00 00 03)."""

    def __init__(self, d):
        out = bytearray()
        i = 0
        while i < len(d):
            if i + 2 < len(d) and d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 3:
                out += b'\x00\x00'
                i += 3
            else:
                out.append(d[i])
                i += 1
        self.d = bytes(out)
        self.p = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            if (self.p >> 3) >= len(self.d):
                raise VmsError('bitstream curto')
            v = (v << 1) | ((self.d[self.p >> 3] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def ue(self):
        z = 0
        while self.u(1) == 0:
            z += 1
            if z > 32:
                raise VmsError('exp-golomb inválido')
        return (1 << z) - 1 + (self.u(z) if z else 0)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)


H264_HIGH_PROFILES = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)


def parse_h264_sps(nal):
    """Campos do SPS que importam para diagnóstico. Sem VUI."""
    b = _Bits(nal[1:])
    profile = b.u(8)
    constraint = b.u(8)
    level = b.u(8)
    sps_id = b.ue()
    chroma = 1
    if profile in H264_HIGH_PROFILES:
        chroma = b.ue()
        if chroma == 3:
            b.u(1)
        b.ue(); b.ue(); b.u(1)
        if b.u(1):  # scaling matrix
            for i in range(8 if chroma != 3 else 12):
                if b.u(1):
                    last = nxt = 8
                    for _ in range(16 if i < 6 else 64):
                        if nxt:
                            nxt = (last + b.se() + 256) % 256
                        last = nxt or last
    log2_max_frame_num = b.ue() + 4
    poc_type = b.ue()
    if poc_type == 0:
        b.ue()
    elif poc_type == 1:
        b.u(1); b.se(); b.se()
        for _ in range(b.ue()):
            b.se()
    num_ref = b.ue()
    gaps = b.u(1)
    mbs_w = b.ue() + 1
    map_h = b.ue() + 1
    frame_mbs_only = b.u(1)
    if not frame_mbs_only:
        b.u(1)
    b.u(1)  # direct_8x8
    crop = [0, 0, 0, 0]
    if b.u(1):
        crop = [b.ue(), b.ue(), b.ue(), b.ue()]
    width = mbs_w * 16 - (crop[0] + crop[1]) * 2
    height = map_h * 16 * (2 - frame_mbs_only) - (crop[2] + crop[3]) * 2
    return dict(profile=profile, constraint=constraint, level=level,
                sps_id=sps_id, log2_max_frame_num=log2_max_frame_num,
                poc_type=poc_type, num_ref=num_ref, gaps_allowed=gaps,
                width=width, height=height)


def parse_h264_pps(nal):
    b = _Bits(nal[1:])
    pps_id = b.ue()
    sps_id = b.ue()
    cabac = b.u(1)
    return dict(pps_id=pps_id, sps_id=sps_id, cabac=cabac)


H264_PROFILE_NAMES = {66: 'Baseline', 77: 'Main', 88: 'Extended', 100: 'High'}


def describe_h264_ps(nals):
    """'Main/4.0 1280x720 sps_id=0 CABAC' a partir de SPS+PPS soltos."""
    parts = []
    for n in nals:
        t = n[0] & 0x1F
        try:
            if t == 7:
                s = parse_h264_sps(n)
                parts.append('%s/%.1f %dx%d sps_id=%d log2_frame_num=%d' % (
                    H264_PROFILE_NAMES.get(s['profile'], 'perfil%d' % s['profile']),
                    s['level'] / 10.0, s['width'], s['height'], s['sps_id'],
                    s['log2_max_frame_num']))
            elif t == 8:
                p = parse_h264_pps(n)
                parts.append('pps_id=%d %s' % (p['pps_id'],
                                               'CABAC' if p['cabac'] else 'CAVLC'))
        except VmsError:
            parts.append('nal tipo %d ilegível' % t)
    return ' | '.join(parts)
