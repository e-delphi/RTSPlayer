unit VMS.Android.MediaRenderer;

// Implementa IMediaSink: recebe o stream da sessão (na thread de rede) e o
// distribui para os decoders de vídeo/áudio. A UI acessa o último frame via
// LockLatestFrame/UnlockFrame.
//
// Lifetime: gerenciado manualmente pela UI (refcount de interface desativado).
// A UI DEVE parar o supervisor antes de liberar o renderer.

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.MediaSink,
  VMS.Android.VideoDecoder,
  VMS.Android.AudioDecoder;

type
  TAndroidMediaRenderer = class(TObject, IInterface, IMediaSink)
  strict private
    FVideo: TVideoDecoder;
    FAudio: TAudioDecoder;
    FAudioEnabled: Boolean;
    function GetOnVideoFrame: TThreadProcedure;
    procedure SetOnVideoFrame(const V: TThreadProcedure);
  protected
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
  public
    constructor Create(const ALogger: ILogger = nil);
    destructor Destroy; override;
    { IMediaSink }
    procedure OnVideoFormat(Codec: TVideoCodec; Width, Height: Word; const Extradata: TBytes);
    procedure OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
                            const Extradata: TBytes);
    procedure OnSample(const Sample: TSample);
    procedure OnStreamStopped;
    { Acesso ao frame para a UI }
    function LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
    procedure UnlockFrame;
    // No-op no Android (o backend Windows usa isso p/ A/V sync via jitter buffer).
    procedure SetDelays(AudioMs, VideoMs: Integer);
    property AudioEnabled: Boolean read FAudioEnabled write FAudioEnabled;
    property OnVideoFrame: TThreadProcedure read GetOnVideoFrame write SetOnVideoFrame;
  end;

implementation

constructor TAndroidMediaRenderer.Create(const ALogger: ILogger);
begin
  inherited Create;
  FVideo := TVideoDecoder.Create(ALogger);
  FAudio := TAudioDecoder.Create(ALogger);
  FAudioEnabled := True;
end;

destructor TAndroidMediaRenderer.Destroy;
begin
  FVideo.Free;
  FAudio.Free;
  inherited;
end;

function TAndroidMediaRenderer.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  if GetInterface(IID, Obj) then
    Result := S_OK
  else
    Result := E_NOINTERFACE;
end;

function TAndroidMediaRenderer._AddRef: Integer;
begin
  Result := -1; // lifetime manual
end;

function TAndroidMediaRenderer._Release: Integer;
begin
  Result := -1; // lifetime manual
end;

function TAndroidMediaRenderer.GetOnVideoFrame: TThreadProcedure;
begin
  Result := FVideo.OnFrame;
end;

procedure TAndroidMediaRenderer.SetOnVideoFrame(const V: TThreadProcedure);
begin
  FVideo.OnFrame := V;
end;

procedure TAndroidMediaRenderer.OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
  const Extradata: TBytes);
begin
  FVideo.Configure(Codec, Width, Height, Extradata);
end;

procedure TAndroidMediaRenderer.OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
  Channels: Byte; const Extradata: TBytes);
begin
  if FAudioEnabled then
    FAudio.Configure(Codec, SampleRate, Channels, Extradata);
end;

procedure TAndroidMediaRenderer.OnSample(const Sample: TSample);
begin
  case Sample.Kind of
    tkVideo: FVideo.Enqueue(Sample);
    tkAudio: if FAudioEnabled then FAudio.Enqueue(Sample);
  end;
end;

procedure TAndroidMediaRenderer.OnStreamStopped;
begin
  FVideo.FlushReset;
  FAudio.FlushReset;
end;

function TAndroidMediaRenderer.LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
begin
  Result := FVideo.LockLatestFrame(RGBA, W, H);
end;

procedure TAndroidMediaRenderer.UnlockFrame;
begin
  FVideo.UnlockFrame;
end;

procedure TAndroidMediaRenderer.SetDelays(AudioMs, VideoMs: Integer);
begin
  // No-op: no Android o sync depende do MediaCodec/AudioTrack, não deste esquema.
end;

end.
