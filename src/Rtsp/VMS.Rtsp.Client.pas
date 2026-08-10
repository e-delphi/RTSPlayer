unit VMS.Rtsp.Client;

interface

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Net.Intf,
  VMS.Rtsp.Messages,
  VMS.Rtsp.Auth,
  VMS.Rtsp.Url,
  VMS.Rtsp.Transport,
  VMS.Rtsp.WireReader;

const
  DEFAULT_USER_AGENT = 'VMS-Delphi/1.0';
  DEFAULT_RTSP_TIMEOUT_MS = 10000;

type
  TRtspKeepAliveMethod = (kamGetParameter, kamOptions);

  TRtspClient = class
  strict private
    FStream: ITcpStream;
    FReader: TRtspWireReader;
    FAuth: TRtspAuthHandler;
    FLogger: ILogger;
    FUserAgent: string;
    FCSeq: Integer;
    FSession: string;
    FSessionTimeoutSec: Integer;
    FUrl: TRtspUrl;
    FBaseControlUri: string;
    FContentBase: string;
    FOwnsStream: Boolean;
    function NextCSeq: Integer;
    function SendRequest(const Method, Uri: string; ExtraHeaders: TStrings; const Body: TBytes): TRtspResponse;
    procedure ApplySessionFromResponse(Resp: TRtspResponse);
  public
    constructor Create(const Stream: ITcpStream; const Reader: TRtspWireReader;
                       const Auth: TRtspAuthHandler; const Logger: ILogger;
                       const Url: TRtspUrl; OwnsStream: Boolean = False);
    destructor Destroy; override;

    function DoOptions: TRtspResponse;
    function DoDescribe: TRtspResponse;
    function DoSetup(const TrackUri: string; const RequestedTransport: TRtspTransportSpec;
                     out NegotiatedTransport: TRtspTransportSpec): TRtspResponse;
    function DoPlay: TRtspResponse;
    function DoTeardown: TRtspResponse;
    function DoKeepAlive(Method: TRtspKeepAliveMethod): TRtspResponse;

    property Session: string read FSession;
    property SessionTimeoutSec: Integer read FSessionTimeoutSec;
    property ContentBase: string read FContentBase;
    property Reader: TRtspWireReader read FReader;
    property Stream: ITcpStream read FStream;
    property Url: TRtspUrl read FUrl;
  end;

implementation

{ TRtspClient }

constructor TRtspClient.Create(const Stream: ITcpStream; const Reader: TRtspWireReader;
                               const Auth: TRtspAuthHandler; const Logger: ILogger;
                               const Url: TRtspUrl; OwnsStream: Boolean);
begin
  inherited Create;
  FStream := Stream;
  FReader := Reader;
  FAuth := Auth;
  FLogger := Logger;
  FUserAgent := DEFAULT_USER_AGENT;
  FCSeq := 0;
  FSessionTimeoutSec := 60;
  FUrl := Url;
  FBaseControlUri := Url.ToString(False);
  FContentBase := FBaseControlUri;
  FOwnsStream := OwnsStream;
end;

destructor TRtspClient.Destroy;
begin
  if FOwnsStream then
    FStream := nil;
  inherited;
end;

function TRtspClient.NextCSeq: Integer;
begin
  Inc(FCSeq);
  Result := FCSeq;
end;

procedure TRtspClient.ApplySessionFromResponse(Resp: TRtspResponse);
var
  V, IdPart, TimeoutPart: string;
  P: Integer;
  Tmp: Integer;
begin
  if Resp.Headers.TryGet('Session', V) then
  begin
    P := Pos(';', V);
    if P > 0 then
    begin
      IdPart := Trim(Copy(V, 1, P - 1));
      TimeoutPart := Copy(V, P + 1, MaxInt);
      FSession := IdPart;
      P := Pos('timeout=', LowerCase(TimeoutPart));
      if P > 0 then
      begin
        TimeoutPart := Copy(TimeoutPart, P + Length('timeout='), MaxInt);
        if TryStrToInt(Trim(TimeoutPart), Tmp) then
          FSessionTimeoutSec := Tmp;
      end;
    end
    else
      FSession := Trim(V);
  end;
  if Resp.Headers.TryGet('Content-Base', V) then
    FContentBase := Trim(V)
  else if Resp.Headers.TryGet('Content-Location', V) then
    FContentBase := Trim(V);
end;

function TRtspClient.SendRequest(const Method, Uri: string; ExtraHeaders: TStrings;
  const Body: TBytes): TRtspResponse;
var
  Req: TRtspRequest;
  Wire: TBytes;
  I: Integer;
  Auth: string;
  RetryWithAuth: Boolean;
