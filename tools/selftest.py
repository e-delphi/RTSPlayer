"""Suíte de testes do formato e dos modelos, sem Delphi, sem câmera, sem servidor.

Roda em segundos e responde passou/falhou. Existe porque o `dcc` deste ambiente
não compila por linha de comando — então o que dá para automatizar é o que lê e
escreve arquivo, e é justamente onde os defeitos difíceis desta base moraram:
formato `.vms`, índice, colagem de segmentos, fragmento de mídia e ritmo.

Não cobre o código Delphi em si. Cobre o CONTRATO que ele tem de cumprir: as
mesmas contas, sobre os mesmos bytes.

  python selftest.py [-v]
"""

import io
import os
import shutil
import struct
import sys
import tempfile
import zlib

import vmslib
import genvms
import apimodel
import fragment
import pacemodel

VERBOSE = '-v' in sys.argv
FALHAS = []
PASSOU = 0


def check(nome, cond, detalhe=''):
    global PASSOU
    if cond:
        PASSOU += 1
        if VERBOSE:
            print('  ok   %s' % nome)
    else:
        FALHAS.append('%s%s' % (nome, (' — ' + detalhe) if detalhe else ''))
        print('  FALHA %s%s' % (nome, (' — ' + detalhe) if detalhe else ''))


def gerar(pasta, nome, **kw):
    """Chama o genvms como se fosse da linha de comando."""
    argv = [os.path.join(pasta, nome)]
    for k, v in kw.items():
        flag = '--' + k.replace('_', '-')
        argv += [flag] if v is True else [flag, str(v)]
    old, quieto = sys.argv, sys.stdout
    sys.argv = ['genvms.py'] + argv
    if not VERBOSE:
        sys.stdout = io.StringIO()   # o gerador fala; aqui só o resultado importa
    try:
        genvms.main()
    finally:
        sys.argv, sys.stdout = old, quieto
    return os.path.join(pasta, nome)


# --------------------------------------------------------------- formato

def teste_formato(pasta):
    print('formato .vms')
    p = gerar(pasta, 'basico.vms', blocos=8, defasagem=120)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    blocos = list(vmslib.iter_blocks(dados, h))

    check('header com crc válido', h.crc_ok)
    check('header declara a versão corrente', h.version == 1, 'veio v%d' % h.version)
    check('todos os blocos com crc válido', all(b.crc_ok for b in blocos))
    check('8 blocos lidos', len(blocos) == 8, 'vieram %d' % len(blocos))

    # âncora A/V: a defasagem gravada tem de voltar exatamente igual
    defs = {b.audio_anchor_ms - b.video_anchor_ms for b in blocos}
    check('âncora A/V preserva a defasagem', defs == {120}, 'achei %s' % defs)

    # payload não pode conter o CRC (o bug do PayloadLen 4 bytes maior)
    for b in blocos[:1]:
        fim = max((s_off + s_len) for s_off, s_len in
                  [(struct.unpack_from('<I', dados, b.offset + 28 + i * 18 + 10)[0],
                    struct.unpack_from('<I', dados, b.offset + 28 + i * 18 + 14)[0])
                   for i in range(len(b.samples))])
        idx = struct.unpack_from('<I', dados, b.offset + 24)[0]
        payload_len = b.size - 28 - idx - 4
        check('payload do bloco não engloba o crc', fim <= payload_len,
              'último sample termina em %d, payload tem %d' % (fim, payload_len))


def teste_ancora_nao_desloca_payload(pasta):
    """A âncora mora dentro da área de índice do bloco. Quem lê percorre
    sample_count entradas e acha o payload por index_size — então esses 20 bytes
    a mais não podem mudar nem o enquadramento nem um byte de mídia."""
    print('âncora A/V não desloca o payload')
    p3 = gerar(pasta, 'c3.vms', blocos=5, defasagem=80)
    p2 = gerar(pasta, 'c2.vms', blocos=5, sem_ancora=True)

    def leitor_cru(dados, header):
        o, out = header.size, []
        while o + 28 <= len(dados):
            if dados[o:o + 4] != b'BLK\x01':
                break
            size = struct.unpack_from('<I', dados, o + 4)[0]
            count = struct.unpack_from('<I', dados, o + 20)[0]
            idx = struct.unpack_from('<I', dados, o + 24)[0]
            p, payload = o + 28, o + 28 + idx
            bloco = []
            for _ in range(count):
                tid, flags = dados[p], dados[p + 1]
                pts = struct.unpack_from('<q', dados, p + 2)[0]
                off = struct.unpack_from('<I', dados, p + 10)[0]
                sz = struct.unpack_from('<I', dados, p + 14)[0]
                p += 18
                bloco.append((tid, flags, pts, dados[payload + off:payload + off + sz]))
            out.append(bloco)
            o += size
        return out

    d3 = open(p3, 'rb').read()
    h3 = vmslib.read_header(d3)
    cru = leitor_cru(d3, h3)
    novo = [[(s.track_id, s.flags, s.pts, s.data) for s in b.samples]
            for b in vmslib.iter_blocks(d3, h3)]
    check('quem ignora a âncora lê os mesmos samples', cru == novo)

    d2 = open(p2, 'rb').read()
    h2 = vmslib.read_header(d2)
    m3 = [s.data for b in vmslib.iter_blocks(d3, h3) for s in b.samples]
    m2 = [s.data for b in vmslib.iter_blocks(d2, h2) for s in b.samples]
    check('mídia é byte a byte igual com e sem âncora', m3 == m2)


