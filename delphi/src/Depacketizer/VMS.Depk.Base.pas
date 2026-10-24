unit VMS.Depk.Base;

interface

uses
  System.SysUtils,
  VMS.Domain.Types,
  VMS.Rtp.Packet,
  VMS.Depk.Intf;

type
  TBaseDepacketizer = class abstract(TInterfacedObject, IDepacketizer)
  strict protected
    FTrackId: TTrackId;
    FOnSample: TSampleEvent;
    procedure Emit(Kind: TTrackKind; Pts: Int64; Flags: TSampleFlags; const Data: TBytes);
  public
    constructor Create;
    function Kind: TTrackKind; virtual; abstract;
    procedure SetTrackId(Id: TTrackId);
    procedure SetOnSample(const Callback: TSampleEvent);
    procedure Feed(const Packet: TRtpPacket); virtual; abstract;
    procedure Flush; virtual;
    procedure Reset; virtual;
  end;

implementation

{ TBaseDepacketizer }

constructor TBaseDepacketizer.Create;
begin
  inherited Create;
  FTrackId := 0;
end;

procedure TBaseDepacketizer.SetTrackId(Id: TTrackId);
begin
  FTrackId := Id;
end;

procedure TBaseDepacketizer.SetOnSample(const Callback: TSampleEvent);
begin
  FOnSample := Callback;
end;

procedure TBaseDepacketizer.Emit(Kind: TTrackKind; Pts: Int64; Flags: TSampleFlags; const Data: TBytes);
var
  S: TSample;
begin
  if not Assigned(FOnSample) then Exit;
  if Length(Data) = 0 then Exit;
  S.Kind := Kind;
  S.TrackId := FTrackId;
  S.Pts := Pts;
  S.Flags := Flags;
  S.Data := Data;
  FOnSample(S);
end;

procedure TBaseDepacketizer.Flush;
begin
end;

procedure TBaseDepacketizer.Reset;
begin
end;

end.
