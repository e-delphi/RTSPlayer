# -*- coding: utf-8 -*-
"""Exercita o schema-v1.sql no sqlite de verdade.

Nao e decoracao: confere que o DDL cria, que os CHECK recusam o que deve
recusar, que a cascata limpa o que deve limpar, e que as quatro consultas que a
API vai fazer devolvem o que o plano promete.
"""
import io
import os
import sqlite3
import sys

SQL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "vms", "src", "Db", "schema-v1.sql")
OK = [0]
FALHA = []


def check(nome, cond, detalhe=''):
    if cond:
        OK[0] += 1
    else:
        FALHA.append(nome + ((' — ' + detalhe) if detalhe else ''))
        print('  FALHA', nome, detalhe)


def recusa(con, nome, sql, args=()):
    """O CHECK tem de barrar. Passar em silencio e o defeito."""
    try:
        con.execute(sql, args)
        check(nome, False, 'aceitou o que devia recusar')
    except sqlite3.IntegrityError:
        check(nome, True)


con = sqlite3.connect(':memory:')
con.executescript(io.open(SQL, encoding='utf-8').read())
con.execute('PRAGMA foreign_keys = ON')

# ------------------------------------------------------------------ estrutura
tab = [r[0] for r in con.execute(
    "select name from sqlite_master where type='table' order by name")]
idx = [r[0] for r in con.execute(
    "select name from sqlite_master where type='index' and sql is not null order by name")]
print('tabelas (%d): %s' % (len(tab), ', '.join(tab)))
print('indices (%d): %s' % (len(idx), ', '.join(idx)))
check('9 tabelas', len(tab) == 9, str(tab))
check('user_version = 1', con.execute('pragma user_version').fetchone()[0] == 1)
n = con.execute('select count(*) from setting').fetchone()[0]
check('padroes semeados', n >= 30, '%d chaves' % n)

# INSERT OR IGNORE nao pode sobrescrever o que o usuario mudou
con.execute("update setting set value='9999' where key='rtspPort'")
texto = io.open(SQL, encoding='utf-8').read()
ini = texto.index('INSERT OR IGNORE INTO setting')
semente = texto[ini:texto.index(';', texto.index("'analytics.classes'"))+1]
con.executescript(semente)
check('rodar de novo nao sobrescreve config do usuario',
      con.execute("select value from setting where key='rtspPort'").fetchone()[0] == '9999')

AGORA = 1755950000000

# -------------------------------------------------------------------- CHECKs
con.execute("insert into camera(id,name,created_at_ms,updated_at_ms) values(1,'frente',?,?)",
            (AGORA, AGORA))
recusa(con, 'nome de camera duplicado (mesmo em outra caixa) e recusado',
       "insert into camera(name,created_at_ms,updated_at_ms) values('FRENTE',0,0)")
recusa(con, 'nome de camera vazio e recusado',
       "insert into camera(name,created_at_ms,updated_at_ms) values('',0,0)")
recusa(con, 'evento que termina antes de comecar e recusado',
       "insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms)"
       " values(1,2000,1000,0,'movimento',0.5,0)")
recusa(con, 'score fora de 0..1 e recusado',
       "insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms)"
       " values(1,1000,2000,0,'movimento',17,0)")
recusa(con, 'tipo de evento desconhecido e recusado',
       "insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms)"
       " values(1,1000,2000,5,'movimento',0.5,0)")
recusa(con, 'caixa fora do quadro e recusada',
       "insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms,box_r)"
       " values(1,1000,2000,1,'person',0.5,0,1.4)")
recusa(con, 'evento de camera inexistente e recusado',
       "insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms)"
       " values(99,1000,2000,0,'movimento',0.5,0)")
recusa(con, 'dois endpoints na mesma ordem sao recusados',
       "insert into camera_endpoint(camera_id,ord,url) values(1,0,'a'),(1,0,'b')")
recusa(con, 'gravacao com o mesmo nome na mesma camera e recusada',
       "insert into recording(camera_id,name,start_ms,end_ms,duration_ms,bytes,blocks,"
       "stamp_size,stamp_mtime_ms) values(1,'x.vms',0,0,0,0,0,0,0),"
       "(1,'x.vms',0,0,0,0,0,0,0)")

# ------------------------------------------------------------------- dados
con.execute("insert into camera_endpoint(camera_id,ord,label,url,transports)"
            " values(1,0,'Local','rtsp://192.168.100.2:555','tcp,udp')")
