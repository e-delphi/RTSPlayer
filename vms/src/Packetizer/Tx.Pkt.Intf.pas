unit Tx.Pkt.Intf;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.RtpBuilder;

const
  TX_DEFAULT_MTU = 1400;

type
  TRtpReadyEvent = reference to procedure(const RtpBytes: TBytes);

  IPacketizer = interface
    ['{8F1A0F62-0B2D-4D0F-9B5C-CC4F2A3E9A10}']
    function Kind: TTrackKind;
    procedure SetPayloadType(Pt: Byte);
    procedure SetSsrc(Ssrc: Cardinal);
    procedure SetMtu(Mtu: Word);
    procedure SetOnRtpReady(const Callback: TRtpReadyEvent);
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean);
  end;

implementation

end.
