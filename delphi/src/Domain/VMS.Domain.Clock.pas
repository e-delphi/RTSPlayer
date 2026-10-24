unit VMS.Domain.Clock;

interface

type
  IClock = interface
    ['{1F1A5D7D-EB12-4F1A-9E0A-7A0A1B3C5D71}']
    function NowUtcMs: Int64;
    function MonotonicMs: Int64;
  end;

implementation

end.
