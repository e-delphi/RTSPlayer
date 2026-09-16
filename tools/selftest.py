"""Suíte de testes do formato e dos modelos, sem Delphi, sem câmera, sem servidor.

Roda em segundos e responde passou/falhou. Existe porque o `dcc` deste ambiente
não compila por linha de comando — então o que dá para automatizar é o que lê e
escreve arquivo, e é justamente onde os defeitos difíceis desta base moraram:
formato `.vms`, índice, colagem de segmentos, fragmento de mídia e ritmo.

Não cobre o código Delphi em si. Cobre o CONTRATO que ele tem de cumprir: as
mesmas contas, sobre os mesmos bytes.

  python selftest.py [-v]
"""

import base64
import hashlib
import io
import os
import re
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
import anchormodel
import eventlib

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


def _indice_do_leitor(caminho):
    """O índice que o EnsureIndex monta num arquivo SEM rodapé: o que o sidecar
    registrou, mais a varredura da cauda a partir do valid_up_to dele. É este o
    caminho que substituiu a varredura do arquivo inteiro."""
    dados = open(caminho, 'rb').read()
    h = vmslib.read_header(dados)
    try:
        sc = vmslib.read_sidecar(caminho, h.creation_unix_ms)
    except vmslib.VmsError:
        sc = None
    if not sc:
        return _varre_cauda(dados, h.size), 'varredura inteira'
    ent = [(e.offset, e.start_unix_ms, 1 if e.keyframe else 0) for e in sc[0]]
    de = sc[1]
    if de > len(dados):
        # sidecar adiante da mídia: aproveita o prefixo que ainda tem arquivo
        # por baixo, e recomeça a varredura na última entrada descartada
        corte = 0
        while corte < len(ent) and ent[corte][0] < len(dados):
            corte += 1
        if corte > 0:
            corte -= 1
        if corte <= 0:
            return _varre_cauda(dados, h.size), 'varredura inteira'
        de, ent = ent[corte][0], ent[:corte]
    cauda = _varre_cauda(dados, de)
    return ent + cauda, 'sidecar(%d) + cauda(%d)' % (len(ent), len(cauda))


