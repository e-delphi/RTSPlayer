unit VMS.Depk.G726;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

type
  TG726Depacketizer = class(TBaseDepacketizer)
  public
    function Kind: TTrackKind; override;
    procedure Feed(const Packet: TRtpPacket); override;
  end;

implementation

function TG726Depacketizer.Kind: TTrackKind;
begin
  Result := tkAudio;
end;

procedure TG726Depacketizer.Feed(const Packet: TRtpPacket);
begin
  if Length(Packet.Payload) = 0 then Exit;
  Emit(tkAudio, Packet.Timestamp, [], Packet.Payload);
end;

end.