con.execute("insert into camera_endpoint(camera_id,ord,label,url)"
            " values(1,1,'Tailnet','rtsp://100.1.2.3:8554/live/frente')")

DIA = 86400000
for i in range(3):                       # 3 arquivos de 1 h no mesmo dia
    con.execute("insert into recording(camera_id,name,start_ms,end_ms,duration_ms,"
                "bytes,blocks,closed,indexed,has_video,video_codec,width,height,"
                "stamp_size,stamp_mtime_ms) values(1,?,?,?,?,?,?,1,1,1,1,1920,1080,?,?)",
                ('f%d.vms' % i, AGORA + i*3600000, AGORA + (i+1)*3600000,
                 3600000, 1000, 10, 1000, AGORA))
# ontem, para a retencao ter o que apagar
con.execute("insert into recording(camera_id,name,start_ms,end_ms,duration_ms,bytes,"
            "blocks,closed,indexed,stamp_size,stamp_mtime_ms)"
            " values(1,'velho.vms',?,?,3600000,1000,10,1,1,1000,?)",
            (AGORA - DIA, AGORA - DIA + 3600000, AGORA))

con.execute("insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms)"
            " values(1,?,?,0,'movimento',0.05,?)", (AGORA-120000, AGORA+60000, AGORA))
con.execute("insert into event(camera_id,start_ms,end_ms,kind,name,score,obj_count,"
            "box_l,box_t,box_r,box_b,created_at_ms)"
            " values(1,?,?,1,'person',0.87,3,0.31,0.22,0.48,0.91,?)",
            (AGORA+10000, AGORA+12000, AGORA))
con.execute("insert into event(camera_id,start_ms,end_ms,kind,name,score,created_at_ms)"
            " values(1,?,?,1,'car',0.4,?)", (AGORA+900000, AGORA+901000, AGORA))

con.execute("insert into thumb(camera_id,minute_ms,state,path,bytes,width,height,"
            "created_at_ms) values(1,?,0,'frente/thumbs/2026-08-23/1200.jpg',4000,160,90,?)",
            (AGORA - AGORA % 60000, AGORA))
con.execute("insert into thumb(camera_id,minute_ms,state,created_at_ms)"
            " values(1,?,1,?)", (AGORA + 60000, AGORA))

con.execute("insert into analysis_progress(camera_id,analyzed_to_ms,frames,"
            "decode_failures,model,updated_at_ms) values(1,?,1800,37,'yolo26s.onnx',?)",
            (AGORA, AGORA))
con.execute("insert into log(at_ms,level,tag,camera_id,message)"
            " values(?,2,'analytics.frente',1,'1800 quadros analisados')", (AGORA,))

# ------------------------------------------ as consultas que a API vai fazer
dias = con.execute(
    "select date(start_ms/1000,'unixepoch','localtime') dia, min(start_ms), max(end_ms),"
    " sum(duration_ms), count(*) from recording where camera_id=1"
    " group by dia order by dia").fetchall()
check('/api/days agrupa por dia local', len(dias) == 2, str(dias))
check('e soma a duracao do dia', dias[-1][3] == 3*3600000, str(dias[-1]))

MAX_EV = 300000   # analytics.maxEventMs — e o piso da consulta
jan = [r[0] for r in con.execute(
    "select name from event where camera_id=1 and start_ms>=? and start_ms<=?"
    " and end_ms>=? order by start_ms",
    (AGORA - MAX_EV, AGORA + 60000, AGORA))]
check('janela pega o evento que COMECOU antes dela', 'movimento' in jan, str(jan))
check('e nao pega o que esta fora', 'car' not in jan, str(jan))

so_obj = [r[0] for r in con.execute(
    "select name from event where camera_id=1 and kind=1 and start_ms between ? and ?",
    (AGORA - MAX_EV, AGORA + 60000))]
check('filtro por tipo isola os objetos', so_obj == ['person'], str(so_obj))

t = con.execute("select state from thumb where camera_id=1 and minute_ms=?",
                (AGORA + 60000,)).fetchone()
check('minuto sem imagem fica lembrado no banco', t and t[0] == 1)

plano = con.execute(
    "explain query plan select * from event where camera_id=1 and start_ms>=? and start_ms<=?",
    (0, 0)).fetchall()
