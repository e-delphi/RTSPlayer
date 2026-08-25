"""Gera Vms.Db.Schema.Sql.pas a partir de vms/src/Db/schema-v1.sql.

O `.sql` e a fonte da verdade: e ele que o `tools/testschema.py` exercita no
sqlite de verdade, e e ele que alguem le para entender o banco. A unit gerada e
so o mesmo texto embutido no executavel, para o servidor nao depender de um
arquivo solto ao lado dele — arquivo que falta e um modo de falha a mais numa
subida que ja tem varios.

Embutir como string, e nao como recurso (.rc/.res): recurso exige um passo de
build a mais, e este projeto e compilado a mao na IDE.

Os comentarios saem na geracao. Nao e economia de bytes — e que eles tem acento,
e literal de string com acento em .pas sem BOM depende de como o compilador
adivinha a codificacao. O texto que sobra e ASCII puro, e a geracao falha se nao
for. O porque de cada coluna continua no `.sql`, que e onde se vai ler.

    python tools/gen_schema_pas.py
"""

import io
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
ENTRADA = os.path.join(AQUI, '..', 'vms', 'src', 'Db', 'schema-v1.sql')
SAIDA = os.path.join(AQUI, '..', 'vms', 'src', 'Db', 'Vms.Db.Schema.Sql.pas')


def corta_comentario(linha):
    """Tira o `--` para o fim, respeitando aspas.

    Cortar por `linha.split('--')` quebraria no dia em que um valor semeado
    tivesse dois hifens dentro. Custa cinco linhas fazer certo.
    """
    dentro = False
    i = 0
    while i < len(linha):
        c = linha[i]
        if c == "'":
            # '' dentro de string e uma aspa escapada, nao o fim dela
            if dentro and i + 1 < len(linha) and linha[i + 1] == "'":
                i += 2
                continue
            dentro = not dentro
        elif c == '-' and not dentro and linha[i + 1:i + 2] == '-':
            return linha[:i].rstrip()
        i += 1
    return linha.rstrip()


def limpa(texto):
    saida = []
    branco_anterior = False
    for linha in texto.splitlines():
        l = corta_comentario(linha)
        if not l.strip():
            # uma linha em branco basta para separar comandos
            if not branco_anterior and saida:
                saida.append('')
                branco_anterior = True
            continue
        branco_anterior = False
        saida.append(l)
    return saida


def main():
    sql = io.open(ENTRADA, encoding='utf-8').read()
    linhas = limpa(sql)

    nao_ascii = [l for l in linhas if any(ord(c) > 126 for c in l)]
    if nao_ascii:
        print('ERRO: sobrou caractere nao-ASCII depois de tirar os comentarios:')
        for l in nao_ascii[:5]:
            print('   ', l)
        return 1

    corpo = []
    for i, l in enumerate(linhas):
        virgula = ',' if i < len(linhas) - 1 else ''
        corpo.append("    '%s'%s" % (l.replace("'", "''"), virgula))

    unit = '''unit Vms.Db.Schema.Sql;

// GERADO por tools/gen_schema_pas.py — NAO EDITE ESTA UNIT.
//
// A fonte e vms/src/Db/schema-v1.sql. Mexeu la, rode o gerador de novo:
//
//     python tools/gen_schema_pas.py
//
// Os comentarios do .sql nao vem para ca (ver o cabecalho do gerador); o porque
// de cada coluna esta no arquivo, que e onde se vai ler. Os comandos sao
// identicos, e o tools/testschema.py confere que os dois produzem o mesmo banco.

interface

const
  // O que este script deixa em PRAGMA user_version.
  SCHEMA_VERSION = 1;

// O script inteiro, para o TFDScript executar de uma vez.
function SchemaSql: string;

implementation

uses
  System.SysUtils,
  System.Classes;

const
  LINHAS: array[0..%d] of string = (
%s
  );

function SchemaSql: string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := Low(LINHAS) to High(LINHAS) do
    begin
      SB.Append(LINHAS[I]);
      SB.Append(sLineBreak);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
''' % (len(linhas) - 1, '\n'.join(corpo))

    # utf-8 no arquivo: os COMENTARIOS da unit tem acento, como em todo o
    # projeto. O que precisa ser ASCII sao os LITERAIS, e isso ja foi
    # conferido acima — literal com acento em .pas sem BOM e loteria.
    io.open(SAIDA, 'w', encoding='utf-8', newline='\r\n').write(unit)
    print('gerado %s' % os.path.normpath(SAIDA))
    print('  %d linhas de SQL, %d bytes de unit' % (len(linhas), len(unit)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
