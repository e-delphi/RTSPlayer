unit VMS.Sdp.Parser;

interface

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.NetEncoding,
  VMS.Domain.Types,
  VMS.Sdp.Types;

type
  TSdpCodecInfo = record
    VideoCodec: TVideoCodec;
    AudioCodec: TAudioCodec;
    Timescale: Cardinal;
    SampleRate: Cardinal;
    Channels: Byte;
    Extradata: TBytes;
    Width, Height: Word;
  end;

function ParseSdp(const Text: string): TSdpSession;

function BuildAbsoluteControl(const BaseUri, Control: string): string;

function ExtractCodecFromMedia(Media: TSdpMedia; out Info: TSdpCodecInfo): Boolean;

function DecodeBase64ToBytes(const S: string): TBytes;

implementation

function DecodeBase64ToBytes(const S: string): TBytes;
var
  Clean: string;
begin
  Clean := StringReplace(Trim(S), #13, '', [rfReplaceAll]);
  Clean := StringReplace(Clean, #10, '', [rfReplaceAll]);
  Clean := StringReplace(Clean, ' ', '', [rfReplaceAll]);
  if Clean = '' then Exit(nil);
  try
    Result := TNetEncoding.Base64.DecodeStringToBytes(Clean);
  except
    Result := nil;
  end;
end;

function SplitFirst(const S: string; Delim: Char; out Left, Right: string): Boolean;
var
  P: Integer;
begin
  P := Pos(Delim, S);
  if P < 1 then
  begin
    Left := S;
    Right := '';
    Exit(False);
  end;
  Left := Copy(S, 1, P - 1);
  Right := Copy(S, P + 1, MaxInt);
  Result := True;
end;

function NormalizeNewlines(const S: string): string;
begin
  Result := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
end;

procedure ParseMediaLine(const Value: string; Media: TSdpMedia);
var
  Parts: TArray<string>;
  PType: string;
  PT: Integer;
begin
  Parts := Value.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) < 4 then Exit;
  if SameText(Parts[0], 'video') then
    Media.Kind := smkVideo
  else if SameText(Parts[0], 'audio') then
    Media.Kind := smkAudio
  else
    Media.Kind := smkUnknown;
  Media.Port := StrToIntDef(Parts[1], 0);
  Media.Proto := Parts[2];
  PType := Parts[3];
  if TryStrToInt(PType, PT) then
    Media.PayloadType := PT;
end;

procedure ParseAttribute(const Value: string; Media: TSdpMedia; Session: TSdpSession);
var
  Key, Rest: string;
begin
  if not SplitFirst(Value, ':', Key, Rest) then
  begin
    Key := Value;
    Rest := '';
  end;
  Key := Trim(Key);
  Rest := Trim(Rest);
  if Media <> nil then
  begin
    if SameText(Key, 'rtpmap') then
      Media.Rtpmap := Rest
    else if SameText(Key, 'fmtp') then
      Media.Fmtp := Rest
    else if SameText(Key, 'control') then
      Media.Control := Rest
    else
      Media.ExtraAttributes.AddOrSetValue(LowerCase(Key), Rest);
  end
  else
  begin
    if SameText(Key, 'control') then
      Session.SessionControl := Rest
    // Extensões do vmsserver: dizem se o que vem é a câmera ou o arquivo dela.
    // Câmera comum não manda nada disto, e o padrão de TSdpSession cobre isso.
    else if SameText(Key, 'x-vms-source') then
      Session.SourceIsLive := not SameText(Trim(Rest), 'file')
    else if SameText(Key, 'x-vms-media-start') then
      Session.MediaStartMs := StrToInt64Def(Trim(Rest), 0);
  end;
end;

function ParseSdp(const Text: string): TSdpSession;
var
  Lines: TStringList;
  I: Integer;
  Line, Value: string;
  Field: Char;
  CurrentMedia: TSdpMedia;
begin
  Result := TSdpSession.Create;
  CurrentMedia := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := NormalizeNewlines(Text);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Length(Line) < 2 then Continue;
      if Line[2] <> '=' then Continue;
      Field := Line[1];
      Value := Copy(Line, 3, MaxInt);
      case Field of
        'v': Result.Version := StrToIntDef(Trim(Value), 0);
        'o': Result.Origin := Value;
        's': Result.SessionName := Value;
        'c':
          if CurrentMedia <> nil then
            CurrentMedia.ConnectionAddress := Value
          else
            Result.ConnectionAddress := Value;
        'm':
          begin
            CurrentMedia := TSdpMedia.Create;
            Result.Media.Add(CurrentMedia);
            ParseMediaLine(Value, CurrentMedia);
          end;
        'a':
          ParseAttribute(Value, CurrentMedia, Result);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function BuildAbsoluteControl(const BaseUri, Control: string): string;
var
  C: string;
begin
  C := Trim(Control);
  if C = '' then Exit(BaseUri);
  if (Pos('rtsp://', LowerCase(C)) = 1) or (Pos('rtsps://', LowerCase(C)) = 1) then
    Exit(C);
  if C = '*' then Exit(BaseUri);
  if (BaseUri <> '') and (BaseUri[Length(BaseUri)] = '/') then
    Result := BaseUri + C
  else
    Result := BaseUri + '/' + C;
end;

function ParseRtpmap(const S: string; out Encoding: string; out Clock: Cardinal; out Channels: Byte): Boolean;
var
  EncParts: TArray<string>;
  P: Integer;
  Rest: string;
begin
  Result := False;
  Channels := 0;
  Clock := 0;
  Encoding := '';
  P := Pos(' ', S);
  if P < 1 then Exit;
  Rest := Trim(Copy(S, P + 1, MaxInt));
  EncParts := Rest.Split(['/'], TStringSplitOptions.ExcludeEmpty);
  if Length(EncParts) < 2 then Exit;
  Encoding := EncParts[0];
  Clock := StrToIntDef(EncParts[1], 0);
  if Length(EncParts) >= 3 then
    Channels := StrToIntDef(EncParts[2], 1)
  else
    Channels := 1;
  Result := Clock > 0;
end;

function GetFmtpParam(const Fmtp, Key: string; out Value: string): Boolean;
var
  Body: TArray<string>;
  P: Integer;
  Item, K, V: string;
  Idx: Integer;
begin
  Result := False;
  Value := '';
  P := Pos(' ', Fmtp);
  if P < 1 then
    Body := Fmtp.Split([';'], TStringSplitOptions.ExcludeEmpty)
  else
    Body := Trim(Copy(Fmtp, P + 1, MaxInt)).Split([';'], TStringSplitOptions.ExcludeEmpty);
  for Idx := 0 to High(Body) do
  begin
    Item := Trim(Body[Idx]);
    P := Pos('=', Item);
    if P < 1 then Continue;
    K := Trim(Copy(Item, 1, P - 1));
    V := Trim(Copy(Item, P + 1, MaxInt));
    if SameText(K, Key) then
    begin
      Value := V;
      Exit(True);
    end;
  end;
end;

procedure AppendAnnexBNal(var Buf: TBytes; const Nal: TBytes);
var
  Start: Integer;
begin
  if Length(Nal) = 0 then Exit;
  Start := Length(Buf);
  SetLength(Buf, Start + 4 + Length(Nal));
  Buf[Start]     := $00;
  Buf[Start + 1] := $00;
  Buf[Start + 2] := $00;
  Buf[Start + 3] := $01;
  Move(Nal[0], Buf[Start + 4], Length(Nal));
end;

function BuildH264Extradata(const SpropParamSets: string): TBytes;
var
  Items: TArray<string>;
  I: Integer;
  Nal: TBytes;
begin
  Result := nil;
  if SpropParamSets = '' then Exit;
  Items := SpropParamSets.Split([','], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to High(Items) do
  begin
    Nal := DecodeBase64ToBytes(Trim(Items[I]));
    AppendAnnexBNal(Result, Nal);
  end;
end;

function BuildH265Extradata(const Vps, Sps, Pps: string): TBytes;
var
  Nal: TBytes;
  procedure AddAll(const S: string);
  var
    Items: TArray<string>;
    K: Integer;
  begin
    if S = '' then Exit;
    Items := S.Split([','], TStringSplitOptions.ExcludeEmpty);
    for K := 0 to High(Items) do
    begin
      Nal := DecodeBase64ToBytes(Trim(Items[K]));
      AppendAnnexBNal(Result, Nal);
    end;
  end;
begin
  Result := nil;
  AddAll(Vps);
  AddAll(Sps);
  AddAll(Pps);
end;

function HexCharToInt(C: Char; out V: Integer): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': V := Ord(C) - Ord('0');
    'a'..'f': V := Ord(C) - Ord('a') + 10;
    'A'..'F': V := Ord(C) - Ord('A') + 10;
  else
    V := 0;
    Result := False;
  end;
end;

function HexToBytes(const Hex: string): TBytes;
var
  S: string;
  I, H, L: Integer;
begin
  S := StringReplace(Hex, ' ', '', [rfReplaceAll]);
  if Odd(Length(S)) then Exit(nil);
  SetLength(Result, Length(S) div 2);
  for I := 0 to (Length(S) div 2) - 1 do
  begin
    if not HexCharToInt(S[1 + I * 2],     H) then Exit(nil);
    if not HexCharToInt(S[1 + I * 2 + 1], L) then Exit(nil);
    Result[I] := Byte((H shl 4) or L);
  end;
end;

function ExtractCodecFromMedia(Media: TSdpMedia; out Info: TSdpCodecInfo): Boolean;
var
  Encoding: string;
  Clock: Cardinal;
  Channels: Byte;
  S: string;
  Vps, Sps, Pps, Sprop: string;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);

  if not ParseRtpmap(Media.Rtpmap, Encoding, Clock, Channels) then
  begin
    if Media.Kind = smkAudio then
    begin
      case Media.PayloadType of
        0:
          begin
            Info.AudioCodec := acG711U;
            Info.Timescale := 8000;
            Info.SampleRate := 8000;
            Info.Channels := 1;
            Exit(True);
          end;
        8:
          begin
            Info.AudioCodec := acG711A;
            Info.Timescale := 8000;
            Info.SampleRate := 8000;
            Info.Channels := 1;
            Exit(True);
          end;
      end;
    end;
    Exit(False);
  end;

  Info.Timescale := Clock;
  Info.SampleRate := Clock;
  Info.Channels := Channels;

  if Media.Kind = smkVideo then
  begin
    if SameText(Encoding, 'H264') then
    begin
      Info.VideoCodec := vcH264;
      if GetFmtpParam(Media.Fmtp, 'sprop-parameter-sets', Sprop) then
        Info.Extradata := BuildH264Extradata(Sprop);
      Exit(True);
    end;
    if SameText(Encoding, 'H265') or SameText(Encoding, 'HEVC') then
    begin
      Info.VideoCodec := vcH265;
      GetFmtpParam(Media.Fmtp, 'sprop-vps', Vps);
      GetFmtpParam(Media.Fmtp, 'sprop-sps', Sps);
      GetFmtpParam(Media.Fmtp, 'sprop-pps', Pps);
      Info.Extradata := BuildH265Extradata(Vps, Sps, Pps);
      Exit(True);
    end;
    if SameText(Encoding, 'JPEG') or SameText(Encoding, 'MJPEG') then
    begin
      Info.VideoCodec := vcMJPEG;
      Exit(True);
    end;
    Exit(False);
  end;

  if Media.Kind = smkAudio then
  begin
    if SameText(Encoding, 'PCMU') then begin Info.AudioCodec := acG711U; Exit(True); end;
    if SameText(Encoding, 'PCMA') then begin Info.AudioCodec := acG711A; Exit(True); end;
    if SameText(Encoding, 'L16')  then begin Info.AudioCodec := acPCM;   Exit(True); end;
    if SameText(Encoding, 'MPEG4-GENERIC') or SameText(Encoding, 'mpeg4-generic') then
    begin
      Info.AudioCodec := acAAC;
      if GetFmtpParam(Media.Fmtp, 'config', S) then
        Info.Extradata := HexToBytes(S);
      Exit(True);
    end;
    if SameText(Encoding, 'G726-16') then begin Info.AudioCodec := acG726_16; Exit(True); end;
    if SameText(Encoding, 'G726-24') then begin Info.AudioCodec := acG726_24; Exit(True); end;
    if SameText(Encoding, 'G726-32') then begin Info.AudioCodec := acG726_32; Exit(True); end;
    if SameText(Encoding, 'G726-40') then begin Info.AudioCodec := acG726_40; Exit(True); end;
    Exit(False);
  end;
end;

end.
