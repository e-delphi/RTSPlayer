unit Vms.Thumb.Service;

// Orquestra as quatro peças: cache -> keyframe -> decodificador -> encoder.
//
// Não conhece nenhuma delas por dentro. Recebe as três interfaces prontas no
// construtor, o que é o que permite testá-lo com dublês e o que impede que o
// FFmpeg ou a VCL vazem para cima daqui.
//
// Duas decisões de comportamento que valem estar num lugar só:
//
//   * Um minuto que já falhou não é tentado de novo em seguida. Sem isso, uma
//     faixa de vinte miniaturas num trecho sem gravação viraria vinte
//     decodificações fracassadas por vista, e a barra ficaria travando de
//     propósito.
//   * A geração é serializada. O decodificador é caro e tem estado; deixar
//     várias conexões decodificarem ao mesmo tempo gastaria CPU do servidor de
//     gravação para entregar a mesma imagem duas vezes.

interface

uses
  System.SysUtils,
  System.Classes,        // TThread.GetTickCount64, no controle de falhas
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Types,
  VMS.Domain.Logging,
  Vms.Thumb.Intf,
  Vms.Thumb.Cache;

type
  TThumbService = class(TInterfacedObject, IThumbSource)
  strict private
    FKeyframes: IKeyframeSource;
    FGrabber: IFrameGrabber;
    FEncoder: IImageEncoder;
    FCache: TThumbDiskCache;
    FLogger: ILogger;
    FWidth, FHeight: Integer;
    FLock: TCriticalSection;
    // minutos que não deram imagem, para não insistir a cada vista da barra
    FMisses: TDictionary<string, Int64>;
    procedure Passo(const Camera: string; MinuteMs: Int64; const Msg: string);
    function MissKey(const Camera: string; MinuteMs: Int64): string;
    function RecentMiss(const Key: string): Boolean;
    procedure NoteMiss(const Key: string);
    function Generate(const Camera: string; MinuteMs: Int64;
                      out Data: TBytes; out ActualMs: Int64): Boolean;
  public
    // AWidth/AHeight são o teto da imagem; a proporção do vídeo é preservada.
    constructor Create(const AKeyframes: IKeyframeSource;
                       const AGrabber: IFrameGrabber;
                       const AEncoder: IImageEncoder;
                       ACache: TThumbDiskCache;
                       AWidth, AHeight: Integer; const ALogger: ILogger);
    destructor Destroy; override;
    { IThumbSource }
    function Get(const Camera: string; Ms: Int64; out Data: TBytes;
                 out ActualMs: Int64): Boolean;
    function ContentType: string;
    function Available: Boolean;
  end;

  // O que a composição liga quando não há como decodificar nesta máquina.
  // Responde "não tenho" a tudo, sem erro: a barra fica sem miniatura e o resto
  // do servidor não sabe da diferença.
  TNullThumbSource = class(TInterfacedObject, IThumbSource)
  public
    function Get(const Camera: string; Ms: Int64; out Data: TBytes;
                 out ActualMs: Int64): Boolean;
    function ContentType: string;
    function Available: Boolean;
  end;

implementation

const
  // Quanto tempo um minuto sem imagem fica marcado como sem imagem. Curto o
  // bastante para a gravação que chegou depois aparecer sozinha.
  MISS_TTL_MS = 60000;

{ TNullThumbSource }

function TNullThumbSource.Get(const Camera: string; Ms: Int64;
  out Data: TBytes; out ActualMs: Int64): Boolean;
begin
  Data := nil;
  ActualMs := 0;
  Result := False;
end;

function TNullThumbSource.ContentType: string;
begin
  Result := 'image/jpeg';
end;

function TNullThumbSource.Available: Boolean;
begin
  Result := False;
end;

{ TThumbService }

constructor TThumbService.Create(const AKeyframes: IKeyframeSource;
  const AGrabber: IFrameGrabber; const AEncoder: IImageEncoder;
  ACache: TThumbDiskCache; AWidth, AHeight: Integer; const ALogger: ILogger);
begin
  inherited Create;
  FKeyframes := AKeyframes;
  FGrabber := AGrabber;
  FEncoder := AEncoder;
  FCache := ACache;
  FWidth := AWidth;
  FHeight := AHeight;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
  FMisses := TDictionary<string, Int64>.Create;
end;

destructor TThumbService.Destroy;
begin
  FMisses.Free;
  FLock.Free;
  FCache.Free;
  inherited;
end;

function TThumbService.Available: Boolean;
begin
  Result := (FGrabber <> nil) and FGrabber.Available and (FEncoder <> nil);
end;

