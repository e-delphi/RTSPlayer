unit VMS.Depk.PCM;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

type
  TPcmDepacketizer = class(TBaseDepacketizer)
  public
    function Kind: TTrackKind; override;
    procedure Feed(const Packet: TRtpPacket); override;
  end;

implementation

{ TPcmDepacketizer }

function TPcmDepacketizer.Kind: TTrackKind;
begin
  Result := tkAudio;
end;

procedure TPcmDepacketizer.Feed(const Packet: TRtpPacket);
begin
  if Length(Packet.Payload) = 0 then Exit;
  Emit(tkAudio, Packet.Timestamp, [], Packet.Payload);
end;

end.