def teste_sidecar(pasta):
    print('índice do arquivo em gravação (.vms.idx)')
    # o caso que motivou tudo: arquivo em gravação, sem rodapé
    p = gerar(pasta, 'sc_aberto.vms', blocos=60, sidecar=True, truncado=True)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    check('gravação em curso: sem rodapé', vmslib.read_footer(dados) is None)
    check('e com sidecar ao lado', os.path.exists(p + '.idx'))
    entradas, valid = vmslib.read_sidecar(p, h.creation_unix_ms)
    inteira = _varre_cauda(dados, h.size)
    check('sidecar confere com os blocos que ele cobre',
          vmslib.check_index(list(vmslib.iter_blocks(dados, h))[:len(entradas)],
                             entradas) == [])
    obtido, como = _indice_do_leitor(p)
    check('sidecar + cauda == varredura inteira', obtido == inteira, como)
    check('e o sidecar cobriu a maior parte sozinho',
          0 < len(entradas) < len(inteira),
          '%d de %d blocos' % (len(entradas), len(inteira)))
    check('valid_up_to cai exatamente no começo de um bloco',
          valid in [b[0] for b in inteira])

    # fechou direito: o VIDX foi para o fim do .vms e o sidecar sumiu
    p = gerar(pasta, 'sc_fechado.vms', blocos=40, sidecar=True)
    dados = open(p, 'rb').read()
    check('gravação fechada: sidecar apagado', not os.path.exists(p + '.idx'))
    entradas = vmslib.read_block_index(dados)
    check('e o índice completo ficou no fim do .vms',
          entradas is not None and len(entradas) == 40)
    check('índice do rodapé confere com a varredura',
          vmslib.check_index(list(vmslib.iter_blocks(dados, h)), entradas) == [])

    # queda no meio da escrita de um lote: vale o que veio antes dele
    p = gerar(pasta, 'sc_torto.vms', blocos=60, sidecar=True, truncado=True)
    bruto = bytearray(open(p + '.idx', 'rb').read())
    antes = len(vmslib.read_sidecar(p, vmslib.read_header(
        open(p, 'rb').read()).creation_unix_ms)[0])
    bruto[-8] ^= 0xFF                     # estraga a última entrada do último lote
    open(p + '.idx', 'wb').write(bruto)
    depois = vmslib.read_sidecar(p, vmslib.read_header(
        open(p, 'rb').read()).creation_unix_ms)
    check('lote com crc quebrado é descartado',
          depois is not None and len(depois[0]) < antes,
          '%d -> %d entradas' % (antes, len(depois[0])))
    obtido, como = _indice_do_leitor(p)
    check('e o índice final continua igual à varredura inteira',
          obtido == _varre_cauda(open(p, 'rb').read(),
                                 vmslib.read_header(open(p, 'rb').read()).size), como)

    # lote cortado no meio (o que a gravação em curso deixa no fim do arquivo)
    p = gerar(pasta, 'sc_cortado.vms', blocos=60, sidecar=True, truncado=True)
    bruto = open(p + '.idx', 'rb').read()
    open(p + '.idx', 'wb').write(bruto[:-30])
    obtido, como = _indice_do_leitor(p)
    check('lote cortado no fim não atrapalha',
          obtido == _varre_cauda(open(p, 'rb').read(),
                                 vmslib.read_header(open(p, 'rb').read()).size), como)

    # sidecar de OUTRA gravação não pode ser usado
    p2 = gerar(pasta, 'sc_outro.vms', blocos=20, sidecar=True, truncado=True,
               inicio=1755000000000)
    p3 = gerar(pasta, 'sc_alvo.vms', blocos=20, sidecar=True, truncado=True,
               inicio=1755229501000)
    import shutil
    shutil.copyfile(p2 + '.idx', p3 + '.idx')
    alvo = vmslib.read_header(open(p3, 'rb').read())
    check('sidecar de outra gravação é ignorado',
          vmslib.read_sidecar(p3, alvo.creation_unix_ms) is None)

    # queda de energia levando a cauda da MÍDIA e não a do índice: os dois
    # arquivos não vão para o disco no mesmo instante
    p = gerar(pasta, 'sc_adiante.vms', blocos=60, sidecar=True, truncado=True)
    bruto = open(p, 'rb').read()
    entradas = vmslib.read_sidecar(p, vmslib.read_header(bruto).creation_unix_ms)[0]
    # corta a mídia no meio do trecho que o sidecar já registrou
    corte = entradas[len(entradas) // 2].offset + 40
    open(p, 'wb').write(bruto[:corte])
    obtido, como = _indice_do_leitor(p)
    esperado = _varre_cauda(open(p, 'rb').read(), vmslib.read_header(bruto).size)
    check('índice adiante da mídia: aproveita o prefixo, não varre tudo',
          'sidecar(' in como, como)
    check('e o resultado é o mesmo da varredura inteira', obtido == esperado, como)
    check('nenhum bloco duplicado ou fora do arquivo',
          len(obtido) == len(set(b[0] for b in obtido)) and
          all(b[0] < corte for b in obtido))

    # fragmento da API: header + blocos, sem sidecar nenhum
    p = gerar(pasta, 'sc_frag.vms', blocos=4)
    dados = open(p, 'rb').read()
    h = vmslib.read_header(dados)
    check('fragmento da API não tem sidecar', not os.path.exists(p + '.idx'))
    check('e a mídia começa em HeaderSize',
          list(vmslib.iter_blocks(dados, h))[0].offset == h.size)


def _finaliza_orfao(caminho):
    """Modelo do Vms.Server.Repair: monta o índice (sidecar + cauda), corta a
    cauda que a queda deixou pela metade e escreve VIDX + rodapé no fim do .vms.
    Devolve False quando não há o que fazer."""
    dados = open(caminho, 'rb').read()
    h = vmslib.read_header(dados)
    if not os.path.exists(caminho + '.idx'):
        return False
    if vmslib.read_footer(dados) is not None:
        os.remove(caminho + '.idx')      # sobra de um fechamento que deu certo
        return False
    entradas, _ = _indice_do_leitor(caminho)
    if not entradas:
        os.remove(caminho + '.idx')
        return False

    ultimo = entradas[-1][0]
    fim_midia = ultimo + struct.unpack_from('<I', dados, ultimo + 4)[0]
    corpo = genvms.MAGIC_INDEX + genvms.u32(12 + len(entradas) * 17 + 4) \
        + genvms.u32(len(entradas))
    for off, ms, flags in entradas:
        corpo += genvms.i64(off) + genvms.i64(ms) + bytes([flags])
    chunk = corpo + genvms.u32(zlib.crc32(corpo))

    duracao = max(0, entradas[-1][1] - h.creation_unix_ms)
    foot = (vmslib.MAGIC_FOOTER + genvms.u32(len(entradas)) + genvms.i64(duracao)
            + genvms.u64(ultimo) + genvms.u64(fim_midia) + genvms.u32(len(entradas)))
    rodape = foot + genvms.u32(zlib.crc32(foot))

    with open(caminho, 'wb') as f:
        f.write(dados[:fim_midia] + chunk + rodape)
    os.remove(caminho + '.idx')
    return True


def teste_finaliza_gravacao_aberta(pasta):
    print('gravação que ficou aberta é fechada na subida do servidor')
    p = gerar(pasta, 'rep_orfao.vms', blocos=60, sidecar=True, truncado=True)
    antes = open(p, 'rb').read()
    esperado = _varre_cauda(antes, vmslib.read_header(antes).size)
    tamanho_antes = len(antes)

    check('antes: sem rodapé e com sidecar',
          vmslib.read_footer(antes) is None and os.path.exists(p + '.idx'))
    check('finalizou', _finaliza_orfao(p) is True)

    dados = open(p, 'rb').read()
    rodape = vmslib.read_footer(dados)
    check('depois: tem rodapé', rodape is not None)
    check('e o sidecar sumiu', not os.path.exists(p + '.idx'))
    entradas = vmslib.read_block_index(dados, rodape)
    check('índice no fim do .vms == o que a varredura acha',
          [(e.offset, e.start_unix_ms, 1 if e.keyframe else 0) for e in entradas]
          == esperado)
    check('índice confere com os blocos, entrada por entrada',
          vmslib.check_index(list(vmslib.iter_blocks(dados, vmslib.read_header(dados))),
                             entradas) == [])
    check('o rodapé conta os mesmos blocos', rodape.total_blocks == len(esperado))
    check('a cauda incompleta foi descartada',
          rodape.index_offset == esperado[-1][0] +
          struct.unpack_from('<I', dados, esperado[-1][0] + 4)[0],
          'índice começa em %d' % rodape.index_offset)
    check('e o arquivo encolheu (o pedaço cortado saiu)',
          rodape.index_offset < tamanho_antes)

    # agora ele é indistinguível de uma gravação que fechou direito
    caro, barato = _resumo_caro(p), _resumo_barato(p)
    check('depois de fechado, o resumo barato bate com o caro',
          caro == barato, '%s vs %s' % (caro, barato))

    # arquivo que JÁ tinha rodapé: o .vms não pode ser tocado, só a sobra sai
    p = gerar(pasta, 'rep_fechado.vms', blocos=20, sidecar=True)
    open(p + '.idx', 'wb').write(b'sobra que nao deveria estar aqui')
    antes = open(p, 'rb').read()
    check('arquivo já fechado não é finalizado de novo', _finaliza_orfao(p) is False)
    check('o .vms fica byte a byte igual', open(p, 'rb').read() == antes)
    check('e a sobra de sidecar é removida', not os.path.exists(p + '.idx'))


ASSUMIDO_MS = 2000      # mesma estimativa do servidor para o último bloco


def _resumo_caro(caminho):
    """Como o inventário era feito: monta o índice e olha as pontas."""
    dados = open(caminho, 'rb').read()
    h = vmslib.read_header(dados)
    rodape = vmslib.read_footer(dados)
    entradas = vmslib.read_block_index(dados, rodape) if rodape else None
    if entradas is None:
        entradas = [vmslib.IndexEntry(o, ms, f)
                    for o, ms, f in _indice_do_leitor(caminho)[0]]
    if not entradas:
        return None
    fim = entradas[-1].start_unix_ms + ASSUMIDO_MS
    if rodape and rodape.duration_ms > 0:
        fim = h.creation_unix_ms + rodape.duration_ms + ASSUMIDO_MS
    return dict(inicio=entradas[0].start_unix_ms, fim=fim, blocos=len(entradas))


def _resumo_barato(caminho):
    """Como o inventário passou a ser feito: rodapé ou sidecar, sem índice."""
    dados = open(caminho, 'rb').read()
    h = vmslib.read_header(dados)
    o = h.size
    if dados[o:o + 4] != vmslib.MAGIC_BLOCK:
        return None
    inicio = struct.unpack_from('<q', dados, o + 12)[0]     # 1 leitura curta
    rodape = vmslib.read_footer(dados)
    if rodape is not None:
        return dict(inicio=inicio,
                    fim=h.creation_unix_ms + rodape.duration_ms + ASSUMIDO_MS,
                    blocos=rodape.total_blocks)
    sc = vmslib.read_sidecar(caminho, h.creation_unix_ms)
    if sc:
        return dict(inicio=sc[0][0].start_unix_ms,
                    fim=sc[0][-1].start_unix_ms + ASSUMIDO_MS,
                    blocos=len(sc[0]))
    return None     # cai na varredura, como o ReadInfo faz


def teste_resumo_do_inventario(pasta):
    print('resumo de arquivo sem montar índice')
    # fechado: o resumo barato tem de bater EXATAMENTE com o caro
    p = gerar(pasta, 'inv_fechado.vms', blocos=40, sidecar=True)
    caro, barato = _resumo_caro(p), _resumo_barato(p)
    check('arquivo fechado: mesmo início', caro['inicio'] == barato['inicio'],
          '%d vs %d' % (caro['inicio'], barato['inicio']))
    check('arquivo fechado: mesmo fim', caro['fim'] == barato['fim'],
          '%d vs %d' % (caro['fim'], barato['fim']))
    check('arquivo fechado: mesma contagem de blocos',
          caro['blocos'] == barato['blocos'])

    # em gravação: início exato; fim atrasado no máximo um lote, nunca à frente
    p = gerar(pasta, 'inv_aberto.vms', blocos=60, sidecar=True, truncado=True)
    caro, barato = _resumo_caro(p), _resumo_barato(p)
    check('em gravação: início exato', caro['inicio'] == barato['inicio'])
    check('em gravação: fim nunca passa do real', barato['fim'] <= caro['fim'])
    atraso = caro['fim'] - barato['fim']
    check('em gravação: fim atrasado no máximo um lote',
          atraso <= genvms.SIDECAR_BATCH_BLOCKS * ASSUMIDO_MS,
          '%d ms de atraso' % atraso)
    check('em gravação: contagem nunca passa do real',
          0 < barato['blocos'] <= caro['blocos'])

    # arquivo recém-aberto, antes do primeiro lote: o resumo barato desiste e
    # quem chamou varre — que é barato, porque o arquivo é curto
    p = gerar(pasta, 'inv_novo.vms', blocos=3, sidecar=True, truncado=True)
    check('antes do primeiro lote, o resumo barato devolve nada',
          _resumo_barato(p) is None)
    check('e a varredura ainda descreve o arquivo',
          _resumo_caro(p)['blocos'] == 2)


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

def teste_varredura(pasta):
    print('varredura: o servidor entrega só o que vai ser exibido')
    rec = os.path.join(pasta, 'rec3')
    os.makedirs(os.path.join(rec, 'cam'), exist_ok=True)
    gerar(os.path.join(rec, 'cam'), 'cam_0.vms', blocos=30, inicio=0)
    arquivos = fragment.scan(rec, 'cam')
    ts = arquivos[0]['header'].video.timescale or 90000

    inteiro = fragment.fetch(arquivos, from_ms=0, blocks=30)
    varrido = fragment.fetch(arquivos, from_ms=0, blocks=30, step_ms=6000)

    # 1) o fragmento decimado continua sendo um .vms que abre no mesmo leitor
    h = vmslib.read_header(varrido['data'])
    blocos = list(vmslib.iter_blocks(varrido['data'], h))
    check('fragmento da varredura abre no leitor normal', len(blocos) > 0)
    check('todo bloco entregue tem crc válido', all(b.crc_ok for b in blocos))

    amostras = [s for b in blocos for s in b.samples]
    check('só vídeo: o áudio não atravessa a rede',
          all(s.is_video for s in amostras))
    check('só keyframe: quadro P precisa de referência que não vai junto',
          all(s.keyframe for s in amostras))

    # 2) o horário de cada quadro sobrevive à remontagem do bloco — é o que
    #    quebraria se a âncora não fosse recalculada
    def horarios(frag):
        hh = vmslib.read_header(frag['data'])
        tsc = hh.video.timescale or 90000
        out = []
        for b in vmslib.iter_blocks(frag['data'], hh):
            base = next(s.pts for s in b.samples if s.is_video)
            anc = b.video_anchor_ms or b.start_unix_ms
            for smp in b.samples:
                if smp.is_video and smp.keyframe:
                    out.append(anc + (smp.pts - base) * 1000 // tsc)
        return out

    esperado = horarios(inteiro)
    obtido = horarios(varrido)
    check('os quadros entregues são um subconjunto dos originais',
          set(obtido).issubset(set(esperado)),
          '%s vs %s' % (obtido[:4], esperado[:4]))
    check('e cada um mantém o horário que tinha na gravação',
          obtido == [t for t in esperado if t in set(obtido)])

    # 3) o espaçamento é respeitado ATRAVÉS dos blocos, não só dentro de cada um
    faltas = [b - a for a, b in zip(obtido, obtido[1:]) if b - a < 6000]
    check('nenhum par entregue mais junto que o passo pedido', faltas == [],
          'intervalos curtos: %s' % faltas[:4])

    # 4) e o ponto de tudo isto: rede
    check('a varredura carrega uma fração dos bytes',
          len(varrido['data']) * 4 < len(inteiro['data']),
          '%d B contra %d B' % (len(varrido['data']), len(inteiro['data'])))

    # 5) passo maior entrega menos; passo zero entrega tudo, como antes
    esparso = fragment.fetch(arquivos, from_ms=0, blocks=30, step_ms=20000)
    check('passo maior entrega menos quadros',
          len(horarios(esparso)) < len(obtido))
    check('sem passo, o fragmento é idêntico ao de antes',
          fragment.fetch(arquivos, from_ms=0, blocks=30)['data'] == inteiro['data'])


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


# ------------------------------------------------- eventos da analise


def teste_eventos_formato(pasta):
    print('formato .vev (eventos da análise)')
    dia = 1755950000000
    evs = [
        eventlib.build_record(dia, dia + 4000, eventlib.KIND_MOTION, 'movimento',
                              score=0.08, count=1, box=(0.1, 0.2, 0.4, 0.9)),
        eventlib.build_record(dia + 10000, dia + 22000, eventlib.KIND_OBJECT,
                              'person', score=0.87, count=3,
                              box=(0.0, 0.0, 1.0, 1.0)),
    ]
    dados = eventlib.build_header(dia) + b''.join(evs)

    lidos = eventlib.read_file(dados)
    check('cabeçalho .vev com crc válido', lidos is not None)
    check('dois eventos lidos', len(lidos) == 2, 'vieram %d' % len(lidos))
    check('rótulo sobrevive à ida e volta', lidos[1]['name'] == 'person')
    check('contagem sobrevive', lidos[1]['count'] == 3)
    check('score volta com erro menor que 0,01%',
          abs(lidos[1]['score'] - 0.87) < 0.0001,
          'voltou %.6f' % lidos[1]['score'])
    check('caixa 0..1 volta dentro de 1/65535',
          max(abs(a - b) for a, b in zip(lidos[0]['box'], (0.1, 0.2, 0.4, 0.9)))
          < 1.0 / 65535,
          'voltou %s' % (lidos[0]['box'],))
    check('caixa cheia continua cheia', lidos[1]['box'] == (0.0, 0.0, 1.0, 1.0))

    # queda de energia no meio de um append: sobra um rabo de tamanho errado
    truncado = dados[:-20]
    lidos = eventlib.read_file(truncado)
    check('rabo truncado sai de fora, o resto fica',
          len(lidos) == 1 and lidos[0]['name'] == 'movimento',
          'vieram %d' % len(lidos))

    # um registro corrompido nao leva os vizinhos junto
    corrompido = bytearray(dados)
    corrompido[eventlib.HEADER_SIZE + 5] ^= 0xFF
    lidos = eventlib.read_file(bytes(corrompido))
    check('registro com crc quebrado é descartado sozinho',
          len(lidos) == 1 and lidos[0]['name'] == 'person',
          'vieram %d' % len(lidos))

    # cabecalho corrompido invalida o arquivo inteiro: nao da para confiar nem
    # no tamanho de registro que ele declara
    ruim = bytearray(dados)
    ruim[10] ^= 0xFF
    check('cabeçalho corrompido rejeita o arquivo',
          eventlib.read_file(bytes(ruim)) is None)

    # rotulo mais longo que o campo e truncado, e nao corrompe o registro
    longo = eventlib.build_header(dia) + eventlib.build_record(
        dia, dia, eventlib.KIND_OBJECT, 'x' * 60)
    lidos = eventlib.read_file(longo)
    check('rótulo longo demais é truncado, não quebra o registro',
          len(lidos) == 1 and len(lidos[0]['name']) == eventlib.NAME_SIZE,
          'veio %r' % (lidos and lidos[0]['name']))

    check('todo registro tem exatamente %d bytes' % eventlib.RECORD_SIZE,
          all(len(e) == eventlib.RECORD_SIZE for e in evs))
    check('o arquivo é cabeçalho + n registros, sem sobra',
          (len(dados) - eventlib.HEADER_SIZE) % eventlib.RECORD_SIZE == 0)


def teste_eventos_consulta(pasta):
    print('consulta de eventos por janela')
    base = 1755950000000
    evs = [
        {'start_ms': base - 120000, 'end_ms': base + 60000, 'kind': 0,
         'name': 'movimento', 'score': 0.05},
        {'start_ms': base + 10000, 'end_ms': base + 12000, 'kind': 1,
         'name': 'person', 'score': 0.9},
        {'start_ms': base + 900000, 'end_ms': base + 901000, 'kind': 1,
         'name': 'car', 'score': 0.4},
    ]
    janela = eventlib.query(evs, base, base + 60000)
    check('evento que COMEÇOU antes da janela entra se ainda estava em curso',
          any(e['name'] == 'movimento' for e in janela))
    check('evento fora da janela fica de fora',
          not any(e['name'] == 'car' for e in janela))
    check('resultado vem em ordem de início',
          [e['start_ms'] for e in janela] == sorted(e['start_ms'] for e in janela))
    check('filtro por tipo isola os objetos',
          [e['name'] for e in eventlib.query(evs, base, base + 60000, kind=1)]
          == ['person'])
    check('filtro por rótulo é insensível a maiúscula',
          len(eventlib.query(evs, base, base + 60000, name='PERSON')) == 1)
    check('limiar de confiança corta o que está abaixo',
          [e['name'] for e in eventlib.query(evs, base, base + 1000000,
                                             min_score=0.5)] == ['person'])


def teste_movimento(pasta):
    print('detecção de movimento')
    W, H = 160, 90
    m = eventlib.Motion()
    fundo = eventlib.gray_frame(W, H, 100)

    r = m.feed(1000, fundo, W, H)
    check('primeiro quadro não gera evento (não há com o que comparar)',
          not r['moved'] and not r['scene'])

    r = m.feed(3000, eventlib.gray_frame(W, H, 100), W, H)
    check('cena parada não acusa movimento', not r['moved'],
          'score %.4f' % r['score'])

    # um vulto atravessando
    vulto = eventlib.gray_frame(W, H, 100)
    eventlib.paint(vulto, W, H, 60, 30, 80, 70, 220)
    r = m.feed(5000, vulto, W, H)
    check('um vulto na cena acusa movimento', r['moved'],
          'score %.4f' % r['score'])
    check('a caixa cerca o vulto, e não a tela inteira',
          r['box'] is not None and r['box'][0] > 0.25 and r['box'][2] < 0.75,
          'caixa %s' % (r['box'],))

    # luz acesa: o quadro inteiro muda de nivel
    m2 = eventlib.Motion()
    m2.feed(1000, eventlib.gray_frame(W, H, 60), W, H)
    r = m2.feed(3000, eventlib.gray_frame(W, H, 200), W, H)
    check('luz acesa é CENA NOVA, não movimento',
          r['scene'] and not r['moved'], 'score %.4f' % r['score'])
    r = m2.feed(5000, eventlib.gray_frame(W, H, 200), W, H)
    check('e a referência já é a cena nova no quadro seguinte',
          not r['moved'] and not r['scene'], 'score %.4f' % r['score'])

    # buraco de gravacao: os dois lados nao sao comparaveis
    m3 = eventlib.Motion()
    m3.feed(1000, eventlib.gray_frame(W, H, 60), W, H)
    r = m3.feed(1000 + 3600000, eventlib.gray_frame(W, H, 190), W, H)
    check('salto no tempo zera a referência em vez de acusar movimento',
          not r['moved'] and not r['scene'])

    # ruido de compressao abaixo do limiar de celula nao acende nada
    m4 = eventlib.Motion()
    m4.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    r = m4.feed(3000, eventlib.gray_frame(W, H, 108), W, H)
    check('oscilação de 8 níveis é ruído, não movimento', not r['moved'],
          'score %.4f' % r['score'])


def teste_grade_e_delta(pasta):
    # Os dois ajustes da tela de sintonia servem a coisas DIFERENTES, e é fácil
    # confundi-los: um filtra movimento pequeno, o outro filtra deslocamento de
    # brilho. Aqui a diferença fica medida, e não argumentada.
    print('grade e delta por célula')
    W, H = 160, 90

    def com(grade=1.0, delta=0):
        return eventlib.Motion(threshold=0.004, grid_scale=grade,
                               cell_delta=delta)

    def vulto(x0, y0, x1, y1):
        q = eventlib.gray_frame(W, H, 100)
        eventlib.paint(q, W, H, x0, y0, x1, y1, 220)
        return q

    check('a grade encolhe pelo lado, com piso',
          eventlib.grade_de(1.0) == (64, 36) and
          eventlib.grade_de(0.5) == (32, 18) and
          eventlib.grade_de(0.25) == (16, 9) and
          eventlib.grade_de(0.01) == (8, 5))

    # ---- 1. grade grossa contra movimento PEQUENO
    #
    # O que decide não é o tamanho do vulto sozinho: é se ele levanta a MÉDIA
    # da célula até o delta. Um vulto de 4x4 pixels com contraste moderado
    # (+40) enche células da grade fina, mas numa célula de 10x10 da grade
    # grossa vira +6 e não chega ao delta.
    fina, grossa = com(), com(grade=0.25)
    fina.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    grossa.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    pequeno = eventlib.gray_frame(W, H, 100)
    eventlib.paint(pequeno, W, H, 80, 44, 84, 48, 140)
    rf = fina.feed(3000, pequeno, W, H)
    rg = grossa.feed(3000, pequeno, W, H)
    check('movimento pequeno acende na grade fina', rf['score'] > 0,
          'score %.4f' % rf['score'])
    check('e some na grade grossa', rg['score'] == 0,
          'score %.4f' % rg['score'])

    # ---- 1b. e o que a grade grossa NÃO faz
    #
    # Medido, contra a intuição: um vulto pequeno e MUITO claro sobrevive à
    # média, e como o score é a fração de células acesas, ele passa a ocupar
    # uma fração MAIOR da grade grossa -- 1 de 144 é mais que 4 de 2304. Grade
    # grossa não é "menos sensível" em geral; ela é cega para pouco contraste.
    fina, grossa = com(), com(grade=0.25)
    fina.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    grossa.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    berrante = vulto(80, 44, 84, 48)          # +120 nos mesmos 4x4 pixels
    rf = fina.feed(3000, berrante, W, H)
    rg = grossa.feed(3000, berrante, W, H)
    check('vulto pequeno e muito claro atravessa a grade grossa',
          rg['score'] > 0, 'score %.4f' % rg['score'])
    check('e nela chega a pesar MAIS, porque o score é fração de células',
          rg['score'] > rf['score'],
          'fina %.4f, grossa %.4f' % (rf['score'], rg['score']))

    # ---- 2. mas a grade NÃO ajuda contra deslocamento de brilho
    #
    # É o caso do ganho automático da câmera com infravermelho: a cena inteira
    # clareia alguns níveis de uma vez. Toda célula anda junto, e mediar mais
    # pixels não muda nada -- a média desloca junto.
    fina, grossa = com(), com(grade=0.25)
    fina.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    grossa.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    claro = eventlib.gray_frame(W, H, 118)          # +18, acima do delta padrão
    rf = fina.feed(3000, claro, W, H)
    rg = grossa.feed(3000, claro, W, H)
    check('brilho subindo acende a grade fina inteira', rf['score'] == 1.0,
          'score %.4f' % rf['score'])
    check('e a grossa inteira também: a grade não filtra isso',
          rg['score'] == 1.0, 'score %.4f' % rg['score'])

    # ---- 3. o delta por célula é o que filtra
    surdo = com(delta=24)
    surdo.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    r = surdo.feed(3000, eventlib.gray_frame(W, H, 118), W, H)
    check('com delta 24 o mesmo salto de brilho não move nada',
          r['score'] == 0, 'score %.4f' % r['score'])

    # ---- 4. e o preço dele: movimento de pouco contraste some junto
    surdo2 = com(delta=24)
    surdo2.feed(1000, eventlib.gray_frame(W, H, 100), W, H)
    fraco = eventlib.gray_frame(W, H, 100)
    eventlib.paint(fraco, W, H, 40, 20, 120, 70, 118)   # vulto de +18 só
    r = surdo2.feed(3000, fraco, W, H)
    check('mas um vulto de pouco contraste some junto com ele',
          r['score'] == 0, 'score %.4f' % r['score'])


def teste_agregacao_eventos(pasta):
    print('agregação de avistamentos em eventos')
    base = 1755950000000
    g = eventlib.Merger(merge_gap_ms=8000)
    # uma pessoa atravessando: oito quadros de 2 em 2 segundos
    for i in range(8):
        g.note(base + i * 2000, 'person', eventlib.KIND_OBJECT,
               score=0.5 + i * 0.05, count=1, box=(0.1 * i, 0, 0.1 * i + 0.1, 1))
    # e volta bem depois: outra passagem
    g.note(base + 120000, 'person', eventlib.KIND_OBJECT, score=0.6)
    evs = g.flush()

    pessoas = [e for e in evs if e['name'] == 'person']
    check('oito avistamentos seguidos viram UM evento, não oito',
          len(pessoas) == 2, 'vieram %d' % len(pessoas))
    check('o evento cobre do primeiro ao último avistamento',
          pessoas[0]['start_ms'] == base and
          pessoas[0]['end_ms'] == base + 14000,
          '%d..%d' % (pessoas[0]['start_ms'], pessoas[0]['end_ms']))
    check('o score guardado é o do PICO',
          abs(pessoas[0]['score'] - 0.85) < 1e-6,
          'ficou %.3f' % pessoas[0]['score'])
    check('a caixa guardada é a do quadro de pico, não a união',
          abs(pessoas[0]['box'][0] - 0.7) < 1e-6,
          'ficou %s' % (pessoas[0]['box'],))
    check('passagem depois da janela de fusão é OUTRO evento',
          pessoas[1]['start_ms'] == base + 120000)

    # rotulos diferentes no mesmo instante sao eventos separados
    g2 = eventlib.Merger()
    g2.note(base, 'person', eventlib.KIND_OBJECT, score=0.9)
    g2.note(base, 'car', eventlib.KIND_OBJECT, score=0.8)
    g2.note(base + 2000, 'person', eventlib.KIND_OBJECT, score=0.7)
    evs = g2.flush()
    check('rótulos diferentes não se fundem', len(evs) == 2,
          'vieram %d' % len(evs))


def teste_ancora_do_gravador(_pasta):
    """A âncora de cada bloco sai do pts da gravação, e não da chegada.

    O leitor calcula `wallMs = âncora + (pts - primeiro pts) / timescale`: dentro
    do bloco quem manda é o pts, e na virada quem manda é a âncora. Enquanto a
    âncora foi o relógio de chegada, os dois não andavam no mesmo passo, e a rede
    que segura quadros e depois os despeja fazia dois blocos cobrirem o mesmo
    intervalo -- que na reprodução é a imagem voltando um pedaço.
    """
    print('âncora dos blocos do gravador')
    TS, POR_BLOCO = 90000, 20

    def medir(cena, regra):
        blocos = anchormodel.montar(cena, TS, POR_BLOCO, regra)
        r = anchormodel.analisar(blocos, TS)
        r['recuou'] = any(blocos[i]['ancora'] < blocos[i - 1]['ancora']
                          for i in range(1, len(blocos)))
        r['desvio'] = max(abs(b['ancora'] - b['chegou']) for b in blocos)
        return r

    # 1) rede que trava e depois despeja: o caso que apareceu em disco
    rajada = anchormodel.cena_rajada()
    antes = medir(rajada, anchormodel.ancora_por_chegada)
    depois = medir(rajada, anchormodel.ancora_derivada)
    check('pela chegada, a rajada faz blocos se sobreporem',
          len(antes['sobrepostos']) > 0 and antes['maiorSobreposicao'] > 1000,
          '%d sobreposições, maior %d ms'
          % (len(antes['sobrepostos']), antes['maiorSobreposicao']))
    check('pela chegada, a âncora chega a andar para trás', antes['recuou'])
    check('derivada do pts, nenhum bloco se sobrepõe',
          not depois['sobrepostos'],
          '%d sobreposições' % len(depois['sobrepostos']))
    check('derivada do pts, a âncora nunca anda para trás', not depois['recuou'])
    # A rajada é atraso de TRANSPORTE: os quadros foram capturados no ritmo
    # normal. Inventar buraco ali seria mentir sobre a gravação.
    check('derivada do pts, a rajada não vira buraco', not depois['buracos'],
          'buracos: %s' % depois['buracos'])
    check('pela chegada, a rajada inventava buracos', len(antes['buracos']) > 0,
          '%d buracos' % len(antes['buracos']))

    # 2) tremor de chegada, que é o caso de todo dia
    tremor = anchormodel.cena_jitter()
    a2 = medir(tremor, anchormodel.ancora_por_chegada)
    d2 = medir(tremor, anchormodel.ancora_derivada)
    check('pela chegada, o tremor já bastava para sobrepor',
          len(a2['sobrepostos']) > 0, '%d sobreposições' % len(a2['sobrepostos']))
    check('derivada do pts, o tremor some', not d2['sobrepostos'])
    check('e o desvio para o relógio de quem grava fica pequeno',
          d2['desvio'] < 1000, '%d ms' % d2['desvio'])

    # 3) reconexão com pts zerado: aí a âncora TEM de ser refeita, e o buraco
    #    de verdade tem de aparecer
    reinicio = anchormodel.cena_reinicio()
    d3 = medir(reinicio, anchormodel.ancora_derivada)
    check('pts reiniciado re-ancora pelo relógio de quem grava',
          d3['desvio'] == 0, 'desvio %d ms' % d3['desvio'])
    check('e o buraco real de 40 s continua lá',
          d3['maiorBuraco'] > 39000 and d3['maiorBuraco'] < 41000,
          'maior buraco %d ms' % d3['maiorBuraco'])
    check('sem sobrepor nada na volta', not d3['sobrepostos'])


def teste_parameter_sets_da_sequencia(_pasta):
    """Numa sequencia, o extradata do header so vale ate o fluxo mostrar o seu.

    A camera ayla grava um header cujo SPS diz Baseline/CAVLC, enquanto o fluxo
    e Main/CABAC -- com o mesmo sps_id. O AU de keyframe traz SPS/PPS proprios e
    escapava da prefixacao; os quadros P seguintes nao trazem nada, levavam o
    SPS/PPS velho colado na frente, e reativavam o errado por cima do bom. O
    FFmpeg entao le o cabecalho de fatia torto ("deblocking_filter_idc out of
    range"), esconde o erro com concealment, e o GOP inteiro decodifica sujo ate
    o keyframe seguinte -- que o detector de movimento le como movimento.

    Medido nas DLLs do proprio servidor, num GOP real de 40 AUs: pela regra
    velha sairam 22 quadros, 164 celulas da grade fora do lugar; pela nova
    sairam os 40, nenhuma celula fora.
    """
    print('parameter sets ao longo de uma sequencia')

    def tem_ps(au):
        """Porte do HasParameterSets: SPS(7) ou PPS(8) em Annex-B."""
        i = 0
        while i + 4 < len(au):
            if au[i] == 0 and au[i + 1] == 0:
                if au[i + 2] == 1:
                    t = i + 3
                elif au[i + 2] == 0 and au[i + 3] == 1:
                    t = i + 4
                else:
                    i += 1
                    continue
                if t >= len(au):
                    return False
                if au[t] & 31 in (7, 8):
                    return True
                i = t
            else:
                i += 1
        return False

    def por_au(aus):
        """A regra antiga: decide AU a AU."""
        return [not tem_ps(a) for a in aus]

    def por_sequencia(aus):
        """A regra nova: viu parameter sets uma vez, nao prefixa mais."""
        saida, viu = [], False
        for a in aus:
            if tem_ps(a):
                viu = True
            saida.append(not viu)
        return saida

    def nal(tipo, tam=40):
        return bytes([0, 0, 0, 1, tipo]) + bytes(tam)

    idr = nal(7, 20) + nal(8, 4) + nal(5, 400)   # SPS + PPS + fatia IDR
    p = nal(1, 200)                              # so a fatia
    gop = [idr] + [p] * 9 + [idr] + [p] * 9

    velha, nova = por_au(gop), por_sequencia(gop)
    check('o keyframe nunca recebe o extradata do header',
          not velha[0] and not nova[0])
    check('pela regra antiga, todo quadro P recebia o extradata velho',
          sum(1 for i, x in enumerate(velha) if x) == 18,
          '%d de %d AUs prefixados' % (sum(velha), len(gop)))
    check('pela regra da sequencia, nenhum AU recebe depois do keyframe',
          not any(nova), '%d AUs prefixados' % sum(nova))

    # O extradata do header continua fazendo falta quando o fluxo nao traz nada:
    # camera que so manda fatias, ou percurso que comeca fora de um keyframe.
    sem_ps = [p] * 5
    check('fluxo sem parameter sets nenhum ainda recebe o do header',
          all(por_sequencia(sem_ps)), 'prefixados: %s' % por_sequencia(sem_ps))

    # E quando os parameter sets aparecem no meio, a prefixacao para dali.
    tarde = [p, p, idr, p, p]
    r = por_sequencia(tarde)
    check('parameter sets no meio param a prefixacao dali em diante',
          r == [True, True, False, False, False], 'prefixados: %s' % r)


def teste_entrada_no_keyframe(_pasta):
    """Um percurso novo nao entrega quadro antes do primeiro keyframe.

    O bloco de entrada e escolhido por HasKeyframe, que diz que ele CONTEM um
    keyframe -- nao que comece com um: o TBlockBuilder fecha bloco por tempo e
    tamanho. Alimentar o decodificador a partir do primeiro sample do bloco
    entrega, quase sempre, um quadro P sem referencia; o FFmpeg inventa a
    referencia que falta e devolve um quadro CINZA CHAPADO.

    Medido no servidor: a grade desse primeiro quadro ia de 121 a 132, num
    instante cuja faixa real e 58..254. Ele virava a referencia do detector, e
    os ~4 s seguintes de cena parada pontuavam ~30% de movimento, decaindo junto
    com a media movel do fundo (0.296, 0.275, 0.245, 0.203, 0.165, ...). Como o
    worker refaz o percurso a cada 30 s (PERCURSO_MS), a linha do tempo ganhava
    um evento falso a cada 30 s, sempre na mesma fase -- foi assim que o padrao
    apareceu: 27 eventos em :31.71 e 11 em :01.71.
    """
    print('entrada do percurso pelo keyframe')

    K, P_ = 1, 0     # 1 = sample com sfKeyframe

    def bloco(flags):
        return [{'chave': bool(f), 'i': i} for i, f in enumerate(flags)]

    def contem_chave(b):
        """O criterio do indice: HasKeyframe/SamplesHaveKeyframe."""
        return any(x['chave'] for x in b)

    def alimentados(b, esperar_chave):
        """Os samples que chegam ao decodificador, na ordem."""
        saida, esperando = [], esperar_chave
        for x in b:
            if esperando:
                if not x['chave']:
                    continue
                esperando = False
            saida.append(x['i'])
        return saida

    # O caso real: o bloco traz um keyframe, mas no meio.
    b = bloco([P_, P_, K, P_, P_, P_])
    check('o bloco serve de entrada porque CONTEM keyframe', contem_chave(b))
    check('mas ele nao comeca por um', not b[0]['chave'])

    velha = alimentados(b, False)
    nova = alimentados(b, True)
    check('pela regra antiga, dois quadros P entravam antes do keyframe',
          velha[:2] == [0, 1], 'entraram: %s' % velha[:3])
    check('pela regra nova, o keyframe e o primeiro a entrar',
          nova[0] == 2, 'entraram: %s' % nova[:3])
    check('e dali em diante nada mais e pulado',
          nova == [2, 3, 4, 5], 'entraram: %s' % nova)

    # Bloco que ja comeca no keyframe: a regra nova nao pode custar nada.
    b2 = bloco([K, P_, P_])
    check('bloco que comeca no keyframe passa inteiro pelas duas regras',
          alimentados(b2, True) == alimentados(b2, False) == [0, 1, 2])

    # Um keyframe adiante desliga a espera de uma vez so, e nao a cada bloco.
    b3 = bloco([P_, K, P_]) + bloco([P_, P_])
    seguidos, esperando = [], True
    for x in b3:
        if esperando:
            if not x['chave']:
                continue
            esperando = False
        seguidos.append(x['i'])
    check('depois do primeiro keyframe, os blocos seguintes entram inteiros',
          len(seguidos) == 4, 'entraram %d samples' % len(seguidos))


def teste_bloco_do_anel_ao_vivo(_pasta):
    """O bloco que o /api/live monta do anel data igual ao que o gravador grava.

    O ao vivo passou a sair do anel em memoria (Vms.Server.LiveHub) em vez da
    cauda do arquivo, porque o arquivo so cresce quando um bloco FECHA -- 2 s de
    block.maxDurationMs -- e a isso se somava o recuo de abertura, que fica para
    sempre porque o player ancora o relogio no primeiro quadro exibido.

    A parte arriscada da troca e a DATA. Por dentro o anel carimba por relogio
    monotonico; o .vms carrega hora de parede, e o leitor a reconstroi com
    `wall = ancora + (pts - primeiro pts) * 1000 / timescale`, uma ancora por
    trilha. Errar isso nao quebra a imagem -- ela aparece com a hora errada, o
    que e pior, porque a regua deixa de fechar com o video e ninguem desconfia
    do relogio.
    """
    print('bloco do anel do ao vivo')
    TS = 90000                      # a base de PTS do video, como no hub

    def montar(itens, agora_parede, agora_mono):
        """O que o HandleLive faz: um bloco, uma ancora por trilha.

        itens: lista de (track, pts, keyframe, mono_ms).
        """
        parede = lambda mono: agora_parede - (agora_mono - mono)
        amostras, va, aa = [], 0, 0
        for track, pts, chave, mono in itens:
            amostras.append((track, 1 if chave else 0, pts,
                             bytes([track]) * 16))
            if track == 0 and not va:
                va = parede(mono)
            if track == 1 and not aa:
                aa = parede(mono)
        inicio = va or aa
        return (genvms.build_header(inicio)
                + genvms.build_block(1, inicio, amostras, anchors=(va, aa)))

    # Uma rajada como a que sai do anel: video a 10 fps e audio junto.
    AGORA, MONO = 1788400000000, 5000000
    itens = []
    for i in range(10):
        itens.append((0, i * (TS // 10), i == 0, MONO - 900 + i * 100))
        itens.append((1, i * 800, False, MONO - 900 + i * 100))

    dados = montar(itens, AGORA, MONO)
    cab = vmslib.read_header(dados)
    blocos = list(vmslib.iter_blocks(dados, cab))
    check('o bloco montado do anel e legivel', len(blocos) == 1,
          '%d blocos' % len(blocos))
    b = blocos[0]
    check('e o crc fecha', b.crc_ok)
    check('as duas ancoras entraram', b.video_anchor_ms > 0 and b.audio_anchor_ms > 0,
          'video=%s audio=%s' % (b.video_anchor_ms, b.audio_anchor_ms))

    # A regra do leitor, aplicada aqui: cada trilha data pela ancora DELA.
    def datar(bloco, track, timescale):
        prim = None
        fora = []
        for sm in bloco.samples:
            if sm.track_id != track:
                continue
            if prim is None:
                prim = sm.pts
            anc = bloco.video_anchor_ms if track == 0 else bloco.audio_anchor_ms
            fora.append(anc + (sm.pts - prim) * 1000 // timescale)
        return fora

    esperado_v = [AGORA - 900 + i * 100 for i in range(10)]
    check('o video sai com a hora de parede de quando chegou',
          datar(b, 0, TS) == esperado_v,
          'primeiro=%d esperado=%d' % (datar(b, 0, TS)[0], esperado_v[0]))
    check('o primeiro quadro e o keyframe', (b.samples[0].flags & 1) == 1)
    check('e a hora do primeiro e a ancora',
          datar(b, 0, TS)[0] == b.video_anchor_ms)

    # Audio numa base de PTS propria: e por isso que ha duas ancoras.
    esperado_a = [AGORA - 900 + i * 100 for i in range(10)]
    check('o audio data pela ancora dele, e nao pela do video',
          datar(b, 1, 8000) == esperado_a,
          'primeiro=%d esperado=%d' % (datar(b, 1, 8000)[0], esperado_a[0]))

    # Rajada so de video: sem trilha de audio, a ancora dela fica em zero e o
    # bloco continua valido -- e o caso da camera sem som.
    so_video = [(0, i * (TS // 10), i == 0, MONO + i * 100) for i in range(4)]
    d2 = montar(so_video, AGORA, MONO)
    b2 = list(vmslib.iter_blocks(d2, vmslib.read_header(d2)))[0]
    check('rajada sem audio ainda monta bloco valido', b2.crc_ok)
    check('e sem ancora de audio', b2.audio_anchor_ms == 0,
          'audio=%s' % b2.audio_anchor_ms)

    # O cursor do anel tem de ser distinguivel do cursor de arquivo, senao um
    # cliente voltando do plano B seria lido como se estivesse no anel.
    def cursor_do_anel(seq, epoca, espera_chave):
        return 'L%d-%d-%d' % (seq, epoca, 1 if espera_chave else 0)

    def le_cursor(texto):
        if not texto.startswith('L'):
            return None
        p = texto[1:].split('-')
        if len(p) != 3:
            return None
        return int(p[0]), int(p[1]), p[2] != '0'

    check('cursor do anel volta igual ao que saiu',
          le_cursor(cursor_do_anel(4321, 2, True)) == (4321, 2, True))
    check('cursor de arquivo nao passa por cursor de anel',
          le_cursor('1788400000000-17-2-frente_2026-09-03_18-29-39.vms') is None)
    check('cursor vazio nao passa', le_cursor('') is None)
    check('o zero que o cliente manda ao abrir nao passa', le_cursor('0') is None)


def teste_onvif(_pasta):
    """As tres regras puras do cliente ONVIF: digest, leitura do XML e endereco.

    O resto do cliente e conversa em rede e so se prova contra uma camera. Estas
    tres nao: sao conta e texto, e sao exatamente onde a integracao costuma
    quebrar calada -- o digest errado devolve "sender not authorized" sem dizer
    por que, e a leitura errada do XAddr manda o comando para o servico errado.
    """
    print('cliente ONVIF')

    # ------------------------------------------------------------- o digest
    #
    # WS-Security UsernameToken: base64(sha1(nonce + created + senha)), com o
    # nonce nos BYTES crus, e nao no base64 dele -- e o engano classico, e ele
    # passa despercebido porque produz um digest de aparencia perfeita.
    def digest(nonce_b64, created, senha):
        cru = base64.b64decode(nonce_b64)
        return base64.b64encode(hashlib.sha1(
            cru + created.encode('utf-8') + senha.encode('utf-8')).digest()).decode()

    check('o digest bate com o vetor conhecido da norma',
          digest('LKqI6G/AikKCQrN0zqZFlg==', '2010-09-16T07:50:45Z',
                 'userpassword') == 'tuOSpGlFlIXsozq4HFNeeGeFLEI=')
    check('nonce em base64 no lugar dos bytes daria outro digest',
          digest('LKqI6G/AikKCQrN0zqZFlg==', '2010-09-16T07:50:45Z', 'userpassword')
          != base64.b64encode(hashlib.sha1(
              b'LKqI6G/AikKCQrN0zqZFlg==' + b'2010-09-16T07:50:45Z'
              + b'userpassword').digest()).decode())
    check('senha diferente, digest diferente',
          digest('LKqI6G/AikKCQrN0zqZFlg==', '2010-09-16T07:50:45Z', 'outra')
          != 'tuOSpGlFlIXsozq4HFNeeGeFLEI=')

    # -------------------------------------------------- a leitura do XML
    #
    # Porte do ValorDaTag/ValorDentroDe: compara so a parte do nome depois do
    # ultimo ':', porque o prefixo e escolha da camera (tt, tds, trt, nenhum).
    def local(nome):
        return nome.rsplit(':', 1)[-1]

    def achar_abertura(xml, nome, de=0):
        i = de
        while True:
            i = xml.find('<', i)
            if i < 0:
                return -1, -1
            i += 1
            if i >= len(xml) or xml[i] in '/?!':
                continue
            p = i
            while p < len(xml) and xml[p] not in '> /\t\r\n':
                p += 1
            if local(xml[i:p]).lower() == nome.lower():
                return i - 1, p
            i = p

    def achar_fechamento(xml, nome, de=0):
        i = de
        while True:
            i = xml.find('</', i)
            if i < 0:
                return -1
            p = i + 2
            while p < len(xml) and xml[p] not in '> \t\r\n':
                p += 1
            if local(xml[i + 2:p]).lower() == nome.lower():
                return i
            i = p

    def valor(xml, nome):
        i = 0
        while True:
            abre, apos = achar_abertura(xml, nome, i)
            if abre < 0:
                return ''
            ini = xml.find('>', apos)
            if ini < 0:
                return ''
            if ini > 0 and xml[ini - 1] == '/':
                i = ini
                continue
            fim = xml.find('</', ini)
            if fim < 0:
                return ''
            return xml[ini + 1:fim].strip()

    def valor_dentro(xml, dentro, nome):
        abre, apos = achar_abertura(xml, dentro)
        if abre < 0:
            return ''
        fecha = achar_fechamento(xml, dentro, apos)
        if fecha < 0:
            fecha = len(xml)
        return valor(xml[abre:fecha], nome)

    CAPS = (
        '<tds:GetCapabilitiesResponse><tds:Capabilities>'
        '<tt:Media><tt:XAddr>http://10.0.0.7/onvif/media</tt:XAddr></tt:Media>'
        '<tt:PTZ><tt:XAddr>http://10.0.0.7/onvif/ptz</tt:XAddr></tt:PTZ>'
        '</tds:Capabilities></tds:GetCapabilitiesResponse>')
    check('o XAddr do PTZ sai de dentro do PTZ',
          valor_dentro(CAPS, 'PTZ', 'XAddr') == 'http://10.0.0.7/onvif/ptz',
          valor_dentro(CAPS, 'PTZ', 'XAddr'))
    check('e o da midia de dentro da midia -- mesmo nome local, elementos',
          valor_dentro(CAPS, 'Media', 'XAddr') == 'http://10.0.0.7/onvif/media',
          valor_dentro(CAPS, 'Media', 'XAddr'))
    check('procurar XAddr solto pegaria o primeiro, que e o errado',
          valor(CAPS, 'XAddr') == 'http://10.0.0.7/onvif/media')

    # Camera fixa: sem o elemento PTZ. Tem de dar vazio, e nao o da midia.
    SEM_PTZ = ('<tds:Capabilities>'
               '<tt:Media><tt:XAddr>http://10.0.0.7/onvif/media</tt:XAddr></tt:Media>'
               '</tds:Capabilities>')
    check('camera sem PTZ devolve vazio, e nao o endereco da midia',
          valor_dentro(SEM_PTZ, 'PTZ', 'XAddr') == '',
          valor_dentro(SEM_PTZ, 'PTZ', 'XAddr'))

    # Prefixo e escolha da camera: as tres formas tem de dar no mesmo.
    for xml in ('<a:Hour>13</a:Hour>', '<Hour>13</Hour>', '<qq:Hour>13</qq:Hour>'):
        check('prefixo nao muda a leitura (%s)' % xml[:12], valor(xml, 'Hour') == '13')

    # Profile x Profiles: comparar o nome inteiro, e nao por substring.
    DOIS = '<trt:Profiles token="p0"><tt:Name>principal</tt:Name></trt:Profiles>'
    check('Profiles nao e confundido com Profile',
          achar_abertura(DOIS, 'Profile')[0] < 0)
    check('e o nome do perfil e lido',
          valor(DOIS, 'Name') == 'principal')

    # Tag vazia nao tem conteudo: segue para a proxima ocorrencia.
    check('tag vazia nao vira valor',
          valor('<tt:XAddr/><tt:XAddr>http://x/</tt:XAddr>', 'XAddr') == 'http://x/')

    # A hora da camera, que e de onde sai o acerto de relogio.
    HORA = ('<tds:GetSystemDateAndTimeResponse><tt:SystemDateAndTime>'
            '<tt:UTCDateTime><tt:Time><tt:Hour>7</tt:Hour><tt:Minute>50</tt:Minute>'
            '<tt:Second>45</tt:Second></tt:Time><tt:Date><tt:Year>2010</tt:Year>'
            '<tt:Month>9</tt:Month><tt:Day>16</tt:Day></tt:Date></tt:UTCDateTime>'
            '</tt:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>')
    d = valor_dentro(HORA, 'Date', 'Year'), valor_dentro(HORA, 'Date', 'Month')
    h = valor_dentro(HORA, 'Time', 'Hour')
    check('a data da camera e lida de dentro do Date', d == ('2010', '9'), str(d))
    check('e a hora de dentro do Time', h == '7', h)

    # ------------------------------------------------------- o endereco padrao
    #
    # A porta da midia nao serve ao ONVIF: 554 e do RTSP e 34567 e do DVRIP. O
    # servico de dispositivo mora no HTTP da camera.
    def endereco(url):
        s2 = url.strip()
        i = s2.find('://')
        if i >= 0:
            s2 = s2[i + 3:]
        i = s2.find('@')
        if i >= 0:
            s2 = s2[i + 1:]
        i = s2.find('/')
        if i >= 0:
            s2 = s2[:i]
        host = s2.split(':')[0]
        return 'http://' + host + '/onvif/device_service' if host else ''

    for url, esperado in (
            ('rtsp://192.168.0.10:554/onvif1', 'http://192.168.0.10/onvif/device_service'),
            ('rtsp://user:pw@192.168.0.10:554/live', 'http://192.168.0.10/onvif/device_service'),
            ('dvrip://192.168.0.11:34567/main', 'http://192.168.0.11/onvif/device_service'),
            ('rtsp://cam.local/stream', 'http://cam.local/onvif/device_service')):
        check('endereco padrao de %s' % url, endereco(url) == esperado, endereco(url))
    check('url sem host nao vira endereco', endereco('') == '')

    # ---------------------------------------------- a duracao do movimento
    #
    # Sem o campo Timeout a camera aplica o padrao dela, e nesta familia o
    # padrao e curto: segurar o botao dava um passo so em vez de mover
    # continuamente. Medido na Ayla.
    #
    # O valor acompanha o teto da tela: a pagina desiste em 8 s, e a camera
    # para sozinha no mesmo tempo se a parada se perder no caminho. Menor
    # engasgaria no meio do gesto; maior deixaria a camera girando depois de a
    # tela ja ter desistido.
    aqui = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    onvif_pas = io.open(os.path.join(aqui, 'vms', 'src', 'Onvif',
                                     'Vms.Onvif.Client.pas'),
                        encoding='utf-8-sig').read()
    i6 = onvif_pas.index('function TOnvifClient.MoverContinuo')
    mover = onvif_pas[i6:onvif_pas.index('function TOnvifClient.Parar')]
    check('o movimento continuo diz por quanto tempo vale',
          '<Timeout>' in mover)
    check('e a duracao bate com o teto de tempo da tela',
          "DURACAO = 'PT8S'" in onvif_pas)
    pagina_ptz = io.open(os.path.join(aqui, 'src', 'UI', 'web', 'app-ui.html'),
                         encoding='utf-8-sig').read()
    check('que e o mesmo 8000 do TETO_PTZ_MS',
          'TETO_PTZ_MS = 8000' in pagina_ptz)
    parar_pas = onvif_pas[onvif_pas.index('function TOnvifClient.Parar'):]
    parar_pas = parar_pas[:parar_pas.index('function TOnvifClient.LerPresets')]
    check('a parada por velocidade zero NAO leva duracao',
          '<Timeout>' not in parar_pas)

    # ------------------------------------------- o endereco escrito no cadastro
    #
    # A porta NAO se adivinha. A norma sugere a 80; a Ayla daqui atende ONVIF na
    # 5000, e nada na URL de video dela diz isso. Entao quem sabe escreve, em
    # qualquer das tres formas que uma pessoa escreveria.
    def endereco_do_cadastro(escrito, url_midia):
        t = (escrito or '').strip()
        if not t:
            return endereco(url_midia)
        if '://' not in t:
            t = 'http://' + t
        if '/' not in t[t.index('://') + 3:]:
            t += '/onvif/device_service'
        return t

    ALVO = 'http://192.168.100.2:5000/onvif/device_service'
    for escrito in ('192.168.100.2:5000',
                    'http://192.168.100.2:5000',
                    'http://192.168.100.2:5000/onvif/device_service'):
        check('cadastro "%s" vira o mesmo endereco' % escrito,
              endereco_do_cadastro(escrito, '') == ALVO,
              endereco_do_cadastro(escrito, ''))
    check('so o host tambem serve, e cai na porta 80',
          endereco_do_cadastro('10.0.0.7', '') ==
          'http://10.0.0.7/onvif/device_service')
    check('cadastro vazio cai no palpite da norma',
          endereco_do_cadastro('', 'rtsp://192.168.0.10:554/onvif1') ==
          'http://192.168.0.10/onvif/device_service')
    check('a porta do cadastro NAO e trocada pela 80',
          ':5000' in endereco_do_cadastro('192.168.100.2:5000', ''))

    # ------------------------------------ o endereco anunciado, atras do NAT
    #
    # Camera atras de encaminhamento anuncia o IP da rede DELA. A Ayla responde
    # em 192.168.100.2:5000 e se diz 192.168.0.6:5000; seguir o anuncio seria
    # falar com uma maquina que nao existe deste lado. Troca-se o host e
    # guarda-se a porta, porque ha camera que legitimamente poe um servico em
    # porta propria.
    def mesmo_host(anunciado, base):
        a, b = (anunciado or '').strip(), (base or '').strip()
        if not a or not b:
            return anunciado
        if '://' in b:
            b = b[b.index('://') + 3:]
        if '/' in b:
            b = b[:b.index('/')]
        host_base = b.split(':')[0]
        if not host_base or '://' not in a:
            return anunciado
        resto = a[a.index('://') + 3:]
        if '/' in resto:
            autoridade, resto = resto[:resto.index('/')], resto[resto.index('/'):]
        else:
            autoridade, resto = resto, ''
        if ':' in autoridade:
            autoridade = host_base + autoridade[autoridade.index(':'):]
        else:
            autoridade = host_base
        return 'http://' + autoridade + resto

    BASE = 'http://192.168.100.2:5000/onvif/device_service'
    check('o anuncio da Ayla e trazido para o host alcancavel',
          mesmo_host('http://192.168.0.6:5000/onvif/deviceio_service', BASE) ==
          'http://192.168.100.2:5000/onvif/deviceio_service',
          mesmo_host('http://192.168.0.6:5000/onvif/deviceio_service', BASE))
    check('o caminho anunciado e preservado',
          mesmo_host('http://192.168.0.6:5000/onvif/ptz_service', BASE)
          .endswith('/onvif/ptz_service'))
    check('a porta anunciada e preservada, e nao a da base',
          mesmo_host('http://192.168.0.6:8000/x', BASE) ==
          'http://192.168.100.2:8000/x',
          mesmo_host('http://192.168.0.6:8000/x', BASE))
    check('anuncio sem porta continua sem porta',
          mesmo_host('http://192.168.0.6/x', BASE) == 'http://192.168.100.2/x')
    check('camera na mesma rede nao muda de endereco',
          mesmo_host(BASE, BASE) == BASE)
    check('anuncio vazio nao vira endereco inventado',
          mesmo_host('', BASE) == '')


def teste_ptz_dvrip(_pasta):
    """O comando de PTZ sai igual ao que o iCSee manda.

    Nao ha ONVIF nestas cameras -- a varredura da rede provou que a porta 80
    delas recusa conexao e que nenhuma porta encaminhada fala SOAP. O que move a
    PTZ e DVRIP, o mesmo protocolo que o projeto ja usa para gravar.

    O formato veio de uma captura do iCSee movendo a camera. Para que lado, a
    captura NAO diz -- e eu supus esquerda, o que estava errado e inverteu o
    horizontal inteiro ate ser medido nas cameras. Ver abaixo. E a captura
    PROVA o resultado, por um caminho que nao depende de eu ter
    lido o JSON direito: o DataLen do pacote dela vale 328 no comando e 325 na
    parada. Se o texto montado aqui der outro tamanho, ele nao e o mesmo texto.

    Os 3 bytes de diferenca entre os dois sao exatamente "65535" contra "-1",
    que e o unico campo que muda entre andar e parar.
    """
    print('PTZ por DVRIP')

    def ptz(comando, passo, canal, iniciar, sessao):
        preset = 65535 if iniciar else -1
        passo = max(1, min(8, passo))
        return ('{ "Name" : "OPPTZControl", "OPPTZControl" : { "Command" : "%s"'
                ', "Parameter" : { "AUX" : { "Number" : 0, "Status" : "On" }, '
                '"Channel" : %d, "MenuOpts" : "Enter", '
                '"POINT" : { "bottom" : 0, "left" : 0, "right" : 0, "top" : 0 }'
                ', "Pattern" : "SetBegin", "Preset" : %d, "Step" : %d, '
                '"Tour" : 0 } }, "SessionID" : "%s" }'
                % (comando, canal, preset, passo, sessao))

    # O DataLen do pacote inclui o \n final (ver o cabecalho do VMS.Dvrip.Protocol).
    anda = ptz('DirectionLeft', 5, 0, True, '0x2d')
    para = ptz('DirectionLeft', 5, 0, False, '0x2d')
    check('o comando tem os 328 bytes do pacote capturado',
          len(anda) + 1 == 328, '%d' % (len(anda) + 1))
    check('e a parada tem os 325 do pacote seguinte',
          len(para) + 1 == 325, '%d' % (len(para) + 1))
    check('a diferenca e so o Preset, 3 caracteres',
          len(anda) - len(para) == 3)
    check('andar manda Preset 65535', '"Preset" : 65535' in anda)
    check('parar manda Preset -1', '"Preset" : -1' in para)
    check('e o comando e o MESMO nos dois -- so o Preset muda',
          anda.replace('65535', '-1') == para)

    # O MsgID saiu dos dois bytes antes do DataLen no pacote: 78 05, em little
    # endian. Vale registrar a conta, que e o que liga o numero a captura.
    check('MsgID 1400 e o 0x0578 lido no pacote', 0x0578 == 1400)
    check('e o byte baixo do DataLen bate com o que aparecia em texto',
          (328 & 0xFF, 325 & 0xFF) == (0x48, 0x45),
          'H=0x48 e E=0x45 eram os bytes visiveis')

    # Passo fora da faixa nao vai para a camera como veio.
    check('passo abaixo de 1 vira 1', '"Step" : 1' in ptz('DirectionUp', 0, 0, True, '0x1'))
    check('passo acima de 8 vira 8', '"Step" : 8' in ptz('DirectionUp', 99, 0, True, '0x1'))

    # Canal e sessao entram como vieram.
    j = ptz('DirectionRight', 5, 3, True, '0x0000002d')
    check('o canal pedido vai no JSON', '"Channel" : 3' in j)
    check('a sessao vai como a camera a escreve',
          '"SessionID" : "0x0000002d"' in j)

    # ------------------------------------------ a resposta do PTZ e controle
    #
    # 1401 estava fora da tabela de mensagens de controle. O efeito: a camera
    # respondia ao comando de movimento e o log dizia "MsgID desconhecido" em
    # vez do JSON dela -- justamente a resposta que se quer ler quando a camera
    # aceita o comando e nao se mexe.
    proto1 = io.open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'src', 'Dvrip', 'VMS.Dvrip.Protocol.pas'), encoding='utf-8-sig').read()
    i7 = proto1.index('function DvripClassifyMsg')
    i7 = proto1.index('case MsgID of', i7)
    # Ate o fim do case, e nao ate a primeira mencao de mkUnknown: ela aparece
    # tambem no comentario que explica por que a entrada foi acrescentada.
    tabela = proto1[i7:proto1.index('  else', i7)]
    check('o pedido e a resposta de PTZ contam como controle',
          'DVRIP_PTZ, DVRIP_PTZ_RSP' in tabela)
    check('e o ramo de midia continua so com o canal de dados',
          tabela.index('mkMedia') < tabela.index('DVRIP_PTZ,'))

    # ------------------------------------------------ o aviso de evento
    #
    # A camera manda AlarmInfo (1504) sozinha, com numero de sessao PROPRIO.
    # Recusar por causa da sessao custava caro: o leitor perdia o sincronismo
    # e varria o fluxo atras do proximo cabecalho, jogando fora mais de cem
    # bytes de video. Medido nas duas cameras, a cada comando de PTZ.
    check('o aviso de evento tem numero e e controle',
          'DVRIP_ALARM_INFO          = 1504' in proto1 and
          'DVRIP_ALARM_INFO' in tabela)
    i8 = proto1.index('function HeaderReject')
    rej = proto1[i8:proto1.index('function HeaderPlausible')]
    check('cabecalho de outra sessao passa quando o MsgID e conhecido',
          'DvripClassifyMsg' in rej and 'mkUnknown' in rej)
    # A regra do SessionID continua: e ela que separa cabecalho de verdade de
    # coincidencia dentro do video comprimido.
    check('e a regra do SessionID continua valendo para MsgID desconhecido',
          "Exit(Format('sessao=%x" in rej)

    # -------------------------------------------------- o lado de cada nome
    #
    # MEDIDO em duas cameras: mandando 'DirectionRight' a imagem anda para a
    # ESQUERDA nas duas. O nome da camera e o espelho do que se ve na tela --
    # parece ser do ponto de vista de quem olha para ela.
    #
    # Isto ficou errado por um tempo porque eu tinha deduzido os nomes de uma
    # captura sem saber para que lado o dedo tinha ido. O teste existe para a
    # deducao nao voltar.
    proto0 = io.open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'src', 'Dvrip', 'VMS.Dvrip.Protocol.pas'), encoding='utf-8-sig').read()

    def valor(nome):
        i = proto0.index(nome + ' ')
        i = proto0.index("'", i)
        return proto0[i + 1:proto0.index("'", i + 1)]

    check('a direita da tela manda o nome de esquerda da camera',
          valor('DVRIP_PTZ_DIREITA') == 'DirectionLeft',
          valor('DVRIP_PTZ_DIREITA'))
    check('e a esquerda da tela manda o de direita',
          valor('DVRIP_PTZ_ESQUERDA') == 'DirectionRight',
          valor('DVRIP_PTZ_ESQUERDA'))
    check('as diagonais seguem a mesma troca no horizontal',
          valor('DVRIP_PTZ_CIMA_DIR') == 'DirectionLeftUp' and
          valor('DVRIP_PTZ_BAIXO_DIR') == 'DirectionLeftDown' and
          valor('DVRIP_PTZ_CIMA_ESQ') == 'DirectionRightUp' and
          valor('DVRIP_PTZ_BAIXO_ESQ') == 'DirectionRightDown')
    check('e o vertical NAO inverte: cima e cima',
          valor('DVRIP_PTZ_CIMA') == 'DirectionUp' and
          valor('DVRIP_PTZ_BAIXO') == 'DirectionDown')

    # ------------------------------------------------------------ presets
    #
    # O preset e a MESMA mensagem, com outro Command e o numero onde as
    # direcoes poem 65535. Isto NAO veio de captura, ao contrario das oito
    # direcoes; se a camera ignorar, e o primeiro lugar a olhar.
    ir = ptz('GotoPreset', 5, 0, True, '0x2d').replace('"Preset" : 65535',
                                                       '"Preset" : 3')
    check('o preset entra no campo que as direcoes usam para 65535',
          '"Preset" : 3' in ir)
    check('e o resto da mensagem e identico ao de andar',
          ir.replace('"Preset" : 3', '"Preset" : 65535')
          .replace('GotoPreset', 'DirectionLeft') == anda)
    proto = io.open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'src', 'Dvrip', 'VMS.Dvrip.Protocol.pas'), encoding='utf-8-sig').read()
    check('as duas mensagens saem do mesmo texto, sem copia',
          proto.count("'{ \"Name\" : \"OPPTZControl\"") == 1)
    check('e o comando de ir ao preset tem nome proprio',
          'DVRIP_PTZ_PRESET_IR' in proto)

    # -------------------------------------------------- os dezenove comandos
    #
    # A lista da implementacao de referencia (python-dvr). Ela CONFIRMOU, nome
    # por nome, os quatro que eu tinha deduzido da familia -- ZoomTile,
    # ZoomWide, GotoPreset e SetPreset -- e trouxe os outros que faltavam.
    REF = ['DirectionUp', 'DirectionDown', 'DirectionLeft', 'DirectionRight',
           'DirectionLeftUp', 'DirectionLeftDown', 'DirectionRightUp',
           'DirectionRightDown', 'ZoomTile', 'ZoomWide', 'FocusNear',
           'FocusFar', 'IrisSmall', 'IrisLarge', 'SetPreset', 'GotoPreset',
           'ClearPreset', 'StartTour', 'StopTour']
    protoc = io.open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'src', 'Dvrip', 'VMS.Dvrip.Protocol.pas'), encoding='utf-8-sig').read()
    faltando = [c for c in REF if ("'%s'" % c) not in protoc]
    check('os dezenove comandos da referencia estao no codigo',
          not faltando, 'faltam: %s' % faltando)
    # O comentario que marcava zoom e preset como deducao sai: eles foram
    # confirmados. Deixar o aviso seria mandar procurar defeito onde nao ha.
    check('e nenhum deles segue marcado como deducao',
          'NAO vieram de captura' not in protoc)

    # ------------------------------------------------------ as duas formas
    #
    # A implementacao de referencia (python-dvr) monta OPPTZControl de dois
    # jeitos: ptz_step usa Pattern "SetBegin" COM o campo POINT, e ptz usa
    # Pattern "Start" SEM ele. Nos so tinhamos a primeira, que e a da captura
    # do iCSee e a que a Isis obedece. A Frente aceita essa e nao se move, e a
    # segunda nunca tinha sido tentada nela.
    def op(comando, passo, canal, preset, sessao, forma):
        ponto = ('"POINT" : { "bottom" : 0, "left" : 0, "right" : 0, '
                 '"top" : 0 }, ') if forma == 'passo' else ''
        padrao = 'SetBegin' if forma == 'passo' else 'Start'
        return ('{ "Name" : "OPPTZControl", "OPPTZControl" : { "Command" : "%s"'
                ', "Parameter" : { "AUX" : { "Number" : 0, "Status" : "On" }, '
                '"Channel" : %d, "MenuOpts" : "Enter", %s'
                '"Pattern" : "%s", "Preset" : %d, "Step" : %d, '
                '"Tour" : 0 } }, "SessionID" : "%s" }'
                % (comando, canal, ponto, padrao, preset, passo, sessao))

    check('a forma de passo continua identica a da captura',
          op('DirectionLeft', 5, 0, 65535, '0x2d', 'passo') == anda)
    outra = op('DirectionLeft', 5, 0, 65535, '0x2d', 'start')
    check('a outra forma troca o Pattern', '"Pattern" : "Start"' in outra)
    check('e tira o POINT', 'POINT' not in outra)
    check('e so isso muda entre as duas',
          outra.replace('"Pattern" : "Start"', '"Pattern" : "SetBegin"')
          == anda.replace('"POINT" : { "bottom" : 0, "left" : 0, '
                          '"right" : 0, "top" : 0 }, ', ''))

    proto2 = io.open(os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'src', 'Dvrip', 'VMS.Dvrip.Protocol.pas'), encoding='utf-8-sig').read()
    check('o codigo tem as duas formas', 'TDvripPtzForma = (fPasso, fStart)'
          in proto2)
    # Preset usa a forma que a referencia usa para preset, e nao a de mover.
    # Cada forma e usada onde a referencia a usa, e nao ha botao para escolher:
    # a Frente obedece as duas, entao escolher nao discrimina nada. O que a
    # fazia ignorar o comando era o AlarmInfo recusado.
    check('mover usa a forma de passo',
          'OpPtzJson(Comando, Passo, Canal, Preset, SessionHex, fPasso)'
          in proto2)
    check('e o preset usa a de Start, como na referencia',
          'OpPtzJson(Comando, 5, Canal, Preset, SessionHex, fStart)' in proto2)

    # ------------------------------------------------- as tres velocidades
    #
    # A tela manda a velocidade normalizada, em milesimos, e cada protocolo faz
    # a conta dele. No DVRIP e passo de 1 a 8. Os tres degraus da tela tem de
    # cair em passos DIFERENTES: dois degraus com o mesmo passo seriam dois
    # botoes que fazem a mesma coisa.
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pagina = io.open(os.path.join(raiz, 'src', 'UI', 'web', 'app-ui.html'),
                     encoding='utf-8-sig').read()
    i = pagina.index('<div id="ptz-vel">')
    niveis = [int(x) for x in
              re.findall(r'data-vel="(\d+)"', pagina[i:pagina.index('</div>', i)])]

    def passo(milesimos):
        # PassoDvripDe: round(v * 8), com piso em 1.
        return max(1, round(milesimos / 1000 * 8))

    check('a tela oferece tres velocidades', len(niveis) == 3, str(niveis))
    check('em ordem crescente', niveis == sorted(niveis), str(niveis))
    check('a mais rapida e o maximo normalizado', niveis[-1] == 1000)
    passos = [passo(v) for v in niveis]
    check('cada uma cai num passo DIFERENTE do DVRIP',
          len(set(passos)) == 3, str(passos))
    check('e a mais rapida chega ao passo 8, o teto do protocolo',
          passos[-1] == 8, str(passos))
    check('nenhuma cai em meio passo, onde o arredondamento seria discutivel',
          all(abs(v / 1000 * 8 - int(v / 1000 * 8)) != 0.5 for v in niveis))