function TThumbService.ContentType: string;
begin
  if FEncoder <> nil then
    Result := FEncoder.ContentType
  else
    Result := 'image/jpeg';
end;

function TThumbService.MissKey(const Camera: string; MinuteMs: Int64): string;
begin
  Result := LowerCase(Camera) + '|' + IntToStr(MinuteMs);
end;

function TThumbService.RecentMiss(const Key: string): Boolean;
var
  When: Int64;
begin
  Result := False;
  FLock.Enter;
  try
    if FMisses.TryGetValue(Key, When) then
      Result := (TThread.GetTickCount64 - UInt64(When)) < MISS_TTL_MS;
  finally
    FLock.Leave;
  end;
end;

procedure TThumbService.NoteMiss(const Key: string);
begin
  FLock.Enter;
  try
    FMisses.AddOrSetValue(Key, Int64(TThread.GetTickCount64));
    // Não deixa a lista de falhas virar um vazamento lento: varrer o dia inteiro
    // de uma câmera sem gravação são 1.440 chaves.
    if FMisses.Count > 5000 then FMisses.Clear;
  finally
    FLock.Leave;
  end;
end;

// Cada etapa que falha diz o que falhou. Sem isto, uma miniatura que não sai é
// um 404 mudo: não dá para saber se faltou gravação, se o decodificador não
// abriu ou se o JPEG não fechou — que foi exatamente o que aconteceu na
// primeira vez que isto rodou.
procedure TThumbService.Passo(const Camera: string; MinuteMs: Int64;
  const Msg: string);
begin
  if FLogger <> nil then
    FLogger.Debug('thumb', Format('%s %d: %s', [Camera, MinuteMs, Msg]));
end;

function TThumbService.Generate(const Camera: string; MinuteMs: Int64;
  out Data: TBytes; out ActualMs: Int64): Boolean;
var
  AU, Extra: TBytes;
  Codec: TVideoCodec;
  Img: TRgbImage;
begin
  Result := False;
  Data := nil;
  ActualMs := 0;
  if not FKeyframes.Grab(Camera, MinuteMs, AU, Extra, Codec, ActualMs) then
  begin
    Passo(Camera, MinuteMs, 'sem keyframe na gravacao para este instante');
    Exit;
  end;
  if Length(AU) = 0 then
  begin
    Passo(Camera, MinuteMs, 'keyframe vazio');
    Exit;
  end;
  if not FGrabber.Decode(AU, Extra, Codec, FWidth, FHeight, Img) then
  begin
    Passo(Camera, MinuteMs, Format('decodificacao falhou (codec %d, %d bytes, ' +
      'extradata %d)', [Ord(Codec), Length(AU), Length(Extra)]));
    Exit;
  end;
  if not Img.IsValid then
  begin
    Passo(Camera, MinuteMs, 'decodificou mas a imagem saiu invalida');
    Exit;
  end;
  Result := FEncoder.Encode(Img, Data) and (Length(Data) > 0);
  if not Result then
    Passo(Camera, MinuteMs, Format('encode falhou (%dx%d)', [Img.Width, Img.Height]))
  else
    Passo(Camera, MinuteMs, Format('gerada %dx%d, %d bytes',
      [Img.Width, Img.Height, Length(Data)]));
end;

function TThumbService.Get(const Camera: string; Ms: Int64; out Data: TBytes;
  out ActualMs: Int64): Boolean;
var
  MinuteMs: Int64;
  Key: string;
begin
  Data := nil;
  MinuteMs := TThumbDiskCache.MinuteOf(Ms);
  ActualMs := MinuteMs;
  Result := False;
  if Camera = '' then Exit;

  // 1. Já está no disco: é o caminho de quase toda requisição.
  if FCache.TryRead(Camera, MinuteMs, Data) then Exit(True);
  if not Available then Exit;

  Key := MissKey(Camera, MinuteMs);
  if RecentMiss(Key) then Exit;

  // 2. Uma geração por vez. Duas conexões pedindo o mesmo minuto: a segunda
  //    espera e acha pronto no disco.
  FLock.Enter;
  try
    if FCache.TryRead(Camera, MinuteMs, Data) then Exit(True);
    try
      Result := Generate(Camera, MinuteMs, Data, ActualMs);
    except
      on E: Exception do
      begin
        Result := False;
        if FLogger <> nil then
          FLogger.Warn('thumb', Format('%s %d: %s', [Camera, MinuteMs, E.Message]));
      end;
    end;
  finally
    FLock.Leave;
  end;

  if Result then
    FCache.Write(Camera, MinuteMs, Data)
  else
  begin
    NoteMiss(Key);
    ActualMs := MinuteMs;
  end;
end;

end.
