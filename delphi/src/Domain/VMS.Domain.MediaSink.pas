unit VMS.Domain.MediaSink;

interface

uses
  System.SysUtils,
  VMS.Domain.Types;

type
  // Live consumer of depacketized samples (video + audio).
  // Implemented by the platform renderer (e.g. Android MediaCodec).
  //
  // Threading: OnVideoFormat/OnAudioFormat/OnSample/OnStreamStopped are all
  // invoked on the session worker thread. Implementations must marshal any
  // UI work to the main thread themselves (e.g. TThread.Queue).
  IMediaSink = interface
    ['{B7E3F1A0-9C44-4E8B-9F1D-2A6C5D8E7F31}']
    procedure OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
                            const Extradata: TBytes);
    procedure OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
                            Channels: Byte; const Extradata: TBytes);
    procedure OnSample(const Sample: TSample);
    procedure OnStreamStopped;
  end;

implementation

end.
