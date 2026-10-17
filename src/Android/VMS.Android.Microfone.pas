unit VMS.Android.Microfone;

// O microfone do aparelho, gravado pelo proprio app, para a fala com a camera.
//
// Existe porque o WebView do FMX nega o microfone a pagina. Quem decide e o
// WebChromeClient.onPermissionRequest, e o padrao dele e recusar; mudar isso
// exige uma subclasse Java, que o Delphi nao escreve sem um .jar compilado a
// parte. O AudioRecord, ao contrario, e uma classe comum: o Delphi cria e le
// direto pelo JNI. Entao no Android a pagina so diz "liga" e "desliga", e o
// audio nem passa por ela.
//
// Fora do Android e no-op -- CriarMicrofone devolve nil, e a pagina usa o
// getUserMedia do navegador, que no WebView2 funciona.

interface

uses
  System.SysUtils;

type
  // Recebe PCM 16 bits little-endian, 8 kHz, mono, em pedacos de ~160 ms. E
  // chamado na thread da gravacao, e nao na principal.
  TPcmProc = reference to procedure(const Pcm: TBytes);

  IMicrofone = interface
    ['{3C8F1A62-7D4B-4E95-B0A1-6F2E9C5D8B17}']
    // True = pode gravar ja. False = a permissao ainda nao foi dada: o pedido
    // e feito aqui (a janela do sistema aparece) e Motivo diz o que fazer.
    // Nao espera a resposta -- quem chama e uma thread do HTTP, e a janela
    // depende de a pessoa tocar nela.
    function Pronto(out Motivo: string): Boolean;
    function Iniciar(const OnPcm: TPcmProc; out Motivo: string): Boolean;
    // Espera a thread da gravacao sair. Nao chamar de dentro do OnPcm.
    procedure Parar;
    function Gravando: Boolean;
  end;

// nil fora do Android.
function CriarMicrofone: IMicrofone;

implementation

{$IFDEF ANDROID}

uses
  System.Types,        // TClassicStringDynArray
  System.Classes,
  System.SyncObjs,
  System.Permissions,
  Androidapi.JNIBridge,
  Androidapi.JNI.Media;

const
  PERMISSAO = 'android.permission.RECORD_AUDIO';
  TAXA = 8000;
  // Numeros das constantes do Android, e nao as propriedades das classes
  // importadas: sao fixos na API desde sempre, e assim esta unit nao depende
  // de qual versao do import traz qual nome.
  //
  // VOICE_COMMUNICATION, e nao MIC: e a fonte que liga o cancelamento de eco
  // e a supressao de ruido do aparelho -- o alto-falante da camera costuma
  // estar no mesmo ambiente que o microfone dela, e o ao vivo toca o audio.
  FONTE_VOZ = 7;             // MediaRecorder.AudioSource.VOICE_COMMUNICATION
  CANAL_MONO = 16;           // AudioFormat.CHANNEL_IN_MONO
  PCM_16 = 2;                // AudioFormat.ENCODING_PCM_16BIT
  ESTADO_INICIADO = 1;       // AudioRecord.STATE_INITIALIZED
  // 160 ms: o mesmo pedaco que a pagina manda no Windows.
  PEDACO = TAXA * 2 * 160 div 1000;

type
  TMicrofoneAndroid = class(TInterfacedObject, IMicrofone)
  strict private
    FLock: TCriticalSection;
    FThread: TThread;
    FParar: TEvent;
    FPedindo: Boolean;
    procedure Laco(const Rec: JAudioRecord; const OnPcm: TPcmProc);
  public
    constructor Create;
    destructor Destroy; override;
    function Pronto(out Motivo: string): Boolean;
    function Iniciar(const OnPcm: TPcmProc; out Motivo: string): Boolean;
    procedure Parar;
    function Gravando: Boolean;
  end;

  TLacoMic = class(TThread)
  strict private
    FProc: TProc;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProc: TProc);
  end;

constructor TLacoMic.Create(const AProc: TProc);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProc := AProc;
end;

procedure TLacoMic.Execute;
begin
  FProc();
end;

constructor TMicrofoneAndroid.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FParar := TEvent.Create(nil, True, False, '');
end;

