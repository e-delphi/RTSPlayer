unit VMS.Rtsp.Url;

interface

uses
  System.SysUtils;

type
  TRtspUrl = record
    Scheme: string;
    User: string;
    Password: string;
    Host: string;
    Port: Word;
    Path: string;
    function FullPathQuery: string;
    function HostPort: string;
    function ToString(IncludeCredentials: Boolean = False): string;
  end;

function ParseRtspUrl(const Url: string; out Parsed: TRtspUrl): Boolean;

implementation

function ParseRtspUrl(const Url: string; out Parsed: TRtspUrl): Boolean;
var
  S, AuthHost, HostPart, UserInfo, PortStr: string;
  P, SlashP, AtP, ColonP: Integer;
begin
  FillChar(Parsed, SizeOf(Parsed), 0);
  Parsed.Scheme := '';
  Parsed.Host := '';
  Parsed.Path := '/';
  Parsed.Port := 554;
  Result := False;
  S := Trim(Url);
  if S = '' then Exit;
  P := Pos('://', S);
  if P < 1 then Exit;
  Parsed.Scheme := LowerCase(Copy(S, 1, P - 1));
  if (Parsed.Scheme <> 'rtsp') and (Parsed.Scheme <> 'rtsps') then Exit;
  if Parsed.Scheme = 'rtsps' then Parsed.Port := 322;
  Delete(S, 1, P + 2);
  SlashP := Pos('/', S);
  if SlashP > 0 then
  begin
    AuthHost := Copy(S, 1, SlashP - 1);
    Parsed.Path := Copy(S, SlashP, MaxInt);
  end
  else
  begin
    AuthHost := S;
    Parsed.Path := '/';
  end;
  AtP := LastDelimiter('@', AuthHost);
  if AtP > 0 then
  begin
    UserInfo := Copy(AuthHost, 1, AtP - 1);
    HostPart := Copy(AuthHost, AtP + 1, MaxInt);
    ColonP := Pos(':', UserInfo);
    if ColonP > 0 then
    begin
      Parsed.User := Copy(UserInfo, 1, ColonP - 1);
      Parsed.Password := Copy(UserInfo, ColonP + 1, MaxInt);
    end
    else
      Parsed.User := UserInfo;
  end
  else
    HostPart := AuthHost;
  ColonP := Pos(':', HostPart);
  if ColonP > 0 then
  begin
    Parsed.Host := Copy(HostPart, 1, ColonP - 1);
    PortStr := Copy(HostPart, ColonP + 1, MaxInt);
    Parsed.Port := Word(StrToIntDef(PortStr, Parsed.Port));
  end
  else
    Parsed.Host := HostPart;
  if Parsed.Host = '' then Exit;
  Result := True;
end;

{ TRtspUrl }

function TRtspUrl.FullPathQuery: string;
begin
  if Path = '' then
    Result := '/'
  else
    Result := Path;
end;

function TRtspUrl.HostPort: string;
begin
  Result := Host + ':' + IntToStr(Port);
end;

function TRtspUrl.ToString(IncludeCredentials: Boolean): string;
var
  Credentials: string;
begin
  if IncludeCredentials and (User <> '') then
  begin
    if Password <> '' then
      Credentials := User + ':' + Password + '@'
    else
      Credentials := User + '@';
  end
  else
    Credentials := '';
  Result := Format('%s://%s%s:%d%s', [Scheme, Credentials, Host, Port, FullPathQuery]);
end;

end.
