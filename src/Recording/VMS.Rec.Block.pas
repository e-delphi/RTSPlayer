unit VMS.Rec.Block;

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Rec.Format;

type
  TBlockClosedEvent = reference to procedure(const Block: TVmsBlock);

  TBlockBuilder = class
  strict private
    FSeq: Cardinal;
    FStartUnixMs: Int64;
    FStartMonotonicMs: Int64;
    // instante de parede do primeiro sample de cada trilha neste bloco (0 = a
    // trilha ainda não apareceu); é a âncora A/V que vai no bloco
    FFirstVideoMs: Int64;
    FFirstAudioMs: Int64;
    FSamples: array of TVmsSampleEntry;
    FSampleCount: Integer;
    FPayload: TBytes;
    FPayloadSize: Integer;
    FMaxSamples: Integer;
    FMaxDurationMs: Integer;
    FMaxSizeBytes: Integer;
    FOnClose: TBlockClosedEvent;
    procedure GrowPayload(Need: Integer);
    procedure StartNew(NowUnixMs, NowMonotonicMs: Int64);
    function ShouldClose(NowMonotonicMs: Int64): Boolean;
    procedure EmitBlock;
  public
    constructor Create(AMaxSamples, AMaxDurationMs, AMaxSizeBytes: Integer);
    procedure SetOnBlockClosed(const Callback: TBlockClosedEvent);
    procedure AddSample(const Sample: TSample; NowUnixMs, NowMonotonicMs: Int64);
    procedure ForceFlush(NowUnixMs, NowMonotonicMs: Int64);
    function IsEmpty: Boolean;
    function CurrentSeq: Cardinal;
  end;

implementation

const
  INITIAL_PAYLOAD_CAP = 64 * 1024;
  INITIAL_SAMPLES_CAP = 128;

{ TBlockBuilder }

constructor TBlockBuilder.Create(AMaxSamples, AMaxDurationMs, AMaxSizeBytes: Integer);
begin
  inherited Create;
  FSeq := 0;
  FMaxSamples := AMaxSamples;
  FMaxDurationMs := AMaxDurationMs;
  FMaxSizeBytes := AMaxSizeBytes;
  if FMaxSamples <= 0 then FMaxSamples := 256;
  if FMaxDurationMs <= 0 then FMaxDurationMs := 2000;
  if FMaxSizeBytes <= 0 then FMaxSizeBytes := 1024 * 1024;
  SetLength(FSamples, INITIAL_SAMPLES_CAP);
  SetLength(FPayload, INITIAL_PAYLOAD_CAP);
  FSampleCount := 0;
  FPayloadSize := 0;
  FStartUnixMs := 0;
  FStartMonotonicMs := 0;
end;

procedure TBlockBuilder.SetOnBlockClosed(const Callback: TBlockClosedEvent);
begin
  FOnClose := Callback;
end;

procedure TBlockBuilder.GrowPayload(Need: Integer);
var
  NewCap: Integer;
begin
  if Need <= Length(FPayload) then Exit;
  NewCap := Length(FPayload);
  while NewCap < Need do NewCap := NewCap * 2;
  SetLength(FPayload, NewCap);
end;

procedure TBlockBuilder.StartNew(NowUnixMs, NowMonotonicMs: Int64);
begin
  FSampleCount := 0;
  FPayloadSize := 0;
  FStartUnixMs := NowUnixMs;
  FStartMonotonicMs := NowMonotonicMs;
  FFirstVideoMs := 0;
  FFirstAudioMs := 0;
end;

function TBlockBuilder.ShouldClose(NowMonotonicMs: Int64): Boolean;
begin
  if FSampleCount = 0 then Exit(False);
  if FSampleCount >= FMaxSamples then Exit(True);
  if FPayloadSize >= FMaxSizeBytes then Exit(True);
  if (NowMonotonicMs - FStartMonotonicMs) >= FMaxDurationMs then Exit(True);
  Result := False;
end;

procedure TBlockBuilder.EmitBlock;
var
  Block: TVmsBlock;
  I: Integer;
begin
  if FSampleCount = 0 then Exit;
  Block.BlockSeq := FSeq;
  Block.StartUnixMs := FStartUnixMs;
  Block.VideoAnchorMs := FFirstVideoMs;
  Block.AudioAnchorMs := FFirstAudioMs;
  SetLength(Block.Samples, FSampleCount);
  for I := 0 to FSampleCount - 1 do
    Block.Samples[I] := FSamples[I];
  SetLength(Block.Payload, FPayloadSize);
  if FPayloadSize > 0 then
    Move(FPayload[0], Block.Payload[0], FPayloadSize);
  Inc(FSeq);
  FSampleCount := 0;
  FPayloadSize := 0;
  if Assigned(FOnClose) then
    FOnClose(Block);
end;

procedure TBlockBuilder.AddSample(const Sample: TSample; NowUnixMs, NowMonotonicMs: Int64);
var
  Entry: TVmsSampleEntry;
  DataSize: Integer;
begin
  DataSize := Length(Sample.Data);
  if DataSize = 0 then Exit;
  if FSampleCount = 0 then
    StartNew(NowUnixMs, NowMonotonicMs);

  if FSampleCount >= Length(FSamples) then
    SetLength(FSamples, Length(FSamples) * 2);
  GrowPayload(FPayloadSize + DataSize);

  // Primeiro sample de cada trilha no bloco: guarda o instante de parede. É o
  // único ponto do sistema que sabe QUANDO cada trilha começou aqui — depois só
  // restam PTS em bases diferentes.
  if Sample.Kind = tkVideo then
  begin
    if FFirstVideoMs = 0 then FFirstVideoMs := NowUnixMs;
  end
  else
    if FFirstAudioMs = 0 then FFirstAudioMs := NowUnixMs;

  Entry.TrackId := Sample.TrackId;
  Entry.FlagsByte := FlagsToByte(Sample.Flags);
  Entry.Pts := Sample.Pts;
  Entry.PayloadOffset := Cardinal(FPayloadSize);
  Entry.PayloadSize := Cardinal(DataSize);
  if Sample.Kind = tkVideo then
    Entry.TrackId := Sample.TrackId
  else
    Entry.TrackId := Sample.TrackId;

  FSamples[FSampleCount] := Entry;
  Inc(FSampleCount);
  Move(Sample.Data[0], FPayload[FPayloadSize], DataSize);
  Inc(FPayloadSize, DataSize);

  if ShouldClose(NowMonotonicMs) then
    EmitBlock;
end;

procedure TBlockBuilder.ForceFlush(NowUnixMs, NowMonotonicMs: Int64);
begin
  if FSampleCount > 0 then
    EmitBlock;
end;

function TBlockBuilder.IsEmpty: Boolean;
begin
  Result := FSampleCount = 0;
end;

function TBlockBuilder.CurrentSeq: Cardinal;
begin
  Result := FSeq;
end;

end.
