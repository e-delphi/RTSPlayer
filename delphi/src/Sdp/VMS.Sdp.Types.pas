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
    FSourceIsLive: Boolean;
    FMediaStartMs: Int64;
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
    // A mídia vem da câmera agora, ou de gravação? Só o vmsserver responde isto
    // (a=x-vms-source); câmera de verdade não diz nada, e aí o padrão é True —
    // quem fala RTSP direto com a câmera está sempre vendo o agora.
    property SourceIsLive: Boolean read FSourceIsLive write FSourceIsLive;
    // Sendo gravação, de quando é a primeira imagem. 0 = não informado.
    property MediaStartMs: Int64 read FMediaStartMs write FMediaStartMs;
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
  FSourceIsLive := True;   // ver o comentário da propriedade: o padrão é "agora"
  FMediaStartMs := 0;
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

