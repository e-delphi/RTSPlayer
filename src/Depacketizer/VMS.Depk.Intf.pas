unit VMS.Depk.Intf;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet;

type
  TSampleEvent = reference to procedure(const Sample: TSample);

  IDepacketizer = interface
    ['{2F1A0F62-0B2D-4D0F-9B5C-CC4F2A3E8E40}']
    function Kind: TTrackKind;
    procedure SetTrackId(Id: TTrackId);
    procedure SetOnSample(const Callback: TSampleEvent);
    procedure Feed(const Packet: TRtpPacket);
    procedure Flush;
    procedure Reset;
  end;

implementation

end.
