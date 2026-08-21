unit Vms.Server.RecSink;

// Grava um stream ao vivo em .vms a partir do IMediaSink.
//
// Por que existe: no caminho RTSP quem grava é o próprio TCameraSession
// (FConfig.RecordEnabled -> TBlockBuilder + TFileRecordingWriter). O caminho
// DVRIP (TDvripSession) não tem writer: ele só entrega formato/samples ao
// IMediaSink. Este sink fecha essa lacuna reusando as MESMAS peças de
// gravação, para que a câmera dvrip gere .vms igual às outras e possa ser
// servida pelo /live/ do servidor RTSP.
//
// Threading: todas as chamadas do IMediaSink vêm da thread da sessão (uma só).

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  VMS.Domain.Clock,
  VMS.Domain.MediaSink,
  VMS.Rec.Format,
  VMS.Rec.Block,
  VMS.Rec.Paths,
  VMS.Rec.Writer;

type
  TRecordingSink = class(TInterfacedObject, IMediaSink)
  strict private
    // configuração
    FName: string;
    FStorageDir: string;
    FPattern: string;
    FSourceUri: string;
    FRecordAudio: Boolean;
    FMaxSamples: Integer;
    FMaxDurationMs: Integer;
    FMaxSizeBytes: Integer;
    FRotateMs: Int64;         // 0 = não roda de arquivo
    FFileStartedMs: Int64;    // monotônico, de quando o arquivo corrente abriu
    FWaitAudioMs: Int64;
    FLogger: ILogger;
    FClock: IClock;
    // gravação corrente
    FWriter: IRecordingWriter;
    FBuilder: TBlockBuilder;
    FOpen: Boolean;
    // formatos anunciados
    FHasVideo: Boolean;
    FVCodec: TVideoCodec;
    FVWidth: Word;
    FVHeight: Word;
    FVExtra: TBytes;
    FHasAudio: Boolean;
    FACodec: TAudioCodec;
    FARate: Cardinal;
    FAChannels: Byte;
    FAExtra: TBytes;
    // janela de espera antes de abrir o arquivo
    FFirstFormatMs: Int64;
    FPending: TArray<TSample>;
    FPendingCount: Integer;
    FPendingBytes: Integer;
    function OutputPath: string;
    function ReadyToOpen: Boolean;
    procedure NoteFirstFormat;
    function BuildHeader: TVmsHeader;
    procedure OpenWriter;
    // Está na hora de rodar de arquivo? Ver TCameraSession.RotateDue.
    function RotateDue(const Block: TVmsBlock): Boolean;
    // Fecha o arquivo corrente e abre o seguinte SEM parar a gravação: o
    // TBlockBuilder continua o mesmo, só o writer troca.
    procedure RotateWriter;
    procedure HoldSample(const S: TSample);
    procedure FlushPending;
    procedure CloseWriter(Clean: Boolean);
    procedure ResetState;
    procedure Log(const Msg: string);
  public
    constructor Create(const AName, AStorageDir, AFilenamePattern, ASourceUri: string;
                       ARecordAudio: Boolean;
                       AMaxSamples, AMaxDurationMs, AMaxSizeBytes: Integer;
                       const ALogger: ILogger; const AClock: IClock;
                       AWaitAudioMs: Integer = 1500;
                       ARotateMs: Integer = 0);
    destructor Destroy; override;
    { IMediaSink }
    procedure OnVideoFormat(Codec: TVideoCodec; Width, Height: Word; const Extradata: TBytes);
    procedure OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal; Channels: Byte;
                            const Extradata: TBytes);
    procedure OnSample(const Sample: TSample);
    procedure OnStreamStopped;
  end;

// Mesmo formato de nome do gravador RTSP — obrigatório, porque o servidor acha
// o arquivo ao vivo por FindMostRecentVmsForCamera, que casa '<nome>_*.vms'.
function FormatRecFilename(const Pattern, Name: string; CreationUtc: TDateTime): string;

implementation

const
  // RTP de vídeo é 90 kHz; é a base em que o TDvripSession numera os PTS.
  VIDEO_TIMESCALE = 90000;
  // teto do buffer de espera, p/ não crescer sem limite se o áudio nunca vier
  MAX_PENDING_BYTES = 8 * 1024 * 1024;
  // quanto se espera por um keyframe depois de vencido o prazo de rotação
  ROTATE_KEYFRAME_GRACE_MS = 60000;