def teste_ptz_no_aparelho(_pasta):
    """A PTZ de uma camera do aparelho e atendida pelo aparelho.

    Este e o defeito que existiu: a pagina so perguntava se havia PTZ quando
    havia um vmsserver escolhido, e o servidor local encaminhava /api/ptz para
    la. Quem conecta direto na camera nao tem servidor nenhum -- e e justamente
    ele quem tem a sessao DVRIP autenticada na mao. Resultado: os botoes nunca
    apareciam no caso em que eram mais faceis de atender.

    Nao da para provar isto por conta; o que da para provar e que as duas
    condicoes que causavam o defeito nao voltaram ao texto.
    """
    print('PTZ da camera do proprio aparelho')
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    pagina = io.open(os.path.join(raiz, 'src', 'UI', 'web', 'app-ui.html'),
                     encoding='utf-8-sig').read()
    i = pagina.index('function verSeTemPtz()')
    # Ate a chave que fecha a funcao, na coluna zero: as de dentro sao
    # indentadas, entao esta e sempre o fim.
    corpo = pagina[i:pagina.index(chr(10) + '}' + chr(10), i)]
    check('a pagina pergunta por PTZ sem exigir servidor',
          'comServidor' not in corpo)
    check('e ainda exige saber de que camera se trata',
          '!camAtual' in corpo)

    # A segunda metade do mesmo defeito: perguntar UMA vez respondia sempre
    # "nao tem sessao viva", porque no instante em que a tela abre a camera
    # ainda esta logando. A resposta muda com o tempo, entao a pergunta repete.
    esperas = pagina[pagina.index('var ESPERAS_PTZ_MS'):]
    esperas = esperas[esperas.index('[') + 1:esperas.index(']')]
    esperas = [int(x) for x in esperas.split(',')]
    check('a pergunta se repete enquanto a camera conecta', len(esperas) > 1)
    check('a primeira sai na hora, sem espera', esperas[0] == 0)
    check('as esperas so crescem', esperas == sorted(esperas))
    check('e a insistencia acaba, em vez de durar a tela inteira',
          30000 <= sum(esperas) <= 120000, '%d ms' % sum(esperas))
    # O teclado nasce FECHADO, atras de um botao: ele ocupa um canto do video e
    # a maior parte do tempo o que se quer e olhar a imagem.
    check('o teclado nasce fechado a cada abertura do ao vivo',
          'alternarPtz(false)' in corpo)
    fechar = pagina[pagina.index('function alternarPtz'):]
    fechar = fechar[:fechar.index(chr(10) + '}' + chr(10))]
    # Fechar com um movimento em curso tem de parar a camera: some-lo da tela
    # sem parar deixaria ela girando ate o teto de tempo, fora de vista.
    check('e fechar para o que estiver andando',
          'ptzParar()' in fechar)

    check('desiste quando a tela ou a camera mudou',
          "classList.contains(" + chr(34) + "on" + chr(34) + ")" in corpo
          and 'camAtual !== cam' in corpo)

    # -------------------------------------------------- a barreira de ponteiro
    #
    # A PTZ mora DENTRO do palco, e o palco pede setPointerCapture no
    # pointerdown para a pinca de zoom nao se perder. Sem barreira, apertar um
    # botao da PTZ borbulhava ate la, a captura mudava de dono no meio do
    # aperto, e o navegador passava a entregar os eventos ao palco: o botao de
    # velocidade ficava sem o pointerup que gera o click, e a seta levava um
    # pointerleave -- que e uma das paradas -- milissegundos depois de comecar.
    # O sintoma era a camera dar um cutucao em vez de andar enquanto apertada.
    i2 = pagina.index('id="palco"')
    j2 = pagina.index('id="ptz"')
    check('a PTZ fica dentro do palco, que e por isso que a barreira existe',
          i2 < j2)
    check('e o palco realmente toma a captura do ponteiro',
          'palco.setPointerCapture' in pagina)
    barreira = pagina[pagina.index('O que comeca na PTZ e da PTZ'):]
    barreira = barreira[:barreira.index('});') + 3]
    for evento in ('pointerdown', 'pointerup', 'pointercancel'):
        check('a PTZ segura o %s dela' % evento, evento in barreira)
    check('segurando por stopPropagation, e nao por preventDefault',
          'stopPropagation' in barreira and 'preventDefault' not in barreira)

    local = io.open(os.path.join(raiz, 'src', 'Api', 'VMS.Local.Server.pas'),
                    encoding='utf-8-sig').read()
    rota = local.find("Caminho = '/api/ptz'")
    encaminha = local.find("Caminho.StartsWith('/api/')")
    check('o servidor do app atende /api/ptz antes de encaminhar',
          0 <= rota < encaminha,
          'rota=%d encaminhamento=%d' % (rota, encaminha))
    # A rota so e dele quando NAO ha escopo de servidor: com escopo, a camera e
    # do servidor e a sessao viva esta la, nao aqui.
    trecho = local[max(rota, 0):max(encaminha, 0)]
    check('e so quando o pedido nao tem escopo de servidor',
          "Params.Values['server']" in trecho and "= ''" in trecho)
    check('o comando sai pela sessao ja autenticada, e nao por um login novo',
          'TPtzRegistry.Achar' in local)
    # Nenhum dos dois caminhos: a resposta diz OS DOIS que faltaram, porque
    # "sem PTZ" sozinho nao distingue camera fixa de camera desconectada.
    check('camera sem nenhum caminho vira 503, e nao um erro mudo',
          'sem sessao viva e sem endereco de ONVIF' in local)

    # ------------------------------------------------------ a procura de ONVIF
    #
    # A porta do ONVIF nao se adivinha: a norma nao fixa nenhuma e nenhuma das
    # cameras daqui usa a 80. Sem procura, cadastrar camera nova exigiria
    # capturar a rede do aplicativo do fabricante -- que foi como a 5000 da
    # Ayla apareceu, e nao e pedido que se faca a alguem.
    onvif = io.open(os.path.join(raiz, 'vms', 'src', 'Onvif',
                                 'Vms.Onvif.Client.pas'),
                    encoding='utf-8-sig').read()
    i = onvif.index('function PortasComunsOnvif: TArray<Integer>;', 
                    onvif.index('implementation'))
    portas = [int(x) for x in
              re.findall(r'\d+', onvif[onvif.index('[', i):onvif.index(']', i)])]
    check('a procura tenta a porta da norma', 80 in portas)
    check('e a porta em que a Ayla realmente atende', 5000 in portas)
    check('sem porta repetida, que so custaria espera',
          len(portas) == len(set(portas)), str(portas))
    check('a lista e curta: cada porta custa uma espera',
          3 <= len(portas) <= 14, '%d portas' % len(portas))
    check('a procura para na primeira com PTZ',
          'if Achado.TemPtz then Exit;' in onvif)
    check('e distingue "nao ha nada" de "ha camera fixa"',
          'RespondeOnvif' in onvif)
    check('o servidor do app expoe a procura', "'/api/ptz/procurar'" in local)

    # Os dois hospedeiros aceitam o endereco escrito do mesmo jeito. No app ele
    # vem do cadastro da camera; no vmsserver, da chave ptz.<camera>.xaddr. Se
    # so um deles passasse pelo EnderecoOnvif, "192.168.0.6:5000" funcionaria
    # de um lado e falharia calado do outro -- os dois hospedeiros aceitam o
    # mesmo texto ou nenhum.
    api = io.open(os.path.join(raiz, 'vms', 'src', 'Api', 'Vms.Server.Api.pas'),
                  encoding='utf-8-sig').read()
    check('o vmsserver normaliza o endereco escrito na chave dele',
          'EnderecoOnvif(XAddr, Url)' in api)
    check('e nao usa mais so o palpite da porta 80',
          'XAddr := EnderecoPadrao(' not in api)
    # Sem palpite nenhum, alias: chave vazia responde "sem ONVIF" na hora.
    # Medido no servidor do usuario, adivinhar a porta 80 custava 8 segundos
    # por pergunta numa camera que nao tem ONVIF, e a tela pergunta ate sete
    # vezes ao abrir o ao vivo.
    i5 = api.index('function TApiRouter.ClienteOnvif')
    cli = api[i5:api.index('function ', i5 + 10)]
    check('chave de ONVIF vazia nao vira tentativa na porta 80',
          "if Trim(XAddr) = '' then Exit;" in cli)

    # A senha da camera vai no CORPO, nunca na URL: em URL ela ficaria no
    # historico do navegador e em qualquer log de acesso pelo caminho.
    j = pagina.index('$("f-procurar").onclick')
    handler = pagina[j:pagina.index(chr(10) + '};', j)]
    check('a procura vai por POST', '"POST"' in handler)
    check('e a senha nao entra na URL',
          'password' in handler and
          'procurar?' not in handler and 'password=' not in handler)
    check('e o ONVIF e tentado quando nao ha sessao DVRIP',
          'ServirPtzOnvif' in local and 'MoverContinuo' in local)


