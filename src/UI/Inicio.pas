unit Inicio;

// O que sobrou do app depois que a interface virou HTML.
//
// Este formulário não desenha mais nada: ele monta o que só o Delphi sabe fazer
// — configuração, relógio, log, conexão com a câmera — sobe um servidor HTTP
// local e mostra um WebView em tela cheia apontado para ele. Câmeras, dias,
// reprodução, ao vivo e cadastro são páginas (ver vms/src/Api/app-ui.html).
//
// ## O que ficou no Delphi, e por quê
//
// RTSP, DVRIP, depacketizers, leitura do `.vms`, reconexão: nada disso existe
// no navegador. O resto — layout, listas, régua do tempo, formulários — foi
// para HTML, onde é mais barato de mexer e roda igual no app e no navegador.
//
// O vídeo NÃO é decodificado aqui: a página faz isso com WebCodecs, lendo o
// `.vms` direto. Por isso não há renderer, nem decodificador, nem engine de
// reprodução neste app.
//
// ## O ao vivo
//
// Uma câmera por vez. A página pede `/api/live?camera=X`; se for outra câmera,
// a anterior cai. Um aparelho tem um decodificador e uma bateria, e manter três
// conexões RTSP abertas para ver uma só não se paga.
//
// Os samples vão para um `TLiveRing`, que os empacota no MESMO formato `.vms`
// das gravações — assim a página usa um leitor só para ao vivo e gravação.

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  System.UITypes,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.Graphics,            // TBrushKind: o fundo do formulario
  FMX.Layouts,
  FMX.Platform,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.App.Clock,           // TSystemClock
  VMS.Rtsp.Client,         // TRtspKeepAliveMethod (kamGetParameter)
  VMS.Domain.MediaSink,
  VMS.Domain.Supervisor,
  VMS.App.Config,
  VMS.App.Composition,
  VMS.App.Encerrar,        // EncerrarProcesso: sair, no Android, e sair
  VMS.App.ScreenAwake,
  VMS.Local.Server,
  VMS.App.Servers,         // TRegistroServidores: escolhe a rota do servidor
  VMS.Live.Ring,
  VMS.Win.Edge,
  UI.Common,
  UI.Shell;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure SairPelaPagina;
  private
    FLogger: ILogger;
    FClock: IClock;
    FAppCfg: TAppConfig;
    FCameras: TArray<TCameraConfigEntry>;
    // Os servidores cadastrados, guardados como o JSON que veio da página. O
    // Delphi não interpreta o formato além de `name` e `url` -- quem dá sentido
    // ao resto é a tela, e assim acrescentar um campo não mexe aqui.
    FServidoresJson: string;
    FClosing: Boolean;

    FLocal: TLocalServer;
    // Quem sabe por onde falar com cada servidor cadastrado. Fica aqui, e nao
    // dentro do TLocalServer, porque o cadastro e do app -- o servidor local so
    // pergunta o endereco na hora de encaminhar.
    FServidores: TRegistroServidores;
    FFrameShell: TFrameShell;

    // O ao vivo. O lock protege a troca de câmera, que vem das threads do Indy.
    FLiveLock: TCriticalSection;
    FLiveCam: string;
    FLiveRing: TLiveRing;
    FLiveSink: IMediaSink;    // segura a referência contada do anel
    FSupervisor: TCameraSupervisor;
    // Qual câmera o AbrirAoVivoNaUI vai abrir. Campo, e não parâmetro, porque
    // quem pede vem de uma thread do Indy e o trabalho acontece na principal.
    FIndiceAbrir: Integer;

    procedure DefaultAppCfg;
    function CamerasFilePath: string;
    procedure LoadCameras;
    procedure SaveCameras;

    { chamados pelo servidor local, quase sempre de uma thread do Indy }
    function CamerasDoApp: TArray<string>;
    function LerConfigCameras: string;
    function ServidoresFilePath: string;
    procedure LoadServidores;
    function LerServidores: string;
    function GravarServidores(const Json: string): string;
    function UrlDoServidor(const Nome: string): string;
    procedure ServidorFalhou(const Nome: string);
    function CredencialDoServidor(const Nome: string;
                                  out Usuario, Senha: string): Boolean;
    function SondarServidor(const Nome: string): string;
    function DiagServidores: string;
    function GravarConfigCameras(const Json: string): string;
    function LerAoVivo(const Camera: string; Cursor: Cardinal;
                       out Dados: TBytes; out ProxCursor: Cardinal): Boolean;

    procedure PararAoVivo;
    // Abre a câmera de FIndiceAbrir. Sem parâmetros de propósito: é essa a
    // forma que o TThread.Synchronize aceita direto, e o índice viaja pelo
    // campo em vez de por um método anônimo.
    procedure AbrirAoVivoNaUI;
    procedure ShellSair(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar;
                        Shift: TShiftState);
    function HandleAppEvent(AAppEvent: TApplicationEvent;
                            AContext: TObject): Boolean;
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

