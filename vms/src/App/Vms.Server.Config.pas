unit Vms.Server.Config;

// Config do servidor = a config padrão do VMS (storageDir, block, cameras,
// logs — lida pelo TAppConfigLoader compartilhado com o RTSPlayer) MAIS os
// campos que só o servidor RTSP tem:
//   "rtspPort":    porta única onde todas as câmeras são publicadas (8554)
//   "bindAddress": IP onde escutar. Vazio = todas as interfaces. Preencha com
//                  o IP 100.x do Tailscale para não expor o servidor na LAN.
//   "retention":   limpeza automática das gravações (ver Vms.Server.Retention).
//   "live":        buffer em memória de onde o ao vivo é publicado, em vez de
//                  reler o .vms que está sendo gravado (ver Vms.Server.LiveHub).
//   "api":         rotas HTTP das gravações, na MESMA porta do RTSP (ver
//                  Vms.Server.Api).
//   "analytics":   detecção de movimento e de objetos sobre a gravação, e os
//                  eventos que ela produz (ver Vms.Analytics.*).
//
// A leitura da parte comum não é reimplementada aqui: só o gancho LoadExtra é
// sobrescrito, e ele recebe a raiz do mesmo JSON que a base já carregou.

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  System.Generics.Collections,
  VMS.App.Config,
  Vms.Server.Retention,
  Vms.Server.LiveHub,
  Vms.Server.Api,
  Vms.Analytics.Types;

type
  TVmsServerConfig = class(TAppConfigLoader)
  strict private
    FRtspPort: Word;
    FBindAddress: string;
    FRetention: TRetentionPolicy;
    FLive: TLiveConfig;
    FApi: TApiConfig;
    FAnalytics: TAnalyticsConfig;
  protected
    procedure LoadExtra(Root: TJSONObject); override;
  public
    property RtspPort: Word read FRtspPort;
    property BindAddress: string read FBindAddress;
    property Retention: TRetentionPolicy read FRetention;
    property Live: TLiveConfig read FLive;
    property Api: TApiConfig read FApi;
    property Analytics: TAnalyticsConfig read FAnalytics;
  end;

implementation

// A lista de rótulos que interessam ("classes": ["person","car"]). Ausente ou
// vazia = todos os que o modelo conhecer, que é o padrão sensato: quem não
// escreveu nada não quer filtrar nada.
function LerClasses(Obj: TJSONObject): TArray<string>;
var
  Arr: TJSONArray;
  V: TJSONValue;
  I, N: Integer;
begin
  Result := nil;
  V := Obj.GetValue('classes');
  if not (V is TJSONArray) then Exit;
  Arr := TJSONArray(V);
  SetLength(Result, Arr.Count);
  N := 0;
  for I := 0 to Arr.Count - 1 do
    if Trim(Arr.Items[I].Value) <> '' then
    begin
      Result[N] := LowerCase(Trim(Arr.Items[I].Value));
      Inc(N);
    end;
  SetLength(Result, N);
end;

procedure TVmsServerConfig.LoadExtra(Root: TJSONObject);
var
  V: TJSONValue;
  Obj: TJSONObject;
  Gb: Double;
