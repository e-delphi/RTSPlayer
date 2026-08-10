unit VMS.Media.Renderer;

// Facade cross-platform do renderer. A UI usa `TMediaRenderer` sem saber a
// plataforma: no Android é o backend MediaCodec (JNI), no Windows é o backend
// FFmpeg. Ambos expõem a MESMA superfície pública (Create/OnVideoFormat/
// OnAudioFormat/OnSample/OnStreamStopped/LockLatestFrame/UnlockFrame/
// AudioEnabled/OnVideoFrame) e implementam IMediaSink.

interface

uses
{$IFDEF ANDROID}
  VMS.Android.MediaRenderer;
{$ENDIF}
{$IFDEF MSWINDOWS}
  VMS.Win.MediaRenderer;
{$ENDIF}

type
{$IFDEF ANDROID}
  TMediaRenderer = VMS.Android.MediaRenderer.TAndroidMediaRenderer;
{$ENDIF}
{$IFDEF MSWINDOWS}
  TMediaRenderer = VMS.Win.MediaRenderer.TWindowsMediaRenderer;
{$ENDIF}

implementation

end.
