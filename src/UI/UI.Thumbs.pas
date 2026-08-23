unit UI.Thumbs;

// Miniaturas para a barra do tempo: pede ao servidor, guarda na memória, avisa
// quando chegou.
//
// A barra do tempo não fala HTTP. Ela conhece IThumbProvider — "me dá a imagem
// deste minuto" — e desenha o que já chegou. Quem busca é uma thread daqui, e a
// barra só é acordada quando há algo novo para mostrar. Sem essa fronteira, a
// UI.Timeline passaria a depender do cliente de API e de threads, e não daria
// para desenhá-la sem servidor.
//
// Regras que valem a pena estar num lugar só:
//
//   * Pedido é assíncrono e sem promessa. A barra pede a cada redesenho os
//     minutos que couberem na tela; quem já está na memória sai na hora, o resto
//     entra numa fila. Redesenhar não pode esperar rede.
//   * Um minuto que não tem imagem é lembrado como não tendo. Sem isso, arrastar
//     a barra sobre um trecho sem gravação repetiria o mesmo pedido perdido a
//     cada quadro de animação.
//   * A fila é curta e descartável: ao mudar de zoom ou de dia, o que estava
//     pendente perde a validade, e insistir nele só atrasaria o que interessa.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,   // comparador padrão do TArray.Sort
  FMX.Graphics,
  VMS.Domain.Logging,
  VMS.Api.Client;

type
  // O que a barra do tempo enxerga.
  IThumbProvider = interface
    ['{1D3C5B77-9A24-4F58-B6E1-0C7F2A8D4E19}']
    // Qual câmera as próximas perguntas são sobre. Trocar de câmera descarta o
    // que estava pendente.
    procedure SetCamera(const Camera: string);
    // A imagem daquele minuto, se já estiver na memória. Não pede nada.
    function TryGet(MinuteMs: Int64; out Bmp: TBitmap): Boolean;
    // Pede, se ainda não tiver. Volta na hora.
    procedure Request(MinuteMs: Int64);
    // Nada do que foi pedido antes disto interessa mais.
    procedure DropPending;
    // Chamado na thread principal quando alguma imagem nova chegou.
    procedure SetOnArrived(const Handler: TProc);
  end;

  TApiThumbProvider = class(TInterfacedObject, IThumbProvider)
  strict private
  type
    TFetcher = class(TThread)
    strict private
      FOwner: TApiThumbProvider;
    protected
      procedure Execute; override;
    public
      constructor Create(AOwner: TApiThumbProvider);
    end;
  strict private
    FApi: TVmsApiClient;
    FLogger: ILogger;
    FLock: TCriticalSection;
    FWake: TEvent;
    FThread: TFetcher;
    FStop: Boolean;
    FCamera: string;
    FQueue: TList<Int64>;
    FCache: TObjectDictionary<Int64, TBitmap>;
    FMisses: TDictionary<Int64, Boolean>;
    FOnArrived: TProc;
    FNotifyPending: Boolean;
    function NextWanted(out MinuteMs: Int64; out Camera: string): Boolean;
    procedure Store(MinuteMs: Int64; const Data: TBytes);
    procedure NoteMiss(MinuteMs: Int64);
    procedure Arrived;
  public
    constructor Create(AApi: TVmsApiClient; const ALogger: ILogger);
    destructor Destroy; override;
    { IThumbProvider }
    procedure SetCamera(const Camera: string);
    function TryGet(MinuteMs: Int64; out Bmp: TBitmap): Boolean;
    procedure Request(MinuteMs: Int64);
    procedure DropPending;
    procedure SetOnArrived(const Handler: TProc);
  end;

implementation

const
  // Quantas imagens ficam na memória. Uma barra cheia mostra algumas dezenas;
  // este teto cobre umas quantas vistas de zoom sem virar consumo.
  MAX_CACHED = 240;
  // Teto da fila de pedidos. Passando disto, o pedido mais antigo sai: o que
  // interessa é sempre o que está na tela agora.
  MAX_QUEUED = 64;

{ TApiThumbProvider.TFetcher }

constructor TApiThumbProvider.TFetcher.Create(AOwner: TApiThumbProvider);
begin
  // Campos primeiro, `inherited` por último, e SEM chamar Start.
  //
  // Quem inicia a thread é o TThread.AfterConstruction, que roda depois do
  // construtor mais externo — então os campos daqui já estão escritos quando o
  // Execute arranca, e a corrida que eu temia não existe. Chamar Start aqui
  // dentro zera o FCreateSuspended, o AfterConstruction acha que ainda precisa
  // iniciar, e o segundo ResumeThread levanta "Cannot call Start on a running
  // or suspended thread" (ver TThread.InternalStart no System.Classes).
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TApiThumbProvider.TFetcher.Execute;
var
  MinuteMs, ActualMs: Int64;
  Camera: string;
  Data: TBytes;
begin
  while not Terminated do
  begin
    if not FOwner.NextWanted(MinuteMs, Camera) then
    begin
      FOwner.FWake.WaitFor(200);
      Continue;
    end;
    if FOwner.FApi.GetThumb(Camera, MinuteMs, Data, ActualMs) and
       (Length(Data) > 0) then
      FOwner.Store(MinuteMs, Data)
    else
      // Pode ser trecho sem gravação, servidor sem FFmpeg, ou rede fora. Nos
      // três casos a resposta é a mesma: não insiste neste minuto.
      FOwner.NoteMiss(MinuteMs);
  end;
