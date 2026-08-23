unit UI.Events;

// A linha do tempo só de eventos: o que a análise do servidor viu naquele dia,
// um item por evento, do mais recente para o mais antigo.
//
// Existe porque a faixa de marcas na barra do player responde "houve algo aqui"
// mas não "o quê, e quando exatamente". Numa madrugada com quatro passagens de
// carro, achar as quatro arrastando a barra é o trabalho que esta tela elimina:
// as quatro estão listadas, com a hora e a imagem do momento, e um toque leva a
// reprodução até lá.
//
// Montada em código, sem .fmx, pelo mesmo motivo da UI.Days: é uma lista.
//
// As miniaturas vêm pelo MESMO IThumbProvider da barra do tempo. Não há cache
// novo, nem thread nova, nem rota nova: o evento tem hora, e a barra já sabia
// pedir a imagem de uma hora. Se a tela tivesse a sua própria busca, as duas
// pediriam o mesmo minuto ao servidor em paralelo.

interface

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  System.DateUtils,
  FMX.Types,
  FMX.Controls,
  FMX.Objects,
  FMX.Layouts,
  FMX.StdCtrls,
  FMX.Graphics,
  VMS.Api.Client,
  UI.Thumbs,
  UI.Common;

type
  TEventPickEvent = procedure(Sender: TObject; UnixMs: Int64) of object;

  // Que tipo de evento a lista mostra. Movimento é o pano de fundo — numa rua
  // ele é quase contínuo — e por isso o filtro começa em "objetos": é a lista
  // que responde "o que passou aqui", que é a pergunta que se faz.
  TEventFilter = (efObjects, efMotion, efAll);

  TFrameEvents = class(TLayout)
  private
    FTop: TRectangle;
    FBtnBack: TRectangle;
    FPathBack: TPath;
    FLblTitle: TLabel;
    FTabs: TLayout;
    FTabBtn: array[TEventFilter] of TLabel;
    FList: TVertScrollBox;
    FLblEmpty: TLabel;
    FEvents: TArray<TApiEvent>;   // tudo o que veio do servidor
    FFilter: TEventFilter;
    FThumbs: IThumbProvider;
    // Miniaturas pedidas mas ainda não chegadas: o Tag da TImage guarda o
    // minuto, e é por ele que a chegada encontra onde desenhar.
    FPendentes: TArray<TImage>;
    FOnBack: TNotifyEvent;
    FOnPick: TEventPickEvent;
    procedure BackClick(Sender: TObject);
    procedure TabClick(Sender: TObject);
    procedure ItemClick(Sender: TObject);
    procedure ClearItems;
    procedure Rebuild;
    procedure SetMessage(const S: string);
    function Accepts(const Ev: TApiEvent): Boolean;
    function AddHeader(const Texto: string): TLabel;
    function AddItem(const Ev: TApiEvent; Index: Integer): TRectangle;
    procedure UpdateTabs;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetTitle(const S: string);
    procedure SetLoading;
    procedure SetError(const Msg: string);
    // A lista completa do dia. O filtro é aplicado aqui dentro, sem ir ao
    // servidor de novo: trocar de aba não é motivo para uma requisição.
    procedure SetEvents(const Events: TArray<TApiEvent>);
    procedure SetThumbProvider(const Provider: IThumbProvider);
    // Quem assina o aviso do provedor é o formulário, e não esta tela: o
    // provedor é o mesmo da barra do tempo e só aceita um assinante (ver
    // TFrameTimeline.ThumbsArrived).
    procedure ThumbsArrived;
    property OnBack: TNotifyEvent read FOnBack write FOnBack;
    property OnPickEvent: TEventPickEvent read FOnPick write FOnPick;
  end;

// 'person' -> 'Pessoa'. O modelo fala inglês; a tela, não. O que não estiver na
// tabela sai como veio, com a primeira letra maiúscula — um rótulo desconhecido
// ainda é mais útil na tela do que um "Objeto" genérico.
function EventLabelPt(const Name: string): string;
function FormatEventDuration(Ms: Int64): string;

implementation

