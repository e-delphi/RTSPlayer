unit VMS.Android.AudioDecoder;

// Reprodução de áudio no Android.
//   AAC          -> MediaCodec (audio/mp4a-latm) -> PCM16 -> AudioTrack
//   G711 u/a-law -> decodificação em software    -> PCM16 -> AudioTrack
//   PCM (L16)    -> byte-swap (big->little)       -> PCM16 -> AudioTrack
//
// Threading: Configure()/Enqueue()/FlushReset() na thread de rede;
// decodificação/reprodução nesta thread (Execute).

{$POINTERMATH ON}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Media,
  Androidapi.Helpers,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Android.JNIUtil;

type
  TAudioDecoder = class(TThread)
  strict private
    FLock: TCriticalSection;
    FItems: TList<TSample>;
    FDataEvent: TEvent;
    // config pendente
    FConfigLock: TCriticalSection;
    FNeedConfig: Boolean;
    FPendingCodec: TAudioCodec;
    FPendingRate: Cardinal;
    FPendingChannels: Byte;
    FPendingExtra: TBytes;
    // estado ativo
    FCodecKind: TAudioCodec;
    FSampleRate: Cardinal;
    FChannels: Byte;
    FUseMediaCodec: Boolean;
    FCodec: JMediaCodec;
    FBufferInfo: JMediaCodec_BufferInfo;
    FTrack: JAudioTrack;
    FReady: Boolean;
    FLogger: ILogger;
    FLoggedPlay: Boolean;
    procedure DoConfigure;
    procedure ReleaseAll;
    function CreateAudioTrack(Rate: Cardinal; Channels: Byte): Boolean;
    function DequeueSample(out S: TSample; TimeoutMs: Cardinal): Boolean;
    procedure DropForBound;
    procedure WritePcm(const Pcm: TBytes; Len: Integer);
    procedure PlayRaw(const S: TSample);
    procedure FeedAac(const S: TSample);
    procedure DrainAac;
  protected
    procedure Execute; override;
  public
    constructor Create(const ALogger: ILogger = nil);
    destructor Destroy; override;
    procedure Configure(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
                        const Extradata: TBytes);
    procedure Enqueue(const S: TSample);
    procedure FlushReset;
  end;

implementation

const
  MAX_QUEUE = 50;
  // Constantes estáveis do Android (evita depender de bindings de constantes)
  STREAM_MUSIC        = 3;   // AudioManager.STREAM_MUSIC
  CHANNEL_OUT_MONO    = 4;   // AudioFormat.CHANNEL_OUT_MONO
  CHANNEL_OUT_STEREO  = 12;  // AudioFormat.CHANNEL_OUT_STEREO
  ENCODING_PCM_16BIT  = 2;   // AudioFormat.ENCODING_PCM_16BIT
  MODE_STREAM         = 1;   // AudioTrack.MODE_STREAM
  PLAYSTATE_PLAYING   = 3;

function FreqIndexFor(Rate: Cardinal): Integer;
begin
  case Rate of
    96000: Result := 0;
    88200: Result := 1;
    64000: Result := 2;
    48000: Result := 3;
    44100: Result := 4;
    32000: Result := 5;
    24000: Result := 6;
    22050: Result := 7;
    16000: Result := 8;
    12000: Result := 9;
    11025: Result := 10;
    8000:  Result := 11;
    7350:  Result := 12;
  else
    Result := 4; // default 44100
  end;
end;

// AudioSpecificConfig (AAC-LC) de 2 bytes a partir de rate/channels.
function BuildAacAsc(Rate: Cardinal; Channels: Byte): TBytes;
var
  FreqIdx, ObjType: Integer;
begin
  ObjType := 2; // AAC-LC
  FreqIdx := FreqIndexFor(Rate);
  if Channels = 0 then Channels := 1;
  SetLength(Result, 2);
  Result[0] := Byte((ObjType shl 3) or ((FreqIdx shr 1) and $07));
  Result[1] := Byte(((FreqIdx and 1) shl 7) or ((Channels and $0F) shl 3));
end;

function MuLawDecode(U: Byte): SmallInt;
const
  BIAS = $84;
var
  T, Sign, Exponent, Mantissa: Integer;
begin
  U := not U;
  Sign := U and $80;
  Exponent := (U shr 4) and $07;
  Mantissa := U and $0F;
  T := ((Mantissa shl 3) + BIAS) shl Exponent;
  T := T - BIAS;
  if Sign <> 0 then
    Result := SmallInt(-T)
  else
    Result := SmallInt(T);
end;

function ALawDecode(A: Byte): SmallInt;
var
  T, Seg: Integer;
begin
  A := A xor $55;
  T := (A and $0F) shl 4;
  Seg := (A and $70) shr 4;
  case Seg of
    0: T := T + 8;
    1: T := T + 264;
  else
    T := (T + 264) shl (Seg - 1);
  end;
  if (A and $80) <> 0 then
    Result := SmallInt(T)
  else
    Result := SmallInt(-T);
