unit Vms.Server.Repair;

// Fecha, na subida do servidor, as gravações que ficaram abertas.
//
// Queda de energia ou processo morto deixam um `.vms` sem rodapé e um
// `.vms.idx` ao lado. Ele continua tocando rápido — o índice sai do sidecar —
// mas fica para sempre dizendo que está "em gravação", com a duração alguns
// segundos curta e ocupando dois arquivos no disco. Esta passada resolve isso de
// uma vez: monta o índice, corta o pedaço que a queda deixou pela metade,
// escreve o VIDX e o rodapé no fim do `.vms` e apaga o sidecar. O que sai é
// indistinguível de uma gravação que fechou direito.
//
// QUANDO roda: logo depois da varredura de retenção e ANTES de subir os
// supervisores. Nesse ponto nada está gravando, então não há corrida com o
// próprio gravador. Contra uma SEGUNDA instância do servidor rodando na mesma
// pasta, a garantia é o `fmShareExclusive`: não abriu, não é nosso, pula.
//
// SÓ mexe em arquivo que tem sidecar. Um `.vms` sem rodapé e sem sidecar
// precisaria de uma varredura completa para ser fechado, e varredura completa na
// subida do servidor pode ser minutos parado — esses continuam sendo lidos como
// hoje (varre uma vez, fica em cache) e saem com a retenção.

interface

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.IOUtils,
  VMS.Domain.Logging,
  VMS.Rec.Format,
  VMS.Rec.Paths,
  VMS.Rec.Reader,
  VMS.Rec.Sidecar,
  VMS.Rec.Writer;

// Percorre as pastas das câmeras e finaliza o que estiver pendente. Devolve
// quantas gravações foram fechadas. Nunca levanta: é passada de manutenção, e
// um arquivo estranho não pode impedir o servidor de subir.
function FinalizeOrphanRecordings(const StorageDir: string;
                                  const Cameras: TArray<string>;
                                  const Logger: ILogger): Integer;

implementation

const
  TAG = 'repair';

procedure Log(const Logger: ILogger; Level: TLogLevel; const Msg: string);
begin
  if Logger <> nil then
    Logger.Log(Level, TAG, Msg);
end;

// O índice completo de um arquivo sem rodapé, mais o offset onde a mídia
// termina. False = não deu para ler, ou não há bloco algum.
function ReadPendingIndex(const Path: string; const Logger: ILogger;
  out Index: TVmsIndex; out MediaEnd: Int64; out CreationUnixMs: Int64): Boolean;
var
  Reader: TVmsReader;
  Footer: TVmsFooter;
begin
  Result := False;
  Index := nil;
  MediaEnd := 0;
  CreationUnixMs := 0;
  try
    Reader := TVmsReader.Create(Path);
  except
    Exit; // em uso, ou sumiu entre listar e abrir
  end;
  try
    Reader.Logger := Logger;
    if not Reader.ReadHeader then Exit;
    // Já tem rodapé: fechou direito e o sidecar é só sobra.
    if Reader.ReadFooter(Footer) then Exit;
    // Sidecar + varredura da cauda: o mesmo índice que o servidor usaria para
    // tocar este arquivo, conferido bloco a bloco.
    if Reader.EnsureIndex = 0 then Exit;
    Index := Copy(Reader.Index);
    // Onde o último bloco COMPLETO termina. O que vier depois é o pedaço que a
    // queda deixou pela metade.
    MediaEnd := Reader.ScannedUpTo;
    CreationUnixMs := Reader.Header.CreationUnixMs;
    Result := (Length(Index) > 0) and (MediaEnd > 0);
  finally
    Reader.Free;
  end;
end;

// Corta a cauda incompleta e escreve índice + rodapé. O handle exclusivo é a
// garantia de que ninguém mais está com o arquivo.
function AppendIndexAndFooter(const Path: string; const Index: TVmsIndex;
  MediaEnd, CreationUnixMs: Int64; const Logger: ILogger): Boolean;
var
  Stream: TFileStream;
  Chunk, Footer: TBytes;
  Duration: Int64;
  Count: Integer;
