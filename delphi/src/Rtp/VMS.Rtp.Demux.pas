unit VMS.Rtp.Demux;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Rtp.Packet;

type
  TRtpPacketHandler = reference to procedure(const Packet: TRtpPacket);

  TRtpDemuxRoute = record
    PayloadType: Byte;
    InterleavedChannel: ShortInt;
    Kind: TTrackKind;
    Handler: TRtpPacketHandler;
  end;

  TRtpDemux = class
  strict private
    FRoutes: TList<TRtpDemuxRoute>;
    function FindByChannel(Channel: Byte; out Idx: Integer): Boolean;
    function FindByPayloadType(Pt: Byte; out Idx: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterRoute(Kind: TTrackKind; PayloadType: Byte;
                            InterleavedChannel: ShortInt;
                            const Handler: TRtpPacketHandler);
    procedure DispatchInterleaved(Channel: Byte; const Data: TBytes);
    procedure DispatchUdp(Kind: TTrackKind; const Data: TBytes);
    function ChannelToKind(Channel: Byte; out Kind: TTrackKind): Boolean;
  end;

implementation

{ TRtpDemux }

constructor TRtpDemux.Create;
begin
  inherited Create;
  FRoutes := TList<TRtpDemuxRoute>.Create;
end;

destructor TRtpDemux.Destroy;
begin
  FRoutes.Free;
  inherited;
end;

procedure TRtpDemux.RegisterRoute(Kind: TTrackKind; PayloadType: Byte;
  InterleavedChannel: ShortInt; const Handler: TRtpPacketHandler);
var
  R: TRtpDemuxRoute;
begin
  R.Kind := Kind;
  R.PayloadType := PayloadType;
  R.InterleavedChannel := InterleavedChannel;
  R.Handler := Handler;
  FRoutes.Add(R);
end;

function TRtpDemux.FindByChannel(Channel: Byte; out Idx: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to FRoutes.Count - 1 do
    if (FRoutes[I].InterleavedChannel >= 0) and (Byte(FRoutes[I].InterleavedChannel) = Channel) then
    begin
      Idx := I;
      Exit(True);
    end;
  Idx := -1;
  Result := False;
end;

function TRtpDemux.FindByPayloadType(Pt: Byte; out Idx: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to FRoutes.Count - 1 do
    if FRoutes[I].PayloadType = Pt then
    begin
      Idx := I;
      Exit(True);
    end;
  Idx := -1;
  Result := False;
end;

function TRtpDemux.ChannelToKind(Channel: Byte; out Kind: TTrackKind): Boolean;
var
  Idx: Integer;
begin
  Result := FindByChannel(Channel, Idx);
  if Result then
    Kind := FRoutes[Idx].Kind;
end;

procedure TRtpDemux.DispatchInterleaved(Channel: Byte; const Data: TBytes);
var
  Idx: Integer;
  Packet: TRtpPacket;
begin
  if (Channel and 1) = 1 then Exit;
  if not FindByChannel(Channel, Idx) then Exit;
  if not ParseRtpPacket(Data, Length(Data), Packet) then Exit;
  if Assigned(FRoutes[Idx].Handler) then
    FRoutes[Idx].Handler(Packet);
end;

procedure TRtpDemux.DispatchUdp(Kind: TTrackKind; const Data: TBytes);
var
  Packet: TRtpPacket;
  I: Integer;
begin
  if not ParseRtpPacket(Data, Length(Data), Packet) then Exit;
  if FindByPayloadType(Packet.PayloadType, I) then
  begin
    if Assigned(FRoutes[I].Handler) then
      FRoutes[I].Handler(Packet);
    Exit;
  end;
  for I := 0 to FRoutes.Count - 1 do
    if FRoutes[I].Kind = Kind then
    begin
      if Assigned(FRoutes[I].Handler) then
        FRoutes[I].Handler(Packet);
      Exit;
    end;
end;

end.
