unit VMS.Rtsp.Messages;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  VMS.Domain.Types;

type
  TRtspHeader = record
    Name: string;
    Value: string;
  end;

  TRtspHeaderList = class
  strict private
    FItems: TList<TRtspHeader>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Add(const Name, Value: string);
    procedure SetValue(const Name, Value: string);
    function Get(const Name: string): string;
    function TryGet(const Name: string; out Value: string): Boolean;
    function Has(const Name: string): Boolean;
    function Count: Integer;
    function GetAt(Index: Integer): TRtspHeader;
  end;

  TRtspRequest = class
  strict private
    FMethod: string;
    FUri: string;
    FVersion: string;
    FHeaders: TRtspHeaderList;
    FBody: TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function Serialize: TBytes;
    property Method: string read FMethod write FMethod;
    property Uri: string read FUri write FUri;
    property Version: string read FVersion write FVersion;
    property Headers: TRtspHeaderList read FHeaders;
    property Body: TBytes read FBody write FBody;
  end;

  TRtspResponse = class
  strict private
    FVersion: string;
    FStatusCode: Integer;
    FStatusText: string;
    FHeaders: TRtspHeaderList;
    FBody: TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function Serialize: TBytes;
    property Version: string read FVersion write FVersion;
    property StatusCode: Integer read FStatusCode write FStatusCode;
    property StatusText: string read FStatusText write FStatusText;
    property Headers: TRtspHeaderList read FHeaders;
    property Body: TBytes read FBody write FBody;
  end;

function ParseRtspResponse(const HeaderText: string; Resp: TRtspResponse): Boolean;
function ParseRtspRequest(const HeaderText: string; Req: TRtspRequest): Boolean;
function ParseContentLength(Headers: TRtspHeaderList): Integer;
function StatusTextForCode(Code: Integer): string;

implementation

{ TRtspHeaderList }

constructor TRtspHeaderList.Create;
begin
  inherited Create;
  FItems := TList<TRtspHeader>.Create;
end;

destructor TRtspHeaderList.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TRtspHeaderList.Clear;
begin
  FItems.Clear;
end;

procedure TRtspHeaderList.Add(const Name, Value: string);
var
  H: TRtspHeader;
begin
  H.Name := Name;
  H.Value := Value;
  FItems.Add(H);
end;

procedure TRtspHeaderList.SetValue(const Name, Value: string);
var
  I: Integer;
  H: TRtspHeader;
begin
  for I := 0 to FItems.Count - 1 do
    if SameText(FItems[I].Name, Name) then
    begin
      H := FItems[I];
      H.Value := Value;
      FItems[I] := H;
      Exit;
    end;
  Add(Name, Value);
end;

function TRtspHeaderList.Get(const Name: string): string;
begin
  if not TryGet(Name, Result) then
    Result := '';
end;

