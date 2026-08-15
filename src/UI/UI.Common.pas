unit UI.Common;

// Constantes visuais (cores/ícones) e helpers de câmera/URL compartilhados entre
// o shell (Inicio) e os frames (UI.List / UI.Player / UI.Editor).

interface

uses
  System.SysUtils, System.UITypes, System.JSON, System.Generics.Collections,
  VMS.Domain.Types,
  VMS.App.Config;

const
  COLOR_SURFACE  = TAlphaColor($FF1E1E1E);
  COLOR_SURFACE2 = TAlphaColor($FF2A2A2A);
  COLOR_ACCENT   = TAlphaColor($FF2D9CDB);
  COLOR_DANGER   = TAlphaColor($FFE74C3C);
  COLOR_TEXT     = TAlphaColor($FFFFFFFF);
  COLOR_DIM      = TAlphaColor($FFB0B0B0);
  COLOR_BG       = TAlphaColor($FF121212);
  // campos de entrada: o estilo padrão pinta fundo branco (Windows) ou
  // transparente (Android), então o app desenha o seu próprio fundo escuro
  COLOR_FIELD        = TAlphaColor($FF262626);
  COLOR_FIELD_BORDER = TAlphaColor($FF3F3F3F);
  STAT_GREEN  = TAlphaColor($FF27AE60);
  STAT_YELLOW = TAlphaColor($FFF2C94C);
  STAT_ORANGE = TAlphaColor($FFF2994A);
  STAT_GRAY   = TAlphaColor($FF888888);
  // ícones (path SVG só com M/L/Z para máxima compatibilidade do parser)
  ICON_ADD    = 'M11 5 L13 5 L13 11 L19 11 L19 13 L13 13 L13 19 L11 19 L11 13 L5 13 L5 11 L11 11 Z';
  ICON_BACK   = 'M13 5 L6 12 L13 19 L14.4 17.6 L9.8 13 L20 13 L20 11 L9.8 11 L14.4 6.4 Z';
  ICON_LOG    = 'M3 5 L21 5 L21 7 L3 7 Z M3 11 L21 11 L21 13 L3 13 Z M3 17 L15 17 L15 19 L3 19 Z';
  ICON_CAMERA = 'M3 7 L3 17 L15 17 L15 13 L21 16 L21 8 L15 11 L15 7 Z';
  // alto-falante + barras de volume / alto-falante + "X" (mudo). Os dois têm a
  // MESMA bounding box (3..19 x 4..20) pro WrapMode=Fit não mudar o tamanho do
  // ícone ao alternar.
  ICON_SOUND  = 'M3 9 L7 9 L12 4 L12 20 L7 15 L3 15 Z M14 8 L15.6 8 L15.6 16 L14 16 Z ' +
                'M17.4 5.5 L19 5.5 L19 18.5 L17.4 18.5 Z';
  ICON_MUTE   = 'M3 9 L7 9 L12 4 L12 20 L7 15 L3 15 Z M14 10.5 L15.4 9.1 L16.5 10.2 ' +
                'L17.6 9.1 L19 10.5 L17.9 11.6 L19 12.7 L17.6 14.1 L16.5 13 L15.4 14.1 ' +
                'L14 12.7 L15.1 11.6 Z';
  ICON_TRASH  = 'M10 3 L14 3 L14 5 L10 5 Z M5 5 L19 5 L19 7 L5 7 Z M7 7 L17 7 L16 21 L8 21 Z';

type
  // eventos usados pelos frames para avisar o shell
  TCamIndexEvent = procedure(Sender: TObject; Index: Integer) of object;
  TCamEntryEvent = procedure(Sender: TObject; const Entry: TCameraConfigEntry;
    EditIndex: Integer) of object;

function JsonStr(O: TJSONObject; const Name: string): string;
function JsonInt(O: TJSONObject; const Name: string; Def: Integer): Integer;
function JsonBool(O: TJSONObject; const Name: string; Def: Boolean): Boolean;

function ParseTransports(const S: string): TArray<TTransportKind>;
function TransportsToStr(const T: TArray<TTransportKind>): string;
function ChipToStr(Idx: Integer): string;
function StrToChip(const S: string): Integer;

// Decompõe uma URL rtsp/dvrip em protocolo, host, porta e caminho. Descarta
// userinfo embutido (user:pass@) — credenciais ficam nos campos próprios.
procedure SplitUrl(const Url: string; out Proto, Host, Port, Path: string);
function BuildUrl(const Proto, Host, Port, Path: string): string;
function ProtoStr(Idx: Integer): string;

function MakeCamera(const Name, Url, User, Pass: string;
  const Transports: TArray<TTransportKind>; MaxRetries: Integer = 0;
  AudioDelay: Integer = 200; VideoDelay: Integer = 200;
  UsesTailscale: Boolean = False): TCameraConfigEntry;

implementation