uses
  System.JSON,
  System.StrUtils,          // IfThen, na linha de log do servers.json
  System.Generics.Collections,
  VMS.Android.MemoLogger;

procedure TForm1.FormCreate(Sender: TObject);
var
  Svc: IFMXApplicationEventService;
begin
  DefaultAppCfg;
  FClock := TSystemClock.Create;
  FLogger := TMemoLogger.Create;
  LoadCameras;
  LoadServidores;

  // O Edge tem de estar escolhido ANTES do primeiro TWebBrowser nascer: o FMX
  // nasce com TWindowsEngine.IEOnly, e o Trident não tem WebCodecs.
  ConfigurarEdge;

  // O fundo do formulario e o mesmo da interface. Enquanto o app fecha, a
  // janela fica um instante na tela sem o WebView em cima, e o branco padrao do
  // FMX era exatamente a "tela branca" que aparecia no fim.
  Fill.Kind := TBrushKind.Solid;
  Fill.Color := COLOR_BG;

  FLiveLock := TCriticalSection.Create;
  FLocal := TLocalServer.Create(FLogger);
  FLocal.OnCameras := CamerasDoApp;
  FLocal.OnLerConfig := LerConfigCameras;
  FLocal.OnGravarConfig := GravarConfigCameras;
  FLocal.OnLive := LerAoVivo;
  FLocal.OnLerServidores := LerServidores;
  FLocal.OnGravarServidores := GravarServidores;
  FLocal.OnServidorUrl := UrlDoServidor;
  FLocal.OnServidorFalhou := ServidorFalhou;
  FLocal.OnServidorCredencial := CredencialDoServidor;
  FLocal.OnSondarServidor := SondarServidor;
  FLocal.OnServidorDiag := DiagServidores;
  FLocal.OnSair := SairPelaPagina;
  FLocal.Start;

  FFrameShell := TFrameShell.Create(Self);
  FFrameShell.Parent := Self;
  FFrameShell.Align := TAlignLayout.Contents;
  FFrameShell.OnSair := ShellSair;
  FFrameShell.Abrir(FLocal.BaseUrl);

  if TPlatformServices.Current.SupportsPlatformService(
       IFMXApplicationEventService, Svc) then
    Svc.SetApplicationEventHandler(HandleAppEvent);

  Self.OnKeyUp := FormKeyUp;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FClosing := True;
  try
    // Migalhas no logcat. Este caminho já empacou uma vez sem deixar rastro, e
    // descobrir ONDE custou uma compilação inteira.
    FLogger.Info('sair', 'demolindo: browser');
    // O WebView vai embora ANTES de tudo: fechar o app leva um tempo (parar o
    // servidor local, dar teardown na sessão RTSP), e nesse tempo a janela
    // ainda está na tela. Deixando o browser vivo, o que se via era ele
    // quebrado — a página perdendo o servidor debaixo dela. Sem ele fica o
    // fundo escuro da casca, que é a mesma cor da interface.
    if FFrameShell <> nil then
      FFrameShell.Encerrar;
    FLogger.Info('sair', 'demolindo: servidor local');
    // Depois o servidor local: cada conexão dele é uma thread do Indy que
    // chama de volta para cá. Derrubar o resto antes deixaria essas threads
    // lendo um formulário em demolição.
    if FLocal <> nil then
    begin
      FLocal.Stop;
      FreeAndNil(FLocal);
    end;
    FLogger.Info('sair', 'demolindo: ao vivo');
    PararAoVivo;
    // Depois do FLocal, e não antes: é ele quem chama o registro, de dentro
    // das threads do Indy.
    FreeAndNil(FServidores);
    FreeAndNil(FLiveLock);
    SetKeepScreenOn(False);
    FLogger.Info('sair', 'demolicao completa');
  finally
    // No Android fechar a janela não encerra o processo, e o processo que fica
    // não tem mais formulário nenhum: reabrir o app dava tela branca para
    // sempre. No finally, e não no fim do corpo: exceção na demolição não pode
    // deixar vivo justamente o processo que quebra a próxima abertura. Ver
    // VMS.App.Encerrar.
    EncerrarProcesso;
  end;
end;