def teste_indice(pasta):
    print('índice do rodapé (VIDX)')
    p = gerar(pasta, 'idx.vms', blocos=10)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    blocos = list(vmslib.iter_blocks(dados, h))
    rodape = vmslib.read_footer(dados)
    check('rodapé encontrado', rodape is not None)
    entradas = vmslib.read_block_index(dados, rodape)
    check('índice presente', entradas is not None and len(entradas) == 10)
    check('índice bate com a varredura', vmslib.check_index(blocos, entradas) == [])

    # índice mentiroso, com CRC refeito, tem de ser pego
    d = bytearray(dados)
    o = rodape.index_offset
    size = struct.unpack_from('<I', d, o + 4)[0]
    d[o + 12 + 16] ^= 0x01                       # inverte o flag de keyframe
    struct.pack_into('<I', d, o + size - 4, zlib.crc32(bytes(d[o:o + size - 4])))
    ent2 = vmslib.read_block_index(bytes(d), vmslib.read_footer(bytes(d)))
    check('índice mentiroso (com crc refeito) é detectado',
          vmslib.check_index(blocos, ent2) != [])

    # arquivo sem rodapé (gravação em curso): último bloco cortado fica de fora
    p = gerar(pasta, 'aberto.vms', blocos=6, truncado=True)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    check('arquivo em gravação: sem rodapé', vmslib.read_footer(dados) is None)
    check('arquivo em gravação: bloco cortado fica de fora',
          len(list(vmslib.iter_blocks(dados, h))) == 5)


def _varre_cauda(dados, de):
    """Imita o ScanBlocksFrom do TVmsReader: cabeçalho + índice de cada bloco,
    sem tocar no payload. Devolve as entradas de índice que ele produziria."""
    saida = []
    o = de
    while o + vmslib.BLOCK_HEADER_SIZE <= len(dados):
        if dados[o:o + 4] != vmslib.MAGIC_BLOCK:
            break
        size = struct.unpack_from('<I', dados, o + 4)[0]
        if size < vmslib.BLOCK_HEADER_SIZE or o + size > len(dados):
            break
        start = struct.unpack_from('<q', dados, o + 12)[0]
        count = struct.unpack_from('<I', dados, o + 20)[0]
        isize = struct.unpack_from('<I', dados, o + 24)[0]
        key = False
        base = o + vmslib.BLOCK_HEADER_SIZE
        for i in range(count):
            b = base + i * vmslib.INDEX_ENTRY_SIZE
            if b + 1 >= base + isize:
                break
            if dados[b] == 0 and (dados[b + 1] & 1):
                key = True
                break
        saida.append((o, start, 1 if key else 0))
        o += size
    return saida


def _indice_do_leitor(dados):
    """O índice que o EnsureIndex monta num arquivo SEM rodapé: o que a região
    commitou, mais a varredura da cauda. É este o caminho que substituiu a
    varredura do arquivo inteiro."""
    h = vmslib.read_header(dados)
    regiao = vmslib.read_region(dados, h)
    if not regiao or not regiao[2]:
        return _varre_cauda(dados, vmslib.first_block_offset(dados, h)), 'varredura inteira'
    ent = [(e.offset, e.start_unix_ms, 1 if e.keyframe else 0) for e in regiao[2]]
    ultimo = ent[-1][0]
    size = struct.unpack_from('<I', dados, ultimo + 4)[0]
    cauda = _varre_cauda(dados, ultimo + size)
    return ent + cauda, 'região(%d) + cauda(%d)' % (len(ent), len(cauda))