usa_idx = any('ix_event_window' in str(r) for r in plano)
check('a consulta de janela usa o indice (nao varre a tabela)', usa_idx, str(plano))

# ------------------------------------------------------------------ cascata
con.execute("delete from recording where camera_id=1 and start_ms < ?", (AGORA - 3600000,))
check('retencao apaga a gravacao velha por faixa',
      con.execute('select count(*) from recording').fetchone()[0] == 3)

con.execute('delete from camera where id=1')
vazios = {t: con.execute('select count(*) from %s' % t).fetchone()[0]
          for t in ('camera_endpoint', 'recording', 'event', 'thumb', 'analysis_progress')}
check('apagar a camera leva junto tudo o que era dela',
      all(v == 0 for v in vazios.values()), str(vazios))
orfao = con.execute('select camera_id from log').fetchone()[0]
check('mas o log sobrevive, com a camera anulada', orfao is None)

# ------------------------------------- a unit gerada nao pode divergir do .sql
#
# O servidor executa o SQL EMBUTIDO (Vms.Db.Schema.Sql.pas), nao este arquivo.
# Se alguem editar o .sql e esquecer de rodar o gerador, o banco em producao
# sera outro — e ninguem notaria. Esta checagem existe para notar.
#
# A comparacao NAO e do texto que o sqlite guarda em sqlite_master: ele preserva
# o CREATE original, comentarios inclusive, e o gerador tira os comentarios de
# proposito. Comparar aquilo acusaria diferenca em 7 de 18 objetos com os dois
# bancos identicos. O que se compara e o que o gerador PRODUZIRIA agora contra o
# que esta no .pas — invariante direta, e que pega ate um CHECK alterado, que
# nenhum `pragma table_info` mostraria.
PAS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "vms", "src", "Db", "Vms.Db.Schema.Sql.pas")


def sql_da_unit(caminho):
    """Volta o script a partir dos literais Pascal da unit gerada."""
    texto = io.open(caminho, encoding="utf-8").read()
    ini = texto.index("LINHAS: array")
    ini = texto.index("(", ini) + 1
    fim = texto.index("\n  );", ini)
    linhas = []
    for bruta in texto[ini:fim].splitlines():
        bruta = bruta.strip().rstrip(",")
        if not bruta.startswith("'"):
            continue
        linhas.append(bruta[1:-1].replace("''", "'"))
    return "\n".join(linhas)


def estrutura(con):
    """Colunas, chaves estrangeiras e indices de cada tabela."""
    out = {}
    for (nome,) in con.execute(
            "select name from sqlite_master where type='table' order by name"):
        out["col:" + nome] = [tuple(r[1:]) for r in
                              con.execute("pragma table_info(%s)" % nome)]
        out["fk:" + nome] = [tuple(r[2:]) for r in
                             con.execute("pragma foreign_key_list(%s)" % nome)]
        out["idx:" + nome] = sorted(
            (r[1], r[2], tuple(x[2] for x in
                               con.execute("pragma index_info(%s)" % r[1])))
            for r in con.execute("pragma index_list(%s)" % nome))
    return out


if not os.path.exists(PAS):
    check("Vms.Db.Schema.Sql.pas existe", False, "rode: python tools/gen_schema_pas.py")
else:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_schema_pas
    esperado = "\n".join(gen_schema_pas.limpa(io.open(SQL, encoding="utf-8").read()))
    check("a unit gerada esta em dia com o .sql",
          sql_da_unit(PAS) == esperado, "rode: python tools/gen_schema_pas.py")

    # E, independente disso, os dois bancos tem de sair iguais.
    a = sqlite3.connect(":memory:")
    a.executescript(io.open(SQL, encoding="utf-8").read())
    b = sqlite3.connect(":memory:")
    b.executescript(sql_da_unit(PAS))
    check("e os dois produzem a mesma estrutura", estrutura(a) == estrutura(b))
    check("a mesma configuracao semeada",
          a.execute("select key,value from setting order by key").fetchall() ==
          b.execute("select key,value from setting order by key").fetchall())
    check("a mesma user_version",
          a.execute("pragma user_version").fetchone()
          == b.execute("pragma user_version").fetchone())

print()
if FALHA:
    print('FALHOU: %d de %d' % (len(FALHA), len(FALHA) + OK[0]))
    for f in FALHA:
        print('  -', f)
    sys.exit(1)
print('passou: %d verificacoes' % OK[0])