function FormatRecFilename(const Pattern, Name: string; CreationUtc: TDateTime): string;
  function Pad(I, W: Integer): string;
  begin
    Result := IntToStr(I);
    while Length(Result) < W do Result := '0' + Result;
  end;
var
  S, Local: string;
  Y, M, D, H, Mn, Sec, Ms: Word;
  DT: TDateTime;
begin
  if Pattern = '' then
    S := '{name}_{yyyy-MM-dd_HH-mm-ss}.vms'
  else
    S := Pattern;
  DT := TTimeZone.Local.ToLocalTime(CreationUtc);
  DecodeDate(DT, Y, M, D);
  DecodeTime(DT, H, Mn, Sec, Ms);
  S := StringReplace(S, '{name}', Name, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '{yyyy}', Pad(Y, 4), [rfReplaceAll]);
  S := StringReplace(S, '{MM}', Pad(M, 2), [rfReplaceAll]);
  S := StringReplace(S, '{dd}', Pad(D, 2), [rfReplaceAll]);
  S := StringReplace(S, '{HH}', Pad(H, 2), [rfReplaceAll]);
  S := StringReplace(S, '{mm}', Pad(Mn, 2), [rfReplaceAll]);
  S := StringReplace(S, '{ss}', Pad(Sec, 2), [rfReplaceAll]);
  Local := StringReplace(FormatDateTime('yyyy-mm-dd_hh-nn-ss', DT), ':', '-', [rfReplaceAll]);
  S := StringReplace(S, '{yyyy-MM-dd_HH-mm-ss}', Local, [rfReplaceAll]);
  Result := S;
end;

{ TRecordingSink }

constructor TRecordingSink.Create(const AName, AStorageDir, AFilenamePattern, ASourceUri: string;
  ARecordAudio: Boolean; AMaxSamples, AMaxDurationMs, AMaxSizeBytes: Integer;
  const ALogger: ILogger; const AClock: IClock; AWaitAudioMs: Integer;
  ARotateMs: Integer);
begin
  inherited Create;
  FName := AName;
  FStorageDir := AStorageDir;
  FPattern := AFilenamePattern;
  FSourceUri := ASourceUri;
  FRecordAudio := ARecordAudio;
  FMaxSamples := AMaxSamples;
  FMaxDurationMs := AMaxDurationMs;
  FMaxSizeBytes := AMaxSizeBytes;
  FRotateMs := ARotateMs;
  if FRotateMs < 0 then FRotateMs := 0;
  FLogger := ALogger;
  FClock := AClock;
  if AWaitAudioMs < 0 then AWaitAudioMs := 0;
  FWaitAudioMs := AWaitAudioMs;
  ResetState;
end;

destructor TRecordingSink.Destroy;
begin
  CloseWriter(True);
  inherited;
end;

