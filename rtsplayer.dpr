program rtsplayer;

uses
  System.StartUpCopy,
  FMX.Forms,
  Inicio in 'src\UI\Inicio.pas' {Form1},
  {$IFDEF ANDROID}
  VMS.Android.JNIUtil in 'src\Android\VMS.Android.JNIUtil.pas',
  VMS.Android.VideoDecoder in 'src\Android\VMS.Android.VideoDecoder.pas',
  VMS.Android.AudioDecoder in 'src\Android\VMS.Android.AudioDecoder.pas',
  VMS.Android.MediaRenderer in 'src\Android\VMS.Android.MediaRenderer.pas',
  {$ENDIF }
  {$IFDEF MSWINDOWS}
  FFmpegLib in 'src\Win\FFmpegLib.pas',
  VMS.Win.VideoDecoder in 'src\Win\VMS.Win.VideoDecoder.pas',
  VMS.Win.AudioDecoder in 'src\Win\VMS.Win.AudioDecoder.pas',
  VMS.Win.MediaRenderer in 'src\Win\VMS.Win.MediaRenderer.pas',
  {$ENDIF }
  VMS.Media.Renderer in 'src\Media\VMS.Media.Renderer.pas',
  VMS.Android.MemoLogger in 'src\Android\VMS.Android.MemoLogger.pas',
  VMS.Dvrip.Protocol in 'src\Dvrip\VMS.Dvrip.Protocol.pas',
  VMS.Dvrip.Media in 'src\Dvrip\VMS.Dvrip.Media.pas',
  VMS.Dvrip.Session in 'src\Dvrip\VMS.Dvrip.Session.pas',
  VMS.App.Clock in 'src\App\VMS.App.Clock.pas',
  VMS.App.Composition in 'src\App\VMS.App.Composition.pas',
  VMS.App.Config in 'src\App\VMS.App.Config.pas',
  VMS.App.Logger in 'src\App\VMS.App.Logger.pas',
  VMS.App.ScreenAwake in 'src\App\VMS.App.ScreenAwake.pas',
  VMS.Depk.AAC in 'src\Depacketizer\VMS.Depk.AAC.pas',
  VMS.Depk.Base in 'src\Depacketizer\VMS.Depk.Base.pas',
  VMS.Depk.Factory in 'src\Depacketizer\VMS.Depk.Factory.pas',
  VMS.Depk.G711 in 'src\Depacketizer\VMS.Depk.G711.pas',
  VMS.Depk.G726 in 'src\Depacketizer\VMS.Depk.G726.pas',
  VMS.Depk.H264 in 'src\Depacketizer\VMS.Depk.H264.pas',
  VMS.Depk.H265 in 'src\Depacketizer\VMS.Depk.H265.pas',
  VMS.Depk.Intf in 'src\Depacketizer\VMS.Depk.Intf.pas',
  VMS.Depk.MJPEG in 'src\Depacketizer\VMS.Depk.MJPEG.pas',
  VMS.Depk.PCM in 'src\Depacketizer\VMS.Depk.PCM.pas',
  VMS.Domain.Clock in 'src\Domain\VMS.Domain.Clock.pas',
  VMS.Domain.Logging in 'src\Domain\VMS.Domain.Logging.pas',
  VMS.Domain.MediaSink in 'src\Domain\VMS.Domain.MediaSink.pas',
  VMS.Domain.Reconnect in 'src\Domain\VMS.Domain.Reconnect.pas',
  VMS.Domain.Session in 'src\Domain\VMS.Domain.Session.pas',
  VMS.Domain.Supervisor in 'src\Domain\VMS.Domain.Supervisor.pas',
  VMS.Domain.Types in 'src\Domain\VMS.Domain.Types.pas',
  VMS.Net.Intf in 'src\Net\VMS.Net.Intf.pas',
  VMS.Net.Tcp in 'src\Net\VMS.Net.Tcp.pas',
  VMS.Net.Udp in 'src\Net\VMS.Net.Udp.pas',
  VMS.Rec.Block in 'src\Recording\VMS.Rec.Block.pas',
  VMS.Rec.Crc32 in 'src\Recording\VMS.Rec.Crc32.pas',
  VMS.Rec.Format in 'src\Recording\VMS.Rec.Format.pas',
  VMS.Rec.Reader in 'src\Recording\VMS.Rec.Reader.pas',
  VMS.Rec.Writer in 'src\Recording\VMS.Rec.Writer.pas',
  VMS.Rtp.Demux in 'src\Rtp\VMS.Rtp.Demux.pas',
  VMS.Rtp.Packet in 'src\Rtp\VMS.Rtp.Packet.pas',
  VMS.Rtsp.Auth in 'src\Rtsp\VMS.Rtsp.Auth.pas',
  VMS.Rtsp.Client in 'src\Rtsp\VMS.Rtsp.Client.pas',
  VMS.Rtsp.Messages in 'src\Rtsp\VMS.Rtsp.Messages.pas',
  VMS.Rtsp.Transport in 'src\Rtsp\VMS.Rtsp.Transport.pas',
  VMS.Rtsp.Url in 'src\Rtsp\VMS.Rtsp.Url.pas',
  VMS.Rtsp.WireReader in 'src\Rtsp\VMS.Rtsp.WireReader.pas',
  VMS.Sdp.Parser in 'src\Sdp\VMS.Sdp.Parser.pas',
  VMS.Sdp.Types in 'src\Sdp\VMS.Sdp.Types.pas',
  UI.Common in 'src\UI\UI.Common.pas',
  UI.List in 'src\UI\UI.List.pas' {FrameList: TFrame},
  UI.Player in 'src\UI\UI.Player.pas' {FramePlayer: TFrame},
  UI.Editor in 'src\UI\UI.Editor.pas' {FrameEditor: TFrame};

{$R *.res}

begin
  Application.Initialize;
  Application.FormFactor.Orientations := [TFormOrientation.Portrait, TFormOrientation.InvertedPortrait, TFormOrientation.Landscape, TFormOrientation.InvertedLandscape];
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
