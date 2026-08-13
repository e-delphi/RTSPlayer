unit Tx.Server.Sdp;

interface

uses
  System.SysUtils,
  System.Classes,
  System.NetEncoding,
  VMS.Domain.Types,
  VMS.Rec.Format,
  Tx.Server.Types;

function BuildSdpForHeader(const Header: TVmsHeader; const SessionName: string): string;
function SplitAnnexB(const Data: TBytes): TArray<TBytes>;

implementation

function SplitAnnexB(const Data: TBytes): TArray<TBytes>;
var
  I, NalStart, Count: Integer;
  Tmp: TArray<TBytes>;
  NalBytes: TBytes;

  function StartCodeAt(P: Integer): Integer;
  begin
    if (P + 3 < Length(Data)) and (Data[P] = 0) and (Data[P+1] = 0) and (Data[P+2] = 0) and (Data[P+3] = 1) then
      Exit(4);
    if (P + 2 < Length(Data)) and (Data[P] = 0) and (Data[P+1] = 0) and (Data[P+2] = 1) then
      Exit(3);
    Result := 0;
  end;

var
  Sk: Integer;
begin
  Result := nil;
  Count := 0;
  SetLength(Tmp, 4);
  I := 0;
  NalStart := -1;
  while I < Length(Data) do
  begin
    Sk := StartCodeAt(I);
    if Sk > 0 then
    begin
      if NalStart >= 0 then
      begin
        SetLength(NalBytes, I - NalStart);
        if I - NalStart > 0 then
          Move(Data[NalStart], NalBytes[0], I - NalStart);
        if Count >= Length(Tmp) then SetLength(Tmp, Length(Tmp) * 2);
        Tmp[Count] := NalBytes;
        Inc(Count);
      end;
      Inc(I, Sk);
      NalStart := I;
    end
    else
      Inc(I);
  end;
  if (NalStart >= 0) and (NalStart < Length(Data)) then
  begin
    SetLength(NalBytes, Length(Data) - NalStart);
    Move(Data[NalStart], NalBytes[0], Length(Data) - NalStart);
    if Count >= Length(Tmp) then SetLength(Tmp, Length(Tmp) * 2);
    Tmp[Count] := NalBytes;
    Inc(Count);
  end;
  Result := Copy(Tmp, 0, Count);
end;

