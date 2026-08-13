unit Vms.Server.Config;

// Config do servidor = a config padrão do VMS (storageDir, block, cameras,
// logs — lida pelo TAppConfigLoader compartilhado com o RTSPlayer) MAIS os dois
// campos que só o servidor RTSP tem:
//   "rtspPort":    porta única onde todas as câmeras são publicadas (8554)
//   "bindAddress": IP onde escutar. Vazio = todas as interfaces. Preencha com
//                  o IP 100.x do Tailscale para não expor o servidor na LAN.
//
// A leitura da parte comum não é reimplementada aqui: só o gancho LoadExtra é
// sobrescrito, e ele recebe a raiz do mesmo JSON que a base já carregou.

interface

uses
  System.SysUtils,
  System.JSON,
  VMS.App.Config;

type
  TVmsServerConfig = class(TAppConfigLoader)
  strict private
    FRtspPort: Word;
    FBindAddress: string;
  protected
    procedure LoadExtra(Root: TJSONObject); override;
  public
    property RtspPort: Word read FRtspPort;
    property BindAddress: string read FBindAddress;
  end;

implementation

procedure TVmsServerConfig.LoadExtra(Root: TJSONObject);
begin
  inherited;
  FRtspPort := Word(GetJsonInt(Root, 'rtspPort', 8554));
  FBindAddress := Trim(GetJsonStr(Root, 'bindAddress', ''));
end;

end.