destructor TMicrofoneAndroid.Destroy;
begin
  Parar;
  FParar.Free;
  FLock.Free;
  inherited;
end;

function TMicrofoneAndroid.Pronto(out Motivo: string): Boolean;
begin
  Motivo := '';
  Result := PermissionsService.IsPermissionGranted(PERMISSAO);
  if Result then Exit;
  Motivo := 'permita o microfone e toque em Falar de novo';
  FLock.Enter;
  try
    // Um pedido so por vez: tocar de novo com a janela aberta empilharia
    // outra janela igual atras dela.
    if FPedindo then Exit;
    FPedindo := True;
  finally
    FLock.Leave;
  end;
  // A janela do sistema tem de ser pedida na thread principal.
  TThread.Queue(nil,
    procedure
    begin
      PermissionsService.RequestPermissions([PERMISSAO],
        procedure(const APermissions: TClassicStringDynArray;
                  const AGrantResults: TClassicPermissionStatusDynArray)
        begin
          FPedindo := False;
        end);
    end);
end;

function TMicrofoneAndroid.Iniciar(const OnPcm: TPcmProc;
  out Motivo: string): Boolean;
var
  Minimo: Integer;
  Rec: JAudioRecord;
begin
  Result := False;
  Motivo := '';
  Parar;
  if not Pronto(Motivo) then Exit;
  try
    Minimo := TJAudioRecord.JavaClass.getMinBufferSize(TAXA, CANAL_MONO, PCM_16);
    if Minimo <= 0 then
    begin
      Motivo := 'o aparelho nao grava a 8 kHz';
      Exit;
    end;
    // Folga de dois segundos no buffer do sistema: a primeira entrega espera
    // o login na camera, e nesse tempo ninguem esta lendo.
    if Minimo < TAXA * 2 * 2 then Minimo := TAXA * 2 * 2;
    Rec := TJAudioRecord.JavaClass.init(FONTE_VOZ, TAXA, CANAL_MONO, PCM_16, Minimo);
    if Rec.getState <> ESTADO_INICIADO then
    begin
      Rec.release;
      Motivo := 'o microfone nao abriu (outro app usando?)';
      Exit;
    end;
    Rec.startRecording;
  except
    on E: Exception do
    begin
      Motivo := 'microfone: ' + E.Message;
      Exit;
    end;
  end;
  FParar.ResetEvent;
  FThread := TLacoMic.Create(
    procedure
    begin
      Laco(Rec, OnPcm);
    end);
  FThread.Start;
  Result := True;
end;

procedure TMicrofoneAndroid.Laco(const Rec: JAudioRecord; const OnPcm: TPcmProc);
var
  Buf: TJavaArray<Byte>;
  Pcm: TBytes;
  Lidos: Integer;
begin
  Buf := TJavaArray<Byte>.Create(PEDACO);
  try
    try
      while FParar.WaitFor(0) <> wrSignaled do
      begin
        // Bloqueia ate juntar o pedaco: e o proprio microfone que da o ritmo.
        Lidos := Rec.read(Buf, 0, PEDACO);
        if Lidos <= 0 then Break;
        SetLength(Pcm, Lidos);
        Move(Buf.Data^, Pcm[0], Lidos);
        // Solta a copia que o Data pegou. Sem isto a proxima volta leria de
        // novo a MESMA copia -- o JNI pode entregar os elementos copiados, e
        // o que o read escreve depois fica so do lado Java.
        Buf.Sync;
        OnPcm(Pcm);
      end;
    except
      // A gravacao nao pode derrubar o app. Quem liga ve pelo Gravando.
    end;
  finally
    Buf.Free;
    try
      Rec.stop;
      Rec.release;
    except
    end;
  end;
end;

procedure TMicrofoneAndroid.Parar;
begin
  if FThread = nil then Exit;
  FParar.SetEvent;
  // O read devolve no maximo em 160 ms, e ai o laco ve o evento.
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

function TMicrofoneAndroid.Gravando: Boolean;
begin
  Result := (FThread <> nil) and not FThread.Finished;
end;

function CriarMicrofone: IMicrofone;
begin
  Result := TMicrofoneAndroid.Create;
end;

{$ELSE}

function CriarMicrofone: IMicrofone;
begin
  Result := nil;
end;

{$ENDIF}

end.
