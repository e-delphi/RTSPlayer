unit VMS.Domain.Types;

interface

uses
  System.SysUtils,
  System.Classes;

type
  TVideoCodec = (
    vcNone   = 0,
    vcH264   = 1,
    vcH265   = 2,
    vcMJPEG  = 3
  );

  TAudioCodec = (
    acNone     = 0,
    acPCM      = 1,
    acAAC      = 2,
    acG711U    = 3,
    acG711A    = 4,
    acG726_16  = 5,
    acG726_24  = 6,
    acG726_32  = 7,
    acG726_40  = 8
  );

  TTrackKind = (tkVideo, tkAudio);

  TTrackId = type Byte;

  TSampleFlag = (
    sfKeyframe,
    sfStartOfFrame,
    sfEndOfFrame
  );
  TSampleFlags = set of TSampleFlag;

  TSample = record
    Kind: TTrackKind;
    TrackId: TTrackId;
    Pts: Int64;
    Flags: TSampleFlags;
    Data: TBytes;
  end;

  TVideoTrackInfo = record
    Codec: TVideoCodec;
    Timescale: Cardinal;
    Width: Word;
    Height: Word;
    Extradata: TBytes;
  end;

  TAudioTrackInfo = record
    Codec: TAudioCodec;
    Timescale: Cardinal;
    SampleRate: Cardinal;
    Channels: Byte;
    BitsPerSample: Byte;
    Extradata: TBytes;
  end;

  TTransportKind = (txTcp, txUdp);
  TTransportList = array of TTransportKind;

  // Um jeito de chegar na MESMA câmera. A mesma câmera costuma ter mais de um:
  // o IP dela na LAN, o servidor que a republica na rede local, e o mesmo
  // servidor pela tailnet. Em vez de três câmeras iguais no cadastro, uma
  // câmera com três endpoints em ordem de prioridade — quem conecta testa qual
  // responde (ver VMS.Net.Probe).
  TCameraEndpoint = record
    Name: string;          // rótulo só para a tela: 'Local', 'Online', 'Direto'
    Url: string;
    User: string;
    Password: string;
    Transports: TArray<TTransportKind>;
    UsesTailscale: Boolean;
  end;
  TCameraEndpoints = TArray<TCameraEndpoint>;

  EVmsError         = class(Exception);
  EVmsConfigError   = class(EVmsError);
  EVmsProtocolError = class(EVmsError);
  EVmsIoError       = class(EVmsError);
  EVmsAuthError     = class(EVmsError);
  EVmsTimeoutError  = class(EVmsError);

function VideoCodecToStr(C: TVideoCodec): string;
function AudioCodecToStr(C: TAudioCodec): string;
function TransportKindToStr(T: TTransportKind): string;
function ParseTransportKind(const S: string; out T: TTransportKind): Boolean;

implementation

function VideoCodecToStr(C: TVideoCodec): string;
begin
  case C of
    vcH264:  Result := 'H264';
    vcH265:  Result := 'H265';
    vcMJPEG: Result := 'MJPEG';
  else
    Result := 'None';
  end;
end;

function AudioCodecToStr(C: TAudioCodec): string;
begin
  case C of
    acPCM:     Result := 'PCM';
    acAAC:     Result := 'AAC';
    acG711U:   Result := 'G711U';
    acG711A:   Result := 'G711A';
    acG726_16: Result := 'G726-16';
    acG726_24: Result := 'G726-24';
    acG726_32: Result := 'G726-32';
    acG726_40: Result := 'G726-40';
  else
    Result := 'None';
  end;
end;

function TransportKindToStr(T: TTransportKind): string;
begin
  case T of
    txTcp: Result := 'tcp';
    txUdp: Result := 'udp';
  else
    Result := '?';
  end;
end;

function ParseTransportKind(const S: string; out T: TTransportKind): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if L = 'tcp' then
  begin
    T := txTcp;
    Exit(True);
  end;
  if L = 'udp' then
  begin
    T := txUdp;
    Exit(True);
  end;
  Result := False;
end;

end.


