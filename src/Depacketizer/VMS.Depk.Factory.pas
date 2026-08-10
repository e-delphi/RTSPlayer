unit VMS.Depk.Factory;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Depk.Intf,
  VMS.Depk.H264,
  VMS.Depk.H265,
  VMS.Depk.MJPEG,
  VMS.Depk.AAC,
  VMS.Depk.PCM,
  VMS.Depk.G711,
  VMS.Depk.G726;

function CreateVideoDepacketizer(Codec: TVideoCodec): IDepacketizer;
function CreateAudioDepacketizer(Codec: TAudioCodec): IDepacketizer;
function CreateDepacketizer(VideoCodec: TVideoCodec; AudioCodec: TAudioCodec;
                            Kind: TTrackKind): IDepacketizer;

implementation

function CreateVideoDepacketizer(Codec: TVideoCodec): IDepacketizer;
begin
  case Codec of
    vcH264:  Result := TH264Depacketizer.Create;
    vcH265:  Result := TH265Depacketizer.Create;
    vcMJPEG: Result := TMjpegDepacketizer.Create;
  else
    Result := nil;
  end;
end;

function CreateAudioDepacketizer(Codec: TAudioCodec): IDepacketizer;
begin
  case Codec of
    acPCM:                                Result := TPcmDepacketizer.Create;
    acAAC:                                Result := TAacDepacketizer.Create;
    acG711U, acG711A:                     Result := TG711Depacketizer.Create;
    acG726_16, acG726_24, acG726_32, acG726_40: Result := TG726Depacketizer.Create;
  else
    Result := nil;
  end;
end;

function CreateDepacketizer(VideoCodec: TVideoCodec; AudioCodec: TAudioCodec;
                            Kind: TTrackKind): IDepacketizer;
begin
  if Kind = tkVideo then
    Result := CreateVideoDepacketizer(VideoCodec)
  else
    Result := CreateAudioDepacketizer(AudioCodec);
end;

end.
