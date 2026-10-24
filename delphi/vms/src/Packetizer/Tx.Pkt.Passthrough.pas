unit Tx.Pkt.Passthrough;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Base;

type
  TPassthroughAudioPacketizer = class(TBasePacketizer)
  public
    function Kind: TTrackKind; override;
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean); override;
  end;

implementation

function TPassthroughAudioPacketizer.Kind: TTrackKind;
begin
  Result := tkAudio;
end;

procedure TPassthroughAudioPacketizer.PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean);
var
  Offset, ChunkSize, MaxPayload: Integer;
  Chunk: TBytes;
  Ts: Cardinal;
  IsLast: Boolean;
begin
  if Length(Data) = 0 then Exit;
  MaxPayload := FMtu;
  if MaxPayload < 1 then Exit;
  Ts := Cardinal(Pts);
  if Length(Data) <= MaxPayload then
  begin
    EmitRtp(True, Ts, Data);
    Exit;
  end;
  Offset := 0;
  while Offset < Length(Data) do
  begin
    ChunkSize := Length(Data) - Offset;
    if ChunkSize > MaxPayload then ChunkSize := MaxPayload;
    SetLength(Chunk, ChunkSize);
    Move(Data[Offset], Chunk[0], ChunkSize);
    IsLast := (Offset + ChunkSize) >= Length(Data);
    EmitRtp(IsLast, Ts, Chunk);
    Inc(Offset, ChunkSize);
  end;
end;

end.
