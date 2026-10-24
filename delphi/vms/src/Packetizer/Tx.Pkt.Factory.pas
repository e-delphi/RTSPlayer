unit Tx.Pkt.Factory;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Intf,
  Tx.Pkt.H264,
  Tx.Pkt.H265,
  Tx.Pkt.AAC,
  Tx.Pkt.MJPEG,
  Tx.Pkt.Passthrough;

function CreateVideoPacketizer(Codec: TVideoCodec): IPacketizer;
function CreateAudioPacketizer(Codec: TAudioCodec): IPacketizer;

implementation

function CreateVideoPacketizer(Codec: TVideoCodec): IPacketizer;
begin
  case Codec of
    vcH264:  Result := TH264Packetizer.Create;
    vcH265:  Result := TH265Packetizer.Create;
    vcMJPEG: Result := TMjpegPacketizer.Create;
  else
    Result := nil;
  end;
end;

function CreateAudioPacketizer(Codec: TAudioCodec): IPacketizer;
begin
  case Codec of
    acAAC:                                       Result := TAacPacketizer.Create;
    acPCM, acG711U, acG711A,
    acG726_16, acG726_24, acG726_32, acG726_40:  Result := TPassthroughAudioPacketizer.Create;
  else
    Result := nil;
  end;
end;

end.
