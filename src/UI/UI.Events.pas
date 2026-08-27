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
// ## Por que TListView, e não cartões como na UI.Days
//
// Uma câmera movimentada produz ~1.500 eventos por dia. Com um TRectangle e
// quatro filhos por item, isso seriam ~7.500 controles FMX construídos de uma
// vez — segundos de espera e memória à toa. O TListView cria os controles das
// linhas VISÍVEIS e reaproveita conforme se rola; a lista pode ter mil itens
// que o custo é o de uma tela.
//
// A miniatura de cada item também é preenchida sob demanda, no OnUpdateObjects
// — o evento que o TListView dispara quando uma linha entra em cena. Pedir a
// imagem dos 1.500 seria uma enxurrada que ninguém veria.
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
  FMX.ListView,
  FMX.ListView.Types,
  FMX.ListView.Appearances,
  FMX.ListView.Adapters.Base,
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
    FList: TListView;
    FLblEmpty: TLabel;
    FEvents: TArray<TApiEvent>;   // tudo o que veio do servidor
    // Índice em FEvents de cada linha da lista (a lista tem cabeçalhos de hora
    // no meio, então a posição não serve como índice).
    FLinhas: TArray<Integer>;
    FFilter: TEventFilter;
    FThumbs: IThumbProvider;
    // A lista só é construída quando a tela aparece: montá-la ao receber os
    // eventos fazia o PLAYER demorar a abrir, porque é lá que eles chegam.
    FPrecisaMontar: Boolean;
    FOnBack: TNotifyEvent;
    FOnPick: TEventPickEvent;
    procedure BackClick(Sender: TObject);
    procedure TabClick(Sender: TObject);
    procedure Rebuild;
    procedure ItemClickLv(const Sender: TObject; const AItem: TListViewItem);
    // Preenche a miniatura da linha que acabou de entrar em cena.
    procedure UpdateObjects(const Sender: TObject; const AItem: TListViewItem);
    function MinutoDe(Index: Integer): Int64;
    procedure SetMessage(const S: string);
    function Accepts(const Ev: TApiEvent): Boolean;

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
    // Chamado quando a tela vai aparecer: é aqui que a lista é montada.
    procedure Montar;
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
  // A miniatura manda no tamanho da linha: 16:9, que é o formato do vídeo, com
  // uma folga em volta para o texto respirar.
  THUMB_W = 128;
  THUMB_H = 72;
  ITEM_HEIGHT = THUMB_H + 12;
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

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := TAlignLayout.Client;
  // Aparência de fábrica com imagem + título + detalhe: é exatamente miniatura,
  // hora e descrição, sem precisar desenhar item à mão.
  FList.ItemAppearanceName := 'ImageListItemBottomDetail';
  // As alturas vivem em ItemAppearance (TPublishedAppearance), e nao em
  // ItemAppearanceObjects — aquele so guarda os OBJETOS de cada aparencia.
  FList.ItemAppearance.ItemHeight := ITEM_HEIGHT;
  FList.ItemAppearance.HeaderHeight := HEADER_HEIGHT;
  // O tamanho da imagem NÃO vem da aparência escolhida — ela traz um ícone
  // pequeno, pensado para avatar. Aqui a miniatura é o conteúdo principal da
  // linha, então é preciso dizer o tamanho.
  FList.ItemAppearanceObjects.ItemObjects.Image.Width := THUMB_W;
  FList.ItemAppearanceObjects.ItemObjects.Image.Height := THUMB_H;
  FList.CanSwipeDelete := False;
  FList.OnItemClick := ItemClickLv;
  FList.OnUpdateObjects := UpdateObjects;

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
  // A tela já está aberta: trocar de aba remonta na hora, sem ir ao servidor.
  FPrecisaMontar := False;
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

function TFrameEvents.MinutoDe(Index: Integer): Int64;
begin
  Result := 0;
  if (Index < 0) or (Index > High(FEvents)) then Exit;
  Result := (FEvents[Index].StartMs div ONE_MINUTE_MS) * ONE_MINUTE_MS;
end;

procedure TFrameEvents.SetMessage(const S: string);
begin
  FList.Items.Clear;
  FLinhas := nil;
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

// Guarda e marca para montar. NÃO monta: quem chama isto é a resposta da API,
// que chega enquanto o PLAYER está abrindo — montar aqui era o que fazia o
// histórico demorar a aparecer.
procedure TFrameEvents.SetEvents(const Events: TArray<TApiEvent>);
begin
  FEvents := Events;
  FPrecisaMontar := True;
end;