end;

{ TAudioDecoder }

constructor TAudioDecoder.Create(const ALogger: ILogger);
begin
  inherited Create(True); // suspenso: inicializa campos antes de Execute
  FreeOnTerminate := False;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FConfigLock := TCriticalSection.Create;
  FItems := TList<TSample>.Create;
  FDataEvent := TEvent.Create(nil, True, False, '');
  Start;
end;

destructor TAudioDecoder.Destroy;
begin
  Terminate;
  FDataEvent.SetEvent;
  WaitFor;
  FItems.Free;
  FDataEvent.Free;
  FLock.Free;
  FConfigLock.Free;
  inherited;
end;

procedure TAudioDecoder.Configure(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
  const Extradata: TBytes);
begin
  FConfigLock.Enter;
  try
    FPendingCodec := Codec;
    FPendingRate := SampleRate;
    FPendingChannels := Channels;
    FPendingExtra := Copy(Extradata);
    FNeedConfig := True;
  finally
    FConfigLock.Leave;
  end;
end;

procedure TAudioDecoder.DropForBound;
begin
  while FItems.Count > MAX_QUEUE do
    FItems.Delete(0);
end;

procedure TAudioDecoder.Enqueue(const S: TSample);
begin
  FLock.Enter;
  try
    FItems.Add(S);
    DropForBound;
  finally
    FLock.Leave;
  end;
  FDataEvent.SetEvent;
end;

procedure TAudioDecoder.FlushReset;
begin
  FLock.Enter;
  try
    FItems.Clear;
    FDataEvent.ResetEvent;
  finally
    FLock.Leave;
  end;
end;

function TAudioDecoder.DequeueSample(out S: TSample; TimeoutMs: Cardinal): Boolean;
begin
  Result := False;
  FDataEvent.WaitFor(TimeoutMs);
  FLock.Enter;
  try
    if FItems.Count > 0 then
    begin
      S := FItems[0];
      FItems.Delete(0);
      Result := True;
    end;
    if FItems.Count = 0 then
      FDataEvent.ResetEvent;
  finally
    FLock.Leave;
  end;
end;

function TAudioDecoder.CreateAudioTrack(Rate: Cardinal; Channels: Byte): Boolean;
var
  ChannelConfig, MinBuf, BufSize: Integer;
begin
  if Channels >= 2 then
    ChannelConfig := CHANNEL_OUT_STEREO
  else
    ChannelConfig := CHANNEL_OUT_MONO;
  MinBuf := TJAudioTrack.JavaClass.getMinBufferSize(Integer(Rate), ChannelConfig, ENCODING_PCM_16BIT);
  if MinBuf <= 0 then
    MinBuf := Integer(Rate) * Channels * 2 div 2;
  BufSize := MinBuf * 4;
  try
    FTrack := TJAudioTrack.JavaClass.init(STREAM_MUSIC, Integer(Rate), ChannelConfig,
                                          ENCODING_PCM_16BIT, BufSize, MODE_STREAM);
    FTrack.play;
    Result := True;
  except
    FTrack := nil;
    Result := False;
  end;
end;

procedure TAudioDecoder.ReleaseAll;
begin
  if FCodec <> nil then
  begin
    try FCodec.stop; except end;
    try FCodec.release; except end;
    FCodec := nil;
  end;
  if FTrack <> nil then
  begin
    try FTrack.stop; except end;
    try FTrack.release; except end;
    FTrack := nil;
  end;
  FReady := False;
end;

procedure TAudioDecoder.DoConfigure;
var
  Asc: TBytes;
  Fmt: JMediaFormat;
begin
  FConfigLock.Enter;
  try
    FCodecKind := FPendingCodec;
    FSampleRate := FPendingRate;
    FChannels := FPendingChannels;
    Asc := Copy(FPendingExtra);
    FNeedConfig := False;
  finally
    FConfigLock.Leave;
  end;

  ReleaseAll;
  if FChannels = 0 then FChannels := 1;
  if FSampleRate = 0 then FSampleRate := 8000;
  FLoggedPlay := False;

  FUseMediaCodec := (FCodecKind = acAAC);
  if FLogger <> nil then
    FLogger.Info('audio', Format('config %s %dHz %dch (MediaCodec=%s)',
      [AudioCodecToStr(FCodecKind), FSampleRate, FChannels, BoolToStr(FUseMediaCodec, True)]));

  if not CreateAudioTrack(FSampleRate, FChannels) then
  begin
    if FLogger <> nil then
      FLogger.Error('audio', 'ERRO ao criar AudioTrack (sem audio)');
    Exit;
  end;

  if FUseMediaCodec then
  begin
    if Length(Asc) = 0 then
      Asc := BuildAacAsc(FSampleRate, FChannels);
    try
      FCodec := TJMediaCodec.JavaClass.createDecoderByType(StringToJString('audio/mp4a-latm'));
      Fmt := TJMediaFormat.JavaClass.createAudioFormat(StringToJString('audio/mp4a-latm'),
                                                       Integer(FSampleRate), FChannels);
      Fmt.setByteBuffer(StringToJString('csd-0'), BytesToDirectBuffer(Asc));
      FCodec.configure(Fmt, nil, nil, 0);
      FCodec.start;
    except
      on E: Exception do
      begin
        if FCodec <> nil then begin try FCodec.release; except end; FCodec := nil; end;
        FUseMediaCodec := False; // sem decoder AAC: silencia
        if FLogger <> nil then
          FLogger.Warn('audio', 'ERRO config AAC (' + E.Message + '); audio silenciado');
      end;
    end;
  end;

  FLock.Enter;
  try
    FItems.Clear;
    FDataEvent.ResetEvent;
  finally
    FLock.Leave;
  end;
  FReady := True;
  if FLogger <> nil then
    FLogger.Info('audio', 'pronto');
