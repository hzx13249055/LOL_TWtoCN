# 台服 LOL 简中启动项目

在 Windows 上使用**已安装的国服 `zh_CN` 资源**启动台服《英雄联盟》。项目同时提供 Clash Verge Rev 的 `DIRECT` 分流规则示例，供雷神加速器、Riot 客户端和游戏使用。游戏资源、Riot 凭据及个人代理订阅均不包含在仓库中。

## 准备

1. 安装并更新国服及台服《英雄联盟》，两端须处于同一补丁版本，例如都是 `16.19`。脚本会拒绝混用不同补丁的资源。
2. 安装 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)、Riot Client。简中资源必须来自新设备上的国服安装目录。
3. 若需原有网络效果，安装 Clash Verge Rev 和雷神加速器，在雷神中选择台服/国际服游戏及合适节点。加速是否生效应在雷神内查看实时状态，并以实际对局网络表现确认。

## 在新设备安装

在此项目目录打开 PowerShell 7，根据实际安装路径运行：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -CnRoot 'D:\WeGameApps\英雄联盟' `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends' `
  -RiotClientExe 'C:\Riot Games\Riot Client\RiotClientServices.exe'
```

安装器会检查游戏目录，生成被 Git 忽略的 `config.local.json`，并创建桌面入口 **台服 LOL 简体中文**。今后通过此入口启动。若 Riot 已打开但 League 客户端尚未打开，也可使用此入口。若 League 客户端已打开，请先关闭它。

只检查资源和版本，不启动游戏：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -CheckOnly
```

## Clash Verge Rev 与雷神

在 Clash Verge Rev 中为当前订阅建立“规则”扩展，将 [`clash-verge-rules.yaml`](./clash-verge-rules.yaml) 中的 `prepend` 规则放在现有规则前，并确认扩展已关联到当前订阅。更新订阅后也要确认扩展仍然启用。

**保持 Clash TUN 和系统代理处于原有开启状态。** 这些 `DIRECT` 规则让相关连接不使用 Clash 代理节点，但在 TUN 开启时，流量仍可能经过 Clash 的 TUN 捕获层；`DIRECT` 本身不等于完全绕开 Clash。雷神的实际加速路线由雷神客户端及其驱动决定，单靠 Clash 规则不能保证加速。请在新设备上分别验证 Clash 连接记录为 `DIRECT`、雷神显示加速中，并在实际对局检查延迟。

## 工作方式与限制

- Riot 客户端启动时可能把台服产品设置 YAML 中的语言改回 `zh_TW`。桌面入口会在每次启动前调用 Riot 本地接口重新设为 `zh_CN`，再复制本机国服的简中游戏及客户端资源，然后启动台服游戏。不要依赖手工修改 YAML 的持久性。
- Riot 更新可能改变本地接口、安装布局或资源格式。若脚本报错，先更新两端游戏，再运行 `-CheckOnly`；必要时更新本项目。
- 运行日志仅保存在 `%LOCALAPPDATA%\LOL_TWtoCN\launcher.log`。本机路径配置与日志不进入 Git。
- 未将国服资源包上传 GitHub。新设备须自行安装国服并保持版本匹配。

本项目为个人配置脚本，与 Riot Games、腾讯、雷神或 Clash Verge Rev 均无关联。