procedure TFrameEvents.Montar;
begin
  if not FPrecisaMontar then Exit;
  FPrecisaMontar := False;
  Rebuild;
end;

procedure TFrameEvents.Rebuild;
var
  I, Mostrados: Integer;
  Hora, HoraAnterior: Int64;
  Item: TListViewItem;
  Texto: string;
begin
  FList.BeginUpdate;
  try
    FList.Items.Clear;
    FLinhas := nil;
    Mostrados := 0;
    HoraAnterior := -1;
    // Do mais recente para o mais antigo: é o fim do dia que se quer ver
    // primeiro. Aqui a ordem é a de inserção mesmo — TListView é uma lista, e
    // não controles alinhados (ver o comentário gêmeo em UI.Days).
    for I := High(FEvents) downto 0 do
    begin
      if not Accepts(FEvents[I]) then Continue;
      Hora := Trunc(LocalOf(FEvents[I].StartMs) * 24);
      if Hora <> HoraAnterior then
      begin
        Item := FList.Items.Add;
        Item.Purpose := TListItemPurpose.Header;
        Item.Text := FormatDateTime('hh', LocalOf(FEvents[I].StartMs)) + 'h';
        SetLength(FLinhas, Length(FLinhas) + 1);
        FLinhas[High(FLinhas)] := -1;      // cabeçalho não aponta para evento
        HoraAnterior := Hora;
      end;

      Item := FList.Items.Add;
      Item.Text := FormatDateTime('hh:nn:ss', LocalOf(FEvents[I].StartMs));
      Texto := EventLabelPt(FEvents[I].Name);
      if FEvents[I].Count > 1 then
        Texto := Format('%s x%d', [Texto, FEvents[I].Count]);
      Texto := Texto + ' - ' + FormatEventDuration(FEvents[I].DurationMs);
      // A confiança só aparece para objeto: no evento de movimento o "score" é
      // a fração da tela que mexeu, que não é a mesma grandeza e enganaria.
      if not FEvents[I].IsMotion then
        Texto := Texto + Format(' - %.0f%%', [FEvents[I].Score * 100]);
      Item.Detail := Texto;
      SetLength(FLinhas, Length(FLinhas) + 1);
      FLinhas[High(FLinhas)] := I;
      Inc(Mostrados);
    end;
  finally
    FList.EndUpdate;
  end;

  if Mostrados = 0 then
  begin
    if FFilter = efObjects then
      SetMessage('Nenhum objeto reconhecido neste dia.' + sLineBreak +
                 'Veja em "Movimento" ou "Tudo".')
    else
      SetMessage('Nenhum evento deste tipo neste dia.');
    Exit;
  end;
  FLblEmpty.Visible := False;
  FList.Visible := True;
end;

// Disparado pelo TListView quando uma linha entra em cena. É o gancho da
// virtualização: só as visíveis pedem imagem.
procedure TFrameEvents.UpdateObjects(const Sender: TObject;
  const AItem: TListViewItem);
var
  Idx: Integer;
  Minuto: Int64;
  Bmp: TBitmap;
begin
  if (FThumbs = nil) or (AItem = nil) then Exit;
  if AItem.Purpose <> TListItemPurpose.None then Exit;
  if (AItem.Index < 0) or (AItem.Index > High(FLinhas)) then Exit;
  Idx := FLinhas[AItem.Index];
  if Idx < 0 then Exit;
  Minuto := MinutoDe(Idx);
  if FThumbs.TryGet(Minuto, Bmp) and (Bmp <> nil) then
    AItem.Bitmap := Bmp
  else
    FThumbs.Request(Minuto);
end;

// Uma imagem nova chegou. Repintar basta: o OnUpdateObjects roda de novo para
// as linhas em cena e pega o que agora está em memória.
procedure TFrameEvents.ThumbsArrived;
begin
  if FList <> nil then
    FList.Repaint;
end;

procedure TFrameEvents.ItemClickLv(const Sender: TObject;
  const AItem: TListViewItem);
var
  Idx: Integer;
begin
  if (not Assigned(FOnPick)) or (AItem = nil) then Exit;
  if (AItem.Index < 0) or (AItem.Index > High(FLinhas)) then Exit;
  Idx := FLinhas[AItem.Index];
  if (Idx < 0) or (Idx > High(FEvents)) then Exit;
  // Um pouco ANTES do começo: cair exatamente no primeiro quadro do evento faz
  // a reprodução começar com a coisa já acontecendo.
  FOnPick(Self, FEvents[Idx].StartMs - 2000);
end;

end.