// ---------------------------------------------------------------- config

procedure TForm1.DefaultAppCfg;
begin
  FAppCfg.StorageDir := '';
  FAppCfg.LogDir := '';
  FAppCfg.TransportFallbackTimeoutMs := 5000;
  FAppCfg.KeepAliveMethod := kamGetParameter;
  FAppCfg.MaxBlockSamples := 256;
  FAppCfg.MaxBlockDurationMs := 2000;
  FAppCfg.MaxBlockSizeBytes := 1048576;
  FAppCfg.RotateMs := DEFAULT_ROTATE_MINUTES * 60000;
end;

function TForm1.CamerasFilePath: string;
begin
  Result := TPath.Combine(TPath.GetDocumentsPath, 'cameras.json');
end;

procedure TForm1.LoadCameras;
var
  S: string;
begin
  SetLength(FCameras, 0);
  if not TFile.Exists(CamerasFilePath) then
    Exit;   // começa vazio; o arquivo nasce ao cadastrar a primeira câmera
  try
    S := TFile.ReadAllText(CamerasFilePath, TEncoding.UTF8);
    if not CamerasFromJson(S, FCameras) then
      SetLength(FCameras, 0);
  except
    on E: Exception do
    begin
      FLogger.Error('cfg', 'cameras.json ilegivel: ' + E.Message);
      SetLength(FCameras, 0);
    end;
  end;
end;

procedure TForm1.SaveCameras;
begin
  // O mesmo texto que a exportação manda para outro aparelho: um serializador
  // só (ver CamerasToJson em UI.Common).
  TFile.WriteAllText(CamerasFilePath, CamerasToJson(FCameras), TEncoding.UTF8);
end;

// ------------------------------------------------- o que o servidor pergunta

function TForm1.CamerasDoApp: TArray<string>;
var
  I, N: Integer;
begin
  SetLength(Result, Length(FCameras));
  N := 0;
  for I := 0 to High(FCameras) do
    if FCameras[I].Enabled then
    begin
      Result[N] := FCameras[I].Name;
      Inc(N);
    end;
  SetLength(Result, N);
end;

function TForm1.LerConfigCameras: string;
begin
  Result := CamerasToJson(FCameras);
end;

// ------------------------------------------------------------- servidores
//
// Ficam num arquivo próprio, ao lado do cameras.json. São coisas diferentes: um
// servidor é de onde se BUSCA gravação, uma câmera é o que este aparelho
// conecta direto. Misturar os dois num arquivo só daria um formato que precisa
// explicar qual é qual.

function TForm1.ServidoresFilePath: string;
begin
  Result := TPath.Combine(TPath.GetDocumentsPath, 'servers.json');
end;

procedure TForm1.LoadServidores;
begin
  FServidoresJson := '{"servers":[]}';
  if TFile.Exists(ServidoresFilePath) then
  try
    FServidoresJson := TFile.ReadAllText(ServidoresFilePath, TEncoding.UTF8);
  except
    on E: Exception do
      FLogger.Error('cfg', 'servers.json ilegivel: ' + E.Message);
  end;
  // O caminho E o tamanho: "não achei o arquivo" e "achei um arquivo vazio"
  // levam a lugares diferentes, e do lado de fora os dois parecem iguais.
  FLogger.Info('cfg', Format('servers.json em %s (%s, %d bytes)',
    [ServidoresFilePath,
     IfThen(TFile.Exists(ServidoresFilePath), 'existe', 'NAO existe'),
     Length(FServidoresJson)]));
  if FServidores = nil then
    FServidores := TRegistroServidores.Create(FLogger);
  FServidores.Carregar(FServidoresJson);
end;

function TForm1.LerServidores: string;
begin
  Result := FServidoresJson;
end;

function TForm1.GravarServidores(const Json: string): string;
var
  Valor: TJSONValue;
  Erro: string;
  Tarefa: TThreadProcedure;
