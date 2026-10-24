unit VMS.Net.Udp;

interface

uses
  System.SysUtils,
  System.Classes,
  IdUDPClient,
  IdSocketHandle,
  IdGlobal,
  IdStack,
  IdStackConsts,
  IdException,
  IdExceptionCore,
  VMS.Net.Intf,
  VMS.Domain.Types;

const
  UDP_MAX_PACKET = 65535;
  UDP_FIRST_PORT = 50000;
  UDP_LAST_PORT  = 59998;
  // Buffer de recepção do kernel (SO_RCVBUF). Vídeo H264 chega em rajadas
  // grandes (keyframe = centenas de pacotes); buffer pequeno descarta pacotes
  // e corrompe o frame. 4 MB evita perda nos bursts (kernel pode limitar).
  RTP_RCVBUF = 4 * 1024 * 1024;

type
  TIndyUdpPair = class(TInterfacedObject, IUdpReceiver)
  strict private
    FRtpSock: TIdUDPClient;
    FRtcpSock: TIdUDPClient;
    FRtpPort: Word;
    FRtcpPort: Word;
    // Buffer de recepção, alocado uma vez e reaproveitado (ver ReceiveFrom).
    FRecvIdb: TIdBytes;
    function TryBindPair(const Host: string; StartPort: Word): Boolean;
    function ReceiveFrom(Sock: TIdUDPClient; out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BindPair(const Host: string; var ARtpPort, ARtcpPort: Word);
    procedure Close;
    function ReceiveRtp(out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
    function ReceiveRtcp(out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
    procedure SendRtcp(const Host: string; Port: Word; const Data: TBytes);
    function RtpPort: Word;
    function RtcpPort: Word;
  end;

implementation

var
  // Próxima porta base a tentar no bind por faixa (avança a cada par bindado,
  // para vídeo e áudio não colidirem). Compartilhada entre instâncias.
  GNextUdpPort: Word = UDP_FIRST_PORT;

{ TIndyUdpPair }

constructor TIndyUdpPair.Create;
begin
  inherited Create;
  FRtpSock := TIdUDPClient.Create(nil);
  FRtcpSock := TIdUDPClient.Create(nil);
  FRtpSock.BufferSize := UDP_MAX_PACKET;
  FRtcpSock.BufferSize := UDP_MAX_PACKET;
  FRtpSock.ReceiveTimeout := 100;
  FRtcpSock.ReceiveTimeout := 100;
end;

destructor TIndyUdpPair.Destroy;
begin
  Close;
  FRtcpSock.Free;
  FRtpSock.Free;
  inherited;
end;

function TIndyUdpPair.TryBindPair(const Host: string; StartPort: Word): Boolean;
begin
  Result := False;
  try
    FRtpSock.BoundIP := Host;
    FRtpSock.BoundPort := StartPort;
    FRtpSock.Active := True;
    try
      FRtpSock.Binding.SetSockOpt(Id_SOL_SOCKET, Id_SO_RCVBUF, RTP_RCVBUF);
    except
    end;
    try
      FRtcpSock.BoundIP := Host;
      FRtcpSock.BoundPort := StartPort + 1;
      FRtcpSock.Active := True;
    except
      FRtpSock.Active := False;
      raise;
    end;
    FRtpPort := StartPort;
    FRtcpPort := StartPort + 1;
    Result := True;
  except
    on E: EIdException do ;
    on E: Exception do ;
  end;
end;

procedure TIndyUdpPair.BindPair(const Host: string; var ARtpPort, ARtcpPort: Word);
var
  P: Word;
  I, Slots: Integer;
begin
  if ARtpPort <> 0 then
  begin
    if not TryBindPair(Host, ARtpPort) then
      raise EVmsIoError.CreateFmt('UDP bind failed on %s:%d-%d', [Host, ARtpPort, ARtpPort + 1]);
    Exit;
  end;
  // Escaneia a partir da próxima porta livre conhecida (GNextUdpPort, compartilhada
  // entre instâncias): garante que pares consecutivos (vídeo/áudio) peguem faixas
  // DISTINTAS, sem depender do comportamento de reuse do socket por plataforma
  // (no Windows o rebind na mesma porta pode "ter sucesso" e colidir os sockets).
  P := GNextUdpPort;
  if (P < UDP_FIRST_PORT) or (P > UDP_LAST_PORT) or Odd(P) then
    P := UDP_FIRST_PORT;
  Slots := (UDP_LAST_PORT - UDP_FIRST_PORT) div 2 + 1;
  for I := 0 to Slots - 1 do
  begin
    if TryBindPair(Host, P) then
    begin
      ARtpPort := FRtpPort;
      ARtcpPort := FRtcpPort;
      if FRtpPort >= UDP_LAST_PORT - 1 then
        GNextUdpPort := UDP_FIRST_PORT
      else
        GNextUdpPort := FRtpPort + 2;
      Exit;
    end;
    if P >= UDP_LAST_PORT - 1 then
      P := UDP_FIRST_PORT
    else
      Inc(P, 2);
  end;
  raise EVmsIoError.Create('UDP bind: no even/odd port pair available');
end;

procedure TIndyUdpPair.Close;
begin
  try
    if FRtpSock.Active then FRtpSock.Active := False;
  except
  end;
  try
    if FRtcpSock.Active then FRtcpSock.Active := False;
  except
  end;
end;

function TIndyUdpPair.ReceiveFrom(Sock: TIdUDPClient; out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
var
  PeerIP: string;
  PeerPort: TIdPort;
  PeerIPVer: TIdIPVersion;
  Size: Integer;
begin
  // FRecvIdb é alocado uma vez (ver Create): o Indy preenche no lugar e devolve
  // quantos bytes vieram, sem redimensionar nada. Alocar UDP_MAX_PACKET por
  // pacote, como estava, era jogar fora esse buffer a cada quadro RTP.
  if Length(FRecvIdb) < UDP_MAX_PACKET then
    SetLength(FRecvIdb, UDP_MAX_PACKET);
  Sock.ReceiveTimeout := Integer(TimeoutMs);
  try
    Size := Sock.ReceiveBuffer(FRecvIdb, PeerIP, PeerPort, PeerIPVer, Integer(TimeoutMs));
    if Size <= 0 then Exit(False);
    // O payload muda de dono aqui (vai para o demux e para o depacketizer),
    // então esta cópia do tamanho exato é a que continua valendo a pena.
    SetLength(Packet.Data, Size);
    Move(FRecvIdb[0], Packet.Data[0], Size);
    Packet.Size := Size;
    Packet.SrcHost := PeerIP;
    Packet.SrcPort := PeerPort;
    Result := True;
  except
    on E: EIdReadTimeout do Exit(False);
    on E: Exception do
      raise EVmsIoError.Create('UDP recv error: ' + E.Message);
  end;
end;

function TIndyUdpPair.ReceiveRtp(out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
begin
  Result := ReceiveFrom(FRtpSock, Packet, TimeoutMs);
end;

function TIndyUdpPair.ReceiveRtcp(out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
begin
  Result := ReceiveFrom(FRtcpSock, Packet, TimeoutMs);
end;

procedure TIndyUdpPair.SendRtcp(const Host: string; Port: Word; const Data: TBytes);
var
  Idb: TIdBytes;
begin
  if Length(Data) = 0 then Exit;
  SetLength(Idb, Length(Data));
  Move(Data[0], Idb[0], Length(Data));
  try
    FRtcpSock.SendBuffer(Host, Port, Idb);
  except
    on E: Exception do
      raise EVmsIoError.Create('UDP send failed: ' + E.Message);
  end;
end;

function TIndyUdpPair.RtpPort: Word;  begin Result := FRtpPort;  end;
function TIndyUdpPair.RtcpPort: Word; begin Result := FRtcpPort; end;

end.

