unit VMS.Depk.G711;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Base;

type
  TG711Depacketizer = class(TBaseDepacketizer)
  public
    function Kind: TTrackKind; override;
    procedure Feed(const Packet: TRtpPacket); override;
  end;

implementation

function TG711Depacketizer.Kind: TTrackKind;
begin
  Result := tkAudio;
end;

procedure TG711Depacketizer.Feed(const Packet: TRtpPacket);
begin
  if Length(Packet.Payload) = 0 then Exit;
  Emit(tkAudio, Packet.Timestamp, [], Packet.Payload);
end;

end.
