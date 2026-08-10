unit VMS.Net.Tcp;

interface

uses
  System.SysUtils,
  System.Classes,
  IdTCPClient,
  IdGlobal,
  IdStack,
  IdExceptionCore,
  IdException,
  VMS.Net.Intf,
  VMS.Domain.Types;

type
  TIndyTcpStream = class(TInterfacedObject, ITcpStream)
  strict private
    FClient: TIdTCPClient;
    procedure EnsureConnected;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const Host: string; Port: Word; TimeoutMs: Cardinal);
    procedure Disconnect;
    function Connected: Boolean;
    procedure Send(const Buffer: TBytes); overload;
    procedure Send(const Buffer: Pointer; Size: Integer); overload;
    function Recv(var Buffer: TBytes; MaxSize: Integer; TimeoutMs: Cardinal): Integer;
    function RecvByte(TimeoutMs: Cardinal): Byte;
    function RecvExact(var Buffer: TBytes; Size: Integer; TimeoutMs: Cardinal): Boolean;
    function LocalPort: Word;
    function PeerAddress: string;
  end;

implementation

uses
  IdIOHandler;

{ TIndyTcpStream }

constructor TIndyTcpStream.Create;
begin
  inherited Create;
  FClient := TIdTCPClient.Create(nil);
end;

destructor TIndyTcpStream.Destroy;
begin
  try
    if (FClient <> nil) and FClient.Connected then
      FClient.Disconnect;
  except
  end;
  FClient.Free;
  inherited;
end;

procedure TIndyTcpStream.EnsureConnected;
begin
  if not FClient.Connected then
    raise EVmsIoError.Create('TCP not connected');
end;

procedure TIndyTcpStream.Connect(const Host: string; Port: Word; TimeoutMs: Cardinal);
begin
  FClient.Host := Host;
  FClient.Port := Port;
  FClient.ConnectTimeout := TimeoutMs;
  FClient.ReadTimeout := -1;
  try
    FClient.Connect;
  except
    on E: EIdConnectTimeout do
      raise EVmsTimeoutError.CreateFmt('Connect timeout to %s:%d', [Host, Port]);
    on E: EIdSocketError do
      raise EVmsIoError.CreateFmt('Connect error to %s:%d: %s', [Host, Port, E.Message]);
    on E: Exception do
      raise EVmsIoError.CreateFmt('Connect failed to %s:%d: %s', [Host, Port, E.Message]);
  end;
end;

procedure TIndyTcpStream.Disconnect;
begin
  try
    if FClient.Connected then
      FClient.Disconnect;
  except
  end;
end;

function TIndyTcpStream.Connected: Boolean;
begin
  try
    Result := FClient.Connected;
  except
    Result := False;
  end;
end;

procedure TIndyTcpStream.Send(const Buffer: TBytes);
var
  Idb: TIdBytes;
begin
  EnsureConnected;
  if Length(Buffer) = 0 then Exit;
  SetLength(Idb, Length(Buffer));
  if Length(Buffer) > 0 then
    Move(Buffer[0], Idb[0], Length(Buffer));
  try
    FClient.IOHandler.Write(Idb);
  except
    on E: Exception do
      raise EVmsIoError.Create('TCP send failed: ' + E.Message);
  end;
end;

procedure TIndyTcpStream.Send(const Buffer: Pointer; Size: Integer);
var
  Tmp: TBytes;
begin
  if Size <= 0 then Exit;
  SetLength(Tmp, Size);
  Move(Buffer^, Tmp[0], Size);
  Send(Tmp);
end;

function TIndyTcpStream.Recv(var Buffer: TBytes; MaxSize: Integer; TimeoutMs: Cardinal): Integer;
var
  Idb: TIdBytes;
  Available, ToRead: Integer;
begin
  EnsureConnected;
  if MaxSize <= 0 then Exit(0);
  if Length(Buffer) < MaxSize then
    SetLength(Buffer, MaxSize);

  FClient.IOHandler.ReadTimeout := Integer(TimeoutMs);
  try
    FClient.IOHandler.CheckForDataOnSource(Integer(TimeoutMs));
  except
    on E: Exception do
      raise EVmsIoError.Create('TCP recv failed: ' + E.Message);
  end;

  Available := FClient.IOHandler.InputBuffer.Size;
  if Available <= 0 then
  begin
    try
      FClient.IOHandler.CheckForDisconnect(True, True);
    except
      on E: EIdConnClosedGracefully do
        raise EVmsIoError.Create('TCP closed by peer');
      on E: Exception do
        raise EVmsIoError.Create('TCP recv error: ' + E.Message);
    end;
    Exit(0);
  end;

  ToRead := Available;
  if ToRead > MaxSize then ToRead := MaxSize;

  SetLength(Idb, ToRead);
  try
    FClient.IOHandler.ReadBytes(Idb, ToRead, False);
  except
    on E: Exception do
      raise EVmsIoError.Create('TCP read bytes failed: ' + E.Message);
  end;
  if ToRead > 0 then
    Move(Idb[0], Buffer[0], ToRead);
  Result := ToRead;
end;

function TIndyTcpStream.RecvByte(TimeoutMs: Cardinal): Byte;
begin
  EnsureConnected;
  FClient.IOHandler.ReadTimeout := Integer(TimeoutMs);
  try
    Result := FClient.IOHandler.ReadByte;
  except
    on E: EIdReadTimeout do
      raise EVmsTimeoutError.Create('TCP read byte timeout');
    on E: EIdConnClosedGracefully do
      raise EVmsIoError.Create('TCP closed by peer');
    on E: Exception do
      raise EVmsIoError.Create('TCP read byte error: ' + E.Message);
  end;
end;

function TIndyTcpStream.RecvExact(var Buffer: TBytes; Size: Integer; TimeoutMs: Cardinal): Boolean;
var
  Idb: TIdBytes;
begin
  EnsureConnected;
  if Size <= 0 then Exit(True);
  if Length(Buffer) < Size then
    SetLength(Buffer, Size);
  SetLength(Idb, Size);
  FClient.IOHandler.ReadTimeout := Integer(TimeoutMs);
  try
    FClient.IOHandler.ReadBytes(Idb, Size, False);
  except
    on E: EIdReadTimeout do
      raise EVmsTimeoutError.Create('TCP read exact timeout');
    on E: EIdConnClosedGracefully do
      raise EVmsIoError.Create('TCP closed by peer');
    on E: Exception do
      raise EVmsIoError.Create('TCP read exact failed: ' + E.Message);
  end;
  if Size > 0 then
    Move(Idb[0], Buffer[0], Size);
  Result := True;
end;

function TIndyTcpStream.LocalPort: Word;
begin
  try
    Result := FClient.Socket.Binding.Port;
  except
    Result := 0;
  end;
end;

function TIndyTcpStream.PeerAddress: string;
begin
  try
    Result := FClient.Socket.Binding.PeerIP;
  except
    Result := '';
  end;
end;

end.