begin
  // Validação mínima: tem de ser um objeto JSON. O conteúdo é da tela.
  Valor := TJSONObject.ParseJSONValue(Json);
  if not (Valor is TJSONObject) then
  begin
    Valor.Free;
    Exit('json invalido');
  end;
  Valor.Free;

  Erro := '';
  Tarefa :=
    procedure
    begin
      if FClosing then
      begin
        Erro := 'app encerrando';
        Exit;
      end;
      try
        FServidoresJson := Json;
        TFile.WriteAllText(ServidoresFilePath, Json, TEncoding.UTF8);
        // O cadastro mudou: nenhuma rota escolhida antes vale mais.
        //
        // Se esta linha não rodar -- exceção na escrita, registro ainda nil --,
        // o arquivo passa a ter o servidor e a busca do endereço não, até
        // reiniciar o app. É um estado difícil de enxergar de fora, então ele
        // aparece no log dos dois jeitos.
        if FServidores <> nil then
        begin
          FServidores.Carregar(Json);
          FLogger.Info('cfg', Format('servers.json gravado (%d bytes) e ' +
            'recarregado em memoria', [Length(Json)]));
        end
        else
          FLogger.Warn('cfg', 'servers.json gravado, mas o registro em ' +
            'memoria nao existe: a busca de endereco so vai funcionar depois ' +
            'de reiniciar o app');
      except
        on E: Exception do
          Erro := E.Message;
      end;
    end;
  TThread.Synchronize(nil, Tarefa);
  Result := Erro;
end;

// Por onde falar com um servidor cadastrado. Chamado de uma thread do Indy a
// cada requisição encaminhada; quem decide -- e quem guarda a decisão para não
// sondar toda vez -- é o TRegistroServidores.
function TForm1.UrlDoServidor(const Nome: string): string;
begin
  if FServidores = nil then Exit('');
  Result := FServidores.UrlDe(Nome);
end;

// O encaminhamento não conseguiu falar com a rota escolhida. Pode ser o
// servidor fora do ar, pode ser o aparelho ter saído de casa: nos dois casos a
// próxima requisição tem de escolher de novo, e é assim que trocar de rede no
// meio de uma sessão se resolve sem ninguém mexer em nada.
procedure TForm1.ServidorFalhou(const Nome: string);
begin
  if FServidores <> nil then FServidores.Invalidar(Nome);
end;

// Uma linha sobre o cadastro em memória, para a falha de encaminhamento se
// explicar em vez de dizer só "sem servidor configurado".
function TForm1.DiagServidores: string;
begin
  if FServidores = nil then Exit('o cadastro nem chegou a ser carregado');
  Result := FServidores.Diagnostico;
end;

// O usuário e a senha cadastrados para este servidor.
function TForm1.CredencialDoServidor(const Nome: string;
  out Usuario, Senha: string): Boolean;
begin
  Usuario := '';
  Senha := '';
  Result := (FServidores <> nil) and FServidores.Credencial(Nome, Usuario, Senha);
end;

// A sondagem que a tela de cadastro mostra: cada rota, uma a uma, e qual delas
// seria usada agora.
function TForm1.SondarServidor(const Nome: string): string;
var
  Obj: TJSONObject;
begin
  if FServidores = nil then Exit('{"error":"sem cadastro"}');
  Obj := FServidores.SondarTodas(Nome);
  try
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function TForm1.GravarConfigCameras(const Json: string): string;
var
  Novas: TArray<TCameraConfigEntry>;
  Erro: string;
  Tarefa: TThreadProcedure;
begin
  if not CamerasFromJson(Json, Novas) then
    Exit('json invalido');

  Erro := '';
  Tarefa :=
    procedure
    begin
      if FClosing then
      begin
        Erro := 'app encerrando';
        Exit;
      end;
      try
        FCameras := Novas;
        SaveCameras;
      except
        on E: Exception do
          Erro := E.Message;
      end;
    end;
  TThread.Synchronize(nil, Tarefa);
  Result := Erro;
end;

procedure TForm1.PararAoVivo;
begin
  FLiveCam := '';
  FLiveRing := nil;
  FLiveSink := nil;
  if FSupervisor <> nil then
  begin
    FSupervisor.Stop;
    FreeAndNil(FSupervisor);
  end;
  SetKeepScreenOn(False);
end;

// Abre a câmera de FIndiceAbrir. SEMPRE na thread principal: o supervisor tem
// threads próprias, e criá-las de dentro de uma conexão do Indy daria corrida
// com o encerramento do app.
procedure TForm1.AbrirAoVivoNaUI;
begin
  if FClosing then Exit;
  if (FIndiceAbrir < 0) or (FIndiceAbrir > High(FCameras)) then Exit;
  PararAoVivo;
  FLiveRing := TLiveRing.Create(FCameras[FIndiceAbrir].Url, FClock);
  FLiveSink := FLiveRing;
  FLiveCam := FCameras[FIndiceAbrir].Name;
  try
    FSupervisor := BuildPlayerSupervisor(FAppCfg, FCameras[FIndiceAbrir],
                                         FLogger, FClock, FLiveSink);
    FSupervisor.Start;
    // Enquanto a câmera está no ar a tela não pode apagar: o usuário fica
    // minutos sem tocar em nada, olhando.
    SetKeepScreenOn(True);
  except
    on E: Exception do
    begin
      FLogger.Error('live', 'falha ao iniciar: ' + E.Message);
      PararAoVivo;
    end;
  end;
