unit VMS.Domain.Logging;

interface

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  // Só escrita, e sem filtro em lugar nenhum: nenhuma implementação decide o
  // que sai. O nível entra na linha para quem LÊ saber o peso do evento, não
  // para o programa escolher se registra — ver VMS.App.Logger.
  ILogger = interface
    ['{B8B0F8C0-7C0A-4F1E-9F1A-3A6C7F5C2E10}']
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
  end;

function LogLevelToStr(Level: TLogLevel): string;

implementation

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

end.
