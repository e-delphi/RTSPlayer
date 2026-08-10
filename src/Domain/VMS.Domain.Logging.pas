unit VMS.Domain.Logging;

interface

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  ILogger = interface
    ['{B8B0F8C0-7C0A-4F1E-9F1A-3A6C7F5C2E10}']
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
    function MinLevel: TLogLevel;
    procedure SetMinLevel(Level: TLogLevel);
  end;

function LogLevelToStr(Level: TLogLevel): string;
function ParseLogLevel(const S: string; out Level: TLogLevel): Boolean;

implementation

uses
  System.SysUtils;

function LogLevelToStr(Level: TLogLevel): string;
begin
  case Level of
    llDebug: Result := 'DEBUG';
    llInfo:  Result := 'INFO ';
    llWarn:  Result := 'WARN ';
    llError: Result := 'ERROR';
  else
    Result := '?    ';
  end;
end;

function ParseLogLevel(const S: string; out Level: TLogLevel): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if (L = 'debug') then begin Level := llDebug; Exit(True); end;
  if (L = 'info')  then begin Level := llInfo;  Exit(True); end;
  if (L = 'warn') or (L = 'warning') then begin Level := llWarn; Exit(True); end;
  if (L = 'error') then begin Level := llError; Exit(True); end;
  Result := False;
end;

end.