begin
  Result := False;
  Count := Length(Index);
  if Count = 0 then Exit;
  Chunk := BuildIndexChunk(Index, Count);
  if Length(Chunk) = 0 then Exit;

  try
    Stream := TFileStream.Create(Path, fmOpenReadWrite or fmShareExclusive);
  except
    // Outra instância do servidor, ou um leitor com o arquivo aberto: não é
    // hora de mexer. Fica para a próxima subida.
    Log(Logger, llDebug, Format('%s em uso; deixei como estava',
      [ExtractFileName(Path)]));
    Exit;
  end;
  try
    if Stream.Size < MediaEnd then Exit; // encolheu debaixo de nós
    // O rodapé mede do header ao último bloco, que é como o gravador conta.
    Duration := Index[Count - 1].StartUnixMs - CreationUnixMs;
    if Duration < 0 then Duration := 0;
    Footer := BuildFooter(Cardinal(Count), Duration,
                          UInt64(Index[Count - 1].Offset), UInt64(MediaEnd),
                          Cardinal(Count));
    // Trunca ANTES de escrever: o índice tem que começar exatamente onde a
    // mídia acaba, senão o rodapé aponta para o meio de um bloco quebrado.
    Stream.Size := MediaEnd;
    Stream.Position := MediaEnd;
    Stream.WriteBuffer(Chunk[0], Length(Chunk));
    Stream.WriteBuffer(Footer[0], Length(Footer));
    Result := True;
  except
    on E: Exception do
      Log(Logger, llWarn, Format('falha ao fechar %s: %s',
        [ExtractFileName(Path), E.Message]));
  end;
  Stream.Free;
end;

function FinalizeOne(const Path: string; const Logger: ILogger): Boolean;
var
  Index: TVmsIndex;
  MediaEnd, CreationUnixMs, SizeBefore: Int64;
begin
  Result := False;
  if not TFile.Exists(SidecarPathOf(Path)) then Exit;

  if not ReadPendingIndex(Path, Logger, Index, MediaEnd, CreationUnixMs) then
  begin
    // Ou já tinha rodapé, ou não tem bloco nenhum. Nos dois casos o sidecar não
    // serve mais para nada: quem tem rodapé lê por ele, e arquivo sem bloco não
    // tem o que indexar.
    DeleteSidecar(Path);
    Exit;
  end;

  try
    SizeBefore := TFile.GetSize(Path);
  except
    SizeBefore := 0;
  end;

  if not AppendIndexAndFooter(Path, Index, MediaEnd, CreationUnixMs, Logger) then Exit;

  DeleteSidecar(Path);
  Log(Logger, llInfo, Format('%s fechado: %d blocos indexados%s',
    [ExtractFileName(Path), Length(Index),
     IfThen(SizeBefore > MediaEnd,
            Format(', %d bytes de cauda incompleta descartados',
                   [SizeBefore - MediaEnd]), '')]));
  Result := True;
end;

function FinalizeOrphanRecordings(const StorageDir: string;
  const Cameras: TArray<string>; const Logger: ILogger): Integer;
var
  I, K: Integer;
  Dir: string;
  Files: TArray<string>;
begin
  Result := 0;
  for I := 0 to High(Cameras) do
  begin
    Dir := CameraDir(StorageDir, Cameras[I]);
    if not TDirectory.Exists(Dir) then Continue;
    try
      Files := TDirectory.GetFiles(Dir, '*.vms');
    except
      Continue;
    end;
    for K := 0 to High(Files) do
    begin
      // O filtro do sistema casa por nome curto também; sem conferir a extensão
      // um `.vms.idx` entraria aqui como se fosse gravação.
      if not SameText(ExtractFileExt(Files[K]), '.vms') then Continue;
      try
        if FinalizeOne(Files[K], Logger) then
          Inc(Result);
      except
        on E: Exception do
          Log(Logger, llWarn, Format('%s: %s', [ExtractFileName(Files[K]), E.Message]));
      end;
    end;
  end;
  if Result > 0 then
    Log(Logger, llInfo, Format('%d gravacao(oes) que ficaram abertas foram fechadas',
      [Result]));
end;

end.
