unit VMS.Rtsp.WireReader;

interface

uses
  System.SysUtils,
  System.Classes,
  VMS.Domain.Types,
  VMS.Net.Intf,
  VMS.Rtsp.Messages;

type
  TWireEventKind = (wekNone, wekRtspMessage, wekInterleaved);

  TInterleavedFrame = record
    Channel: Byte;
    Data: TBytes;
  end;

  TWireEvent = record
    Kind: TWireEventKind;
    Response: TRtspResponse;
    Frame: TInterleavedFrame;
  end;

  TRtspWireReader = class
  strict private
    FStream: ITcpStream;
    FBuffer: TBytes;
    FBufStart: Integer;
    FBufEnd: Integer;
    // Área de recepção reaproveitada. O Recv só exige que ela caiba o pedido
    // (ele mesmo cresce se faltar), então declarar isto como local — como
    // estava — era uma alocação de dezenas de KB por leitura de socket, no laço
    // mais quente do cliente.
    FRecv: TBytes;
    procedure Compact;
    function EnsureBytes(N: Integer; TimeoutMs: Cardinal): Boolean;
    function ReadOne(TimeoutMs: Cardinal): Boolean;
    function PeekByte: Byte;
    procedure AdvanceBy(N: Integer);
    function FindHeaderTerminator(out HeaderLen: Integer): Boolean;
  public
    constructor Create(const Stream: ITcpStream);
    function ReadRtspResponse(TimeoutMs: Cardinal): TRtspResponse;
    function ReadNext(TimeoutMs: Cardinal): TWireEvent;
    function TryReadNext(TimeoutMs: Cardinal; out Event: TWireEvent): Boolean;
    function BytesAvailable: Integer;
  end;

implementation

const
  HEADER_TERMINATOR: array[0..3] of Byte = ($0D, $0A, $0D, $0A);

{ TRtspWireReader }

constructor TRtspWireReader.Create(const Stream: ITcpStream);
begin
  inherited Create;
  FStream := Stream;
  SetLength(FBuffer, 32 * 1024);
  FBufStart := 0;
  FBufEnd := 0;
end;

procedure TRtspWireReader.Compact;
var
  N: Integer;
begin
  N := FBufEnd - FBufStart;
  if N > 0 then
    Move(FBuffer[FBufStart], FBuffer[0], N);
  FBufStart := 0;
  FBufEnd := N;
end;

function TRtspWireReader.ReadOne(TimeoutMs: Cardinal): Boolean;
var
  N, Free: Integer;
begin
  if FBufEnd >= Length(FBuffer) then
  begin
    Compact;
    if FBufEnd >= Length(FBuffer) then
      SetLength(FBuffer, Length(FBuffer) * 2);
  end;
  Free := Length(FBuffer) - FBufEnd;
  if Length(FRecv) < Free then
    SetLength(FRecv, Free);   // cresce no máximo junto com FBuffer, e não encolhe
  N := FStream.Recv(FRecv, Free, TimeoutMs);
  if N <= 0 then Exit(False);
  Move(FRecv[0], FBuffer[FBufEnd], N);
  Inc(FBufEnd, N);
  Result := True;
end;

function TRtspWireReader.EnsureBytes(N: Integer; TimeoutMs: Cardinal): Boolean;
var
  Deadline, NowTick: UInt64;
  RemMs: Cardinal;
begin
  NowTick := TThread.GetTickCount64;
  Deadline := NowTick + TimeoutMs;
  while (FBufEnd - FBufStart) < N do
  begin
    NowTick := TThread.GetTickCount64;
    if NowTick >= Deadline then
      Exit(False);
    RemMs := Cardinal(Deadline - NowTick);
    if RemMs = 0 then RemMs := 1;
    if not ReadOne(RemMs) then
      if (FBufEnd - FBufStart) < N then Exit(False);
  end;
  Result := True;
end;

function TRtspWireReader.PeekByte: Byte;
begin
  Result := FBuffer[FBufStart];
end;

procedure TRtspWireReader.AdvanceBy(N: Integer);
begin
  Inc(FBufStart, N);
  if FBufStart = FBufEnd then
  begin
    FBufStart := 0;
    FBufEnd := 0;
  end;
end;

function TRtspWireReader.BytesAvailable: Integer;
begin
  Result := FBufEnd - FBufStart;
end;

function TRtspWireReader.TryReadNext(TimeoutMs: Cardinal; out Event: TWireEvent): Boolean;
begin
  try
    Event := ReadNext(TimeoutMs);
    Result := True;
  except
    on E: EVmsTimeoutError do
    begin
      FillChar(Event, SizeOf(Event), 0);
      Event.Kind := wekNone;
      Result := False;
    end;
  end;
end;

function TRtspWireReader.FindHeaderTerminator(out HeaderLen: Integer): Boolean;
var
  I, Limit: Integer;
begin
  Result := False;
  Limit := FBufEnd - 3;
  I := FBufStart;
  while I < Limit do
  begin
    if (FBuffer[I]     = HEADER_TERMINATOR[0]) and
       (FBuffer[I + 1] = HEADER_TERMINATOR[1]) and
       (FBuffer[I + 2] = HEADER_TERMINATOR[2]) and
       (FBuffer[I + 3] = HEADER_TERMINATOR[3]) then
    begin
      HeaderLen := I - FBufStart + 4;
      Exit(True);
    end;
    Inc(I);
  end;
