unit Vms.Server.Favicon.Svg;

// GERADO por tools/gen_ui_pas.py -- NAO EDITE ESTA UNIT.
//
// A fonte e vms/src/Api/favicon.svg. Mexeu la, rode o gerador de novo:
//
//     python tools/gen_ui_pas.py
//
// Servido em /favicon.svg e /favicon.ico pelos dois servidores.

interface

// A pagina inteira, pronta para servir ou carregar.
function FaviconSvg: string;

implementation

uses
  System.SysUtils,
  System.Classes;

const
  LINHAS: array[0..12] of string = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">',
    '  <!-- O icone da aba. SVG, e nao .ico: e um arquivo de texto, cabe no',
    '       executavel como qualquer outra pagina e nao precisa de ferramenta para',
    '       ser editado. As duas rotas (/favicon.svg e /favicon.ico) devolvem este',
    '       mesmo desenho; o <link> das paginas aponta para a primeira, que e a que',
    '       diz o tipo certo. -->',
    '  <rect width="32" height="32" rx="7" fill="#151515"/>',
    '  <rect x="3" y="10" width="17" height="13" rx="3" fill="#2d9cdb"/>',
    '  <path d="M22 14.5 L28.5 10.5 V22.5 L22 18.5 Z" fill="#2d9cdb"/>',
    '  <circle cx="11.5" cy="16.5" r="3.2" fill="#151515"/>',
    '  <circle cx="11.5" cy="16.5" r="1.4" fill="#2d9cdb"/>',
    '</svg>',
    ''
  );

function FaviconSvg: string;
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
