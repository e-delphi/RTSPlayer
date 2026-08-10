unit VMS.Rec.Format;

interface

uses
  System.SysUtils,
  VMS.Domain.Types;

const
  VMS_MAGIC_FILE   : array[0..3] of Byte = (Ord('V'), Ord('M'), Ord('S'), Ord('1'));
  VMS_MAGIC_BLOCK  : array[0..3] of Byte = (Ord('B'), Ord('L'), Ord('K'), $01);
  VMS_MAGIC_FOOTER : array[0..3] of Byte = (Ord('V'), Ord('E'), Ord('O'), Ord('F'));

  VMS_FORMAT_VERSION = 1;

type
  TVmsHeader = record
    Version: Word;
    HeaderSize: Cardinal;
    CreationUnixMs: Int64;
    SourceUri: string;
    VideoPresent: Boolean;
    Video: TVideoTrackInfo;
    AudioPresent: Boolean;
    Audio: TAudioTrackInfo;
  end;

  TVmsSampleEntry = record
    TrackId: TTrackId;
    FlagsByte: Byte;
    Pts: Int64;
    PayloadOffset: Cardinal;
    PayloadSize: Cardinal;
  end;

  TVmsBlock = record
    BlockSeq: Cardinal;
    StartUnixMs: Int64;
    Samples: array of TVmsSampleEntry;
    Payload: TBytes;
  end;

  TVmsFooter = record
    TotalBlocks: Cardinal;
    TotalDurationMs: Int64;
    LastBlockOffset: UInt64;
  end;

function FlagsToByte(const Flags: TSampleFlags): Byte;
function ByteToFlags(B: Byte): TSampleFlags;

implementation

function FlagsToByte(const Flags: TSampleFlags): Byte;
begin
  Result := 0;
  if sfKeyframe in Flags    then Result := Result or $01;
  if sfStartOfFrame in Flags then Result := Result or $02;
  if sfEndOfFrame in Flags   then Result := Result or $04;
end;

function ByteToFlags(B: Byte): TSampleFlags;
begin
  Result := [];
  if (B and $01) <> 0 then Include(Result, sfKeyframe);
  if (B and $02) <> 0 then Include(Result, sfStartOfFrame);
  if (B and $04) <> 0 then Include(Result, sfEndOfFrame);
end;

end.
