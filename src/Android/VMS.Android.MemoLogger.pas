unit VMS.Android.MemoLogger;

// Logger que acumula as linhas num buffer thread-safe. Quem mostra le por
// posição (ver Desde) -- hoje é a página, pelo /api/app/log, que as escreve no
// console do navegador. Evita marshaling/lifetime: os logs chegam na thread de
// rede; só strings cruzam a fronteira.
//
// ## O espelho no logcat
//
// No Android cada linha sai TAMBÉM pelo logcat, com a tag `VMS`. O buffer só
// existe dentro do app: para ver o que aconteceu era preciso estar com o
// aparelho na mão, olhando a tela. Pelo logcat o mesmo log sai por cabo:
//
//     adb logcat -s VMS
//     adb logcat -s VMS:W        (só avisos e erros)
//     adb logcat -c              (limpa antes de reproduzir o problema)
//
// A tag é fixa e curta de propósito: `-s VMS` filtra tudo do app e nada mais.
// O nível vai no texto e também na prioridade da linha, então dá para filtrar
// pelos dois caminhos.

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
    FMaxBuffered: Integer;
    // Quantas linhas ja passaram por aqui desde que o app abriu, contando as
    // que o buffer descartou. E este numero, e nao o indice no buffer, que o
    // leitor guarda: descartar a linha mais velha nao pode mover o lugar das
    // outras debaixo dele.
    FTotal: Int64;
    procedure Emit(Level: TLogLevel; const Tag, Msg: string);
  public
    constructor Create;
    destructor Destroy; override;
    // As linhas a partir da posicao Desde, e a posicao seguinte. Posicao fora
    // do que o buffer ainda guarda devolve tudo que ha -- e o que a pagina
    // quer ao abrir: o que aconteceu antes dela chegar.
    function Desde(Posicao: Int64; out Proxima: Int64): TArray<string>;
    { ILogger }
    procedure Log(Level: TLogLevel; const Tag, Msg: string);
    procedure Debug(const Tag, Msg: string);
    procedure Info(const Tag, Msg: string);
    procedure Warn(const Tag, Msg: string);
    procedure Error(const Tag, Msg: string);
  end;

implementation

{$IFDEF ANDROID}
uses
  Androidapi.Log;

const
  TAG_LOGCAT: MarshaledAString = 'VMS';

// A mesma linha, no logcat. UTF8String porque o __android_log_write recebe
// bytes: passar UnicodeString direto sairia truncado no primeiro caractere.
procedure ParaLogcat(Level: TLogLevel; const Linha: string);
var
  Prio: android_LogPriority;
  U: UTF8String;
begin
  case Level of
    llDebug: Prio := android_LogPriority.ANDROID_LOG_DEBUG;
    llWarn:  Prio := android_LogPriority.ANDROID_LOG_WARN;
    llError: Prio := android_LogPriority.ANDROID_LOG_ERROR;
  else
    Prio := android_LogPriority.ANDROID_LOG_INFO;
  end;
  U := UTF8String(Linha);
  __android_log_write(Prio, TAG_LOGCAT, MarshaledAString(PAnsiChar(U)));
end;
{$ENDIF}

constructor TMemoLogger.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBuffer := TStringList.Create;
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
  Line := Format('%s %s: %s', [LogLevelToStr(Level), Tag, Msg]);
{$IFDEF ANDROID}
  // Fora do lock: escrever no logcat é uma chamada de sistema, e segurar o
  // buffer durante ela atrasaria as threads de rede que também logam.
  ParaLogcat(Level, Line);
{$ENDIF}
  FLock.Enter;
  try
    FBuffer.Add(Line);
    Inc(FTotal);
    while FBuffer.Count > FMaxBuffered do
      FBuffer.Delete(0);
  finally
    FLock.Leave;
  end;
end;

function TMemoLogger.Desde(Posicao: Int64;
  out Proxima: Int64): TArray<string>;
var
  Primeira: Int64;
  I, N: Integer;
begin
  FLock.Enter;
  try
    Proxima := FTotal;
    // A posicao da linha mais velha que ainda esta no buffer.
    Primeira := FTotal - FBuffer.Count;
    if (Posicao < Primeira) or (Posicao > FTotal) then
      Posicao := Primeira;
    N := Integer(FTotal - Posicao);
    SetLength(Result, N);
    for I := 0 to N - 1 do
      Result[I] := FBuffer[FBuffer.Count - N + I];
  finally
    FLock.Leave;
  end;
end;

procedure TMemoLogger.Log(Level: TLogLevel; const Tag, Msg: string); begin Emit(Level, Tag, Msg); end;
procedure TMemoLogger.Debug(const Tag, Msg: string); begin Emit(llDebug, Tag, Msg); end;
procedure TMemoLogger.Info(const Tag, Msg: string);  begin Emit(llInfo,  Tag, Msg); end;
procedure TMemoLogger.Warn(const Tag, Msg: string);  begin Emit(llWarn,  Tag, Msg); end;
procedure TMemoLogger.Error(const Tag, Msg: string); begin Emit(llError, Tag, Msg); end;


end.
