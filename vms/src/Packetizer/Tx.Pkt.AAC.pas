unit Tx.Pkt.AAC;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Base;

type
  TAacPacketizer = class(TBasePacketizer)
  public
    function Kind: TTrackKind; override;
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean); override;
  end;

implementation

function TAacPacketizer.Kind: TTrackKind;
begin
  Result := tkAudio;
end;

procedure TAacPacketizer.PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean);
var
  AuSize: Integer;
  Payload: TBytes;
  AuHeader: Word;
begin
  AuSize := Length(Data);
  if AuSize = 0 then Exit;
  SetLength(Payload, 4 + AuSize);
  Payload[0] := $00;
  Payload[1] := $10;
  AuHeader := Word((AuSize and $1FFF) shl 3);
  Payload[2] := Byte((AuHeader shr 8) and $FF);
  Payload[3] := Byte(AuHeader and $FF);
  Move(Data[0], Payload[4], AuSize);
  EmitRtp(True, Cardinal(Pts), Payload);
end;

end.