function JsonStr(O: TJSONObject; const Name: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  if O = nil then Exit;
  V := O.GetValue(Name);
  if V is TJSONString then
    Result := TJSONString(V).Value;
end;

function JsonInt(O: TJSONObject; const Name: string; Def: Integer): Integer;
var
  V: TJSONValue;
begin
  Result := Def;
  if O = nil then Exit;
  V := O.GetValue(Name);
  if V is TJSONNumber then
    Result := TJSONNumber(V).AsInt
  else if V is TJSONString then
    Result := StrToIntDef(TJSONString(V).Value, Def);
end;

function JsonBool(O: TJSONObject; const Name: string; Def: Boolean): Boolean;
var
  V: TJSONValue;
begin
  Result := Def;
  if O = nil then Exit;
  V := O.GetValue(Name);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean
  else if V is TJSONString then
    Result := SameText(Trim(TJSONString(V).Value), 'true');
end;

function ParseTransports(const S: string): TArray<TTransportKind>;
var
  Parts: TArray<string>;
  I: Integer;
  T: TTransportKind;
  List: TList<TTransportKind>;
  L: string;
begin
  L := LowerCase(Trim(S));
  if (L = '') or (L = 'auto') then
  begin
    SetLength(Result, 2);
    Result[0] := txTcp;
    Result[1] := txUdp;
    Exit;
  end;
  List := TList<TTransportKind>.Create;
  try
    Parts := L.Split([',']);
    for I := 0 to High(Parts) do
      if ParseTransportKind(Trim(Parts[I]), T) then
        List.Add(T);
    if List.Count = 0 then
    begin
      List.Add(txTcp);
      List.Add(txUdp);
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TransportsToStr(const T: TArray<TTransportKind>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(T) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + TransportKindToStr(T[I]);
  end;
  if Result = '' then Result := 'tcp,udp';
end;

function ChipToStr(Idx: Integer): string;
begin
  case Idx of
    0: Result := 'auto';
    1: Result := 'tcp,udp';
    2: Result := 'udp,tcp';
    3: Result := 'tcp';
    4: Result := 'udp';
  else
    Result := 'auto';
  end;
end;

function StrToChip(const S: string): Integer;
begin
  if S = 'tcp,udp' then Result := 1
  else if S = 'udp,tcp' then Result := 2
  else if S = 'tcp' then Result := 3
  else if S = 'udp' then Result := 4
  else Result := 0;
end;

procedure SplitUrl(const Url: string; out Proto, Host, Port, Path: string);
var
  S: string;
  P: Integer;
begin
  Proto := 'rtsp'; Host := ''; Port := ''; Path := '';
  S := Trim(Url);
  P := Pos('://', S);
  if P > 0 then
  begin
    Proto := LowerCase(Copy(S, 1, P - 1));
    Delete(S, 1, P + 2);
  end;
  if (Proto <> 'rtsp') and (Proto <> 'dvrip') then Proto := 'rtsp';
  P := Pos('/', S);
  if P > 0 then
  begin
    Path := Copy(S, P, MaxInt);
    S := Copy(S, 1, P - 1);
  end;
  P := LastDelimiter('@', S);
  if P > 0 then Delete(S, 1, P);
  P := Pos(':', S);
  if P > 0 then
  begin
    Host := Copy(S, 1, P - 1);
    Port := Copy(S, P + 1, MaxInt);
  end
  else
    Host := S;
end;

function BuildUrl(const Proto, Host, Port, Path: string): string;
var
  Pr, Pa: string;
begin
  Pr := LowerCase(Trim(Proto));
  if (Pr <> 'rtsp') and (Pr <> 'dvrip') then Pr := 'rtsp';
  Result := Pr + '://' + Trim(Host);
  if Trim(Port) <> '' then Result := Result + ':' + Trim(Port);
  Pa := Trim(Path);
  if Pa <> '' then
  begin
    if Pa[1] <> '/' then Result := Result + '/';
    Result := Result + Pa;
  end;
end;

function ProtoStr(Idx: Integer): string;
begin
  if Idx = 1 then Result := 'dvrip' else Result := 'rtsp';
end;

function MakeCamera(const Name, Url, User, Pass: string;
  const Transports: TArray<TTransportKind>; MaxRetries: Integer = 0;
  AudioDelay: Integer = 200; VideoDelay: Integer = 200;
  UsesTailscale: Boolean = False): TCameraConfigEntry;
begin
  Result.Name := Name;
  Result.Enabled := True;
  Result.Url := Url;
  Result.User := User;
  Result.Password := Pass;
  Result.Transports := Transports;
  if Length(Result.Transports) = 0 then
    Result.Transports := ParseTransports('auto');
  Result.RecordAudio := True;
  Result.FilenamePattern := '';
  // Uso móvel: numa troca de célula/perda de sinal no 4G o backoff de 30 s do
  // gravador deixaria a tela parada tempo demais. Teto curto: quem está olhando
  // a câmera quer a imagem de volta, e uma tentativa a mais custa pouco.
  Result.Reconnect.InitialDelayMs := 1000;
  Result.Reconnect.MaxDelayMs := 6000;
  Result.Reconnect.BackoffMultiplier := 2.0;
  Result.Reconnect.NoRtpTimeoutMs := 10000;
  if MaxRetries < 0 then MaxRetries := 0;
  Result.MaxReconnectAttempts := MaxRetries;
  if AudioDelay < 0 then AudioDelay := 0;
  if VideoDelay < 0 then VideoDelay := 0;
  Result.AudioDelayMs := AudioDelay;
  Result.VideoDelayMs := VideoDelay;
  Result.UsesTailscale := UsesTailscale;
end;

end.