begin
  RetryWithAuth := False;
  while True do
  begin
    Req := TRtspRequest.Create;
    try
      Req.Method := Method;
      Req.Uri := Uri;
      Req.Headers.Add('CSeq', IntToStr(NextCSeq));
      Req.Headers.Add('User-Agent', FUserAgent);
      if FSession <> '' then
        Req.Headers.Add('Session', FSession);
      if (FAuth <> nil) and FAuth.HasChallenge then
      begin
        Auth := FAuth.BuildAuthorization(Method, Uri);
        if Auth <> '' then
          Req.Headers.Add('Authorization', Auth);
      end;
      if Assigned(ExtraHeaders) then
        for I := 0 to ExtraHeaders.Count - 1 do
          Req.Headers.Add(ExtraHeaders.Names[I], ExtraHeaders.ValueFromIndex[I]);
      if Length(Body) > 0 then
      begin
        Req.Headers.Add('Content-Length', IntToStr(Length(Body)));
        Req.Body := Body;
      end;
      Wire := Req.Serialize;
    finally
      Req.Free;
    end;

    if Assigned(FLogger) then
      FLogger.Debug('rtsp.tx', Format('%s %s (CSeq=%d, %d bytes)',
        [Method, Uri, FCSeq, Length(Wire)]));
    FStream.Send(Wire);

    Result := FReader.ReadRtspResponse(DEFAULT_RTSP_TIMEOUT_MS);
    if Assigned(FLogger) then
      FLogger.Debug('rtsp.rx', Format('%s %s -> %d %s',
        [Method, Uri, Result.StatusCode, Result.StatusText]));

    if (Result.StatusCode = 401) and (FAuth <> nil) and (not RetryWithAuth) then
    begin
      FAuth.ConsumeChallenge(Result.Headers.Get('WWW-Authenticate'));
      if not FAuth.HasChallenge then
      begin
        Exit;
      end;
      Result.Free;
      RetryWithAuth := True;
      Continue;
    end;

    ApplySessionFromResponse(Result);
    Exit;
  end;
end;

function TRtspClient.DoOptions: TRtspResponse;
begin
  Result := SendRequest('OPTIONS', FUrl.ToString(False), nil, nil);
end;

function TRtspClient.DoDescribe: TRtspResponse;
var
  Headers: TStringList;
begin
  Headers := TStringList.Create;
  try
    Headers.Add('Accept=application/sdp');
    Result := SendRequest('DESCRIBE', FUrl.ToString(False), Headers, nil);
  finally
    Headers.Free;
  end;
end;

function TRtspClient.DoSetup(const TrackUri: string; const RequestedTransport: TRtspTransportSpec;
                             out NegotiatedTransport: TRtspTransportSpec): TRtspResponse;
var
  Headers: TStringList;
  TransportHeader: string;
begin
  NegotiatedTransport := RequestedTransport;
  TransportHeader := RequestedTransport.BuildHeader;
  Headers := TStringList.Create;
  try
    Headers.Add('Transport=' + TransportHeader);
    Result := SendRequest('SETUP', TrackUri, Headers, nil);
  finally
    Headers.Free;
  end;
  if Result.StatusCode = 200 then
  begin
    if not ParseTransportResponse(Result.Headers.Get('Transport'), NegotiatedTransport) then
      raise EVmsProtocolError.Create('SETUP: invalid Transport response header');
  end;
end;

function TRtspClient.DoPlay: TRtspResponse;
var
  Headers: TStringList;
  TargetUri: string;
begin
  if FContentBase <> '' then
    TargetUri := FContentBase
  else
    TargetUri := FUrl.ToString(False);
  Headers := TStringList.Create;
  try
    Headers.Add('Range=npt=0.000-');
    Result := SendRequest('PLAY', TargetUri, Headers, nil);
  finally
    Headers.Free;
  end;
end;

function TRtspClient.DoTeardown: TRtspResponse;
var
  TargetUri: string;
begin
  if FContentBase <> '' then
    TargetUri := FContentBase
  else
    TargetUri := FUrl.ToString(False);
  Result := SendRequest('TEARDOWN', TargetUri, nil, nil);
  FSession := '';
end;

function TRtspClient.DoKeepAlive(Method: TRtspKeepAliveMethod): TRtspResponse;
var
  TargetUri: string;
begin
  if FContentBase <> '' then
    TargetUri := FContentBase
  else
    TargetUri := FUrl.ToString(False);
  case Method of
    kamGetParameter: Result := SendRequest('GET_PARAMETER', TargetUri, nil, nil);
    kamOptions:      Result := SendRequest('OPTIONS', FUrl.ToString(False), nil, nil);
  else
    Result := SendRequest('OPTIONS', FUrl.ToString(False), nil, nil);
  end;
end;

end.