end;

function TRtspWireReader.ReadRtspResponse(TimeoutMs: Cardinal): TRtspResponse;
var
  Ev: TWireEvent;
  Deadline, NowTick: UInt64;
  RemMs: Cardinal;
begin
  NowTick := TThread.GetTickCount64;
  Deadline := NowTick + TimeoutMs;
  while True do
  begin
    NowTick := TThread.GetTickCount64;
    if NowTick >= Deadline then
      raise EVmsTimeoutError.Create('RTSP response timeout');
    RemMs := Cardinal(Deadline - NowTick);
    Ev := ReadNext(RemMs);
    case Ev.Kind of
      wekRtspMessage:
        begin
          Result := Ev.Response;
          Exit;
        end;
      wekInterleaved:
        begin
          Continue;
        end;
    else
      raise EVmsIoError.Create('Unexpected end of stream');
    end;
  end;
end;

function TRtspWireReader.ReadNext(TimeoutMs: Cardinal): TWireEvent;
var
  HeaderLen: Integer;
  HeaderText: string;
  Resp: TRtspResponse;
  ContentLen, BodyToRead: Integer;
  Ch: Byte;
  Len: Word;
  FrameData: TBytes;
  Deadline, NowTick: UInt64;
  RemMs: Cardinal;
  HeaderBytes: TBytes;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := wekNone;

  NowTick := TThread.GetTickCount64;
  Deadline := NowTick + TimeoutMs;

  while True do
  begin
    if (FBufEnd - FBufStart) = 0 then
    begin
      NowTick := TThread.GetTickCount64;
      if NowTick >= Deadline then
        raise EVmsTimeoutError.Create('Wire read timeout');
      RemMs := Cardinal(Deadline - NowTick);
      if not ReadOne(RemMs) then
        Continue;
    end;
    Break;
  end;

  if PeekByte = $24 then
  begin
    // Garante o header de 4 bytes (sem consumir ainda: precisamos do Len).
    NowTick := TThread.GetTickCount64;
    if NowTick >= Deadline then RemMs := 1
    else RemMs := Cardinal(Deadline - NowTick);
    if not EnsureBytes(4, RemMs) then
      raise EVmsTimeoutError.Create('Interleaved header timeout');
    Ch := FBuffer[FBufStart + 1];
    Len := (Word(FBuffer[FBufStart + 2]) shl 8) or Word(FBuffer[FBufStart + 3]);
    // Frame ATÔMICO: só consome depois de ter header+payload inteiros no
    // buffer. Se faltar dentro do timeout, levanta SEM consumir o header —
    // o próximo ReadNext reencontra o mesmo $24 e continua acumulando o
    // payload, sem perder o sincronismo do stream interleaved.
    NowTick := TThread.GetTickCount64;
    if NowTick >= Deadline then RemMs := 1
    else RemMs := Cardinal(Deadline - NowTick);
    if not EnsureBytes(4 + Len, RemMs) then
      raise EVmsTimeoutError.Create('Interleaved payload timeout');
    AdvanceBy(4);
    SetLength(FrameData, Len);
    if Len > 0 then
      Move(FBuffer[FBufStart], FrameData[0], Len);
    AdvanceBy(Len);
    Result.Kind := wekInterleaved;
    Result.Frame.Channel := Ch;
    Result.Frame.Data := FrameData;
    Exit;
  end;

  while not FindHeaderTerminator(HeaderLen) do
  begin
    NowTick := TThread.GetTickCount64;
    if NowTick >= Deadline then
      raise EVmsTimeoutError.Create('RTSP header read timeout');
    RemMs := Cardinal(Deadline - NowTick);
    if not ReadOne(RemMs) then
      raise EVmsIoError.Create('Stream closed while reading RTSP header');
  end;

  SetLength(HeaderBytes, HeaderLen);
  Move(FBuffer[FBufStart], HeaderBytes[0], HeaderLen);
  AdvanceBy(HeaderLen);
  HeaderText := TEncoding.UTF8.GetString(HeaderBytes);

  Resp := TRtspResponse.Create;
  try
    if not ParseRtspResponse(HeaderText, Resp) then
    begin
      Resp.Free;
      raise EVmsProtocolError.Create('Invalid RTSP response');
    end;
    ContentLen := ParseContentLength(Resp.Headers);
    if ContentLen > 0 then
    begin
      NowTick := TThread.GetTickCount64;
      if NowTick >= Deadline then RemMs := 1
      else RemMs := Cardinal(Deadline - NowTick);
      if not EnsureBytes(ContentLen, RemMs) then
      begin
        Resp.Free;
        raise EVmsTimeoutError.Create('RTSP body read timeout');
      end;
      SetLength(FrameData, ContentLen);
      BodyToRead := ContentLen;
      if BodyToRead > 0 then
        Move(FBuffer[FBufStart], FrameData[0], BodyToRead);
      AdvanceBy(BodyToRead);
      Resp.Body := FrameData;
    end;
    Result.Kind := wekRtspMessage;
    Result.Response := Resp;
  except
    Resp.Free;
    raise;
  end;
end;

end.
