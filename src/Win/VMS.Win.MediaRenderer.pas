unit VMS.Win.MediaRenderer;

// Renderer Windows: implementa IMediaSink e distribui o stream aos decoders de
// vídeo (FFmpeg) e áudio (G711/PCM/AAC -> waveOut). Mesma superfície pública do
// TAndroidMediaRenderer (a UI e o facade VMS.Media.Renderer não sabem qual
// backend está por baixo).
//
// Lifetime: gerenciado manualmente pela UI (refcount de interface desativado).

{$IFDEF MSWINDOWS}
{$ENDIF}

interface

{$IFDEF MSWINDOWS}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.MediaSink,
  VMS.Win.VideoDecoder,
  VMS.Win.AudioDecoder;

type
  TWindowsMediaRenderer = class(TObject, IInterface, IMediaSink)
  strict private
    FVideo: TVideoDecoder;
    FAudio: TAudioDecoder;
    FAudioEnabled: Boolean;
    FLogger: ILogger;
    // último formato de áudio anunciado pela sessão, guardado para reconfigurar
    // o decoder quando o usuário tira o mudo no meio do stream
    FFmtLock: TCriticalSection;
    FHasAudioFmt: Boolean;
    FFmtCodec: TAudioCodec;
    FFmtRate: Cardinal;
    FFmtChannels: Byte;
    FFmtExtra: TBytes;
    function GetOnVideoFrame: TThreadProcedure;
    procedure SetOnVideoFrame(const V: TThreadProcedure);
    procedure SetAudioEnabled(Value: Boolean);
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
    // Atraso (ms) de áudio (jitter buffer) e vídeo (exibição) p/ A/V sync.
    procedure SetDelays(AudioMs, VideoMs: Integer);
    // False = mudo. Pode ser trocado a qualquer momento (inclusive no meio do
    // stream); a UI escreve daqui da thread principal.
    property AudioEnabled: Boolean read FAudioEnabled write SetAudioEnabled;
    property OnVideoFrame: TThreadProcedure read GetOnVideoFrame write SetOnVideoFrame;
  end;

{$ENDIF MSWINDOWS}

implementation

{$IFDEF MSWINDOWS}

constructor TWindowsMediaRenderer.Create(const ALogger: ILogger);
begin
  inherited Create;
  FLogger := ALogger;
  FFmtLock := TCriticalSection.Create;
  FVideo := TVideoDecoder.Create(ALogger);
  FAudio := TAudioDecoder.Create(ALogger);
  FAudioEnabled := True;
end;

destructor TWindowsMediaRenderer.Destroy;
begin
  FVideo.Free;
  FAudio.Free;
  FFmtLock.Free;
  inherited;
end;

function TWindowsMediaRenderer.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  if GetInterface(IID, Obj) then
    Result := S_OK
  else
    Result := E_NOINTERFACE;
end;

function TWindowsMediaRenderer._AddRef: Integer;
begin
  Result := -1; // lifetime manual
end;

function TWindowsMediaRenderer._Release: Integer;
begin
  Result := -1; // lifetime manual
end;

function TWindowsMediaRenderer.GetOnVideoFrame: TThreadProcedure;
begin
  Result := FVideo.OnFrame;
end;

procedure TWindowsMediaRenderer.SetOnVideoFrame(const V: TThreadProcedure);
begin
  FVideo.OnFrame := V;
end;

procedure TWindowsMediaRenderer.OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
  const Extradata: TBytes);
begin
  FVideo.Configure(Codec, Width, Height, Extradata);
end;

procedure TWindowsMediaRenderer.OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
  Channels: Byte; const Extradata: TBytes);
begin
  FFmtLock.Enter;
  try
    FFmtCodec := Codec;
    FFmtRate := SampleRate;
    FFmtChannels := Channels;
    FFmtExtra := Copy(Extradata);
    FHasAudioFmt := True;
  finally
    FFmtLock.Leave;
  end;
  // no mudo nem configura: não abre o dispositivo de áudio à toa
  if FAudioEnabled then
    FAudio.Configure(Codec, SampleRate, Channels, Extradata);
end;

procedure TWindowsMediaRenderer.SetAudioEnabled(Value: Boolean);
var
  Codec: TAudioCodec;
  Rate: Cardinal;
  Ch: Byte;
  Extra: TBytes;
  HasFmt: Boolean;
begin
  if FAudioEnabled = Value then Exit;
  FAudioEnabled := Value;
  FAudio.FlushReset; // descarta o que ficou na fila: ao religar começa limpo
  if not Value then Exit;
  FFmtLock.Enter;
  try
    HasFmt := FHasAudioFmt;
    Codec := FFmtCodec;
    Rate := FFmtRate;
    Ch := FFmtChannels;
    Extra := Copy(FFmtExtra);
  finally
    FFmtLock.Leave;
  end;
  // saindo do mudo com o stream já rodando: o formato já passou, reconfigura
  if HasFmt then
    FAudio.Configure(Codec, Rate, Ch, Extra);
end;

procedure TWindowsMediaRenderer.OnSample(const Sample: TSample);
begin
  case Sample.Kind of
    tkVideo: FVideo.Enqueue(Sample);
    tkAudio: if FAudioEnabled then FAudio.Enqueue(Sample);
  end;
end;

procedure TWindowsMediaRenderer.OnStreamStopped;
begin
  FVideo.FlushReset;
  FAudio.FlushReset;
  FFmtLock.Enter;
  try
    FHasAudioFmt := False; // o próximo stream anuncia o formato de novo
  finally
    FFmtLock.Leave;
  end;
end;

function TWindowsMediaRenderer.LockLatestFrame(out RGBA: TBytes; out W, H: Integer): Boolean;
begin
  Result := FVideo.LockLatestFrame(RGBA, W, H);
end;

procedure TWindowsMediaRenderer.UnlockFrame;
begin
  FVideo.UnlockFrame;
end;

procedure TWindowsMediaRenderer.SetDelays(AudioMs, VideoMs: Integer);
begin
  FAudio.SetPrimeMs(AudioMs);
  FVideo.SetDelayMs(VideoMs);
end;

{$ENDIF MSWINDOWS}

end.
