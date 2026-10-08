# 台服 LOL 简中启动项目

在 Windows 上以精确 **`zh_CN`** 语言启动台服《英雄联盟》。默认由 Riot 下载和管理当前台服补丁的官方简中游戏、语音及客户端资源，无需国服处于相同补丁。

游戏资源、Riot 凭据及本机配置均不包含在仓库中。

## 准备与安装

安装台服《英雄联盟》、Riot Client，以及 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)。在项目目录打开 PowerShell 7，根据实际路径运行：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends' `
  -RiotClientExe 'C:\Riot Games\Riot Client\RiotClientServices.exe'
```

安装器保存被 Git 忽略的 `config.local.json`，并创建桌面入口 **台服 LOL 简体中文**。使用此入口启动；若 League 客户端或对局已打开，请先正常关闭客户端。

旧版项目更新后，重新运行安装脚本即可更新快捷方式；已有配置中的 `cnRoot` 可以保留，默认模式不读取国服资源。

只检查安装和现有资源，不启动或下载：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -CheckOnly
```

此检查通过只表示安装路径及版本元数据可读取，不代表简中下载已经完成。

## 工作方式

- 启动时通过 Riot 本地接口指定 `zh_CN`，在启动游戏前再次确认。Riot 可能改写产品 YAML，不依赖手工修改 YAML 的持久性。
- 使用 Riot 的 v2 完整更新状态，覆盖游戏及客户端；等待更新完成后，确认简中资源存在，再启动 League 客户端。v1 状态可能显示客户端已更新，但游戏仍在下载。
- Riot 的“允许启动”可能早于语音下载完成。启动器单独请求更新，只有完整更新状态为 `UpToDate` 才启动客户端，避免提前启动暂停剩余语音下载。
- 默认由 Riot 下载官方当前补丁的简中资源，不向台服复制较旧的国服文件，也不在更新期间反复写入资源。
- 首次切换或补丁更新可能需要下载数 GB；所需流量以 Riot 状态为准。真正的补丁下载不会被跳过。使用其他入口改回语言后，也可能再次下载资源。
- 更新默认最多等待 120 分钟；网络较慢时可使用 `-WaitMinutes 1440` 延长。重复点击只允许一个启动器运行。桌面入口失败时显示原因；Riot 接受请求后还会确认 League 客户端已打开。
- 日志保存在 `%LOCALAPPDATA%\LOL_TWtoCN\launcher.log`，不进入 Git。

## 自动本地备份

官方模式在 Riot 完成更新后，自动备份简中游戏文件及两个客户端资源。之后启动时，只恢复**同一完整资源版本**中缺失的文件，再由 Riot 检查；已有文件不会被覆盖，更新或对局期间不会往游戏目录恢复文件。

默认备份目录为项目下的 `cache`，首次约需 4 GB 空间。资源按 SHA-256 内容摘要保存，相同内容在不同版本间只存一份；旧版本清单保留，但不会跨版本恢复。损坏的备份文件不会恢复，交给 Riot 下载。备份失败会记录原因，不阻止正常游戏启动。

可在安装时指定有足够空间的本地目录，安装器会保留此前设置：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends' `
  -CacheRoot 'E:\LOL_TWtoCN_Cache'
```

资源已经下载完成时，也可仅建立备份。此操作读取资源，不关闭或启动游戏；要求 Riot 正在运行、语言为 `zh_CN` 且更新状态完整：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -BackupOnly
```

备份资源、版本清单、临时文件及本机路径配置均被 Git 忽略；仓库仅上传脚本、说明和测试。备份可减少缺失文件导致的重复下载，真正的版本变化仍须由 Riot 更新。不要把备份目录放进游戏安装目录。

## 可选：使用已安装的国服资源

保留旧的本地复制方式，需要安装配置中设置 `cnRoot`，且两端程序及资源必须为相同补丁：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -CnRoot 'D:\WeGameApps\英雄联盟' `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends'

pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -ResourceSource Local -CheckOnly
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -ResourceSource Local -ShowErrors
```

两服均显示“更新完成”不代表补丁相同。本地模式核对程序及 `Game\content-metadata.json`，复制时比较内容摘要，避免同大小的新资源被跳过。桌面入口默认仍使用 Riot 模式。

## 验证

```powershell
pwsh -NoProfile -File .\tests\Launcher.Tests.ps1
pwsh -NoProfile -File .\tests\Resource-Backup.Tests.ps1
```

隔离测试覆盖版本不匹配保护、同大小资源更新、等待补丁完成后再写入，以及官方模式不读取较旧国服资源。测试不访问 Riot、不修改已安装游戏文件。

Riot 更新可能改变接口或资源布局。错误提示及日志可用于定位问题；官方模式未验证完成时不会报告简中启动成功。

本项目为个人配置脚本，与 Riot Games 或腾讯均无关联。
