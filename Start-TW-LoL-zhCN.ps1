param(
    [switch]$CheckOnly,
    [switch]$ShowErrors,
    [switch]$BackupOnly,
    [switch]$PrepareOnly,
    [ValidateSet('zh_CN','zh_TW')][string]$Locale = 'zh_CN',
    [ValidateSet('Riot', 'Local')][string]$ResourceSource = 'Riot',
    [ValidateRange(1, 1440)][int]$WaitMinutes = 120
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'config.local.json'
$localePath = '/riotclient/product-locales/products/league_of_legends/patchlines/live'
$logDir = Join-Path $env:LOCALAPPDATA 'LOL_TWtoCN'
$logPath = Join-Path $logDir 'launcher.log'
$mutex = $null
$ownsMutex = $false
. (Join-Path $PSScriptRoot 'Resource-Backup.ps1')
. (Join-Path $PSScriptRoot 'Vanguard-Status.ps1')

$patchStatePath = '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live'
$patchRequestPath = '/patch-proxy/v2/priority-patch/products/league_of_legends/patchlines/live'
$patchLockPath = '/patch-proxy/v2/session-patch-lock/products/league_of_legends/patchline/live'
$patchLockConnection = $null

function Save-VerifiedBackup {
    Write-Status "正在核对并保存本地 $Locale 备份：$cacheRoot"
    $saved = Save-ResourceBackup $twRoot $cacheRoot $Locale
    Write-Status "本地备份就绪：$($saved.FileCount) 个资源，新增 $($saved.AddedFiles) 个文件（$([math]::Round($saved.AddedBytes / 1MB)) MB）"
}

function Unlock-RiotPatch {
    if ($null -ne $script:patchLockConnection) {
        try { $null = Invoke-Riot $script:patchLockConnection 'DELETE' $patchLockPath } catch {
            # A priority request can already remove the session lock.
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            $null = Invoke-Riot $script:patchLockConnection 'GET' $patchStatePath
        }
        $script:patchLockConnection = $null
    }
}

function Get-ControlledRiotConnection {
    $started = $false
    $deadline = (Get-Date).AddSeconds(120)
    do {
        try {
            $connection = Get-RiotConnection
            if ($null -ne $script:patchLockConnection -and $script:patchLockConnection.Base -eq $connection.Base) { return $connection }
            # Take the exclusive lock before locale/eligibility calls can queue
            # a patch using Riot's remote default (zh_TW).
            $null = Invoke-Riot $connection 'PUT' $patchLockPath 'true' 3
            $script:patchLockConnection = $connection
            return $connection
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -notin @(0,404,423,424,429,503)) { throw }
            if (-not $started) {
                Write-Status '正在启动完整 Riot 客户端；精简后台模式会自动唤醒' | Out-Host
                Start-Process -FilePath $riotExe -WindowStyle Hidden
                $started = $true
            }
            if ($status -eq 429) { Start-Sleep -Seconds 2 } else { Start-Sleep -Milliseconds 250 }
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Riot 未能在两分钟内准备好受保护的更新接口'
}

function Prepare-RequestedPatch([hashtable]$connection) {
    if ($null -eq $script:patchLockConnection -or $script:patchLockConnection.Base -ne $connection.Base) {
        throw '未持有 Riot 更新锁，取消资源恢复'
    }
    $null = Invoke-Riot $connection 'DELETE' '/patch-proxy/v2/patch-jobs/products/league_of_legends/patchlines/live'
    $deadline = (Get-Date).AddSeconds(60)
    do {
        try { $state = (Invoke-Riot $connection 'GET' $patchStatePath).Content | ConvertFrom-Json } catch {
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            # Cold startup can have no patch state yet because our early lock
            # prevented the default-language task from being created. Confirm
            # the full product interface exists after cancellation succeeded.
            $null = Invoke-Riot $connection 'GET' $localePath
            $state = [pscustomobject]@{state='Paused'}
        }
        if ($state.state -in @('Paused','UpToDate','OutOfDate','NeedsRepair')) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if ($state.state -notin @('Paused','UpToDate','OutOfDate','NeedsRepair')) { throw "Riot 更新任务未停止（$($state.state)），取消资源恢复" }
    if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) { throw '检测到客户端或对局，取消资源切换' }
    Write-Status '已锁定并暂停 Riot 更新任务，正在核对同版本语言缓存' | Out-Host
    if ($ResourceSource -eq 'Riot') {
        $otherLocale = if ($Locale -eq 'zh_CN') { 'zh_TW' } else { 'zh_CN' }
        try {
            $released = Release-BackedUpLanguage $twRoot $cacheRoot $otherLocale
            if ($released.Released -gt 0) { Write-Status "已从游戏目录释放 $($released.Released) 个已备份的 $otherLocale 资源" | Out-Host }
        } catch { Write-Status ('未释放另一语言资源：' + $_.Exception.Message) | Out-Host }
        try {
            $restored = Restore-ResourceBackup $twRoot $cacheRoot $Locale -RepairExisting
            Write-Status "同版本 $Locale 缓存：恢复 $($restored.Restored) 个资源，拒绝 $($restored.Rejected) 个损坏资源" | Out-Host
        } catch { Write-Status ('缓存不可用，交给 Riot 官方更新：' + $_.Exception.Message) | Out-Host }
    }
    $null = Invoke-Riot $connection 'PUT' $localePath $localeJson
    # Product locale alone does not bind patch-job locale. Explicitly specify
    # the language in the native request while the exclusive lock is held.
    $request = @{locale=$Locale;createShortcut=$false;isRepair=$false} | ConvertTo-Json -Compress
    $null = Invoke-Riot $connection 'PUT' $patchRequestPath $request
    Unlock-RiotPatch
    Write-Status "已提交明确指定 $Locale 的官方更新任务并释放更新锁" | Out-Host
}

function Prepare-ControlledPatch {
    $deadline = (Get-Date).AddSeconds(120)
    do {
        try {
            $connection = Get-ControlledRiotConnection
            Prepare-RequestedPatch $connection
            return $connection
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -notin @(404,423,424,429,503)) { throw }
            Write-Status 'Riot 更新接口正在初始化，保持资源保护并等待完整接口' | Out-Host
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Riot 完整更新接口未能在两分钟内准备好'
}

function Write-Status([string]$message) {
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
    Write-Output $line
}

function Get-RiotConnection {
    $lockfile = Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Config\lockfile'
    $stream = [IO.FileStream]::new($lockfile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { $parts = $reader.ReadToEnd().Split(':') } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    if ($parts.Count -lt 5 -or $parts[4].Trim() -ne 'https' -or $parts[2] -notmatch '^\d+$') {
        throw 'Riot 本地连接信息无效'
    }
    $authBytes = [Text.Encoding]::ASCII.GetBytes('riot:' + $parts[3])
    return @{
        Base = 'https://127.0.0.1:' + $parts[2]
        Authorization = 'Basic ' + [Convert]::ToBase64String($authBytes)
    }
}

function Invoke-Riot([hashtable]$connection, [string]$method, [string]$path, [string]$body = $null, [int]$timeoutSec = 15) {
    $args = @{
        Uri = $connection.Base + $path
        Method = $method
        Headers = @{ Authorization = $connection.Authorization }
        SkipCertificateCheck = $true
        NoProxy = $true
        TimeoutSec = $timeoutSec
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('body')) {
        $args.ContentType = 'application/json'
        $args.Body = $body
    }
    return Invoke-WebRequest @args
}

function Get-GamePatch([string]$root) {
    $exeVersion = (Get-Item -LiteralPath (Join-Path $root 'Game\League of Legends.exe') -ErrorAction Stop).VersionInfo.FileVersion
    $exePatch = ($exeVersion -split '\.')[0..1] -join '.'
    $metadata = Join-Path $root 'Game\content-metadata.json'
    if (Test-Path -LiteralPath $metadata) {
        $contentVersion = (Get-Content -LiteralPath $metadata -Raw -Encoding utf8 | ConvertFrom-Json).version
        if ($contentVersion -notmatch '^(\d+\.\d+)\.') { throw "游戏资源版本无效：$metadata" }
        if ($Matches[1] -ne $exePatch) { throw "此安装仍有未完成的更新：$root（程序 $exePatch，资源 $($Matches[1])）" }
    }
    return $exePatch
}

function Assert-MatchingPatches {
    $script:cnPatch = Get-GamePatch $cnRoot
    $script:twPatch = Get-GamePatch $twRoot
    if ($cnPatch -ne $twPatch) {
        throw "实际补丁不匹配：国服 $cnPatch（$cnRoot），台服 $twPatch（$twRoot）。两服均显示更新完成，也可能仍处于不同补丁；需要同补丁的国服 zh_CN 资源。"
    }
}

function Copy-Resource([string]$source, [string]$destination) {
    $sourceItem = Get-Item -LiteralPath $source -ErrorAction Stop
    $existing = Get-Item -LiteralPath $destination -ErrorAction SilentlyContinue
    # Equal size does not prove the two patches contain the same resource.
    if ($null -ne $existing -and $existing.Length -eq $sourceItem.Length -and
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { return $false }
    $parent = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
    return $true
}

function Sync-Resources {
    Assert-MatchingPatches
    if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) {
        throw 'League 客户端或对局已打开，请关闭客户端后再使用简中入口'
    }
    $copied = 0
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($cnGame.Length + 1)
        if (Copy-Resource $file.FullName (Join-Path $twGame $relative)) { $copied++ }
    }
    foreach ($relative in $pluginFiles) {
        if (Copy-Resource (Join-Path $cnPlugins $relative) (Join-Path $twPlugins $relative)) { $copied++ }
    }
    Write-Status "简中资源就绪：$($files.Count) 个游戏文件和 $($pluginFiles.Count) 个客户端文件，本次复制 $copied 个"
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '需要 PowerShell 7 (pwsh)' }
    $Locale = if ($Locale -ieq 'zh_CN') { 'zh_CN' } else { 'zh_TW' }
    $localeJson = '"' + $Locale + '"'
    if ($ResourceSource -eq 'Local' -and $Locale -ne 'zh_CN') { throw '国服本地复制模式只适用于 zh_CN；繁中请使用默认官方模式' }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    $cacheRoot = if ($config.cacheRoot) { [IO.Path]::GetFullPath($config.cacheRoot, $PSScriptRoot) } else { Join-Path $PSScriptRoot 'cache' }
    $twRoot = (Resolve-Path -LiteralPath $config.twRoot -ErrorAction Stop).Path.TrimEnd('\')
    $riotExe = (Resolve-Path -LiteralPath $config.riotClientExe -ErrorAction Stop).Path
    $twGame = Join-Path $twRoot 'Game\DATA\FINAL'
    $twPlugins = Join-Path $twRoot 'Plugins'
    $pluginFiles = @("rcp-be-lol-game-data\$Locale-assets.wad", "rcp-fe-lol-typekit\$Locale-assets.wad")
    if ($ResourceSource -eq 'Local') {
        $cnRoot = (Resolve-Path -LiteralPath $config.cnRoot -ErrorAction Stop).Path.TrimEnd('\')
        $cnGame = Join-Path $cnRoot 'Game\DATA\FINAL'
        $cnPlugins = Join-Path $cnRoot 'LeagueClient\Plugins'
        Assert-MatchingPatches
        $files = @(Get-ChildItem -LiteralPath $cnGame -Recurse -File -Filter '*.zh_CN.wad.client')
        if ($files.Count -lt 100 -or -not ($files | Where-Object Name -eq 'Global.zh_CN.wad.client')) {
            throw "国服简中游戏资源不完整：仅找到 $($files.Count) 个文件"
        }
        foreach ($relative in $pluginFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $cnPlugins $relative))) { throw "国服客户端资源缺失：$relative" }
        }
    } else {
        $twPatch = Get-GamePatch $twRoot
    }
    if ($CheckOnly) {
        if ($ResourceSource -eq 'Local') {
            Write-Output "本地资源检查通过：两端均为 $cnPatch；找到 $($files.Count) 个简中游戏资源和 $($pluginFiles.Count) 个客户端资源。"
        } else {
            $installed = @(Get-ChildItem -LiteralPath $twGame -Recurse -File -Filter "*.$Locale.wad.client")
            Write-Output "台服 $twPatch；使用 Riot 官方同补丁 $Locale 资源，不依赖国服版本。当前已有 $($installed.Count) 个游戏语言文件。此检查不启动或下载资源。"
        }
        exit 0
    }

    $mutex = [Threading.Mutex]::new($false, 'Local\LOL_TWtoCN_Launcher')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw '另一个台服语言启动器仍在运行，请等待它完成' }

    if ($BackupOnly) {
        if ($ResourceSource -ne 'Riot') { throw '本地备份仅保存 Riot 官方模式已验证的资源' }
        $connection = Get-RiotConnection
        $state = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
        $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
        if ($state.state -ne 'UpToDate' -or -not $state.launchable -or $current -ne $Locale) { throw "请在 Riot 已完成 $Locale 更新后再建立备份" }
        Save-VerifiedBackup
        exit 0
    }

    if (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue) { throw '对局正在运行，请勿切换语言' }
    if (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue) { throw '请先关闭已打开的 League 客户端' }
    if (-not $PrepareOnly) { Assert-VanguardCooldown $twRoot }
    $connection = Prepare-ControlledPatch

    $launched = $false
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $resourcesReady = $false
    $patchQueued = $true
    $apiUnavailableSince = $null
    do {
        try {
            if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) {
                throw 'League 客户端或对局已打开，停止此次语言设置；请关闭客户端后重试'
            }
            if (-not $patchQueued) {
                $connection = Prepare-ControlledPatch
                $patchQueued = $true
            }
            $connection = Get-RiotConnection
            $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
            if ($current -ne $Locale) {
                $connection = Prepare-ControlledPatch
                $resourcesReady = $false
            }
            # v1 reports only one patchline. v2 covers game and client updates.
            $patch = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
            $apiUnavailableSince = $null
            if ($null -ne $patch.error -or $patch.state -in @('Error','Failed')) {
                throw "Riot 更新失败（$($patch.state)）；请查看 Riot 客户端中的更新错误后重试"
            }
            if ($patch.launchable -eq $true -and $patch.state -eq 'UpToDate') {
                if (-not $resourcesReady) {
                    if ($ResourceSource -eq 'Local') { Sync-Resources } else {
                        $installed = @(Get-ChildItem -LiteralPath $twGame -Recurse -File -Filter "*.$Locale.wad.client")
                        if ($installed.Count -lt 100 -or -not ($installed | Where-Object Name -eq "Global.$Locale.wad.client")) {
                            throw "Riot 更新已结束，但 $Locale 游戏资源不完整：$($installed.Count) 个文件"
                        }
                        foreach ($relative in $pluginFiles) {
                            if (-not (Test-Path -LiteralPath (Join-Path $twPlugins $relative))) { throw "Riot $Locale 客户端资源缺失：$relative" }
                        }
                        Write-Status "Riot 官方 $Locale 资源就绪：$($installed.Count) 个游戏文件，无需复制国服资源"
                        try { Save-VerifiedBackup } catch { Write-Status ('本地备份未更新，继续启动：' + $_.Exception.Message) }
                    }
                    $resourcesReady = $true
                }
            } else {
                $resourcesReady = $false
                $downloaded = [math]::Round($patch.progress.totalBytesDownloaded / 1MB)
                $total = [math]::Round($patch.progress.totalBytesToDownload / 1MB)
                Write-Status "Riot 正在检查或更新资源：$($patch.state)，已下载 $downloaded/$total MB，最多等待 $WaitMinutes 分钟"
                # The explicit-language request is already queued. Do not
                # launch while voice/client downloads are incomplete.
                Start-Sleep -Seconds 10
                continue
            }
            if ($PrepareOnly -and $resourcesReady) {
                Write-Status "已完成 $Locale 资源准备与官方校验；未启动游戏客户端"
                exit 0
            }
            $null = Invoke-Riot $connection 'POST' '/product-launcher/v1/products/league_of_legends/patchlines/live' '{}' 30
            if ($resourcesReady) { $launched = $true; break }
            if (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue) {
                throw 'Riot 在所选语言资源准备好之前打开了客户端，请关闭 League 客户端后重试'
            }
        } catch {
            if ($resourcesReady -and (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue)) {
                $launched = $true
                break
            }
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $timedOut = $_.Exception.Message -match 'Timeout|timed out|超时'
            if ($status -eq 404) {
                # Riot can restart itself for a client update. Re-read the
                # lockfile on the next poll, but reject persistently missing APIs.
                if ($null -eq $apiUnavailableSince) { $apiUnavailableSince = Get-Date }
                if (((Get-Date) - $apiUnavailableSince).TotalSeconds -ge 60) { throw }
                $patchQueued = $false
                Write-Status 'Riot 本地接口暂时未就绪，正在重新连接后台（最多一分钟）'
            } elseif ($status -ne 423 -and $status -ne 424 -and -not $timedOut) { throw }
            $resourcesReady = $false
            Write-Status "Riot 尚未允许启动（$status），继续等待资源检查或更新"
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if (-not $launched) { throw "等待 Riot 更新或依赖检查超过 $WaitMinutes 分钟；请在 Riot 客户端检查更新、登录或 Vanguard 状态后重试" }
    $clientDeadline = (Get-Date).AddSeconds(60)
    while (-not (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $clientDeadline) {
        Start-Sleep -Seconds 2
    }
    if (-not (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue)) {
        throw 'Riot 接受了请求，但 League 客户端未在一分钟内打开；请查看 Riot 客户端中的错误提示'
    }
    $current = (Invoke-Riot (Get-RiotConnection) 'GET' $localePath).Content | ConvertFrom-Json
    if ($current -ne $Locale) { throw "客户端已打开，但 Riot 语言变为 $current；所选语言启动未确认成功" }
    $clientProcess = Get-Process -Name LeagueClient -ErrorAction Stop | Select-Object -First 1
    Write-Status '客户端已打开，正在确认 Vanguard 登录状态'
    Wait-VanguardLogin $twRoot $clientProcess.Id
    Write-Status 'Vanguard 登录已确认正常'
    Write-Status "已以 $Locale 启动台服英雄联盟"
} catch {
    $failure = $_.Exception.Message
    Write-Status ('启动失败：' + $failure)
    if ($ShowErrors -and -not $CheckOnly) {
        try { $null = (New-Object -ComObject WScript.Shell).Popup("$failure`n`n日志：$logPath", 0, "台服 LOL $Locale 启动失败", 16) } catch { }
    }
    exit 1
} finally {
    if ($null -ne $patchLockConnection) {
        try { Unlock-RiotPatch } catch { Write-Status ('释放 Riot 更新锁失败：' + $_.Exception.Message) }
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
