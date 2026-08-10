unit VMS.Net.Intf;

interface

uses
  System.SysUtils;

type
  ITcpStream = interface
    ['{4F1A0F62-0B2D-4D0F-9B5C-CC4F2A3E8E10}']
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

  TUdpPacket = record
    Data: TBytes;
    Size: Integer;
    SrcHost: string;
    SrcPort: Word;
  end;

  IUdpReceiver = interface
    ['{6F1B0F62-0B2D-4D0F-9B5C-CC4F2A3E8E20}']
    procedure BindPair(const Host: string; var RtpPort, RtcpPort: Word);
    procedure Close;
    function ReceiveRtp(out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
    function ReceiveRtcp(out Packet: TUdpPacket; TimeoutMs: Cardinal): Boolean;
    procedure SendRtcp(const Host: string; Port: Word; const Data: TBytes);
    function RtpPort: Word;
    function RtcpPort: Word;
  end;

implementation

end.
