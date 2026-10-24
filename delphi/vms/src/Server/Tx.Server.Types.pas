unit Tx.Server.Types;

interface

uses
  System.SysUtils,
  VMS.Domain.Types;

type
  TTxTrackKind = (ttkVideo, ttkAudio);

  TTxTrackInfo = record
    Kind: TTxTrackKind;
    PayloadType: Byte;
    ClockRate: Cardinal;
    ControlPath: string;
    Ssrc: Cardinal;
  end;

  TTxClientTransport = record
    Kind: TTransportKind;
    InterleavedRtp: Byte;
    InterleavedRtcp: Byte;
    ClientRtpPort: Word;
    ClientRtcpPort: Word;
    ServerRtpPort: Word;
    ServerRtcpPort: Word;
  end;

const
  TX_TRACK_VIDEO_PT = 96;
  TX_TRACK_AUDIO_PT = 97;
  TX_TRACK_VIDEO_CTRL = 'trackID=0';
  TX_TRACK_AUDIO_CTRL = 'trackID=1';

implementation

end.
