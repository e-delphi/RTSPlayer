unit VMS.Rtsp.Auth;

interface

uses
  System.SysUtils,
  System.Hash,
  System.NetEncoding,
  System.Classes,
  System.StrUtils;

type
  TRtspAuthScheme = (asNone, asBasic, asDigest);

  TRtspAuthChallenge = record
    Scheme: TRtspAuthScheme;
    Realm: string;
    Nonce: string;
    Opaque: string;
    Qop: string;
    Algorithm: string;
  end;

  TRtspAuthHandler = class
  strict private
    FUser: string;
    FPassword: string;
    FChallenge: TRtspAuthChallenge;
    FNonceCount: Cardinal;
    function BuildBasic: string;
    function BuildDigest(const Method, Uri: string): string;
  public
    constructor Create(const User, Password: string);
    procedure ConsumeChallenge(const WwwAuthenticate: string);
    function HasChallenge: Boolean;
    function BuildAuthorization(const Method, Uri: string): string;
    property Challenge: TRtspAuthChallenge read FChallenge;
  end;

function ParseAuthenticateHeader(const Header: string; out Challenge: TRtspAuthChallenge): Boolean;

implementation

function MD5Hex(const S: string): string;
begin
  Result := LowerCase(THashMD5.GetHashString(S));
end;

function GenerateCnonce: string;
var
  Buf: array[0..7] of Byte;
  I: Integer;
begin
  for I := 0 to High(Buf) do
    Buf[I] := Byte(Random(256));
  Result := '';
  for I := 0 to High(Buf) do
    Result := Result + IntToHex(Buf[I], 2);
  Result := LowerCase(Result);
end;

function ExtractQuoted(const S: string; var Idx: Integer): string;
var
  StartC: Integer;
begin
  Result := '';
  if (Idx > Length(S)) then Exit;
  if S[Idx] = '"' then
  begin
    Inc(Idx);
    StartC := Idx;
    while (Idx <= Length(S)) and (S[Idx] <> '"') do
      Inc(Idx);
    Result := Copy(S, StartC, Idx - StartC);
    if (Idx <= Length(S)) and (S[Idx] = '"') then Inc(Idx);
  end
  else
  begin
    StartC := Idx;
    while (Idx <= Length(S)) and (S[Idx] <> ',') and (S[Idx] <> ' ') do
      Inc(Idx);
    Result := Copy(S, StartC, Idx - StartC);
  end;
end;

procedure SkipWhiteAndComma(const S: string; var Idx: Integer);
begin
  while (Idx <= Length(S)) and ((S[Idx] = ',') or (S[Idx] = ' ') or (S[Idx] = #9)) do
    Inc(Idx);
end;

function ParseAuthenticateHeader(const Header: string; out Challenge: TRtspAuthChallenge): Boolean;
var
  S, Scheme, Key, Value: string;
  Idx, KeyStart: Integer;
begin
  FillChar(Challenge, SizeOf(Challenge), 0);
  Challenge.Scheme := asNone;
  Result := False;
  S := Trim(Header);
  if S = '' then Exit;

  Idx := 1;
  while (Idx <= Length(S)) and (S[Idx] <> ' ') do Inc(Idx);
  Scheme := Copy(S, 1, Idx - 1);
  if SameText(Scheme, 'Basic') then
    Challenge.Scheme := asBasic
  else if SameText(Scheme, 'Digest') then
    Challenge.Scheme := asDigest
  else
    Exit;

  while (Idx <= Length(S)) and (S[Idx] = ' ') do Inc(Idx);

  while Idx <= Length(S) do
  begin
    SkipWhiteAndComma(S, Idx);
    if Idx > Length(S) then Break;
    KeyStart := Idx;
    while (Idx <= Length(S)) and (S[Idx] <> '=') and (S[Idx] <> ',') do
      Inc(Idx);
    Key := Trim(Copy(S, KeyStart, Idx - KeyStart));
    if (Idx <= Length(S)) and (S[Idx] = '=') then
    begin
      Inc(Idx);
      Value := ExtractQuoted(S, Idx);
    end
    else
      Value := '';
    if Key = '' then Continue;
    if SameText(Key, 'realm')     then Challenge.Realm := Value
    else if SameText(Key, 'nonce')    then Challenge.Nonce := Value
    else if SameText(Key, 'opaque')   then Challenge.Opaque := Value
    else if SameText(Key, 'qop')      then Challenge.Qop := Value
    else if SameText(Key, 'algorithm')then Challenge.Algorithm := Value;
  end;
  Result := True;
end;

{ TRtspAuthHandler }

constructor TRtspAuthHandler.Create(const User, Password: string);
begin
  inherited Create;
  FUser := User;
  FPassword := Password;
  FChallenge.Scheme := asNone;
  FNonceCount := 0;
end;

procedure TRtspAuthHandler.ConsumeChallenge(const WwwAuthenticate: string);
begin
  if not ParseAuthenticateHeader(WwwAuthenticate, FChallenge) then
    FChallenge.Scheme := asNone;
  FNonceCount := 0;
end;

function TRtspAuthHandler.HasChallenge: Boolean;
begin
  Result := FChallenge.Scheme <> asNone;
end;

function TRtspAuthHandler.BuildBasic: string;
var
  Token: string;
begin
  Token := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(FUser + ':' + FPassword));
  Token := StringReplace(Token, #13#10, '', [rfReplaceAll]);
  Result := 'Basic ' + Token;
end;

function TRtspAuthHandler.BuildDigest(const Method, Uri: string): string;
var
  HA1, HA2, Response, Cnonce, NcStr, FirstQop: string;
  QopList: TArray<string>;
begin
  HA1 := MD5Hex(FUser + ':' + FChallenge.Realm + ':' + FPassword);
  HA2 := MD5Hex(Method + ':' + Uri);

  if FChallenge.Qop <> '' then
  begin
    Inc(FNonceCount);
    NcStr := LowerCase(IntToHex(FNonceCount, 8));
    Cnonce := GenerateCnonce;
    QopList := FChallenge.Qop.Split([',']);
    if Length(QopList) > 0 then
      FirstQop := Trim(QopList[0])
    else
      FirstQop := 'auth';
    Response := MD5Hex(HA1 + ':' + FChallenge.Nonce + ':' + NcStr + ':' + Cnonce + ':' + FirstQop + ':' + HA2);
    Result := Format(
      'Digest username="%s", realm="%s", nonce="%s", uri="%s", algorithm=%s, qop=%s, nc=%s, cnonce="%s", response="%s"',
      [FUser, FChallenge.Realm, FChallenge.Nonce, Uri,
       IfThen(FChallenge.Algorithm = '', 'MD5', FChallenge.Algorithm),
       FirstQop, NcStr, Cnonce, Response]);
    if FChallenge.Opaque <> '' then
      Result := Result + Format(', opaque="%s"', [FChallenge.Opaque]);
  end
  else
  begin
    Response := MD5Hex(HA1 + ':' + FChallenge.Nonce + ':' + HA2);
    Result := Format(
      'Digest username="%s", realm="%s", nonce="%s", uri="%s", response="%s"',
      [FUser, FChallenge.Realm, FChallenge.Nonce, Uri, Response]);
    if FChallenge.Opaque <> '' then
      Result := Result + Format(', opaque="%s"', [FChallenge.Opaque]);
  end;
end;

function TRtspAuthHandler.BuildAuthorization(const Method, Uri: string): string;
begin
  case FChallenge.Scheme of
    asBasic:  Result := BuildBasic;
    asDigest: Result := BuildDigest(Method, Uri);
  else
    Result := '';
  end;
end;

end.