function TRtspHeaderList.TryGet(const Name: string; out Value: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if SameText(FItems[I].Name, Name) then
    begin
      Value := FItems[I].Value;
      Exit(True);
    end;
  Value := '';
  Result := False;
end;

function TRtspHeaderList.Has(const Name: string): Boolean;
var
  Dummy: string;
begin
  Result := TryGet(Name, Dummy);
end;

function TRtspHeaderList.Count: Integer;
begin
  Result := FItems.Count;
end;

function TRtspHeaderList.GetAt(Index: Integer): TRtspHeader;
begin
  Result := FItems[Index];
end;

{ TRtspRequest }

constructor TRtspRequest.Create;
begin
  inherited Create;
  FVersion := 'RTSP/1.0';
  FHeaders := TRtspHeaderList.Create;
end;

destructor TRtspRequest.Destroy;
begin
  FHeaders.Free;
  inherited;
end;

function TRtspRequest.Serialize: TBytes;
var
  Sb: TStringBuilder;
  I: Integer;
  H: TRtspHeader;
  HasContentLength: Boolean;
  TextBytes, AllBytes: TBytes;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.Append(FMethod).Append(' ').Append(FUri).Append(' ').Append(FVersion).Append(#13#10);
    HasContentLength := False;
    for I := 0 to FHeaders.Count - 1 do
    begin
      H := FHeaders.GetAt(I);
      Sb.Append(H.Name).Append(': ').Append(H.Value).Append(#13#10);
      if SameText(H.Name, 'Content-Length') then
        HasContentLength := True;
    end;
    if (Length(FBody) > 0) and (not HasContentLength) then
      Sb.Append('Content-Length: ').Append(Length(FBody)).Append(#13#10);
    Sb.Append(#13#10);
    TextBytes := TEncoding.UTF8.GetBytes(Sb.ToString);
    SetLength(AllBytes, Length(TextBytes) + Length(FBody));
    if Length(TextBytes) > 0 then
      Move(TextBytes[0], AllBytes[0], Length(TextBytes));
    if Length(FBody) > 0 then
      Move(FBody[0], AllBytes[Length(TextBytes)], Length(FBody));
    Result := AllBytes;
  finally
    Sb.Free;
  end;
end;

{ TRtspResponse }

constructor TRtspResponse.Create;
begin
  inherited Create;
  FHeaders := TRtspHeaderList.Create;
end;

destructor TRtspResponse.Destroy;
begin
  FHeaders.Free;
  inherited;
end;

function TRtspResponse.Serialize: TBytes;
var
  Sb: TStringBuilder;
  I: Integer;
  H: TRtspHeader;
  HasContentLength: Boolean;
  TextBytes, AllBytes: TBytes;
  Ver: string;
begin
  Sb := TStringBuilder.Create;
  try
    Ver := FVersion;
    if Ver = '' then Ver := 'RTSP/1.0';
    Sb.Append(Ver).Append(' ').Append(FStatusCode).Append(' ').Append(FStatusText).Append(#13#10);
    HasContentLength := False;
    for I := 0 to FHeaders.Count - 1 do
    begin
      H := FHeaders.GetAt(I);
      Sb.Append(H.Name).Append(': ').Append(H.Value).Append(#13#10);
      if SameText(H.Name, 'Content-Length') then HasContentLength := True;
    end;
    if (Length(FBody) > 0) and (not HasContentLength) then
      Sb.Append('Content-Length: ').Append(Length(FBody)).Append(#13#10);
    Sb.Append(#13#10);
    TextBytes := TEncoding.UTF8.GetBytes(Sb.ToString);
    SetLength(AllBytes, Length(TextBytes) + Length(FBody));
    if Length(TextBytes) > 0 then
      Move(TextBytes[0], AllBytes[0], Length(TextBytes));
    if Length(FBody) > 0 then
      Move(FBody[0], AllBytes[Length(TextBytes)], Length(FBody));
    Result := AllBytes;
  finally
    Sb.Free;
  end;
end;

function ParseRtspRequest(const HeaderText: string; Req: TRtspRequest): Boolean;
var
  Lines: TStringList;
  I, P: Integer;
  Line, StartLine, Name, Value: string;
begin
  Result := False;
  Lines := TStringList.Create;
  try
    Lines.Text := HeaderText;
    if Lines.Count = 0 then Exit;
    StartLine := Lines[0];
    P := Pos(' ', StartLine);
    if P < 1 then Exit;
    Req.Method := Copy(StartLine, 1, P - 1);
    Delete(StartLine, 1, P);
    P := Pos(' ', StartLine);
    if P < 1 then Exit;
    Req.Uri := Copy(StartLine, 1, P - 1);
    Req.Version := Trim(Copy(StartLine, P + 1, MaxInt));

    Req.Headers.Clear;
    for I := 1 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Trim(Line) = '' then Continue;
      P := Pos(':', Line);
      if P < 2 then Continue;
      Name := Trim(Copy(Line, 1, P - 1));
      Value := Trim(Copy(Line, P + 1, MaxInt));
      Req.Headers.Add(Name, Value);
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function StatusTextForCode(Code: Integer): string;
begin
  case Code of
    200: Result := 'OK';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    454: Result := 'Session Not Found';
    455: Result := 'Method Not Valid in This State';
    456: Result := 'Header Field Not Valid for Resource';
    461: Result := 'Unsupported Transport';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    503: Result := 'Service Unavailable';
  else
    Result := 'Error';
  end;
end;

function ParseRtspResponse(const HeaderText: string; Resp: TRtspResponse): Boolean;
var
  Lines: TStringList;
  I, P, Code: Integer;
  Line, StatusLine, Name, Value: string;
begin
  Result := False;
  Lines := TStringList.Create;
  try
    Lines.Text := HeaderText;
    if Lines.Count = 0 then Exit;
    StatusLine := Lines[0];
    P := Pos(' ', StatusLine);
    if P < 1 then Exit;
    Resp.Version := Copy(StatusLine, 1, P - 1);
    Delete(StatusLine, 1, P);
    P := Pos(' ', StatusLine);
    if P < 1 then
    begin
      if TryStrToInt(Trim(StatusLine), Code) then
      begin
        Resp.StatusCode := Code;
        Resp.StatusText := '';
        Result := True;
      end;
      Exit;
    end;
    if not TryStrToInt(Copy(StatusLine, 1, P - 1), Code) then Exit;
    Resp.StatusCode := Code;
    Resp.StatusText := Trim(Copy(StatusLine, P + 1, MaxInt));

    Resp.Headers.Clear;
    for I := 1 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Trim(Line) = '' then Continue;
      P := Pos(':', Line);
      if P < 2 then Continue;
      Name := Trim(Copy(Line, 1, P - 1));
      Value := Trim(Copy(Line, P + 1, MaxInt));
      Resp.Headers.Add(Name, Value);
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function ParseContentLength(Headers: TRtspHeaderList): Integer;
var
  V: string;
begin
  Result := 0;
  if Headers.TryGet('Content-Length', V) then
    TryStrToInt(Trim(V), Result);
end;

end.

