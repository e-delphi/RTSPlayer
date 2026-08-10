unit VMS.App.Logger;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  VMS.Domain.Logging;

type
  TConsoleLogger = class(TInterfacedObject, ILogger)
  strict private
    FLock: TCriticalSection;
    FMinLevel: TLogLevel;
  public
    constructor Create(AMinLevel: TLogLevel = llInfo);
    destructor Destroy; override;
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
    function MinLevel: TLogLevel;
    procedure SetMinLevel(Level: TLogLevel);
  end;

  TFileLogger = class(TInterfacedObject, ILogger)
  strict private
    FLock: TCriticalSection;
    FStream: TFileStream;
    FMinLevel: TLogLevel;
    FFilePath: string;
    procedure WriteLine(const S: string);
  public
    constructor Create(const AFilePath: string; AMinLevel: TLogLevel = llInfo);
    destructor Destroy; override;
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
    function MinLevel: TLogLevel;
    procedure SetMinLevel(Level: TLogLevel);
    property FilePath: string read FFilePath;
  end;

  TCompositeLogger = class(TInterfacedObject, ILogger)
  strict private
    FChildren: TList<ILogger>;
    FMinLevel: TLogLevel;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Child: ILogger);
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
    function MinLevel: TLogLevel;
    procedure SetMinLevel(Level: TLogLevel);
  end;

implementation

uses
  System.DateUtils;

function FormatLine(Level: TLogLevel; const Tag, Msg: string): string;
begin
  Result := Format('%s [%s] %s: %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
     LogLevelToStr(Level),
     Tag,
     Msg]);
end;

{ TConsoleLogger }

constructor TConsoleLogger.Create(AMinLevel: TLogLevel);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMinLevel := AMinLevel;
end;

destructor TConsoleLogger.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TConsoleLogger.Log(Level: TLogLevel; const Tag, Msg: string);
begin
  if Level < FMinLevel then Exit;
  FLock.Enter;
  try
    Writeln(FormatLine(Level, Tag, Msg));
  finally
    FLock.Leave;
  end;
end;

procedure TConsoleLogger.Debug(const Tag, Msg: string); begin Log(llDebug, Tag, Msg); end;
procedure TConsoleLogger.Info(const Tag, Msg: string);  begin Log(llInfo,  Tag, Msg); end;
procedure TConsoleLogger.Warn(const Tag, Msg: string);  begin Log(llWarn,  Tag, Msg); end;
procedure TConsoleLogger.Error(const Tag, Msg: string); begin Log(llError, Tag, Msg); end;

function TConsoleLogger.MinLevel: TLogLevel;
begin
  Result := FMinLevel;
end;

procedure TConsoleLogger.SetMinLevel(Level: TLogLevel);
begin
  FMinLevel := Level;
end;

{ TFileLogger }

constructor TFileLogger.Create(const AFilePath: string; AMinLevel: TLogLevel);
var
  Dir: string;
  Mode: Word;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMinLevel := AMinLevel;
  FFilePath := AFilePath;
  Dir := ExtractFilePath(AFilePath);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);
  if FileExists(AFilePath) then
    Mode := fmOpenWrite or fmShareDenyWrite
  else
    Mode := fmCreate or fmShareDenyWrite;
  FStream := TFileStream.Create(AFilePath, Mode);
  FStream.Seek(0, soEnd);
end;

destructor TFileLogger.Destroy;
begin
  FStream.Free;
  FLock.Free;
  inherited;
end;

procedure TFileLogger.WriteLine(const S: string);
var
  Bytes: TBytes;
  NL: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(S);
  NL := TEncoding.UTF8.GetBytes(sLineBreak);
  if Length(Bytes) > 0 then
    FStream.WriteBuffer(Bytes[0], Length(Bytes));
  if Length(NL) > 0 then
    FStream.WriteBuffer(NL[0], Length(NL));
end;

procedure TFileLogger.Log(Level: TLogLevel; const Tag, Msg: string);
begin
  if Level < FMinLevel then Exit;
  FLock.Enter;
  try
    WriteLine(FormatLine(Level, Tag, Msg));
  finally
    FLock.Leave;
  end;
end;

procedure TFileLogger.Debug(const Tag, Msg: string); begin Log(llDebug, Tag, Msg); end;
procedure TFileLogger.Info(const Tag, Msg: string);  begin Log(llInfo,  Tag, Msg); end;
procedure TFileLogger.Warn(const Tag, Msg: string);  begin Log(llWarn,  Tag, Msg); end;
procedure TFileLogger.Error(const Tag, Msg: string); begin Log(llError, Tag, Msg); end;

function TFileLogger.MinLevel: TLogLevel;
begin
  Result := FMinLevel;
end;

procedure TFileLogger.SetMinLevel(Level: TLogLevel);
begin
  FMinLevel := Level;
end;

{ TCompositeLogger }

constructor TCompositeLogger.Create;
begin
  inherited Create;
  FChildren := TList<ILogger>.Create;
  FMinLevel := llDebug;
end;

destructor TCompositeLogger.Destroy;
begin
  FChildren.Free;
  inherited;
end;

procedure TCompositeLogger.Add(const Child: ILogger);
begin
  if Child <> nil then
    FChildren.Add(Child);
end;

procedure TCompositeLogger.Log(Level: TLogLevel; const Tag, Msg: string);
var
  I: Integer;
begin
  if Level < FMinLevel then Exit;
  for I := 0 to FChildren.Count - 1 do
    FChildren[I].Log(Level, Tag, Msg);
end;

procedure TCompositeLogger.Debug(const Tag, Msg: string); begin Log(llDebug, Tag, Msg); end;
procedure TCompositeLogger.Info(const Tag, Msg: string);  begin Log(llInfo,  Tag, Msg); end;
procedure TCompositeLogger.Warn(const Tag, Msg: string);  begin Log(llWarn,  Tag, Msg); end;
procedure TCompositeLogger.Error(const Tag, Msg: string); begin Log(llError, Tag, Msg); end;

function TCompositeLogger.MinLevel: TLogLevel;
begin
  Result := FMinLevel;
end;

procedure TCompositeLogger.SetMinLevel(Level: TLogLevel);
begin
  FMinLevel := Level;
end;

end.
