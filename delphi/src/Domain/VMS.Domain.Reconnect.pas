unit VMS.Domain.Reconnect;

interface

type
  IReconnectPolicy = interface
    ['{4A1A0F62-0B2D-4D0F-9B5C-CC4F2A3E8E70}']
    function NextDelayMs: Cardinal;
    procedure NotifySuccess;
    procedure NotifyFailure;
    function CurrentDelayMs: Cardinal;
    function Attempts: Cardinal;
  end;

  TExponentialBackoffPolicy = class(TInterfacedObject, IReconnectPolicy)
  strict private
    FInitialMs: Cardinal;
    FMaxMs: Cardinal;
    FMultiplier: Double;
    FCurrent: Cardinal;
    FAttempts: Cardinal;
  public
    constructor Create(AInitialMs, AMaxMs: Cardinal; AMultiplier: Double);
    function NextDelayMs: Cardinal;
    procedure NotifySuccess;
    procedure NotifyFailure;
    function CurrentDelayMs: Cardinal;
    function Attempts: Cardinal;
  end;

implementation

{ TExponentialBackoffPolicy }

constructor TExponentialBackoffPolicy.Create(AInitialMs, AMaxMs: Cardinal; AMultiplier: Double);
begin
  inherited Create;
  if AInitialMs = 0 then AInitialMs := 2000;
  if AMaxMs < AInitialMs then AMaxMs := AInitialMs;
  if AMultiplier < 1.0 then AMultiplier := 1.0;
  FInitialMs := AInitialMs;
  FMaxMs := AMaxMs;
  FMultiplier := AMultiplier;
  FCurrent := AInitialMs;
  FAttempts := 0;
end;

function TExponentialBackoffPolicy.NextDelayMs: Cardinal;
begin
  Result := FCurrent;
end;

procedure TExponentialBackoffPolicy.NotifySuccess;
begin
  FCurrent := FInitialMs;
  FAttempts := 0;
end;

procedure TExponentialBackoffPolicy.NotifyFailure;
var
  Next: Double;
begin
  Inc(FAttempts);
  Next := FCurrent * FMultiplier;
  if Next > FMaxMs then Next := FMaxMs;
  if Next < FInitialMs then Next := FInitialMs;
  FCurrent := Cardinal(Trunc(Next));
end;

function TExponentialBackoffPolicy.CurrentDelayMs: Cardinal;
begin
  Result := FCurrent;
end;

function TExponentialBackoffPolicy.Attempts: Cardinal;
begin
  Result := FAttempts;
end;

end.