begin
  inherited;
  FRtspPort := Word(GetJsonInt(Root, 'rtspPort', 8554));
  FBindAddress := Trim(GetJsonStr(Root, 'bindAddress', ''));

  // Retenção desligada quando o bloco não existe: apagar gravação de quem só
  // atualizou o executável seria a pior surpresa possível. Quem quer, escreve os
  // limites — e a partida loga em qual regime está rodando.
  FillChar(FRetention, SizeOf(FRetention), 0);
  FRetention.IntervalMs := 5 * 60 * 1000;
  V := Root.GetValue('retention');
  if V is TJSONObject then
  begin
    Obj := TJSONObject(V);
    FRetention.MaxDays := GetJsonInt(Obj, 'maxDays', 0);
    Gb := GetJsonDouble(Obj, 'maxTotalGB', 0);
    if Gb > 0 then FRetention.MaxTotalBytes := Round(Gb * GIGABYTE);
    Gb := GetJsonDouble(Obj, 'minFreeGB', 0);
    if Gb > 0 then FRetention.MinFreeBytes := Round(Gb * GIGABYTE);
    FRetention.IntervalMs := GetJsonInt(Obj, 'intervalMinutes', 5) * 60 * 1000;
  end;

  // Ao contrário da retenção, o buffer ao vivo vem LIGADO por omissão: ele não
  // apaga nem altera nada, só encurta o caminho da câmera até o cliente. Quem
  // quiser o comportamento antigo (ao vivo lido do arquivo) escreve
  // "live": { "enabled": false }.
  FLive.Enabled := True;
  FLive.BufferMs := LIVE_DEFAULT_BUFFER_MS;
  FLive.MaxBytes := LIVE_DEFAULT_MAX_BYTES;
  V := Root.GetValue('live');
  if V is TJSONObject then
  begin
    Obj := TJSONObject(V);
    FLive.Enabled := GetJsonBool(Obj, 'enabled', True);
    FLive.BufferMs := GetJsonInt(Obj, 'bufferMs', LIVE_DEFAULT_BUFFER_MS);
    Gb := GetJsonDouble(Obj, 'maxBufferMB', 0);
    if Gb > 0 then FLive.MaxBytes := Round(Gb * 1024 * 1024);
    if FLive.BufferMs < 500 then FLive.BufferMs := 500;
  end;

  // A API também vem ligada por omissão: ela só lê o que já está no disco, e sai
  // pela mesma porta que já estava aberta. Quem não quer, escreve
  // "api": { "enabled": false }.
  FApi.Enabled := True;
  FApi.MaxBlocksPerRequest := API_DEFAULT_MAX_BLOCKS;
  V := Root.GetValue('api');
  if V is TJSONObject then
  begin
    Obj := TJSONObject(V);
    FApi.Enabled := GetJsonBool(Obj, 'enabled', True);
    FApi.MaxBlocksPerRequest := GetJsonInt(Obj, 'maxBlocksPerRequest', API_DEFAULT_MAX_BLOCKS);
    if FApi.MaxBlocksPerRequest < 1 then FApi.MaxBlocksPerRequest := 1;
  end;

  // A análise vem DESLIGADA por omissão, ao contrário do ao vivo e da API. Ela é
  // a única coisa aqui que consome CPU continuamente numa máquina que também
  // está gravando: quem a quer, escreve o bloco e assume o custo.
  //
  // Sem "modelPath", ela liga só com detecção de movimento — que é aritmética e
  // custa quase nada. É um regime útil por si só, e é o que roda quando o
  // onnxruntime.dll ou o .onnx não estão no disco.
  FAnalytics := TAnalyticsConfig.Default;
  V := Root.GetValue('analytics');
  if V is TJSONObject then
  begin
    Obj := TJSONObject(V);
    FAnalytics.Enabled := GetJsonBool(Obj, 'enabled', True);
    FAnalytics.StepMs := GetJsonInt(Obj, 'stepMs', 2000);
    FAnalytics.MotionThreshold := GetJsonDouble(Obj, 'motionThreshold', 0.012);
    FAnalytics.SceneChangeThreshold := GetJsonDouble(Obj, 'sceneChangeThreshold', 0.55);
    FAnalytics.ObjectMinIntervalMs := GetJsonInt(Obj, 'objectIntervalMs', 5000);
    FAnalytics.ObjectThreshold := GetJsonDouble(Obj, 'objectThreshold', 0.35);
    FAnalytics.MergeGapMs := GetJsonInt(Obj, 'mergeGapMs', 8000);
    FAnalytics.BackfillMs := Int64(GetJsonInt(Obj, 'backfillHours', 6)) * 3600 * 1000;
    FAnalytics.LagMs := GetJsonInt(Obj, 'lagMs', 30000);
    FAnalytics.ModelPath := Trim(GetJsonStr(Obj, 'modelPath', ''));
    FAnalytics.OnnxDllPath := Trim(GetJsonStr(Obj, 'onnxDll', 'onnxruntime.dll'));
    FAnalytics.Classes := LerClasses(Obj);
    // Caminho relativo é relativo ao EXECUTÁVEL, não ao diretório de trabalho:
    // o servidor costuma subir como serviço, e aí o cwd é C:\Windows\System32.
    if (FAnalytics.ModelPath <> '') and (not TPath.IsPathRooted(FAnalytics.ModelPath)) then
      FAnalytics.ModelPath := ExtractFilePath(ParamStr(0)) + FAnalytics.ModelPath;
    // Passo abaixo de meio segundo não melhora a detecção (a gravação nem tem
    // keyframe tão denso) e multiplica o custo por nada.
    if FAnalytics.StepMs < 500 then FAnalytics.StepMs := 500;
    if FAnalytics.LagMs < 5000 then FAnalytics.LagMs := 5000;
  end;
end;

end.
