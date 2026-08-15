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
//
// A leitura da parte comum não é reimplementada aqui: só o gancho LoadExtra é
// sobrescrito, e ele recebe a raiz do mesmo JSON que a base já carregou.

interface

uses
  System.SysUtils,
  System.JSON,
  VMS.App.Config,
  Vms.Server.Retention,
  Vms.Server.LiveHub;

type
  TVmsServerConfig = class(TAppConfigLoader)
  strict private
    FRtspPort: Word;
    FBindAddress: string;
    FRetention: TRetentionPolicy;
    FLive: TLiveConfig;
  protected
    procedure LoadExtra(Root: TJSONObject); override;
  public
    property RtspPort: Word read FRtspPort;
    property BindAddress: string read FBindAddress;
    property Retention: TRetentionPolicy read FRetention;
    property Live: TLiveConfig read FLive;
  end;

implementation

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
end;

end.
