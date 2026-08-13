unit Vms.Server.Logger;

// Logger do servidor: um arquivo por câmera.
//
// Todo log no VMS carrega uma tag, e as tags das partes que lidam com uma
// câmera terminam no nome dela:
//   session.<cam>     cliente RTSP          supervisor.<cam>  reconexão
//   dvrip.<cam>       cliente DVRIP         recsink.<cam>     gravação do dvrip
//   tx.session.<cam>  cliente assistindo pelo servidor
// Este logger olha a tag e manda a linha para <logDir>\<cam>_<data>.log.
// O que não é de câmera (main, composition, tx.listener) vai para o arquivo
// geral. O console continua recebendo tudo, para acompanhar ao vivo.
//
// Não há corte por nível: debug/info/warn/error são todos gravados. O
// `logLevel` do JSON não é usado aqui.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  VMS.Domain.Logging,
  VMS.App.Logger,
  VMS.App.Config;

type
  TPerCameraLogger = class(TInterfacedObject, ILogger)
  strict private
    FConsole: ILogger;
    FGeneral: ILogger;
    // montado no construtor e nunca mais alterado -> leitura concorrente é
    // segura sem lock (cada TFileLogger já tem o seu)
    FByCamera: TDictionary<string, ILogger>;
    function CameraOf(const Tag: string): string;
    function TargetFor(const Tag: string): ILogger;
  public
    constructor Create(const ALogDir: string; const ACameras: TArray<TCameraConfigEntry>;
                       AConsole: Boolean = True);
    destructor Destroy; override;
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
  end;

implementation

// Deixa o texto seguro para escrever. Payload binário decodificado como UTF-8
// (o `ctrl:` do DVRIP faz isso) vira string com surrogates soltos e caracteres
// de controle; na hora de gravar, a conversão para UTF-8 no arquivo ou para a
// codepage do console levanta "No mapping for the Unicode character exists in
// the target multi-byte code page".
function SanitizeLogText(const S: string): string;
var
  I, N: Integer;
  C: Char;
begin
  SetLength(Result, Length(S));
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if (C >= #$D800) and (C <= #$DBFF) then
    begin
      // par de surrogates válido passa inteiro; high sozinho vira '?'
      if (I < Length(S)) and (S[I + 1] >= #$DC00) and (S[I + 1] <= #$DFFF) then
      begin
        Inc(N); Result[N] := C;
        Inc(N); Result[N] := S[I + 1];
        Inc(I, 2);
        Continue;
      end;
      Inc(N); Result[N] := '?';
    end
    else if (C >= #$DC00) and (C <= #$DFFF) then
    begin
      Inc(N); Result[N] := '?'; // low surrogate solto
    end
    else if (C < #32) and (C <> #9) then
    begin
      Inc(N); Result[N] := ' '; // controle: não quebra a linha do log
    end
    else
    begin
      Inc(N); Result[N] := C;
    end;
    Inc(I);
  end;
  SetLength(Result, N);
end;

function SanitizeForFilename(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if CharInSet(Result[I], ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then
      Result[I] := '_';
  Result := Trim(Result);
  if Result = '' then Result := 'camera';
end;

{ TPerCameraLogger }

constructor TPerCameraLogger.Create(const ALogDir: string;
  const ACameras: TArray<TCameraConfigEntry>; AConsole: Boolean);
var
  I: Integer;
  Dir, Stamp, Key, Path: string;
begin
  inherited Create;
  FByCamera := TDictionary<string, ILogger>.Create;

  if AConsole then
    FConsole := TConsoleLogger.Create(llDebug);

  if Trim(ALogDir) = '' then Exit; // só console

  Dir := IncludeTrailingPathDelimiter(ExpandFileName(ALogDir));
  if not DirectoryExists(Dir) then
    ForceDirectories(Dir);
  Stamp := FormatDateTime('yyyy-mm-dd', Now);

  FGeneral := TFileLogger.Create(Dir + 'vmsserver_' + Stamp + '.log', llDebug);

  for I := 0 to High(ACameras) do
  begin
    if not ACameras[I].Enabled then Continue;
    Key := LowerCase(Trim(ACameras[I].Name));
    if (Key = '') or FByCamera.ContainsKey(Key) then Continue;
    Path := Dir + SanitizeForFilename(ACameras[I].Name) + '_' + Stamp + '.log';
    FByCamera.Add(Key, TFileLogger.Create(Path, llDebug));
  end;
end;

destructor TPerCameraLogger.Destroy;
begin
  FByCamera.Free; // as ILogger de dentro se liberam por refcount
  inherited;
end;

function TPerCameraLogger.CameraOf(const Tag: string): string;
var
  P: Integer;
  Cand: string;
begin
  Result := '';
  P := Pos('.', Tag);
  if P = 0 then Exit;
  // 'session.ayla' -> 'ayla'
  Cand := LowerCase(Copy(Tag, P + 1, MaxInt));
  if FByCamera.ContainsKey(Cand) then Exit(Cand);
  // 'tx.session.ayla' -> 'ayla'
  P := LastDelimiter('.', Tag);
  Cand := LowerCase(Copy(Tag, P + 1, MaxInt));
  if FByCamera.ContainsKey(Cand) then Exit(Cand);
end;

function TPerCameraLogger.TargetFor(const Tag: string): ILogger;
var
  Cam: string;
begin
  Cam := CameraOf(Tag);
  if (Cam <> '') and FByCamera.TryGetValue(Cam, Result) then Exit;
  Result := FGeneral;
end;

procedure TPerCameraLogger.Log(Level: TLogLevel; const Tag, Msg: string);
var
  Target: ILogger;
  Text: string;
begin
  // sem corte por nível: grava tudo, sempre. As chamadas Debug do VMS são de
  // handshake/requisição (nada por pacote), então o arquivo não incha.
  Text := SanitizeLogText(Msg);
  // Escrever log NUNCA pode derrubar quem chamou. Sem isto, uma exceção de
  // codificação subia pela sessão da câmera e matava a conexão dela.
  try
    if FConsole <> nil then
      FConsole.Log(Level, Tag, Text);
    Target := TargetFor(Tag);
    if Target <> nil then
      Target.Log(Level, Tag, Text);
  except
    // um log perdido é melhor que um stream derrubado
  end;
end;

procedure TPerCameraLogger.Debug(const Tag, Msg: string); begin Log(llDebug, Tag, Msg); end;
procedure TPerCameraLogger.Info(const Tag, Msg: string);  begin Log(llInfo,  Tag, Msg); end;
procedure TPerCameraLogger.Warn(const Tag, Msg: string);  begin Log(llWarn,  Tag, Msg); end;
procedure TPerCameraLogger.Error(const Tag, Msg: string); begin Log(llError, Tag, Msg); end;

end.
