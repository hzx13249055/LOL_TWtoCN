# 台服 LOL 简中 / 繁中启动项目

在 Windows 上分别以精确 **`zh_CN`**（简中）或 **`zh_TW`**（繁中）启动台服《英雄联盟》。默认由 Riot 下载和管理当前台服补丁的官方游戏、语音及客户端资源，无需国服处于相同补丁。两种语言各自保留本地备份，切换时复用同版本资源。

游戏资源、Riot 凭据及本机配置均不包含在仓库中。

## 准备与安装

安装台服《英雄联盟》、Riot Client，以及 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)。在项目目录打开 PowerShell 7，根据实际路径运行：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends' `
  -RiotClientExe 'C:\Riot Games\Riot Client\RiotClientServices.exe'
```

安装器保存被 Git 忽略的 `config.local.json`，并创建两个桌面入口：**台服 LOL 简体中文**、**台服 LOL 繁体中文**。按所需语言选择入口；若 League 客户端或对局已打开，请先正常关闭客户端。

旧版项目更新后，重新运行安装脚本即可更新快捷方式；如需保留可选国服路径，请再次传入 `-CnRoot`。默认模式不读取国服资源。

只检查安装和现有资源，不启动或下载：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -CheckOnly
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -Locale zh_TW -CheckOnly
```

此检查通过只表示安装路径及版本元数据可读取，不代表所选语言下载已经完成。脚本文件名为兼容旧入口保持不变，默认语言仍是 `zh_CN`。

## 工作方式

- 启动时通过 Riot 本地接口指定所选语言，在启动游戏前再次确认。Riot 可能改写产品 YAML，不依赖手工修改 YAML 的持久性。
- 完整 Riot 启动前，以及唤醒精简后台前，会核对产品配置指向当前台服安装目录，并同步默认语言、可用语言与所选语言。仅启动后设置语言存在竞态：Riot 可能先按繁中默认值删除简中素材。配置被 Riot 重写后，下一次入口会重新同步。
- 产品配置首次修改前，在同目录保存 `.LOL_TWtoCN.original` 本机备份。结构或安装路径不匹配时停止修改；该备份不上传仓库。
- 正常退出已在后台运行的 Riot，准备缓存后重新打开，避免恢复资源前便开始下载。不会强制结束游戏；其他 Riot 游戏导致后台无法正常退出时，会提示关闭后重试。
- 关闭 Riot 窗口后可能只剩精简后台，LOL 接口返回 404。启动器会先打开完整 Riot 客户端，再正常退出并准备缓存；不会直接把精简后台当作可用的 LOL 接口。
- 使用 Riot 的 v2 完整更新状态，覆盖游戏及客户端；等待更新完成后，确认简中资源存在，再启动 League 客户端。v1 状态可能显示客户端已更新，但游戏仍在下载。
- Riot 的“允许启动”可能早于语音下载完成。启动器单独请求更新，只有完整更新状态为 `UpToDate` 才启动客户端，避免提前启动暂停剩余语音下载。
- 默认由 Riot 下载官方当前补丁的简中资源，不向台服复制较旧的国服文件，也不在更新期间反复写入资源。
- 每种语言首次使用或补丁更新可能需要下载数 GB；所需流量以 Riot 状态为准。真正的补丁下载不会被跳过。
- 请通过这两个入口切换语言。直接从 Riot Client 启动会绕过缓存准备，仍可能触发另一语言的完整下载。
- 更新默认最多等待 120 分钟；网络较慢时可使用 `-WaitMinutes 1440` 延长。重复点击只允许一个启动器运行。桌面入口失败时显示原因；Riot 接受请求后还会确认 League 客户端已打开。
- Riot 后台重启导致本地接口暂时返回 404 时，启动器最多等待一分钟并重新读取连接信息；接口持续不可用时会报告错误。
- 日志保存在 `%LOCALAPPDATA%\LOL_TWtoCN\launcher.log`，不进入 Git。

## 自动本地备份

官方模式在 Riot 完成更新后，自动备份所选语言的游戏文件及两个客户端资源。简中、繁中使用独立的版本清单。之后启动时，只恢复**同一完整资源版本、同一语言**中缺失的文件，再要求 Riot 完整校验；已有文件不会被覆盖。恢复前会正常退出 Riot，对局期间不切换资源。

两套语言备份独立维护，游戏安装目录作为当前所选语言的使用位置。为节省游戏盘空间，切换前会释放另一语言已备份的文件：必须同时验证原文件和独立备份的大小及 SHA-256，且版本一致，才允许释放。没有一致备份的文件保留。另一语言再次启动时可从缓存恢复，无需长期在游戏目录保留两份语言。

默认备份目录为项目下的 `cache`，每种语言约需 4 GB 空间，两种语言请预留至少 8 GB，更新还需要额外空间。资源按 SHA-256 内容摘要保存，相同内容在不同版本间只存一份；旧版本清单保留，但不会跨版本恢复。损坏的备份文件不会恢复，交给 Riot 下载。备份失败会记录原因，不阻止正常游戏启动。旧版仅简中的缓存仍可读取。

可在安装时指定有足够空间的本地目录，安装器会保留此前设置：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends' `
  -CacheRoot 'E:\LOL_TWtoCN_Cache'
```

资源已经下载完成时，也可仅建立备份。此操作读取资源，不关闭或启动游戏；要求 Riot 正在运行、语言与参数一致且更新状态完整：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -BackupOnly
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -Locale zh_TW -BackupOnly
```

备份资源、版本清单、临时文件及本机路径配置均被 Git 忽略；仓库仅上传脚本、说明和测试。备份可减少缺失文件导致的重复下载，真正的版本变化仍须由 Riot 更新。不要把备份目录放进游戏安装目录。

## 可选：使用已安装的国服资源

保留旧的本地复制方式，仅适用于 `zh_CN`，需要安装配置中设置 `cnRoot`，且两端程序及资源必须为相同补丁：

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
pwsh -NoProfile -File .\tests\Product-Locale.Tests.ps1
```

隔离测试覆盖版本不匹配保护、同大小资源更新、完整更新后启动、缓存校验、语言隔离、安全释放、旧缓存兼容、后台重连，以及官方模式不读取较旧国服资源。测试不访问 Riot、不修改已安装游戏文件。

Riot 更新可能改变接口或资源布局。错误提示及日志可用于定位问题；官方模式未验证完成时不会报告所选语言启动成功。

本项目为个人配置脚本，与 Riot Games 或腾讯均无关联。