def teste_cadastro_de_cameras(_pasta):
    """A tela que cadastra as cameras do servidor, e o que ela promete.

    Ate ela existir, mexer numa camera do vmsserver so dava por /api/sql -- a
    mesma rota que le camera_endpoint.password em texto claro e sabe apagar
    qualquer tabela.

    Tres promessas aqui valem verificacao, porque as tres sao invisiveis quando
    estao certas e caras quando quebram: a senha nunca sai do servidor,
    ninguem renomeia uma camera, e ninguem apaga uma.
    """
    print('cadastro de cameras do servidor')
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    pagina = io.open(os.path.join(raiz, 'src', 'UI', 'web', 'cameras-ui.html'),
                     encoding='utf-8').read()
    check('a pagina e ASCII puro, como as outras',
          all(ord(c) < 127 for c in pagina))
    # No SCRIPT, e nao na pagina toda: o comentario do cabecalho cita o
    # /api/sql justamente para dizer por que esta tela existe.
    script = pagina[pagina.index('<script>'):]
    check('ela le o cadastro pela rota propria, e nao pelo /api/sql',
          '/api/config/cameras' in script and '/api/sql' not in script)
    check('e leva o escopo do servidor, para funcionar dentro do app',
          'server=' in pagina)

    api = io.open(os.path.join(raiz, 'vms', 'src', 'Api', 'Vms.Server.Api.pas'),
                  encoding='utf-8-sig').read()
    corpo = api[api.index('function TApiRouter.HandleConfigCamerasGet'):
                api.index('function TApiRouter.HandleCameras:')]

    # ------------------------------------------------------------- a senha
    #
    # O que nao sai do servidor nao vaza pelo cache do navegador, pelo
    # historico nem por uma captura de tela. A tela nao precisa da senha para
    # nada: precisa saber se EXISTE uma.
    check('a leitura devolve se ha senha, e nao a senha',
          "'temSenha'" in corpo)
    check('nenhum AddPair despeja a senha na resposta',
          "AddPair('password'" not in corpo)
    check('campo de senha vazio mantem a que ja esta gravada',
          'Antigas.TryGetValue' in corpo)

    # ------------------------------------------------------------- o nome
    #
    # O nome e a pasta em disco, a rota RTSP e o ?camera= de tudo. Renomear
    # separaria a camera das gravacoes dela, que ficariam na pasta antiga.
    check('renomear e recusado, e com o motivo',
          'renomear a separaria' in corpo)
    check('e o nome nao pode virar caminho', "Pos('..', Nome)" in corpo)

    # ------------------------------------------------------------- apagar
    #
    # Apagar a linha da camera leva junto, por cascata, o inventario das
    # gravacoes, os eventos e as miniaturas -- e os .vms ficariam no disco sem
    # ninguem que os indexe. Desabilitar para a gravacao e guarda o passado.
    check('a rota nao apaga camera nenhuma',
          'DELETE FROM camera WHERE' not in corpo)
    check('so os enderecos dela, que sao regravados em seguida',
          'DELETE FROM camera_endpoint WHERE camera_id' in corpo)

    # A captura passa a valer sozinha, em segundos: a rota anota a camera que
    # mudou e a thread principal aplica na volta seguinte do laco dela. Fazer
    # isso na thread do HTTP prenderia a resposta enquanto o supervisor antigo
    # fecha a conexao com a camera, e poria duas threads na mesma lista.
    check('a resposta diz que a mudanca esta sendo aplicada',
          "'aplicando'" in corpo)
    check('a rota anota a camera em vez de trabalhar na thread do HTTP',
          'FPendentes.Add(Nome)' in corpo)
    check('e a tela avisa que a captura reinicia', 'aviso-boot' in pagina)

    dpr = io.open(os.path.join(raiz, 'vms', 'vmsserver.dpr'),
                  encoding='utf-8-sig').read()
    check('a thread principal drena a fila no laco dela',
          'TomarCamerasPendentes' in dpr)
    check('e reconcilia UMA camera por vez, sem tocar nas outras',
          'ReconciliarCamera' in dpr and 'BuildServerSupervisors' in dpr)
    check('a camera nova entra na lista que a API reconhece',
          'DefinirCameras' in dpr)
    check('e tambem sob analise', 'AcrescentarCamera' in dpr)
    # Parar antes de montar, sempre: duas sessoes na mesma camera gravariam o
    # mesmo video em dois arquivos e brigariam pelo mesmo nome.
    i3 = dpr.index('procedure ReconciliarCamera')
    rec = dpr[i3:dpr.index('procedure RunApp')]
    check('a captura antiga sai antes de a nova entrar',
          rec.index('.Stop') < rec.index('MontarSupervisor'))

    # A procura de ONVIF do servidor roda NO servidor: o que o navegador de
    # quem abriu a tela alcanca nao e o que a maquina do servidor alcanca.
    check('o servidor tem a procura de ONVIF dele',
          "'config/ptz/procurar'" in api)
    check('e a pagina a chama por POST, com a senha no corpo',
          'config/ptz/procurar' in pagina and 'method: "POST"' in pagina)

    # A pagina e servida pelos DOIS: pelo vmsserver, e pelo app, que a mostra
    # num iframe com o escopo do servidor.
    local = io.open(os.path.join(raiz, 'src', 'Api', 'VMS.Local.Server.pas'),
                    encoding='utf-8-sig').read()
    check('o vmsserver serve a pagina', "'cameras-ui.html'" in api)

    # ----------------------------------------- a interface do aparelho
    #
    # No Android a interface e copiada do APK para uma pasta gravavel, e a
    # copia da RTL so CRIA o que falta: instalar por cima deixava o aparelho
    # servindo a pagina da versao anterior enquanto o binario ja era o novo.
    # Custou uma hora de procura no lugar errado.
    assets = io.open(os.path.join(raiz, 'src', 'Android',
                                  'VMS.Android.UiAssets.pas'),
                     encoding='utf-8-sig').read()
    check('o app le a interface de dentro do proprio pacote',
          'getPackageCodePath' in assets and 'TZipFile' in assets)
    check('e do mesmo prefixo que o Deployment usa',
          "'assets/internal/ui/'" in assets)
    # Grava por cima sem comparar: o conteudo ja esta descompactado na mao, e
    # comparar custaria ler o arquivo inteiro do disco para, no caso comum,
    # concluir que nao ha nada a fazer. Sem comparacao a garantia tambem deixa
    # de ser condicional -- a pasta E a do pacote, sem "se".
    check('grava por cima, sem ler o disco para decidir',
          'TFile.WriteAllBytes' in assets and
          'CompareMem' not in assets and 'ReadAllBytes' not in assets)
    check('e diz no log quanto veio do pacote',
          'interface do pacote' in assets)
    check('pacote sem interface e AVISO, e nao silencio',
          'nao trouxe interface nenhuma' in assets)
    # Pasta padrao, e nao UiDir: a variavel de ambiente aponta o FONTE na
    # maquina de quem desenvolve, e sobrescreve-lo seria o contrario do que
    # ela serve.
    check('escreve na pasta do aparelho, nunca na apontada pela variavel',
          'UiDirPadrao' in assets and 'UiDir;' not in assets)

    dpr_app = io.open(os.path.join(raiz, 'rtsplayer.dpr'),
                      encoding='utf-8-sig').read()
    check('a unit esta no projeto do app', 'VMS.Android.UiAssets' in dpr_app)
    inicio = io.open(os.path.join(raiz, 'src', 'UI', 'Inicio.pas'),
                     encoding='utf-8-sig').read()
    i4 = inicio.index('AtualizarUiDoPacote(FLogger)')
    check('e roda ANTES de o servidor local existir',
          i4 < inicio.index('FLocal := TLocalServer.Create'))
    check('e o app tambem, para mostra-la por dentro',
          "'cameras-ui.html'" in local)

    # ------------------------------- o cadastro do APARELHO, mesmo contrato
    #
    # A tela de cameras deste aparelho (app-ui.html, /api/app/cameras) segue o
    # mesmo trato do /api/config/cameras do servidor: a senha nao sai, e campo
    # vazio na volta quer dizer "mantenha a que ja esta la". A resposta atravessa
    # a rede local -- o servidor do app tambem atende de fora do aparelho --,
    # entao aqui vale pelo mesmo motivo.
    comum = io.open(os.path.join(raiz, 'src', 'UI', 'UI.Common.pas'),
                    encoding='utf-8-sig').read()
    # Da implementation em diante: os mesmos nomes aparecem antes, na
    # interface, e uma fatia contada dali sairia ao contrario.
    corpo = comum[comum.index('\nimplementation'):]
    impl = corpo[corpo.index('function CamerasToJsonImpl'):
                 corpo.index('function CamerasToJson(')]
    # Os dois lugares onde a senha aparece -- o caminho principal e cada
    # caminho alternativo -- estao os dois atras do ComSenha.
    check('a senha so sai do serializador quando pedida pelo nome',
          impl.count("AddPair('password'") == 2 and
          impl.count('if ComSenha then') == 2 and
          impl.count("AddPair('temSenha'") == 2)
    check('e sem ela vai o fato de existir uma',
          'function CamerasToJsonSemSenha' in comum and
          'CamerasToJsonImpl(Cams, False)' in comum)
    # O arquivo em disco continua com as senhas: e de la que o app reconecta a
    # camera. Trocar os dois seria arrancar a credencial do cadastro inteiro.
    check('o cameras.json em disco segue com as senhas',
          'CamerasToJsonImpl(Cams, True)' in comum and
          'CamerasToJson(FCameras), TEncoding.UTF8' in inicio)
    check('a rota do aparelho e que devolve sem elas',
          'Result := CamerasToJsonSemSenha(FCameras)' in inicio)

    # Campo vazio = mantenha. Sem isto, gravar UMA camera apagaria a senha de
    # todas: a tela reenvia a lista inteira, e nenhuma das senhas foi ate la.
    grav = inicio[inicio.index('function TForm1.GravarConfigCameras'):
                  inicio.index('procedure TForm1.PararAoVivo')]
    check('campo de senha vazio mantem a que ja esta gravada',
          'MesclarSenhas(Novas, FCameras)' in grav)
    check('e a reposicao acontece antes de o cadastro ser trocado',
          grav.index('MesclarSenhas(Novas, FCameras)') <
          grav.index('FCameras := Novas'))
    # FCameras e da thread principal, e quem chama isto e uma thread do Indy.
    check('dentro do Synchronize, que e onde FCameras pode ser lida',
          grav.index('TThread.Synchronize') >
          grav.index('MesclarSenhas(Novas, FCameras)'))
    mescla = corpo[corpo.index('procedure MesclarSenhas('):
                   corpo.index('function CamerasFromJson(')]
    check('casa a camera pelo nome', 'SameText(Atuais[K].Name' in mescla)
    # Renomear e o unico caso em que o nome nao acha: a tela troca o item no
    # lugar, entao a posicao ainda serve. Lista de outro tamanho e camera criada
    # ou excluida, e ai a posicao nao diz mais nada.
    check('e pela posicao so quando ninguem foi criado nem excluido',
          'MesmoTamanho' in mescla)
    check('os caminhos alternativos tambem', 'Endpoints[K].Password' in mescla)

    app_ui = io.open(os.path.join(raiz, 'src', 'UI', 'web', 'app-ui.html'),
                     encoding='utf-8').read()
    script_app = app_ui[app_ui.index('<script>'):]
    check('a tela do aparelho e ASCII puro, como as outras',
          all(ord(c) < 127 for c in app_ui))
    check('o campo de senha nasce vazio, e nao com o valor',
          '$("f-senha").value = "";' in script_app and
          'c.password || ""' not in script_app)
    check('e a tela diz que ha uma guardada',
          'temSenha' in script_app and 'f-senha-ajuda' in app_ui)
    # A procura de ONVIF sai do MESMO formulario, e o campo de senha dele agora
    # nasce vazio: sem o nome junto, ela iria sem credencial -- que da no mesmo
    # que ir com a errada, porque camera com senha responde 401 e some da lista.
    check('a procura de ONVIF leva o nome da camera',
          'camera: $("f-nome").value.trim()' in script_app)
    check('e a rota completa com a senha do cadastro',
          "Obj.GetValue<string>('camera', '')" in local and
          'FOnOnvifCam(Camera, XAddrCad, UsuarioCad, SenhaCad)' in local)


def main():
    pasta = tempfile.mkdtemp(prefix='vms_selftest_')
    try:
        teste_formato(pasta)
        teste_ancora_nao_desloca_payload(pasta)
        teste_indice(pasta)
        teste_sidecar(pasta)
        teste_resumo_do_inventario(pasta)
        teste_finaliza_gravacao_aberta(pasta)
        teste_crc(pasta)
        teste_segmentos(pasta)
        teste_fragmento(pasta)
        teste_varredura(pasta)
        teste_ritmo(pasta)
        teste_ancora_do_gravador(pasta)
        teste_eventos_formato(pasta)
        teste_eventos_consulta(pasta)
        teste_movimento(pasta)
        teste_grade_e_delta(pasta)
        teste_parameter_sets_da_sequencia(pasta)
        teste_entrada_no_keyframe(pasta)
        teste_bloco_do_anel_ao_vivo(pasta)
        teste_onvif(pasta)
        teste_ptz_dvrip(pasta)
        teste_ptz_no_aparelho(pasta)
        teste_cadastro_de_cameras(pasta)
        teste_agregacao_eventos(pasta)
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