function Base64Of(const Data: TBytes): string;
begin
  if Length(Data) = 0 then Exit('');
  Result := TNetEncoding.Base64.EncodeBytesToString(Data);
  Result := StringReplace(Result, #13#10, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
end;

function HexOf(const Data: TBytes): string;
var
  I: Integer;
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    for I := 0 to High(Data) do
      Sb.Append(IntToHex(Data[I], 2));
    Result := LowerCase(Sb.ToString);
  finally
    Sb.Free;
  end;
end;

procedure AppendVideoSdp(Sb: TStringBuilder; const V: TVideoTrackInfo);
var
  Nals: TArray<TBytes>;
  I: Integer;
  Sps, Pps, Vps, ProfileLevelId: string;
  Sprop: string;
  NalType: Byte;
begin
  case V.Codec of
    vcH264:
      begin
        Sb.AppendFormat('m=video 0 RTP/AVP %d'#13#10, [TX_TRACK_VIDEO_PT]);
        Sb.AppendFormat('a=rtpmap:%d H264/%d'#13#10, [TX_TRACK_VIDEO_PT, V.Timescale]);
        Nals := SplitAnnexB(V.Extradata);
        Sps := '';
        Pps := '';
        for I := 0 to High(Nals) do
        begin
          if Length(Nals[I]) = 0 then Continue;
          NalType := Nals[I][0] and $1F;
          case NalType of
            7:
              begin
                if Sps <> '' then Sps := Sps + ',';
                Sps := Sps + Base64Of(Nals[I]);
                if (ProfileLevelId = '') and (Length(Nals[I]) >= 4) then
                  ProfileLevelId :=
                    LowerCase(IntToHex(Nals[I][1], 2) + IntToHex(Nals[I][2], 2) + IntToHex(Nals[I][3], 2));
              end;
            8:
              begin
                if Pps <> '' then Pps := Pps + ',';
                Pps := Pps + Base64Of(Nals[I]);
              end;
          end;
        end;
        Sprop := '';
        if Sps <> '' then Sprop := Sps;
        if Pps <> '' then
        begin
          if Sprop <> '' then Sprop := Sprop + ',';
          Sprop := Sprop + Pps;
        end;
        Sb.AppendFormat('a=fmtp:%d packetization-mode=1', [TX_TRACK_VIDEO_PT]);
        if ProfileLevelId <> '' then
          Sb.AppendFormat('; profile-level-id=%s', [ProfileLevelId]);
        if Sprop <> '' then
          Sb.AppendFormat('; sprop-parameter-sets=%s', [Sprop]);
        Sb.Append(#13#10);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_VIDEO_CTRL]);
      end;
    vcH265:
      begin
        Sb.AppendFormat('m=video 0 RTP/AVP %d'#13#10, [TX_TRACK_VIDEO_PT]);
        Sb.AppendFormat('a=rtpmap:%d H265/%d'#13#10, [TX_TRACK_VIDEO_PT, V.Timescale]);
        Nals := SplitAnnexB(V.Extradata);
        Vps := '';
        Sps := '';
        Pps := '';
        for I := 0 to High(Nals) do
        begin
          if Length(Nals[I]) < 2 then Continue;
          NalType := (Nals[I][0] shr 1) and $3F;
          case NalType of
            32: Vps := Base64Of(Nals[I]);
            33: Sps := Base64Of(Nals[I]);
            34: Pps := Base64Of(Nals[I]);
          end;
        end;
        Sb.AppendFormat('a=fmtp:%d', [TX_TRACK_VIDEO_PT]);
        if Vps <> '' then Sb.AppendFormat(' sprop-vps=%s;', [Vps]);
        if Sps <> '' then Sb.AppendFormat(' sprop-sps=%s;', [Sps]);
        if Pps <> '' then Sb.AppendFormat(' sprop-pps=%s;', [Pps]);
        Sb.Append(#13#10);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_VIDEO_CTRL]);
      end;
    vcMJPEG:
      begin
        Sb.AppendFormat('m=video 0 RTP/AVP 26'#13#10, []);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_VIDEO_CTRL]);
      end;
  end;
end;

procedure AppendAudioSdp(Sb: TStringBuilder; const A: TAudioTrackInfo);
var
  EncName: string;
begin
  case A.Codec of
    acAAC:
      begin
        Sb.AppendFormat('m=audio 0 RTP/AVP %d'#13#10, [TX_TRACK_AUDIO_PT]);
        Sb.AppendFormat('a=rtpmap:%d MPEG4-GENERIC/%d/%d'#13#10,
          [TX_TRACK_AUDIO_PT, A.Timescale, A.Channels]);
        Sb.AppendFormat(
          'a=fmtp:%d streamtype=5; profile-level-id=1; mode=AAC-hbr; sizelength=13; indexlength=3; indexdeltalength=3',
          [TX_TRACK_AUDIO_PT]);
        if Length(A.Extradata) > 0 then
          Sb.AppendFormat('; config=%s', [HexOf(A.Extradata)]);
        Sb.Append(#13#10);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_AUDIO_CTRL]);
      end;
    acG711U:
      begin
        Sb.Append('m=audio 0 RTP/AVP 0'#13#10);
        Sb.AppendFormat('a=rtpmap:0 PCMU/%d'#13#10, [A.Timescale]);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_AUDIO_CTRL]);
      end;
    acG711A:
      begin
        Sb.Append('m=audio 0 RTP/AVP 8'#13#10);
        Sb.AppendFormat('a=rtpmap:8 PCMA/%d'#13#10, [A.Timescale]);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_AUDIO_CTRL]);
      end;
    acPCM:
      begin
        Sb.AppendFormat('m=audio 0 RTP/AVP %d'#13#10, [TX_TRACK_AUDIO_PT]);
        Sb.AppendFormat('a=rtpmap:%d L16/%d/%d'#13#10,
          [TX_TRACK_AUDIO_PT, A.Timescale, A.Channels]);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_AUDIO_CTRL]);
      end;
    acG726_16, acG726_24, acG726_32, acG726_40:
      begin
        case A.Codec of
          acG726_16: EncName := 'G726-16';
          acG726_24: EncName := 'G726-24';
          acG726_32: EncName := 'G726-32';
          acG726_40: EncName := 'G726-40';
        end;
        Sb.AppendFormat('m=audio 0 RTP/AVP %d'#13#10, [TX_TRACK_AUDIO_PT]);
        Sb.AppendFormat('a=rtpmap:%d %s/%d'#13#10,
          [TX_TRACK_AUDIO_PT, EncName, A.Timescale]);
        Sb.AppendFormat('a=control:%s'#13#10, [TX_TRACK_AUDIO_CTRL]);
      end;
  end;
end;

function BuildSdpForHeader(const Header: TVmsHeader; const SessionName: string): string;
var
  Sb: TStringBuilder;
  SName: string;
begin
  SName := SessionName;
  if SName = '' then SName := 'VMS Stream';
  Sb := TStringBuilder.Create;
  try
    Sb.Append('v=0'#13#10);
    Sb.AppendFormat('o=- 0 0 IN IP4 0.0.0.0'#13#10, []);
    Sb.AppendFormat('s=%s'#13#10, [SName]);
    Sb.Append('c=IN IP4 0.0.0.0'#13#10);
    Sb.Append('t=0 0'#13#10);
    Sb.Append('a=control:*'#13#10);
    if Header.VideoPresent then
      AppendVideoSdp(Sb, Header.Video);
    if Header.AudioPresent then
      AppendAudioSdp(Sb, Header.Audio);
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

end.
