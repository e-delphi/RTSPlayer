unit VMS.App.Clock;

interface

uses
  VMS.Domain.Clock;

type
  TSystemClock = class(TInterfacedObject, IClock)
  public
    function NowUtcMs: Int64;
    function MonotonicMs: Int64;
  end;

implementation

uses
  System.DateUtils,
  System.SysUtils,
  System.Diagnostics;

var
  GStopwatch: TStopwatch;

{ TSystemClock }

function TSystemClock.NowUtcMs: Int64;
begin
  Result := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), False) * 1000
          + MilliSecondOf(Now);
end;

function TSystemClock.MonotonicMs: Int64;
begin
  Result := GStopwatch.ElapsedMilliseconds;
end;

initialization
  GStopwatch := TStopwatch.StartNew;

end.