def teste_regiao_de_indice(pasta):
    print('índice vivo (VLIX): região reservada depois do header')
    p = gerar(pasta, 'reg.vms', blocos=60, regiao_kb=4)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    regiao = vmslib.read_region(dados, h)
    check('região achada logo depois do header', regiao is not None)
    check('capacidade combina com o tamanho reservado',
          regiao[0] == 4096 and regiao[1] == (4096 - vmslib.REGION_HEADER_SIZE) // 17)
    blocos = list(vmslib.iter_blocks(dados, h))
    check('a mídia começa DEPOIS da região',
          blocos[0].offset == h.size + regiao[0], 'primeiro bloco em %d' % blocos[0].offset)
    check('os 60 blocos continuam sendo lidos em sequência', len(blocos) == 60)
    check('região fechada descreve o arquivo inteiro', len(regiao[2]) == 60)
    vidx = vmslib.read_block_index(dados)
    check('região e VIDX do rodapé dizem a mesma coisa',
          [(e.offset, e.start_unix_ms, e.keyframe) for e in vidx] ==
          [(e.offset, e.start_unix_ms, e.keyframe) for e in regiao[2]])
    check('região confere com os blocos do arquivo',
          vmslib.check_index(blocos, regiao[2]) == [])

    # o caso que motivou tudo: arquivo em gravação, sem rodapé
    p = gerar(pasta, 'reg_aberto.vms', blocos=60, regiao_kb=4, truncado=True)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    inteira = _varre_cauda(dados, vmslib.first_block_offset(dados, h))
    obtido, como = _indice_do_leitor(dados)
    check('gravação em curso: sem rodapé', vmslib.read_footer(dados) is None)
    check('região + cauda == varredura inteira', obtido == inteira, como)
    check('e a região cobriu a maior parte sozinha',
          0 < len(vmslib.read_region(dados, h)[2]) < len(inteira))

    # região cheia: para de commitar na capacidade e ninguém perde bloco
    p = gerar(pasta, 'reg_cheia.vms', blocos=80, regiao_kb=1)   # 1 KB = 57 entradas
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    regiao = vmslib.read_region(dados, h)
    check('região cheia commita até a capacidade e para',
          len(regiao[2]) == regiao[1], '%d de %d' % (len(regiao[2]), regiao[1]))
    obtido, como = _indice_do_leitor(dados)
    check('estourando a região, a cauda cobre o resto',
          obtido == _varre_cauda(dados, vmslib.first_block_offset(dados, h)), como)

    # queda no meio do commit: o slot novo fica quebrado, o anterior salva
    d = bytearray(open(gerar(pasta, 'reg_torto.vms', blocos=60, regiao_kb=4,
                             truncado=True), 'rb').read())
    h = vmslib.read_header(bytes(d))
    antes = len(vmslib.read_region(bytes(d), h)[2])
    geracoes = [struct.unpack_from('<I', d, h.size + o + 4)[0]
                for o in vmslib.REGION_COMMIT_OFS]
    novo = vmslib.REGION_COMMIT_OFS[0 if geracoes[0] > geracoes[1] else 1]
    d[h.size + novo + 8] ^= 0xFF                 # estraga o crc do slot valendo
    depois = vmslib.read_region(bytes(d), h)[2]
    check('slot de commit quebrado cai no anterior', 0 < len(depois) < antes,
          '%d -> %d entradas' % (antes, len(depois)))
    obtido, como = _indice_do_leitor(bytes(d))
    check('e o índice final continua igual à varredura inteira',
          obtido == _varre_cauda(bytes(d), vmslib.first_block_offset(bytes(d), h)), como)

    # fragmento servido pela API: header + blocos, sem região
    p = gerar(pasta, 'reg_frag.vms', blocos=4)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    check('fragmento da API não tem região', vmslib.read_region(dados, h) is None)
    check('e nele a mídia começa em HeaderSize',
          vmslib.first_block_offset(dados, h) == h.size)
    check('fragmento sem região continua sendo lido',
          len(list(vmslib.iter_blocks(dados, h))) == 4)


ASSUMIDO_MS = 2000      # mesma estimativa do servidor para o último bloco


def _resumo_caro(dados):
    """Como o inventário era feito: monta o índice e olha as pontas."""
    h = vmslib.read_header(dados)
    rodape = vmslib.read_footer(dados)
    entradas = vmslib.read_block_index(dados, rodape) if rodape else None
    if entradas is None:
        entradas = [vmslib.IndexEntry(o, ms, f)
                    for o, ms, f in _indice_do_leitor(dados)[0]]
    if not entradas:
        return None
    fim = entradas[-1].start_unix_ms + ASSUMIDO_MS
    if rodape and rodape.duration_ms > 0:
        fim = h.creation_unix_ms + rodape.duration_ms + ASSUMIDO_MS
    return dict(inicio=entradas[0].start_unix_ms, fim=fim, blocos=len(entradas))


def _resumo_barato(dados):
    """Como o inventário passou a ser feito: rodapé ou região, sem índice."""
    h = vmslib.read_header(dados)
    o = vmslib.first_block_offset(dados, h)
    if dados[o:o + 4] != vmslib.MAGIC_BLOCK:
        return None
    inicio = struct.unpack_from('<q', dados, o + 12)[0]     # 1 leitura curta
    rodape = vmslib.read_footer(dados)
    if rodape is not None:
        return dict(inicio=inicio,
                    fim=h.creation_unix_ms + rodape.duration_ms + ASSUMIDO_MS,
                    blocos=rodape.total_blocks)
    regiao = vmslib.read_region(dados, h)
    if regiao and regiao[2]:
        return dict(inicio=regiao[2][0].start_unix_ms,
                    fim=regiao[2][-1].start_unix_ms + ASSUMIDO_MS,
                    blocos=len(regiao[2]))
    return None     # cai na varredura, como o ReadInfo faz


def teste_resumo_do_inventario(pasta):
    print('resumo de arquivo sem montar índice')
    # fechado: o resumo barato tem de bater EXATAMENTE com o caro
    dados = open(gerar(pasta, 'inv_fechado.vms', blocos=40, regiao_kb=4), 'rb').read()
    caro, barato = _resumo_caro(dados), _resumo_barato(dados)
    check('arquivo fechado: mesmo início', caro['inicio'] == barato['inicio'],
          '%d vs %d' % (caro['inicio'], barato['inicio']))
    check('arquivo fechado: mesmo fim', caro['fim'] == barato['fim'],
          '%d vs %d' % (caro['fim'], barato['fim']))
    check('arquivo fechado: mesma contagem de blocos',
          caro['blocos'] == barato['blocos'])

    # em gravação: início exato; fim atrasado no máximo um commit, nunca à frente
    dados = open(gerar(pasta, 'inv_aberto.vms', blocos=60, regiao_kb=4,
                       truncado=True), 'rb').read()
    caro, barato = _resumo_caro(dados), _resumo_barato(dados)
    check('em gravação: início exato', caro['inicio'] == barato['inicio'])
    check('em gravação: fim nunca passa do real', barato['fim'] <= caro['fim'])
    atraso = caro['fim'] - barato['fim']
    check('em gravação: fim atrasado no máximo um commit',
          atraso <= genvms.REGION_COMMIT_EVERY * ASSUMIDO_MS,
          '%d ms de atraso' % atraso)
    check('em gravação: contagem nunca passa do real',
          0 < barato['blocos'] <= caro['blocos'])

    # arquivo recém-aberto, antes do primeiro commit: o resumo barato desiste e
    # quem chamou varre — que é barato, porque o arquivo é curto
    dados = open(gerar(pasta, 'inv_novo.vms', blocos=3, regiao_kb=4,
                       truncado=True), 'rb').read()
    check('antes do primeiro commit, o resumo barato devolve nada',
          _resumo_barato(dados) is None)
    check('e a varredura ainda descreve o arquivo',
          _resumo_caro(dados)['blocos'] == 2)


def teste_crc(pasta):
    print('crc de bloco')
    p = gerar(pasta, 'crc.vms', blocos=4)
    d = bytearray(open(p, 'rb').read())
    h = vmslib.read_header(bytes(d))
    blocos = list(vmslib.iter_blocks(bytes(d), h))
    alvo = blocos[2]
    d[alvo.offset + alvo.size - 10] ^= 0xFF      # um byte no payload
    blocos2 = list(vmslib.iter_blocks(bytes(d), h))
    ruins = [b.seq for b in blocos2 if not b.crc_ok]
    check('um byte trocado é acusado pelo crc', ruins == [alvo.seq],
          'blocos acusados: %s' % ruins)
    check('os outros blocos continuam válidos', len(blocos2) == 4)


# ------------------------------------------------------------------ api

def teste_segmentos(pasta):
    """Colagem: reconexão de câmera vira uma faixa só; buraco de verdade fica."""
    print('colagem de segmentos')
    rec = os.path.join(pasta, 'rec')
    # uma pasta por câmera, como o servidor grava
    os.makedirs(os.path.join(rec, 'cam'), exist_ok=True)
    base = 1786846200000
    # três arquivos colados (500 ms entre eles) + um depois de 20 min
    for off in (0, 24500, 49000, 1273000):
        gerar(os.path.join(rec, 'cam'), 'cam_%d.vms' % off, blocos=12,
              inicio=base + off)

    arquivos = [apimodel.file_info(p) for p in apimodel.camera_files(rec, 'cam')]
    check('4 arquivos inventariados', len(arquivos) == 4)

    colado = apimodel.merge(arquivos, apimodel.GAP_MS)
    check('reconexões viram 2 faixas', len(colado) == 2,
          'vieram %d' % len(colado))

    exato = apimodel.merge(arquivos, 0)
    check('sem folga, cada arquivo é uma faixa', len(exato) == 4,
          'vieram %d' % len(exato))

    gravado = sum(r['endMs'] - r['startMs'] for r in exato)
    span = colado[-1]['endMs'] - colado[0]['startMs']
    check('tempo gravado é menor que o intervalo coberto', gravado < span)


def teste_fragmento(pasta):
    """A caminhada de /api/media: entra por keyframe, atravessa arquivo e
    sinaliza a emenda."""
    print('fragmento de mídia')
    rec = os.path.join(pasta, 'rec2')
    os.makedirs(os.path.join(rec, 'cam'), exist_ok=True)
    base = 1786846200000
    for off in (0, 24500):
        gerar(os.path.join(rec, 'cam'), 'cam_%d.vms' % off, blocos=12,
              inicio=base + off)

    arquivos = fragment.scan(rec, 'cam')
    check('2 arquivos para tocar', len(arquivos) == 2)

    r = fragment.fetch(arquivos, from_ms=base + 15000, blocks=5)
    check('seek entra num bloco com keyframe', r['keyframe'],
          'entrou no bloco %d sem keyframe' % r['first'])
    check('seek recua (não avança) do instante pedido', r['start'] <= base + 15000)
    check('primeiro pedaço é descontinuidade', r['disc'])

    vistos, emendas, saltos = 0, 0, 0
    while r['cursor'] and vistos < 12:
        r = fragment.fetch(arquivos, cursor=r['cursor'], blocks=5)
        vistos += 1
        emendas += int(r['disc'])
        saltos += int(r['gap'] > 0)
    check('a caminhada atravessa para o segundo arquivo', emendas >= 1,
          'nenhuma emenda sinalizada em %d pedaços' % vistos)
    check('o buraco entre arquivos é sinalizado', saltos >= 1)


# ---------------------------------------------------------------- ritmo

def teste_ritmo(pasta):
    print('ritmo do playback')
    p = gerar(pasta, 'pace.vms', blocos=10)
    um = pacemodel.simulate(p, 1.0, 0)
    check('em 1x o relógio acompanha a mídia',
          abs(um['elapsed_s'] - um['media_s']) < 0.5,
          'mídia %.1fs em %.1fs' % (um['media_s'], um['elapsed_s']))
    check('em 1x o áudio é entregue', um['audio'] > 0)
    check('uma âncora só (sem re-ancoragem espúria)', um['anchors'] == 1,
          '%d âncoras' % um['anchors'])

    dois = pacemodel.simulate(p, 2.0, 0)
    check('em 2x gasta metade do relógio',
          abs(dois['elapsed_s'] - um['elapsed_s'] / 2) < 0.5,
          '%.1fs contra %.1fs' % (dois['elapsed_s'], um['elapsed_s'] / 2))
    check('fora de 1x o áudio não sai', dois['audio'] == 0)

    seek = pacemodel.simulate(p, 1.0, 8000)
    check('o trecho anterior ao alvo sai sem ritmo', seek['burst'] > 0)
    check('o seek encurta o tempo de relógio', seek['elapsed_s'] < um['elapsed_s'])


def main():
    pasta = tempfile.mkdtemp(prefix='vms_selftest_')
    try:
        teste_formato(pasta)
        teste_ancora_nao_desloca_payload(pasta)
        teste_indice(pasta)
        teste_regiao_de_indice(pasta)
        teste_resumo_do_inventario(pasta)
        teste_crc(pasta)
        teste_segmentos(pasta)
        teste_fragmento(pasta)
        teste_ritmo(pasta)
    finally:
        shutil.rmtree(pasta, ignore_errors=True)

    print()
    if FALHAS:
        print('FALHOU: %d de %d' % (len(FALHAS), len(FALHAS) + PASSOU))
        for f in FALHAS:
            print('  - %s' % f)
        return 1
    print('passou: %d verificações' % PASSOU)
    return 0


if __name__ == '__main__':
    sys.exit(main())
