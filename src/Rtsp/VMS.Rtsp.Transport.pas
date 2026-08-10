unit VMS.Rtsp.Transport;

interface

uses
  System.SysUtils,
  System.StrUtils,
  VMS.Domain.Types;

type
  TRtspTransportSpec = record
    Kind: TTransportKind;
    InterleavedRtp: Byte;
    InterleavedRtcp: Byte;
    ClientRtpPort: Word;
    ClientRtcpPort: Word;
    ServerRtpPort: Word;
    ServerRtcpPort: Word;
    Ssrc: Cardinal;
    SourceHost: string;
    ServerDeclared: string;
    function BuildHeader: string;
  end;

function ParseTransportResponse(const Header: string; var Spec: TRtspTransportSpec): Boolean;

implementation

function ExtractParamValue(const Token, Name: string; out Value: string): Boolean;
var
  T, KeyEq: string;
  P: Integer;
begin
  Result := False;
  Value := '';
  T := Trim(Token);
  KeyEq := Name + '=';
  if SameText(Copy(T, 1, Length(KeyEq)), KeyEq) then
  begin
    Value := Copy(T, Length(KeyEq) + 1, MaxInt);
    Exit(True);
  end;
  P := Pos('=', T);
  if (P > 0) and SameText(Copy(T, 1, P - 1), Name) then
  begin
    Value := Copy(T, P + 1, MaxInt);
    Exit(True);
  end;
end;

procedure ParsePortPair(const S: string; out A, B: Word);
var
  Parts: TArray<string>;
begin
  A := 0;
  B := 0;
  Parts := S.Split(['-']);
  if Length(Parts) >= 1 then A := Word(StrToIntDef(Trim(Parts[0]), 0));
  if Length(Parts) >= 2 then B := Word(StrToIntDef(Trim(Parts[1]), 0));
  if B = 0 then B := A + 1;
end;

function ParseTransportResponse(const Header: string; var Spec: TRtspTransportSpec): Boolean;
var
  Tokens: TArray<string>;
  I: Integer;
  Token, Val: string;
  PortA, PortB: Word;
begin
  Result := False;
  Spec.ServerDeclared := Trim(Header);
  Tokens := Header.Split([';']);
  for I := 0 to High(Tokens) do
  begin
    Token := Trim(Tokens[I]);
    if SameText(Token, 'RTP/AVP/TCP') then
    begin
      Spec.Kind := txTcp;
      Result := True;
      Continue;
    end;
    if SameText(Token, 'RTP/AVP') or SameText(Token, 'RTP/AVP/UDP') then
    begin
      Spec.Kind := txUdp;
      Result := True;
      Continue;
    end;
    if ExtractParamValue(Token, 'interleaved', Val) then
    begin
      ParsePortPair(Val, PortA, PortB);
      Spec.InterleavedRtp := Byte(PortA);
      Spec.InterleavedRtcp := Byte(PortB);
      Spec.Kind := txTcp;
      Continue;
    end;
    if ExtractParamValue(Token, 'client_port', Val) then
    begin
      ParsePortPair(Val, PortA, PortB);
      Spec.ClientRtpPort := PortA;
      Spec.ClientRtcpPort := PortB;
      Continue;
    end;
    if ExtractParamValue(Token, 'server_port', Val) then
    begin
      ParsePortPair(Val, PortA, PortB);
      Spec.ServerRtpPort := PortA;
      Spec.ServerRtcpPort := PortB;
      Continue;
    end;
    if ExtractParamValue(Token, 'ssrc', Val) then
    begin
      Spec.Ssrc := StrToInt64Def('$' + Val, 0);
      Continue;
    end;
    if ExtractParamValue(Token, 'source', Val) then
    begin
      Spec.SourceHost := Val;
      Continue;
    end;
  end;
end;

{ TRtspTransportSpec }

function TRtspTransportSpec.BuildHeader: string;
begin
  case Kind of
    txTcp:
      Result := Format('RTP/AVP/TCP;unicast;interleaved=%d-%d',
        [InterleavedRtp, InterleavedRtcp]);
    txUdp:
      Result := Format('RTP/AVP;unicast;client_port=%d-%d',
        [ClientRtpPort, ClientRtcpPort]);
  else
    Result := '';
  end;
end;

end.
