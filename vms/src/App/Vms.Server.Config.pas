unit Vms.Server.Config;

// Config do servidor = a config padrão do VMS (storageDir, block, cameras,
// logs — lida pelo TAppConfigLoader compartilhado com o RTSPlayer) MAIS os
// campos que só o servidor RTSP tem:
//   "rtspPort":    porta única onde todas as câmeras são publicadas (8554)
//   "bindAddress": IP onde escutar. Vazio = todas as interfaces. Preencha com
//                  o IP 100.x do Tailscale para não expor o servidor na LAN.
//   "retention":   limpeza automática das gravações (ver Vms.Server.Retention).
//
// A leitura da parte comum não é reimplementada aqui: só o gancho LoadExtra é
// sobrescrito, e ele recebe a raiz do mesmo JSON que a base já carregou.

interface

uses
  System.SysUtils,
  System.JSON,
  VMS.App.Config,
  Vms.Server.Retention;

type
  TVmsServerConfig = class(TAppConfigLoader)
  strict private
    FRtspPort: Word;
    FBindAddress: string;
    FRetention: TRetentionPolicy;
  protected
    procedure LoadExtra(Root: TJSONObject); override;
  public
    property RtspPort: Word read FRtspPort;
    property BindAddress: string read FBindAddress;
    property Retention: TRetentionPolicy read FRetention;
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
end;

end.