end;

procedure TAudioDecoder.WritePcm(const Pcm: TBytes; Len: Integer);
var
  Arr: TJavaArray<Byte>;
begin
  if (FTrack = nil) or (Len <= 0) then Exit;
  Arr := BytesToJavaArray(Pcm, Len);
  try
    FTrack.write(Arr, 0, Len);
  finally
    Arr.Free;
  end;
  if not FLoggedPlay then
  begin
    FLoggedPlay := True;
    if FLogger <> nil then
      FLogger.Info('audio', 'reproduzindo');
  end;
end;

procedure TAudioDecoder.PlayRaw(const S: TSample);
var
  I, N: Integer;
  Pcm: TBytes;
  V: SmallInt;
begin
  N := Length(S.Data);
  if N = 0 then Exit;

  case FCodecKind of
    acG711U:
      begin
        SetLength(Pcm, N * 2);
        for I := 0 to N - 1 do
        begin
          V := MuLawDecode(S.Data[I]);
          Pcm[I * 2]     := Byte(V and $FF);
          Pcm[I * 2 + 1] := Byte((V shr 8) and $FF);
        end;
        WritePcm(Pcm, N * 2);
      end;
    acG711A:
      begin
        SetLength(Pcm, N * 2);
        for I := 0 to N - 1 do
        begin
          V := ALawDecode(S.Data[I]);
          Pcm[I * 2]     := Byte(V and $FF);
          Pcm[I * 2 + 1] := Byte((V shr 8) and $FF);
        end;
        WritePcm(Pcm, N * 2);
      end;
    acPCM:
      begin
        // L16: 16-bit big-endian -> little-endian
        SetLength(Pcm, N);
        I := 0;
        while I + 1 < N do
        begin
          Pcm[I]     := S.Data[I + 1];
          Pcm[I + 1] := S.Data[I];
          Inc(I, 2);
        end;
        WritePcm(Pcm, N);
      end;
  else
    // G726 e demais ainda não suportados na reprodução
  end;
end;

procedure TAudioDecoder.FeedAac(const S: TSample);
var
  Idx: Integer;
  Buf: JByteBuffer;
  PtsUs: Int64;
begin
  Idx := FCodec.dequeueInputBuffer(10000);
  if Idx < 0 then Exit;
  Buf := FCodec.getInputBuffer(Idx);
  CopyToDirectBuffer(Buf, S.Data, Length(S.Data));
  if FSampleRate > 0 then
    PtsUs := Round(S.Pts * (1000000.0 / FSampleRate))
  else
    PtsUs := 0;
  FCodec.queueInputBuffer(Idx, 0, Length(S.Data), PtsUs, 0);
end;

procedure TAudioDecoder.DrainAac;
var
  Idx, Size, Off: Integer;
  Buf: JByteBuffer;
  P: PByte;
  Pcm: TBytes;
begin
  Idx := FCodec.dequeueOutputBuffer(FBufferInfo, 0);
  while Idx >= 0 do
  begin
    Size := FBufferInfo.size;
    Off := FBufferInfo.offset;
    if Size > 0 then
    begin
      Buf := FCodec.getOutputBuffer(Idx);
      P := DirectBufferAddress(Buf);
      if P <> nil then
      begin
        SetLength(Pcm, Size);
        Move((P + Off)^, Pcm[0], Size);
        WritePcm(Pcm, Size);
      end;
    end;
    FCodec.releaseOutputBuffer(Idx, False);
    Idx := FCodec.dequeueOutputBuffer(FBufferInfo, 0);
  end;
end;

procedure TAudioDecoder.Execute;
var
  S: TSample;
begin
  FBufferInfo := TJMediaCodec_BufferInfo.JavaClass.init;
  while not Terminated do
  begin
    if FNeedConfig then
      DoConfigure;
    if not FReady then
    begin
      TThread.Sleep(10);
      Continue;
    end;
    if FUseMediaCodec then
    begin
      if DequeueSample(S, 15) then
        FeedAac(S);
      DrainAac;
    end
    else
    begin
      if DequeueSample(S, 15) then
        PlayRaw(S);
    end;
  end;
  ReleaseAll;
end;

end.
