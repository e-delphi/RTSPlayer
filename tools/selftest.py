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
        teste_eventos_formato(pasta)
        teste_eventos_consulta(pasta)
        teste_movimento(pasta)
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
