unit VMS.Sdp.Types;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  VMS.Domain.Types;

type
  TSdpMediaKind = (smkUnknown, smkVideo, smkAudio);

  TSdpMedia = class
  strict private
    FKind: TSdpMediaKind;
    FProto: string;
    FPort: Word;
    FPayloadType: Integer;
    FRtpmap: string;
    FFmtp: string;
    FControl: string;
    FConnectionAddress: string;
    FExtraAttributes: TDictionary<string, string>;
  public
    constructor Create;
    destructor Destroy; override;
    property Kind: TSdpMediaKind read FKind write FKind;
    property Proto: string read FProto write FProto;
    property Port: Word read FPort write FPort;
    property PayloadType: Integer read FPayloadType write FPayloadType;
    property Rtpmap: string read FRtpmap write FRtpmap;
    property Fmtp: string read FFmtp write FFmtp;
    property Control: string read FControl write FControl;
    property ConnectionAddress: string read FConnectionAddress write FConnectionAddress;
    property ExtraAttributes: TDictionary<string, string> read FExtraAttributes;
  end;

  TSdpSession = class
  strict private
    FVersion: Integer;
    FOrigin: string;
    FSessionName: string;
    FConnectionAddress: string;
    FSessionControl: string;
    FMedia: TObjectList<TSdpMedia>;
  public
    constructor Create;
    destructor Destroy; override;
    function FindFirst(Kind: TSdpMediaKind): TSdpMedia;
    property Version: Integer read FVersion write FVersion;
    property Origin: string read FOrigin write FOrigin;
    property SessionName: string read FSessionName write FSessionName;
    property ConnectionAddress: string read FConnectionAddress write FConnectionAddress;
    property SessionControl: string read FSessionControl write FSessionControl;
    property Media: TObjectList<TSdpMedia> read FMedia;
  end;

implementation

{ TSdpMedia }

constructor TSdpMedia.Create;
begin
  inherited Create;
  FExtraAttributes := TDictionary<string, string>.Create;
  FPayloadType := -1;
end;

destructor TSdpMedia.Destroy;
begin
  FExtraAttributes.Free;
  inherited;
end;

{ TSdpSession }

constructor TSdpSession.Create;
begin
  inherited Create;
  FMedia := TObjectList<TSdpMedia>.Create(True);
end;

destructor TSdpSession.Destroy;
begin
  FMedia.Free;
  inherited;
end;

function TSdpSession.FindFirst(Kind: TSdpMediaKind): TSdpMedia;
var
  I: Integer;
begin
  for I := 0 to FMedia.Count - 1 do
    if FMedia[I].Kind = Kind then Exit(FMedia[I]);
  Result := nil;
end;

end.
