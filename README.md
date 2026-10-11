# 台服 LOL 简中启动项目

在 Windows 上使用精确 **`zh_CN`** 启动台服《英雄联盟》。默认使用 Riot 当前台服补丁的官方简中游戏、语音及客户端资源，不要求国服处于同一补丁。

当前版本恢复为**简中单入口**，不再切换繁简语言，也不申请 Riot 的 session patch lock。旧版可能在 Riot 已打开时仍反复申请更新锁，返回 429 并卡住；本版本移除了这段流程。

## 安装与更新

安装台服 LOL、Riot Client 和 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)，在项目目录运行：

```powershell
pwsh -NoProfile -File .\Install.ps1 `
  -TwRoot 'D:\Riot Games\League of Legends\League of Legends' `
  -RiotClientExe 'C:\Riot Games\Riot Client\RiotClientServices.exe' `
  -CacheRoot 'E:\LOL_TWtoCN_Cache'
```

安装器创建 **台服 LOL 简体中文** 桌面入口，并保存被 Git 忽略的 `config.local.json`。更新脚本后原简中快捷方式仍可使用。重新运行安装器会更新入口，并将旧繁中桌面快捷方式移到被 Git 忽略的 `local-backups`；已有繁中缓存保留。

## 启动流程

1. 检查客户端、对局及 Vanguard 启动频率限制。已有 League 客户端或对局时停止。
2. 核对同版本简中缓存和现有文件。无需恢复时保留 Riot 当前登录会话；需要恢复资源时，通过正常退出接口关闭 Riot，精简后台会先打开完整 Riot。Riot 无法正常退出时停止，不强制结束游戏或写入缓存。
3. 仅在 Riot 完全退出后恢复缺失或损坏的资源。匹配的文件直接复用；不删除另一语言的文件。
4. 打开 Riot，通过本地接口固定 `zh_CN`，取消旧更新任务并提交明确带 `locale: zh_CN` 的更新请求。等待本地语言接口最多 45 秒，不访问旧更新锁接口，不依赖改写 YAML。
5. 等待 Riot v2 状态为 `UpToDate`，暂停任务自动恢复最多三次。确认简中资源完整并保存备份后，等待 Riot 登录授权和启动资格最多两分钟，再启动客户端。启动请求回应较慢时等待本次结果，不重复提交；检查 Vanguard 和台服登录错误，并尝试确认登录。账户尚未登录时显示待登录提示，明确的登录失败会单独报错。

补丁更新、缓存缺失或官方资源变化仍需由 Riot 下载。只有同一完整资源版本的缓存可以恢复；缓存不能跳过官方版本检查。通过 Riot 自身入口启动会绕过简中准备，可能再次选择繁中资源，请使用本项目的简中入口。

日志保存在 `%LOCALAPPDATA%\LOL_TWtoCN\launcher.log`。接口等待会显示进度和限时错误；更新默认最多等待 120 分钟，可使用 `-WaitMinutes 1440` 延长。

## 本地备份

默认备份目录为项目下 `cache`，安装时可用 `-CacheRoot` 指定其它本地磁盘。简中约占 4 GB，更新还需要额外空间。资源按 SHA-256 保存，相同内容只存一份；版本由完整资源版本、程序版本及清单摘要识别。

恢复在 Riot 退出后执行：校验缓存的大小与 SHA-256，只修复本版本简中资源。损坏的备份不会覆盖现有文件，交给 Riot 更新。官方更新完成后刷新备份，保留旧版本对象和清单。

游戏资源、备份清单、Riot 凭据、本机路径配置、日志和快捷方式均不上传 Git。

只检查安装和资源，不启动或下载：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -CheckOnly
```

只准备简中缓存及官方更新，不启动 League 客户端：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -PrepareOnly
```

Riot 已完成简中更新时只建立备份，不关闭或启动游戏：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -BackupOnly
```

保留 `-Locale zh_CN` 参数以兼容旧简中快捷方式，`zh_TW` 不再受支持。

## Vanguard

入口保留 VAN 216 冷却检查和客户端错误检查。[Riot 官方说明](https://support.riotgames.com/en-us/riot/performance/error-van-216/)要求短时间频繁启动后至少等待 30 分钟；提前再次启动可能重置等待时间。被本入口的冷却检查阻止时不会启动游戏。`-PrepareOnly` 不启动 League，也不增加游戏启动次数。

客户端打开后最多用 15 秒确认 Vanguard，同时检查本次启动日志中的登录队列认证和账号资料读取错误。Cloudflare 拒绝账号资料请求时显示线路检查提示；这些登录错误不会误报为等待 Vanguard。明确的反作弊错误仍显示失败；账户或 Vanguard 尚未完成登录时显示待登录提示，不重复启动，也不声称反作弊验证已通过。完成账号登录由 Riot/League 自身处理；启动器不会修改加速器或代理配置。

## 可选国服资源模式

旧的国服本地复制模式仍可使用，需要设置 `cnRoot` 且两端程序和资源补丁一致：

```powershell
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -ResourceSource Local -CheckOnly
pwsh -NoProfile -File .\Start-TW-LoL-zhCN.ps1 -ResourceSource Local -ShowErrors
```

桌面入口默认使用 Riot 官方资源。国服补丁不一致时本地复制模式停止；同大小文件也会核对摘要。

## 验证

```powershell
pwsh -NoProfile -File .\tests\Launcher.Tests.ps1
pwsh -NoProfile -File .\tests\Resource-Backup.Tests.ps1
pwsh -NoProfile -File .\tests\Vanguard-Status.Tests.ps1
```

隔离测试覆盖离线缓存恢复、官方简中请求、后台唤醒和重连、未更新完成时不启动、版本和摘要保护，以及 Vanguard 失败。测试禁止调用旧更新锁接口，不访问实际 Riot 或游戏目录。

Riot 更新可能改变接口或资源布局；官方更新未完成时不启动客户端，Vanguard 未确认时明确提示待登录。本项目与 Riot Games 或腾讯无关联。
