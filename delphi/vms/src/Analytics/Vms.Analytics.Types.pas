unit Vms.Analytics.Types;

// O vocabulario de eventos, e mais nada.
//
// Nao depende de ONNX, nem de FFmpeg, nem de HTTP, nem de arquivo. Isso e o que
// permite que o detector de movimento (aritmetica pura), o detector de objetos
// (uma rede neural) e o armazenamento (bytes em disco) sejam trocaveis sem que
// nenhum deles conheca o outro.
//
// Repare que TEventBox NAO e a TBoxF do Vision.Types, ainda que descrevam a
// mesma coisa. A caixa aqui e normalizada (0..1) e e o que o app desenha por
// cima do video, em qualquer resolucao; a de la e em pixels da imagem que a
// rede viu. Se este vocabulario importasse o do vendor, trocar de biblioteca de
// visao viraria uma mudanca no formato de arquivo e na API — que e exatamente a
// dependencia que a inversao existe para impedir.

interface

uses
  System.SysUtils,
  System.Math;

type
  TEventKind = (
    ekMotion,   // mexeu alguma coisa; nao se sabe o que
    ekObject    // a rede reconheceu algo, e o rotulo diz o que
  );

  // Caixa normalizada: 0..1 sobre a largura e a altura do quadro.
  TEventBox = record
    L, T, R, B: Single;
    class function Empty: TEventBox; static;
    class function FromLTRB(ALeft, ATop, ARight, ABottom: Single): TEventBox; static;
    function IsEmpty: Boolean;
    // A menor caixa que contem as duas. Usada ao fundir quadros no mesmo evento.
    function Union(const Other: TEventBox): TEventBox;
    function Clamped: TEventBox;
  end;

  TVmsEvent = record
    StartMs: Int64;     // instante de parede do primeiro quadro do evento
    EndMs: Int64;       // do ultimo; igual ao inicio quando durou um quadro so
    Kind: TEventKind;
    // 'movimento' para ekMotion; o nome da classe ('person', 'car') para
    // ekObject. Sempre em minusculas, para o filtro da API nao precisar decidir
    // sobre maiusculas.
    Name: string;
    Score: Single;      // 0..1, o maior visto durante o evento
    Count: Integer;     // quantos objetos daquela classe no quadro de pico
    Box: TEventBox;     // a caixa do quadro de pico
    function DurationMs: Int64;
    function IsValid: Boolean;
  end;

  TVmsEventArray = TArray<TVmsEvent>;

  // Como o subsistema todo se comporta. Preenchido pelo Vms.Server.Config a
  // partir do bloco "analytics" do vmsserver.json.
  TAnalyticsConfig = record
    Enabled: Boolean;
    // De quanto em quanto tempo de GRAVACAO um quadro e analisado. Nao e taxa
    // de quadros: a analise anda pela gravacao, nao pelo relogio.
    StepMs: Int64;
    // Fracao minima do quadro que precisa ter mudado para valer como movimento.
    MotionThreshold: Single;
    // Acima disto o quadro inteiro mudou (luz acesa, IR ligando, camera
    // reposicionada). Nao e movimento: e cena nova, e a referencia e refeita.
    //
    // Comecou em 0.55 e isso era BAIXO DEMAIS. Medido em 20 h de gravacao das
    // tres cameras: a distribuicao dos eventos de movimento, em vez de cair na
    // cauda, EMPILHAVA na ultima faixa (67 eventos entre 0.50 e 0.55 contra 40
    // entre 0.45 e 0.50). Ou seja, o movimento mais forte — alguem passando
    // perto da camera — era descartado como "cena nova". Pior: descartar
    // refazia a referencia, e os ~20 s seguintes ficavam cegos. Era a causa de
    // "quase nao detecta mais nada".
    SceneChangeThreshold: Single;
    // O lado da grade de decisao, como fracao da grade cheia de 64x36
    // (1 = 64x36, 0.5 = 32x18, 0.25 = 16x9).
    //
    // Grade mais grossa cega o detector para o que tem POUCO CONTRASTE: um
    // vulto pequeno precisa levantar a media de uma celula quatro vezes maior.
    // Nao e "menos sensivel" em geral -- medido no selftest, um vulto pequeno e
    // muito claro atravessa a grade grossa e ate pesa MAIS nela, porque o score
    // e a fracao de celulas acesas (1 de 144 > 4 de 2304).
    //
    // Nao adianta reduzir a imagem antes disto: o detector ja reduz tudo a esta
    // grade, e reduzir duas vezes so faria media de media.
    GridScale: Single;
    // Quanto o cinza medio de uma celula precisa mudar, em 0..255, para ela
    // contar como mexida. 0 = o padrao do detector (14).
    //
    // E este o numero que responde pela oscilacao de brilho: quando o ganho
    // automatico da camera com infravermelho clareia a cena inteira, TODAS as
    // celulas andam juntas alguns niveis -- reduzir a imagem nao ajuda nisso,
    // porque a media desloca junto. Subir o delta e o que faz o detector
    // ignorar esse deslocamento; o preco e nao ver movimento de pouco
    // contraste.
    CellDelta: Integer;
    // Intervalo minimo entre duas passadas da rede. A rede e cara; o movimento
    // e barato. Este numero e o que separa os dois custos.
    ObjectMinIntervalMs: Int64;
    // A rede tambem roda de tempos em tempos SEM movimento nenhum. Sem isto,
    // quem entra no quadro e para de se mexer some da analise: o fundo absorve
    // a pessoa em ~20 s e ela deixa de ser movimento. 0 = so com movimento.
    ObjectIdleIntervalMs: Int64;
    ObjectThreshold: Single;   // confianca minima para a deteccao virar evento
    // Dois avistamentos do mesmo rotulo separados por menos que isto sao o
    // mesmo evento. Sem isso, uma pessoa parada na cena viraria um evento por
    // quadro analisado.
    MergeGapMs: Int64;
    // Teto de duracao de UM evento. Passando disto, ele fecha e comeca outro.
    //
    // Serve a dois donos. Na tela: movimento continuo numa rua manteria o
    // evento aberto por horas, e uma tarja de quatro horas na linha do tempo
    // nao diz nada. No banco: a consulta por sobreposicao so tem piso porque
    // este teto existe (ver Vms.Analytics.StoreDb) — sem ele, procurar os
    // eventos das 14h obrigaria a considerar tudo desde o comeco do banco.
    MaxEventMs: Int64;
    // Quanto tempo de gravacao passada analisar na primeira subida. 0 = tudo o
    // que houver no disco.
    BackfillMs: Int64;
    // Distancia minima entre a analise e o agora. O arquivo mais recente esta
    // sendo escrito; analisar a ponta dele e correr atras do proprio rabo.
    LagMs: Int64;
    ModelPath: string;         // .onnx; vazio = so movimento
    OnnxDllPath: string;
    // Rotulos que interessam. Vazio = todos os que o modelo conhecer.
    Classes: TArray<string>;
    function Describe: string;
    class function Default: TAnalyticsConfig; static;
  end;