end;

function TForm1.LerAoVivo(const Camera: string; Cursor: Cardinal;
  out Dados: TBytes; out ProxCursor: Cardinal): Boolean;
var
  Indice, I: Integer;
  Anel: TLiveRing;
begin
  Result := False;
  Dados := nil;
  ProxCursor := Cursor;
  if FClosing or (FLiveLock = nil) then Exit;

  FLiveLock.Enter;
  try
    if not SameText(FLiveCam, Camera) then
    begin
      Indice := -1;
      for I := 0 to High(FCameras) do
        if SameText(FCameras[I].Name, Camera) and FCameras[I].Enabled then
        begin
          Indice := I;
          Break;
        end;
      if Indice < 0 then Exit;

      // Trocar de câmera derruba a anterior: um decodificador, uma conexão.
      FIndiceAbrir := Indice;
      TThread.Synchronize(nil, AbrirAoVivoNaUI);
      // Recém-aberta: ainda não há bloco fechado, e o 204 diz isso.
      ProxCursor := 0;
      Exit;
    end;
    Anel := FLiveRing;
  finally
    FLiveLock.Leave;
  end;

  if Anel = nil then Exit;
  Result := Anel.Ler(Cursor, Dados, ProxCursor);
end;

// ---------------------------------------------------------------- navegação

// A página já estava na raiz quando o voltar chegou. Sem interface nativa atrás
// dela, isso é o fim: o app fecha, como qualquer outro no Android.
procedure TForm1.ShellSair(Sender: TObject);
begin
  FClosing := True;
  // No Android, sair é encerrar o processo -- e sem arrumar a casa antes.
  //
  // Arrumar a casa é justamente onde ele empacava. Medido no aparelho: o
  // `Close` chega ao FormDestroy, o servidor local para de escutar (a porta
  // 8899 já não tem socket em LISTEN) e dali a demolição não volta mais. Dez
  // segundos depois o sistema desiste -- `Activity destroy timeout` -- e o
  // processo fica vivo com a thread principal parada no laço de mensagens, sem
  // formulário nenhum. A abertura seguinte reaproveita esse processo e é isso
  // que aparece como tela branca eterna.
  //
  // E parar o Indy com jeitinho e dar teardown na sessão RTSP não serve para
  // nada quando o passo seguinte é o processo morrer: quem recolhe socket,
  // thread e memória é o sistema. O que este app tinha para gravar já foi
  // gravado no instante em que mudou.
  FLogger.Info('sair', 'encerrando o processo');
  EncerrarProcesso;
  // Fora do Android o caminho é o normal: some com o browser antes de mandar
  // fechar, e não durante, para o último quadro na tela ser o fundo do app e
  // não uma página sem servidor.
  if FFrameShell <> nil then
    FFrameShell.Encerrar;
  Close;
end;

// A página pediu para sair, por /api/app/sair.
//
// Queue, e não Synchronize: isto chega numa thread do Indy, e o fechamento
// derruba o próprio servidor que ainda está respondendo esta requisição —
// esperar por ele aqui seria esperar por si mesmo.
procedure TForm1.SairPelaPagina;
begin
  TThread.Queue(nil,
    procedure
    begin
      if not FClosing then ShellSair(nil);
    end);
end;

procedure TForm1.FormKeyUp(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key <> vkHardwareBack then Exit;
  // Quem sabe se há para onde voltar é a página: ela tem várias telas dentro de
  // si. A resposta chega depois, por OnSair.
  if FFrameShell <> nil then
  begin
    FFrameShell.Voltar;
    Key := 0;
  end;
end;

function TForm1.HandleAppEvent(AAppEvent: TApplicationEvent;
  AContext: TObject): Boolean;
var
  Tarefa: TThreadProcedure;
begin
  Result := True;
  case AAppEvent of
    TApplicationEvent.EnteredBackground,
    TApplicationEvent.WillTerminate:
      // Em segundo plano o WebView é congelado e ninguém está vendo: manter a
      // câmera conectada só gastaria bateria e dados. A página reabre o ao vivo
      // sozinha quando volta, porque o `/api/live` recomeça a sessão.
      begin
        Tarefa :=
          procedure
          begin
            if not FClosing then PararAoVivo;
          end;
        TThread.Queue(nil, Tarefa);
      end;
  end;
end;

end.