const
  ITEM_HEIGHT = 76;
  THUMB_W = 96;
  THUMB_H = 60;
  HEADER_HEIGHT = 28;
  ONE_MINUTE_MS = Int64(60000);
  // As mesmas duas cores da faixa de eventos na barra do tempo (ver
  // UI.Timeline): a lista e a barra falam do mesmo evento, e cor diferente para
  // a mesma coisa faria parecer que são assuntos diferentes.
  EV_MOTION_COLOR = TAlphaColor($FFB8860B);
  EV_OBJECT_COLOR = TAlphaColor($FFE53935);

  TAB_NAMES: array[TEventFilter] of string = ('Objetos', 'Movimento', 'Tudo');

function EventLabelPt(const Name: string): string;
var
  N: string;
begin
  N := LowerCase(Trim(Name));
  if N = 'movimento' then Exit('Movimento');
  if N = 'person' then Exit('Pessoa');
  if N = 'car' then Exit('Carro');
  if N = 'truck' then Exit('Caminh'#$E3'o');
  if N = 'bus' then Exit(''#$D4'nibus');
  if N = 'motorcycle' then Exit('Moto');
  if N = 'bicycle' then Exit('Bicicleta');
  if N = 'dog' then Exit('Cachorro');
  if N = 'cat' then Exit('Gato');
  if N = 'bird' then Exit('P'#$E1'ssaro');
  if N = 'backpack' then Exit('Mochila');
  if N = 'handbag' then Exit('Bolsa');
  if N = 'umbrella' then Exit('Guarda-chuva');
  if N = 'cell phone' then Exit('Celular');
  if N = '' then Exit('Evento');
  Result := UpperCase(Copy(N, 1, 1)) + Copy(N, 2, MaxInt);
end;

function FormatEventDuration(Ms: Int64): string;
var
  Seg: Int64;
begin
  Seg := (Ms + 500) div 1000;
  if Seg < 1 then Seg := 1;
  if Seg < 60 then
    Result := Format('%ds', [Seg])
  else if Seg < 3600 then
    Result := Format('%dmin %02ds', [Seg div 60, Seg mod 60])
  else
    Result := Format('%dh %02dmin', [Seg div 3600, (Seg mod 3600) div 60]);
end;

function LocalOf(Ms: Int64): TDateTime;
begin
  Result := TTimeZone.Local.ToLocalTime(UnixToDateTime(Ms div 1000, True));
end;

{ TFrameEvents }

constructor TFrameEvents.Create(AOwner: TComponent);
var
  F: TEventFilter;
  Lbl: TLabel;
begin
  inherited Create(AOwner);
  Name := '';
  FFilter := efObjects;

  FTop := TRectangle.Create(Self);
  FTop.Parent := Self;
  FTop.Align := TAlignLayout.Top;
  FTop.Height := 52;
  FTop.Fill.Color := COLOR_SURFACE;
  FTop.Stroke.Kind := TBrushKind.None;

  FBtnBack := TRectangle.Create(Self);
  FBtnBack.Parent := FTop;
  FBtnBack.Align := TAlignLayout.Left;
  FBtnBack.Width := 52;
  FBtnBack.Fill.Kind := TBrushKind.None;
  FBtnBack.Stroke.Kind := TBrushKind.None;
  FBtnBack.HitTest := True;
  FBtnBack.OnClick := BackClick;

  FPathBack := TPath.Create(Self);
  FPathBack.Parent := FBtnBack;
  FPathBack.Align := TAlignLayout.Center;
  FPathBack.Width := 22;
  FPathBack.Height := 22;
  FPathBack.HitTest := False;
  FPathBack.WrapMode := TPathWrapMode.Fit;
  FPathBack.Fill.Color := COLOR_TEXT;
  FPathBack.Stroke.Kind := TBrushKind.None;
  FPathBack.Data.Data := ICON_BACK;

  FLblTitle := TLabel.Create(Self);
  FLblTitle.Parent := FTop;
  FLblTitle.Align := TAlignLayout.Client;
  FLblTitle.Margins.Left := 4;
  FLblTitle.StyledSettings := [];
  FLblTitle.TextSettings.FontColor := COLOR_TEXT;
  FLblTitle.TextSettings.Font.Size := 16;
  FLblTitle.TextSettings.VertAlign := TTextAlign.Center;
  FLblTitle.Text := 'Eventos';

  FTabs := TLayout.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align := TAlignLayout.Top;
  FTabs.Height := 40;
  for F := Low(TEventFilter) to High(TEventFilter) do
  begin
    Lbl := TLabel.Create(Self);
    Lbl.Parent := FTabs;
    Lbl.Align := TAlignLayout.Left;
    Lbl.Width := 104;
    Lbl.Margins.Left := 8;
    Lbl.StyledSettings := [];
    Lbl.TextSettings.Font.Size := 14;
    Lbl.TextSettings.HorzAlign := TTextAlign.Center;
    Lbl.TextSettings.VertAlign := TTextAlign.Center;
    Lbl.Text := TAB_NAMES[F];
    Lbl.HitTest := True;
    Lbl.Tag := Ord(F);
    Lbl.OnClick := TabClick;
    FTabBtn[F] := Lbl;
  end;
  UpdateTabs;

  FList := TVertScrollBox.Create(Self);
  FList.Parent := Self;
  FList.Align := TAlignLayout.Client;

  FLblEmpty := TLabel.Create(Self);
  FLblEmpty.Parent := Self;
  FLblEmpty.Align := TAlignLayout.Client;
  FLblEmpty.StyledSettings := [];
  FLblEmpty.TextSettings.FontColor := COLOR_DIM;
  FLblEmpty.TextSettings.Font.Size := 14;
  FLblEmpty.TextSettings.HorzAlign := TTextAlign.Center;
  FLblEmpty.TextSettings.VertAlign := TTextAlign.Center;
  FLblEmpty.Visible := False;
end;

destructor TFrameEvents.Destroy;
begin
  // O provedor é compartilhado e não é desta tela: só solta a referência.
  FThumbs := nil;
  inherited;
end;

procedure TFrameEvents.SetTitle(const S: string);
begin
  FLblTitle.Text := S;
end;

procedure TFrameEvents.SetThumbProvider(const Provider: IThumbProvider);
begin
  FThumbs := Provider;
end;

procedure TFrameEvents.BackClick(Sender: TObject);
begin
  if Assigned(FOnBack) then FOnBack(Self);
end;

procedure TFrameEvents.UpdateTabs;
var
  F: TEventFilter;
begin
  for F := Low(TEventFilter) to High(TEventFilter) do
    if FTabBtn[F] <> nil then
      if F = FFilter then
        FTabBtn[F].TextSettings.FontColor := COLOR_ACCENT
      else
        FTabBtn[F].TextSettings.FontColor := COLOR_DIM;
end;

procedure TFrameEvents.TabClick(Sender: TObject);
var
  F: TEventFilter;
begin
  if not (Sender is TLabel) then Exit;
  F := TEventFilter(TLabel(Sender).Tag);
  if F = FFilter then Exit;
  FFilter := F;
  UpdateTabs;
  Rebuild;
end;

function TFrameEvents.Accepts(const Ev: TApiEvent): Boolean;
begin
  case FFilter of
    efObjects: Result := not Ev.IsMotion;
    efMotion: Result := Ev.IsMotion;
  else
    Result := True;
  end;
end;

procedure TFrameEvents.ClearItems;
var
  I: Integer;
begin
  FPendentes := nil;
  for I := FList.Content.ChildrenCount - 1 downto 0 do
    FList.Content.Children[I].Free;
end;

procedure TFrameEvents.SetMessage(const S: string);
begin
  ClearItems;
  FLblEmpty.Text := S;
  FLblEmpty.Visible := True;
  FLblEmpty.BringToFront;
  FList.Visible := False;
end;

procedure TFrameEvents.SetLoading;
begin
  SetMessage('Consultando o servidor'#$85);
end;

procedure TFrameEvents.SetError(const Msg: string);
begin
  SetMessage(Msg);
end;

procedure TFrameEvents.SetEvents(const Events: TArray<TApiEvent>);
begin
  FEvents := Events;
  Rebuild;
end;

function TFrameEvents.AddHeader(const Texto: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := FList.Content;
  Result.Align := TAlignLayout.Top;
  Result.Height := HEADER_HEIGHT;
  Result.Margins.Left := 14;
  Result.Margins.Top := 10;
  Result.HitTest := False;
  Result.StyledSettings := [];
  Result.TextSettings.FontColor := COLOR_DIM;
  Result.TextSettings.Font.Size := 12;
  Result.TextSettings.VertAlign := TTextAlign.Center;
  Result.Text := Texto;
end;

// O Tag do card guarda o índice em FEvents, e o da miniatura guarda o minuto.
// Os dados ficam nos próprios controles para a tela não manter uma cópia
// paralela da lista — mesma disciplina da UI.Days.
function TFrameEvents.AddItem(const Ev: TApiEvent; Index: Integer): TRectangle;
var
  Card, Faixa: TRectangle;
  Img: TImage;
  LblHora, LblNome: TLabel;
  Bmp: TBitmap;
  MinutoMs: Int64;
  Texto: string;
begin
  Card := TRectangle.Create(Self);
  Card.Parent := FList.Content;
  Card.Align := TAlignLayout.Top;
  Card.Height := ITEM_HEIGHT;
  Card.Margins.Left := 8;
  Card.Margins.Right := 8;
  Card.Margins.Top := 6;
  Card.XRadius := 8;
  Card.YRadius := 8;
  Card.Fill.Color := COLOR_SURFACE;
  Card.Stroke.Kind := TBrushKind.None;
  Card.HitTest := True;
  Card.Tag := Index;
  Card.OnClick := ItemClick;

  // Tira colorida na borda esquerda: diz o tipo do evento sem gastar texto, e
  // com a MESMA cor que a barra do tempo usa para ele.
  Faixa := TRectangle.Create(Self);
  Faixa.Parent := Card;
  Faixa.Align := TAlignLayout.Left;
  Faixa.Width := 4;
  Faixa.HitTest := False;
  Faixa.Stroke.Kind := TBrushKind.None;
  if Ev.IsMotion then
    Faixa.Fill.Color := EV_MOTION_COLOR
  else
    Faixa.Fill.Color := EV_OBJECT_COLOR;

  Img := TImage.Create(Self);
  Img.Parent := Card;
  Img.SetBounds(12, (ITEM_HEIGHT - THUMB_H) / 2, THUMB_W, THUMB_H);
  Img.HitTest := False;
  Img.WrapMode := TImageWrapMode.Fit;
  // O minuto do evento é a chave da miniatura, igual à da barra do tempo.
  MinutoMs := (Ev.StartMs div ONE_MINUTE_MS) * ONE_MINUTE_MS;
  Img.TagString := '';
  if FThumbs <> nil then
  begin
    if FThumbs.TryGet(MinutoMs, Bmp) and (Bmp <> nil) then
      Img.Bitmap.Assign(Bmp)
    else
    begin
      FThumbs.Request(MinutoMs);
      // Guardada para quando a imagem chegar. O minuto vai no TagString, e não
      // no Tag: Tag é NativeInt, que numa build 32 bits não comporta um instante
      // unix em milissegundos — truncaria e a imagem nunca acharia o dono.
      Img.TagString := IntToStr(MinutoMs);
      SetLength(FPendentes, Length(FPendentes) + 1);
      FPendentes[High(FPendentes)] := Img;
    end;
  end;

  LblHora := TLabel.Create(Self);
  LblHora.Parent := Card;
  LblHora.SetBounds(THUMB_W + 22, 12, 240, 22);
  LblHora.HitTest := False;
  LblHora.StyledSettings := [];
  LblHora.TextSettings.FontColor := COLOR_TEXT;
  LblHora.TextSettings.Font.Size := 15;
  LblHora.Text := FormatDateTime('hh:nn:ss', LocalOf(Ev.StartMs));

  LblNome := TLabel.Create(Self);
  LblNome.Parent := Card;
  LblNome.SetBounds(THUMB_W + 22, 36, 260, 20);
  LblNome.HitTest := False;
  LblNome.StyledSettings := [];
  LblNome.TextSettings.FontColor := COLOR_DIM;
  LblNome.TextSettings.Font.Size := 12;
  Texto := EventLabelPt(Ev.Name);
  if Ev.Count > 1 then
    Texto := Format('%s x%d', [Texto, Ev.Count]);
  Texto := Texto + ' - ' + FormatEventDuration(Ev.DurationMs);
  // A confiança só aparece para objeto: no evento de movimento o "score" é a
  // fração da tela que mexeu, que não é a mesma grandeza e enganaria.
  if not Ev.IsMotion then
    Texto := Texto + Format(' - %.0f%%', [Ev.Score * 100]);
  LblNome.Text := Texto;

  Result := Card;
end;

procedure TFrameEvents.Rebuild;
var
  I, Mostrados: Integer;
  Hora, HoraAnterior: Int64;
begin
  ClearItems;
  if Length(FEvents) = 0 then
  begin
    SetMessage('Nenhum evento neste dia.');
    Exit;
  end;

  FLblEmpty.Visible := False;
  FList.Visible := True;
  Mostrados := 0;
  HoraAnterior := -1;
  // Do mais recente para o mais antigo: com Align=Top os filhos empilham na
  // ordem de criação, e é o fim do dia que se quer ver primeiro.
  for I := High(FEvents) downto 0 do
  begin
    if not Accepts(FEvents[I]) then Continue;
    // A hora local do evento como número inteiro de horas desde a época do
    // TDateTime: é só uma chave de agrupamento, e comparar horas soltas juntaria
    // as 14h de dois dias diferentes.
    Hora := Trunc(LocalOf(FEvents[I].StartMs) * 24);
    if Hora <> HoraAnterior then
    begin
      AddHeader(FormatDateTime('hh', LocalOf(FEvents[I].StartMs)) + 'h');
      HoraAnterior := Hora;
    end;
    AddItem(FEvents[I], I);
    Inc(Mostrados);
  end;

  if Mostrados = 0 then
  begin
    FPendentes := nil;
    if FFilter = efObjects then
      SetMessage('Nenhum objeto reconhecido neste dia.' + sLineBreak +
                 'Veja em "Movimento" ou "Tudo".')
    else
      SetMessage('Nenhum evento deste tipo neste dia.');
  end;
end;

// Chamado na thread principal quando alguma miniatura nova chegou. Percorre só
// o que ainda está pendente: a lista encolhe sozinha conforme as imagens
// entram, e quando esvazia não há mais trabalho a cada rajada.
procedure TFrameEvents.ThumbsArrived;
var
  I, N: Integer;
  Bmp: TBitmap;
  Restantes: TArray<TImage>;
begin
  if FThumbs = nil then Exit;
  SetLength(Restantes, Length(FPendentes));
  N := 0;
  for I := 0 to High(FPendentes) do
  begin
    if FPendentes[I] = nil then Continue;
    if FThumbs.TryGet(StrToInt64Def(FPendentes[I].TagString, 0), Bmp) and
       (Bmp <> nil) then
      FPendentes[I].Bitmap.Assign(Bmp)
    else
    begin
      Restantes[N] := FPendentes[I];
      Inc(N);
    end;
  end;
  SetLength(Restantes, N);
  FPendentes := Restantes;
end;

procedure TFrameEvents.ItemClick(Sender: TObject);
var
  Idx: Integer;
begin
  if not Assigned(FOnPick) then Exit;
  if not (Sender is TRectangle) then Exit;
  Idx := TRectangle(Sender).Tag;
  if (Idx < 0) or (Idx > High(FEvents)) then Exit;
  // Um pouco ANTES do começo: cair exatamente no primeiro quadro do evento faz
  // a reprodução começar com a coisa já acontecendo. Dois segundos de antes é o
  // que deixa ver o que entrou em cena.
  FOnPick(Self, FEvents[Idx].StartMs - 2000);
end;

end.
