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
var
  Utc: TDateTime;
begin
  // Uma conversão só. O ToUniversalTime já entrega UTC, e o segundo parâmetro do
  // DateTimeToUnix diz se o valor JÁ está em UTC — passar False ali mandava
  // converter de novo, e o carimbo saía adiantado pelo tamanho do fuso (4 h
  // aqui). Como todo o resto do sistema lê este número como UTC de verdade, a
  // timeline acabava mostrando UTC no lugar da hora local do vídeo.
  Utc := TTimeZone.Local.ToUniversalTime(Now);
  Result := DateTimeToUnix(Utc, True) * 1000 + MilliSecondOf(Utc);
end;

function TSystemClock.MonotonicMs: Int64;
begin
  Result := GStopwatch.ElapsedMilliseconds;
end;

initialization
  GStopwatch := TStopwatch.StartNew;

end.
