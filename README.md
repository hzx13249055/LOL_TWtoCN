# 台服 LOL 简中启动项目

在 Windows 上使用**已安装的国服 `zh_CN` 资源**启动台服《英雄联盟》。游戏资源和 Riot 凭据均不包含在仓库中。

## 准备

1. 安装并更新国服及台服《英雄联盟》，两端须处于同一补丁版本，例如都是 `16.19`。脚本会拒绝混用不同补丁的资源。
2. 安装 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)、Riot Client。简中资源必须来自新设备上的国服安装目录。

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

## 工作方式与限制

- Riot 客户端启动时可能把台服产品设置 YAML 中的语言改回 `zh_TW`。桌面入口会在每次启动前调用 Riot 本地接口重新设为 `zh_CN`，再复制本机国服的简中游戏及客户端资源，然后启动台服游戏。不要依赖手工修改 YAML 的持久性。
- Riot 更新可能改变本地接口、安装布局或资源格式。若脚本报错，先更新两端游戏，再运行 `-CheckOnly`；必要时更新本项目。
- 运行日志仅保存在 `%LOCALAPPDATA%\LOL_TWtoCN\launcher.log`。本机路径配置与日志不进入 Git。
- 未将国服资源包上传 GitHub。新设备须自行安装国服并保持版本匹配。

本项目为个人配置脚本，与 Riot Games 或腾讯均无关联。
