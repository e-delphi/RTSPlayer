"""Embute paginas .html em units Pascal.

Mesma ideia do gen_schema_pas.py, e pelo mesmo motivo: o `.html` e a fonte da
verdade -- da para abrir no navegador, editar com realce de sintaxe e testar --,
e a unit gerada e so o mesmo texto embutido no executavel, para nada depender de
um arquivo solto ao lado dele.

O HTML tem de ser ASCII PURO (acento por entidade: &ccedil;, &atilde;...). O
texto vira literal de string Pascal, e literal com acento em .pas sem BOM
depende de como o compilador adivinha a codificacao. A geracao falha se achar
byte fora do ASCII, dizendo em qual pagina e em qual linha.

    python tools/gen_ui_pas.py

Para acrescentar uma pagina, some uma linha em PAGINAS.
"""

import io
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.join(AQUI, '..')


class Pagina(object):
    def __init__(self, html, unit, funcao, onde):
        self.html = os.path.join(RAIZ, html)
        self.pas = os.path.join(RAIZ, os.path.dirname(html), unit + '.pas')
        self.rel = html
        self.unit = unit
        self.funcao = funcao
        self.onde = onde


PAGINAS = [
    # A sintonia do detector de movimento, servida pelo proprio vmsserver.
    Pagina('vms/src/Api/motion-ui.html',
           'Vms.Server.Ui.Html', 'MotionUiHtml',
           'A pagina e servida em /ui/motion pelo Vms.Server.Api.'),


    # A faixa de eventos que roda dentro do app, embaixo do video. Servida
    # pelo vmsserver para o fetch dela ser mesma origem: carregada por
    # LoadFromStrings ela nao poderia buscar em http:// (conteudo misto).
    Pagina('vms/src/Api/events-ui.html',
           'Vms.Server.Events.Html', 'EventsUiHtml',
           'A pagina e servida em /ui/events pelo Vms.Server.Api.'),

    # A casca do app: cameras, dias e reproducao numa pagina so.
    Pagina('vms/src/Api/app-ui.html',
           'Vms.Server.App.Html', 'AppUiHtml',
           'Servida em /ui/app pelos dois servidores.'),

    # O player em HTML e as duas bibliotecas que ele carrega. Sao servidos
    # pelo vmsserver E pelo servidor local do app: a mesma pagina, dois
    # hospedeiros, e por isso ela so usa caminho relativo.
    Pagina('vms/src/Api/vmsreader.js',
           'Vms.Server.Reader.Js', 'VmsReaderJs',
           'Servido em /ui/vmsreader.js. Porte do tools/vmslib.py, conferido contra ele pelo tools/testvmsreader.js.'),
    Pagina('vms/src/Api/player.js',
           'Vms.Server.Player.Js', 'PlayerJs',
           'Servido em /ui/player.js. WebCodecs para o video, Web Audio para o G.711 do audio.'),
    Pagina('vms/src/Api/player-ui.html',
           'Vms.Server.Player.Html', 'PlayerUiHtml',
           'Servida em /ui/player.'),

    # A tela de entrada do vmsserver, servida em /ui/login.
    Pagina('vms/src/Api/login-ui.html',
           'Vms.Server.Login.Html', 'LoginUiHtml',
           'Servida em /ui/login pelo Vms.Server.Api.'),

    # O icone da aba, servido em /favicon.svg e /favicon.ico pelos dois
    # servidores. Sem ele o navegador pedia /favicon.ico e levava 404.
    Pagina('vms/src/Api/favicon.svg',
           'Vms.Server.Favicon.Svg', 'FaviconSvg',
           'Servido em /favicon.svg e /favicon.ico pelos dois servidores.'),

    # A sonda de capacidade e o teste de decodificacao sairam daqui: eram
    # diagnostico de perguntas ja respondidas, e o de decodificacao ainda
    # carregava 300 KB de quadros congelados de um dia so. Os .html seguem
    # em src/UI/webcaps.html e tools/videotest.html, e abrem direto no
    # navegador quando um aparelho novo precisar ser medido.
]

MOLDE = '''unit %(unit)s;

// GERADO por tools/gen_ui_pas.py -- NAO EDITE ESTA UNIT.
//
// A fonte e %(fonte)s. Mexeu la, rode o gerador de novo:
//
//     python tools/gen_ui_pas.py
//
// %(onde)s

interface

// A pagina inteira, pronta para servir ou carregar.
function %(funcao)s: string;

implementation

uses
  System.SysUtils,
  System.Classes;

const
  LINHAS: array[0..%(ultima)d] of string = (
%(corpo)s
  );

function %(funcao)s: string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := Low(LINHAS) to High(LINHAS) do
    begin
      SB.Append(LINHAS[I]);
      SB.Append(#10);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
'''


def gera(p):
    texto = io.open(p.html, encoding='utf-8').read()
    linhas = texto.replace('\r\n', '\n').split('\n')

    ruins = [(i + 1, l) for i, l in enumerate(linhas)
             if any(ord(c) > 126 for c in l)]
    if ruins:
        print('ERRO em %s: caractere nao-ASCII (use entidade HTML):' % p.rel)
        for n, l in ruins[:5]:
            print('   linha %d: %s' % (n, l.strip()[:70]))
        return 1

    corpo = []
    for i, l in enumerate(linhas):
        virgula = ',' if i < len(linhas) - 1 else ''
        corpo.append("    '%s'%s" % (l.replace("'", "''"), virgula))

    unit = MOLDE % {
        'unit': p.unit,
        'funcao': p.funcao,
        'fonte': p.rel,
        'onde': p.onde,
        'ultima': len(linhas) - 1,
        'corpo': '\n'.join(corpo),
    }
    io.open(p.pas, 'w', encoding='utf-8', newline='\r\n').write(unit)
    print('gerado %s' % os.path.relpath(p.pas, RAIZ).replace('\\', '/'))
    print('  %d linhas de html, %d bytes de unit' % (len(linhas), len(unit)))
    return 0


def main():
    return max(gera(p) for p in PAGINAS)


if __name__ == '__main__':
    sys.exit(main())