end;

{ TApiThumbProvider }

constructor TApiThumbProvider.Create(AApi: TVmsApiClient; const ALogger: ILogger);
begin
  inherited Create;
  FApi := AApi;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FQueue := TList<Int64>.Create;
  FCache := TObjectDictionary<Int64, TBitmap>.Create([doOwnsValues]);
  FMisses := TDictionary<Int64, Boolean>.Create;
  FThread := TFetcher.Create(Self);
end;

destructor TApiThumbProvider.Destroy;
begin
  FStop := True;
  if FThread <> nil then
  begin
    FThread.Terminate;
    FWake.SetEvent;
    FThread.WaitFor;
    FThread.Free;
  end;
  FMisses.Free;
  FCache.Free;
  FQueue.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TApiThumbProvider.SetCamera(const Camera: string);
begin
  FLock.Enter;
  try
    if SameText(FCamera, Camera) then Exit;
    FCamera := Camera;
    // Câmera nova: imagem e ausência da anterior não dizem nada sobre esta.
    FQueue.Clear;
    FCache.Clear;
    FMisses.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TApiThumbProvider.SetOnArrived(const Handler: TProc);
begin
  FLock.Enter;
  try
    FOnArrived := Handler;
  finally
    FLock.Leave;
  end;
end;

function TApiThumbProvider.TryGet(MinuteMs: Int64; out Bmp: TBitmap): Boolean;
begin
  Bmp := nil;
  FLock.Enter;
  try
    Result := FCache.TryGetValue(MinuteMs, Bmp) and (Bmp <> nil);
  finally
    FLock.Leave;
  end;
end;

procedure TApiThumbProvider.Request(MinuteMs: Int64);
begin
  FLock.Enter;
  try
    if FCamera = '' then Exit;
    if FCache.ContainsKey(MinuteMs) then Exit;
    if FMisses.ContainsKey(MinuteMs) then Exit;
    if FQueue.IndexOf(MinuteMs) >= 0 then Exit;
    // Fila cheia: o pedido mais velho é o que menos importa — a tela já mudou.
    while FQueue.Count >= MAX_QUEUED do
      FQueue.Delete(0);
    FQueue.Add(MinuteMs);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TApiThumbProvider.DropPending;
begin
  FLock.Enter;
  try
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
end;

function TApiThumbProvider.NextWanted(out MinuteMs: Int64;
  out Camera: string): Boolean;
begin
  Result := False;
  MinuteMs := 0;
  Camera := '';
  FLock.Enter;
  try
    if FStop or (FQueue.Count = 0) or (FCamera = '') then Exit;
    // Do fim para o começo: o último pedido é o que a barra desenhou por último,
    // e é o que o olho está esperando.
    MinuteMs := FQueue[FQueue.Count - 1];
    FQueue.Delete(FQueue.Count - 1);
    Camera := FCamera;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TApiThumbProvider.Store(MinuteMs: Int64; const Data: TBytes);
var
  Stream: TBytesStream;
  Bmp: TBitmap;
  Chaves: TArray<Int64>;
  I: Integer;
begin
  Bmp := nil;
  Stream := TBytesStream.Create(Data);
  try
    Bmp := TBitmap.Create;
    try
      Bmp.LoadFromStream(Stream);
    except
      // JPEG que não abre: trata como ausente, sem derrubar a thread
      FreeAndNil(Bmp);
    end;
  finally
    Stream.Free;
  end;
  if Bmp = nil then
  begin
    NoteMiss(MinuteMs);
    Exit;
  end;

  FLock.Enter;
  try
    if FCache.Count >= MAX_CACHED then
    begin
      // Sem histórico de uso aqui: solta o lote mais antigo por chave, que numa
      // barra do tempo é o trecho mais distante do que se está olhando.
      Chaves := FCache.Keys.ToArray;
      TArray.Sort<Int64>(Chaves);
      for I := 0 to (MAX_CACHED div 4) - 1 do
        if I <= High(Chaves) then FCache.Remove(Chaves[I]);
    end;
    FCache.AddOrSetValue(MinuteMs, Bmp);
  finally
    FLock.Leave;
  end;
  Arrived;
end;

procedure TApiThumbProvider.NoteMiss(MinuteMs: Int64);
begin
  FLock.Enter;
  try
    if FMisses.Count > 4000 then FMisses.Clear;
    FMisses.AddOrSetValue(MinuteMs, True);
  finally
    FLock.Leave;
  end;
end;

// Um aviso por rajada: cada imagem que chega dispararia um redesenho da barra
// inteira, e elas chegam em série.
procedure TApiThumbProvider.Arrived;
var
  Handler: TProc;
begin
  FLock.Enter;
  try
    Handler := FOnArrived;
    if (not Assigned(Handler)) or FNotifyPending then Exit;
    FNotifyPending := True;
  finally
    FLock.Leave;
  end;
  TThread.Queue(nil,
    procedure
    begin
      FLock.Enter;
      try
        FNotifyPending := False;
      finally
        FLock.Leave;
      end;
      if Assigned(Handler) then Handler();
    end);
end;

end.
