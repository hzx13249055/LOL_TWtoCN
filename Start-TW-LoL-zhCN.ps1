param(
    [switch]$CheckOnly,
    [switch]$ShowErrors,
    [switch]$BackupOnly,
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

function Save-VerifiedBackup {
    Write-Status "正在核对并保存本地 $Locale 备份：$cacheRoot"
    $saved = Save-ResourceBackup $twRoot $cacheRoot $Locale
    Write-Status "本地备份就绪：$($saved.FileCount) 个资源，新增 $($saved.AddedFiles) 个文件（$([math]::Round($saved.AddedBytes / 1MB)) MB）"
}

function Restore-MissingBackup {
    $restored = Restore-ResourceBackup $twRoot $cacheRoot $Locale
    if ($restored.Restored -gt 0) { Write-Status "已从同版本本地备份恢复 $($restored.Restored) 个缺失资源，继续由 Riot 校验" | Out-Host }
    if ($restored.Rejected -gt 0) { Write-Status "本地备份中 $($restored.Rejected) 个资源未通过校验，交给 Riot 下载" | Out-Host }
    return $restored
}

function Stop-RiotForResourceSwitch {
    if (-not (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue)) { return }
    if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) { throw '请先正常关闭 League 客户端，再切换语言' }
    $connection = Get-RiotConnection
    if ($ResourceSource -eq 'Riot') {
        $before = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
        $previousLocale = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
        if ($before.state -eq 'UpToDate' -and $before.launchable -and $previousLocale -in @('zh_CN','zh_TW') -and $previousLocale -ne $Locale) {
            try {
                $saved = Save-ResourceBackup $twRoot $cacheRoot $previousLocale
                Write-Status "切换前已保存 $previousLocale 备份：$($saved.FileCount) 个资源"
            } catch { Write-Status ('另一语言备份未更新：' + $_.Exception.Message) }
        }
    }
    Write-Status '正在正常退出 Riot 后台，先准备语言缓存，再重新打开'
    try { $null = Invoke-Riot $connection 'POST' '/riot-client-lifecycle/v1/quit' } catch {
        if (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) { throw }
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) { throw 'Riot 未正常退出；请结束其它 Riot 游戏后重试，不会强制关闭正在运行的游戏' }
    if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) { throw '检测到客户端或对局，取消语言资源切换' }
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

    $needsValidation = $false
    Stop-RiotForResourceSwitch
    if (-not (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue)) {
        if ($ResourceSource -eq 'Riot') {
            $otherLocale = if ($Locale -eq 'zh_CN') { 'zh_TW' } else { 'zh_CN' }
            try {
                $released = Release-BackedUpLanguage $twRoot $cacheRoot $otherLocale
                if ($released.Released -gt 0) { Write-Status "已校验 $otherLocale 的独立备份，释放游戏目录中的 $($released.Released) 个资源（$([math]::Round($released.Bytes / 1MB)) MB）" }
                if ($released.Unverified -gt 0) { Write-Status "$($released.Unverified) 个另一语言资源尚无一致备份，保留原文件" }
            } catch { Write-Status ('未释放另一语言资源：' + $_.Exception.Message) }
            try {
                $preRestore = Restore-MissingBackup
                $needsValidation = $preRestore.Restored -gt 0 -or $preRestore.Rejected -gt 0
            } catch { Write-Status ('本地备份未恢复，继续交给 Riot：' + $_.Exception.Message) }
        }
        Write-Status '正在启动 Riot 客户端'
        Start-Process -FilePath $riotExe -WindowStyle Hidden
    }

    # Set the product locale as soon as Riot's local API opens. Waiting for
    # launcher eligibility lets the patcher inspect selected assets as extras.
    $deadline = (Get-Date).AddSeconds(120)
    $earlyLocaleSet = $false
    do {
        try {
            $connection = Get-RiotConnection
            $null = Invoke-Riot $connection 'PUT' $localePath $localeJson 3
            $earlyLocaleSet = $true
            break
        } catch { Start-Sleep -Milliseconds 250 }
    } while ((Get-Date) -lt $deadline)
    if (-not $earlyLocaleSet) { throw 'Riot 客户端未能在两分钟内接受语言设置' }
    Write-Status "已在 Riot 启动早期设置 $Locale"

    $ready = $false
    do {
        try {
            $null = Invoke-Riot $connection 'GET' '/product-launcher/v1/products/league_of_legends/patchlines/live/eligibility'
            $ready = $true
            break
        } catch { Start-Sleep -Seconds 2 }
    } while ((Get-Date) -lt $deadline)
    if (-not $ready) { throw 'Riot 客户端未能在两分钟内准备就绪' }

    $null = Invoke-Riot $connection 'PUT' $localePath $localeJson
    $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
    if ($current -ne $Locale) { throw "Riot 未接受 $Locale；当前为 $current" }
    Write-Status "已将台服游戏语言设为 $Locale"
    if ($needsValidation) {
        $null = Invoke-Riot $connection 'POST' '/patch-proxy/v2/patch-states/refresh/products/league_of_legends/patchlines/live' '{"quickValidation":false,"force":true,"forLaunch":true}'
        Write-Status '已要求 Riot 完整校验启动前恢复的资源'
    }

    $launched = $false
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $resourcesReady = $false
    $patchQueued = $false
    $apiUnavailableSince = $null
    do {
        try {
            if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) {
                throw 'League 客户端或对局已打开，停止此次语言设置；请关闭客户端后重试'
            }
            $connection = Get-RiotConnection
            $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
            if ($current -ne $Locale) { $null = Invoke-Riot $connection 'PUT' $localePath $localeJson; $resourcesReady = $false }
            # v1 reports only one patchline. v2 covers game and client updates.
            $patch = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
            $apiUnavailableSince = $null
            if ($null -ne $patch.error -or $patch.state -in @('Error','Failed')) {
                throw "Riot 更新失败（$($patch.state)）；请查看 Riot 客户端中的更新错误后重试"
            }
            if ($patch.launchable -eq $true -and $patch.state -eq 'UpToDate') {
                if (-not $resourcesReady) {
                    if ($ResourceSource -eq 'Local') { Sync-Resources } else {
                        # UpToDate is idle. Active patching never receives writes.
                        $restored = $null
                        try { $restored = Restore-MissingBackup } catch { Write-Status ('本地备份不可用，继续检查官方资源：' + $_.Exception.Message) }
                        if ($restored.Restored -gt 0 -or $restored.Rejected -gt 0) {
                            $null = Invoke-Riot $connection 'POST' '/patch-proxy/v2/patch-states/refresh/products/league_of_legends/patchlines/live' '{"quickValidation":false,"force":true,"forLaunch":true}'
                            Write-Status '已要求 Riot 完整校验恢复后的资源，等待校验完成再启动'
                            Start-Sleep -Seconds 2
                            continue
                        }
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
                # Launch can pause unfinished voice downloads even when Riot
                # says launchable. Request patching separately and wait fully.
                if (-not $patchQueued) {
                    $null = Invoke-Riot $connection 'PUT' '/patch-proxy/v2/priority-patch/products/league_of_legends/patchlines/live' '{}'
                    $patchQueued = $true
                }
                Start-Sleep -Seconds 10
                continue
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
    Write-Status "已以 $Locale 启动台服英雄联盟"
} catch {
    $failure = $_.Exception.Message
    Write-Status ('启动失败：' + $failure)
    if ($ShowErrors -and -not $CheckOnly) {
        try { $null = (New-Object -ComObject WScript.Shell).Popup("$failure`n`n日志：$logPath", 0, "台服 LOL $Locale 启动失败", 16) } catch { }
    }
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