function EventKindToStr(Kind: TEventKind): string;
function StrToEventKind(const S: string; out Kind: TEventKind): Boolean;

const
  // O rotulo dos eventos de movimento. Uma constante porque tres units
  // diferentes precisam concordar sobre ele.
  MOTION_NAME = 'movimento';

implementation

class function TEventBox.Empty: TEventBox;
begin
  Result.L := 0; Result.T := 0; Result.R := 0; Result.B := 0;
end;

class function TEventBox.FromLTRB(ALeft, ATop, ARight, ABottom: Single): TEventBox;
begin
  Result.L := ALeft; Result.T := ATop; Result.R := ARight; Result.B := ABottom;
end;

function TEventBox.IsEmpty: Boolean;
begin
  Result := (R <= L) or (B <= T);
end;

function TEventBox.Union(const Other: TEventBox): TEventBox;
begin
  if IsEmpty then Exit(Other);
  if Other.IsEmpty then Exit(Self);
  Result.L := Min(L, Other.L);
  Result.T := Min(T, Other.T);
  Result.R := Max(R, Other.R);
  Result.B := Max(B, Other.B);
end;

function TEventBox.Clamped: TEventBox;
begin
  Result.L := Min(Max(L, 0), 1);
  Result.T := Min(Max(T, 0), 1);
  Result.R := Min(Max(R, 0), 1);
  Result.B := Min(Max(B, 0), 1);
end;

{ TVmsEvent }

function TVmsEvent.DurationMs: Int64;
begin
  Result := EndMs - StartMs;
  if Result < 0 then Result := 0;
end;

function TVmsEvent.IsValid: Boolean;
begin
  Result := (StartMs > 0) and (EndMs >= StartMs) and (Name <> '');
end;

{ TAnalyticsConfig }

class function TAnalyticsConfig.Default: TAnalyticsConfig;
begin
  Result.Enabled := False;   // ver o comentario do LoadExtra: nao liga sozinho
  Result.StepMs := 2000;
  Result.MotionThreshold := 0.006;
  Result.SceneChangeThreshold := 0.85;
  Result.GridScale := 1.0;
  Result.CellDelta := 0;
  Result.ObjectMinIntervalMs := 5000;
  Result.ObjectIdleIntervalMs := 60000;
  Result.ObjectThreshold := 0.35;
  Result.MergeGapMs := 8000;
  Result.MaxEventMs := 300000;
  Result.BackfillMs := Int64(6) * 3600 * 1000;
  Result.LagMs := 30000;
  Result.ModelPath := '';
  Result.OnnxDllPath := 'onnxruntime.dll';
  Result.Classes := nil;
end;

function TAnalyticsConfig.Describe: string;
begin
  if not Enabled then Exit('desligada');
  Result := Format('1 quadro a cada %d ms, movimento > %.1f%%',
    [StepMs, MotionThreshold * 100]);
  if GridScale < 0.999 then
    Result := Result + Format(', grade em %.0f%%', [GridScale * 100]);
  if CellDelta > 0 then
    Result := Result + Format(', delta %d', [CellDelta]);
  if ModelPath <> '' then
    Result := Result + Format(', objetos por %s (min %.0f%%, no maximo 1 a cada %d ms)',
      [ExtractFileName(ModelPath), ObjectThreshold * 100, ObjectMinIntervalMs])
  else
    Result := Result + ', sem deteccao de objetos';
  if BackfillMs > 0 then
    Result := Result + Format(', recuperando %d h para tras', [BackfillMs div 3600000])
  else
    Result := Result + ', recuperando toda a gravacao';
end;

function EventKindToStr(Kind: TEventKind): string;
begin
  case Kind of
    ekObject: Result := 'object';
  else
    Result := 'motion';
  end;
end;

function StrToEventKind(const S: string; out Kind: TEventKind): Boolean;
begin
  Result := True;
  if SameText(S, 'motion') then Kind := ekMotion
  else if SameText(S, 'object') then Kind := ekObject
  else
  begin
    Kind := ekMotion;
    Result := False;
  end;
end;

end.
