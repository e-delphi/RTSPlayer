unit Tx.Pkt.Base;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  Tx.Pkt.Intf,
  Tx.Pkt.RtpBuilder;

type
  TBasePacketizer = class abstract(TInterfacedObject, IPacketizer)
  strict protected
    FPayloadType: Byte;
    FSsrc: Cardinal;
    FMtu: Word;
    FSeq: Word;
    FOnRtpReady: TRtpReadyEvent;
    procedure EmitRtp(Marker: Boolean; Timestamp: Cardinal; const Payload: TBytes);
  public
    constructor Create;
    function Kind: TTrackKind; virtual; abstract;
    procedure SetPayloadType(Pt: Byte);
    procedure SetSsrc(Ssrc: Cardinal);
    procedure SetMtu(Mtu: Word);
    procedure SetOnRtpReady(const Callback: TRtpReadyEvent);
    procedure PushSample(Pts: Int64; const Data: TBytes; IsKeyframe: Boolean); virtual; abstract;
  end;

implementation

constructor TBasePacketizer.Create;
begin
  inherited Create;
  FMtu := TX_DEFAULT_MTU;
  FSeq := Word(Random($FFFF));
  FSsrc := Cardinal(Random($7FFFFFFF));
end;

procedure TBasePacketizer.SetPayloadType(Pt: Byte);
begin
  FPayloadType := Pt;
end;

procedure TBasePacketizer.SetSsrc(Ssrc: Cardinal);
begin
  FSsrc := Ssrc;
end;

procedure TBasePacketizer.SetMtu(Mtu: Word);
begin
  if Mtu > 0 then FMtu := Mtu;
end;

procedure TBasePacketizer.SetOnRtpReady(const Callback: TRtpReadyEvent);
begin
  FOnRtpReady := Callback;
end;

procedure TBasePacketizer.EmitRtp(Marker: Boolean; Timestamp: Cardinal; const Payload: TBytes);
var
  Pkt: TRtpOutPacket;
  Bytes: TBytes;
begin
  if not Assigned(FOnRtpReady) then Exit;
  Pkt.Version := 2;
  Pkt.Padding := False;
  Pkt.Extension := False;
  Pkt.CC := 0;
  Pkt.Marker := Marker;
  Pkt.PayloadType := FPayloadType;
  Pkt.SequenceNumber := FSeq;
  Pkt.Timestamp := Timestamp;
  Pkt.Ssrc := FSsrc;
  Pkt.Payload := Payload;
  Bytes := SerializeRtp(Pkt);
  Inc(FSeq);
  FOnRtpReady(Bytes);
end;

end.