procedure TRecordingSink.Log(const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Info('recsink.' + FName, Msg);
end;

procedure TRecordingSink.ResetState;
begin
  FOpen := False;
  FWriter := nil;
  FreeAndNil(FBuilder);
  FHasVideo := False;
  FHasAudio := False;
  FVCodec := vcNone;
  FACodec := acNone;
  FVExtra := nil;
  FAExtra := nil;
  FVWidth := 0;
  FVHeight := 0;
  FARate := 0;
  FAChannels := 0;
  FFirstFormatMs := 0;
  SetLength(FPending, 0);
  FPendingCount := 0;
  FPendingBytes := 0;
end;

function TRecordingSink.OutputPath: string;
var
  Dir, Filename: string;
begin
  Filename := FormatRecFilename(FPattern, FName, TTimeZone.Local.ToUniversalTime(Now));
  // Cada câmera na sua pasta (ver VMS.Rec.Paths).
  Dir := EnsureCameraDir(FStorageDir, FName);
  Result := IncludeTrailingPathDelimiter(Dir) + Filename;
end;

procedure TRecordingSink.NoteFirstFormat;
begin
  if FFirstFormatMs = 0 then
    FFirstFormatMs := FClock.MonotonicMs;
end;

function TRecordingSink.ReadyToOpen: Boolean;
begin
  // O cabeçalho .vms é escrito uma vez e fixa quais trilhas existem, então não
  // dá pra acrescentar áudio depois. Como vídeo e áudio são anunciados em
  // momentos diferentes, segura o início por uma janela curta esperando o
  // áudio — os samples desse intervalo ficam no buffer, e não são perdidos
  // (importante: começar o arquivo num keyframe).
  Result := False;
  if not FHasVideo then Exit;
  if FHasAudio or (not FRecordAudio) then Exit(True);
  if FPendingBytes >= MAX_PENDING_BYTES then Exit(True);
  Result := (FClock.MonotonicMs - FFirstFormatMs) >= FWaitAudioMs;
end;

// O header do arquivo, montado do que as trilhas anunciaram. Sai do OpenWriter
// porque a rotação precisa dele de novo, com outro instante de criação.
function TRecordingSink.BuildHeader: TVmsHeader;
var
  Header: TVmsHeader;
begin
  FillChar(Header, SizeOf(Header), 0);
  Header.Version := VMS_FORMAT_VERSION;
  Header.CreationUnixMs := FClock.NowUtcMs;
  Header.SourceUri := FSourceUri;

  if FHasVideo and (FVCodec <> vcNone) then
  begin
    Header.VideoPresent := True;
    Header.Video.Codec := FVCodec;
    Header.Video.Timescale := VIDEO_TIMESCALE;
    Header.Video.Width := FVWidth;
    Header.Video.Height := FVHeight;
    Header.Video.Extradata := FVExtra;
  end;
  if FRecordAudio and FHasAudio and (FACodec <> acNone) then
  begin
    Header.AudioPresent := True;
    Header.Audio.Codec := FACodec;
    // áudio numera PTS na própria taxa de amostragem
    Header.Audio.Timescale := FARate;
    Header.Audio.SampleRate := FARate;
    Header.Audio.Channels := FAChannels;
    Header.Audio.BitsPerSample := 16;
    Header.Audio.Extradata := FAExtra;
  end;
  Result := Header;
end;

procedure TRecordingSink.OpenWriter;
var
  Path: string;
begin
  Path := UniqueRecordingPath(OutputPath);
  FWriter := TFileRecordingWriter.Create(Path);
  FWriter.WriteHeader(BuildHeader);
  FFileStartedMs := FClock.MonotonicMs;

  FBuilder := TBlockBuilder.Create(FMaxSamples, FMaxDurationMs, FMaxSizeBytes);
  FBuilder.SetOnBlockClosed(
    procedure(const Block: TVmsBlock)
    begin
      if FWriter = nil then Exit;
      // Roda de arquivo ANTES de gravar este bloco, para ele já entrar no
      // arquivo novo — que assim começa por um keyframe.
      if RotateDue(Block) then
        RotateWriter;
      if FWriter <> nil then
        FWriter.WriteBlock(Block);
    end);

  FOpen := True;
  Log('gravando em ' + Path);
end;

// Passou o tempo de rodar de arquivo. Depois do prazo, espera o próximo bloco
// com keyframe: assim o arquivo novo começa por um ponto de entrada do
// decodificador, que é o que o cliente procura depois de uma emenda (ver
// VMS.Play.Engine). Câmera que não manda keyframe nenhum não pode segurar a
// rotação para sempre — daí a tolerância.
function TRecordingSink.RotateDue(const Block: TVmsBlock): Boolean;
var
  Age: Int64;
begin
  Result := False;
  if FRotateMs <= 0 then Exit;
  Age := FClock.MonotonicMs - FFileStartedMs;
  if Age < FRotateMs then Exit;
  Result := SamplesHaveKeyframe(Block.Samples) or
            (Age >= FRotateMs + ROTATE_KEYFRAME_GRACE_MS);
end;

procedure TRecordingSink.RotateWriter;
var
  Path: string;
begin
  try
    if FWriter <> nil then
      FWriter.Close(True);
  except
    on E: Exception do
      Log('falha ao fechar o arquivo na rotacao: ' + E.Message);
  end;
  FWriter := nil;
  Path := UniqueRecordingPath(OutputPath);
  try
    FWriter := TFileRecordingWriter.Create(Path);
    FWriter.WriteHeader(BuildHeader);
    FFileStartedMs := FClock.MonotonicMs;
    Log('rodando de arquivo; seguindo em ' + ExtractFileName(Path));
  except
    on E: Exception do
    begin
      // Sem writer, os blocos deste bloco em diante são descartados. Quem fecha
      // a gravação é o OnSample, DEPOIS de o AddSample retornar: fechar aqui
      // liberaria o TBlockBuilder de dentro do callback dele mesmo.
      FWriter := nil;
      Log('falha ao abrir o arquivo novo: ' + E.Message);
    end;
  end;
end;

procedure TRecordingSink.HoldSample(const S: TSample);
begin
  if FPendingBytes >= MAX_PENDING_BYTES then Exit;
  if FPendingCount >= Length(FPending) then
  begin
    if Length(FPending) = 0 then
      SetLength(FPending, 64)
    else
      SetLength(FPending, Length(FPending) * 2);
  end;
  FPending[FPendingCount] := S;
  Inc(FPendingCount);
  Inc(FPendingBytes, Length(S.Data));
end;

procedure TRecordingSink.FlushPending;
var
  I: Integer;
  KeepAudio: Boolean;
begin
  // se a trilha de áudio não entrou no cabeçalho, os samples de áudio que
  // ficaram no buffer não têm onde ser gravados
  KeepAudio := FRecordAudio and FHasAudio;
  for I := 0 to FPendingCount - 1 do
    if KeepAudio or (FPending[I].Kind <> tkAudio) then
      FBuilder.AddSample(FPending[I], FClock.NowUtcMs, FClock.MonotonicMs);
  SetLength(FPending, 0);
  FPendingCount := 0;
  FPendingBytes := 0;
end;

procedure TRecordingSink.CloseWriter(Clean: Boolean);
begin
  if FBuilder <> nil then
  begin
    try
      FBuilder.ForceFlush(FClock.NowUtcMs, FClock.MonotonicMs);
    except
    end;
    FreeAndNil(FBuilder);
  end;
  if FWriter <> nil then
  begin
    try
      FWriter.Close(Clean);
    except
    end;
    FWriter := nil;
  end;
  FOpen := False;
end;

procedure TRecordingSink.OnVideoFormat(Codec: TVideoCodec; Width, Height: Word;
  const Extradata: TBytes);
begin
  // formato novo no meio do stream: recomeça um arquivo
  if FOpen then
  begin
    CloseWriter(True);
    ResetState;
  end;
  FHasVideo := True;
  FVCodec := Codec;
  FVWidth := Width;
  FVHeight := Height;
  FVExtra := Copy(Extradata);
  NoteFirstFormat;
end;

procedure TRecordingSink.OnAudioFormat(Codec: TAudioCodec; SampleRate: Cardinal;
  Channels: Byte; const Extradata: TBytes);
begin
  if FOpen then Exit; // arquivo já aberto: trilha de áudio não entra mais
  FHasAudio := True;
  FACodec := Codec;
  FARate := SampleRate;
  FAChannels := Channels;
  FAExtra := Copy(Extradata);
  NoteFirstFormat;
end;

procedure TRecordingSink.OnSample(const Sample: TSample);
begin
  if not FOpen then
  begin
    // sem formato de vídeo ainda não há o que gravar
    if not FHasVideo then Exit;
    HoldSample(Sample);
    if not ReadyToOpen then Exit;
    OpenWriter;
    FlushPending;
    Exit;
  end;
  if (Sample.Kind = tkAudio) and (not FRecordAudio) then Exit;
  FBuilder.AddSample(Sample, FClock.NowUtcMs, FClock.MonotonicMs);
  // Rotação que não conseguiu abrir o arquivo novo (disco cheio, pasta sumiu):
  // agora que o AddSample retornou, dá para desmontar e tentar de novo no
  // próximo sample. Os formatos anunciados ficam, então reabre sozinho.
  if FOpen and (FWriter = nil) then
    CloseWriter(True);
end;

procedure TRecordingSink.OnStreamStopped;
begin
  CloseWriter(True);
  // próxima conexão do supervisor começa um arquivo novo
  ResetState;
end;

end.
