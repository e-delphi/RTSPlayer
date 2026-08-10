unit VMS.Android.MemoLogger;

// Logger que acumula as linhas num buffer thread-safe. A UI (timer) drena via
// Drain() e joga no TMemo. Evita marshaling/lifetime: os logs chegam na thread
// de rede; só strings cruzam a fronteira.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  VMS.Domain.Logging;

type
  TMemoLogger = class(TInterfacedObject, ILogger)
  strict private
    FLock: TCriticalSection;
    FBuffer: TStringList;
    FMinLevel: TLogLevel;
    FMaxBuffered: Integer;
    procedure Emit(Level: TLogLevel; const Tag, Msg: string);
  public
    constructor Create(AMinLevel: TLogLevel = llDebug);
    destructor Destroy; override;
    function Drain: TArray<string>;
    { ILogger }
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
    function MinLevel: TLogLevel;
    procedure SetMinLevel(Level: TLogLevel);
  end;

implementation

constructor TMemoLogger.Create(AMinLevel: TLogLevel);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBuffer := TStringList.Create;
  FMinLevel := AMinLevel;
  FMaxBuffered := 2000;
end;

destructor TMemoLogger.Destroy;
begin
  FBuffer.Free;
  FLock.Free;
  inherited;
end;

procedure TMemoLogger.Emit(Level: TLogLevel; const Tag, Msg: string);
var
  Line: string;
begin
  if Level < FMinLevel then Exit;
  Line := Format('%s %s: %s', [LogLevelToStr(Level), Tag, Msg]);
  FLock.Enter;
  try
    FBuffer.Add(Line);
    while FBuffer.Count > FMaxBuffered do
      FBuffer.Delete(0);
  finally
    FLock.Leave;
  end;
end;

function TMemoLogger.Drain: TArray<string>;
begin
  FLock.Enter;
  try
    Result := FBuffer.ToStringArray;
    FBuffer.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TMemoLogger.Log(Level: TLogLevel; const Tag, Msg: string); begin Emit(Level, Tag, Msg); end;
procedure TMemoLogger.Debug(const Tag, Msg: string); begin Emit(llDebug, Tag, Msg); end;
procedure TMemoLogger.Info(const Tag, Msg: string);  begin Emit(llInfo,  Tag, Msg); end;
procedure TMemoLogger.Warn(const Tag, Msg: string);  begin Emit(llWarn,  Tag, Msg); end;
procedure TMemoLogger.Error(const Tag, Msg: string); begin Emit(llError, Tag, Msg); end;

function TMemoLogger.MinLevel: TLogLevel; begin Result := FMinLevel; end;
procedure TMemoLogger.SetMinLevel(Level: TLogLevel); begin FMinLevel := Level; end;

end.
