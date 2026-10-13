param(
    [switch]$CheckOnly,
    [switch]$ShowErrors,
    [switch]$BackupOnly,
    [switch]$PrepareOnly,
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
$patchRequestPath = '/patch-proxy/v2/priority-patch/products/league_of_legends/patchlines/live'

function Request-CnPatch([hashtable]$connection, [switch]$ResetJob) {
    $null = Invoke-Riot $connection 'PUT' $localePath '"zh_CN"'
    if ($ResetJob) {
        $null = Invoke-Riot $connection 'DELETE' '/patch-proxy/v2/patch-jobs/products/league_of_legends/patchlines/live'
    }
    $null = Invoke-Riot $connection 'PUT' $patchRequestPath '{"locale":"zh_CN","createShortcut":false,"isRepair":false}'
    Write-Status '已提交明确指定 zh_CN 的官方校验与更新请求' | Out-Host
}

function Save-VerifiedBackup {
    Write-Status "正在核对并保存本地简中备份：$cacheRoot"
    $saved = Save-ResourceBackup $twRoot $cacheRoot
    Write-Status "本地备份就绪：$($saved.FileCount) 个资源，新增 $($saved.AddedFiles) 个文件（$([math]::Round($saved.AddedBytes / 1MB)) MB）"
}

function Restore-MissingBackup {
    $restored = Restore-ResourceBackup $twRoot $cacheRoot
    if ($restored.Restored -gt 0) { Write-Status "已从同版本本地备份恢复 $($restored.Restored) 个缺失资源，继续由 Riot 校验" | Out-Host }
    if ($restored.Rejected -gt 0) { Write-Status "本地备份中 $($restored.Rejected) 个资源未通过校验，交给 Riot 下载" | Out-Host }
    return $restored
}

function Assert-ClientLogin([int]$ClientId) {
    $file = Get-ChildItem -LiteralPath (Join-Path $twRoot 'Logs\LeagueClient Logs') -File -Filter "*_${ClientId}_LeagueClient.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { return }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $failures = [regex]::Matches($text, '(?m)^\d+(?:\.\d+)?\|[^\r\n]*rcp-be-lol-login\|[^\r\n]*(SUMMONER_FAILURE|Login auth faild with gaps)')
    $successes = [regex]::Matches($text, '(?m)^\d+(?:\.\d+)?\|[^\r\n]*rcp-be-lol-login\|\s*Login complete\.')
    if ($failures.Count -eq 0 -or ($successes.Count -gt 0 -and $successes[-1].Index -gt $failures[-1].Index)) { return }
    if ($text -match '<title>Attention Required! \| Cloudflare</title>') {
        throw '简中资源已校验，但台服账号资料被 Cloudflare 拒绝；请更换雷神台服线路后重试'
    }
    throw '简中资源已校验，但台服账号登录失败；请检查 Riot 登录提示和雷神台服线路'
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
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    $cacheRoot = if ($config.cacheRoot) { [IO.Path]::GetFullPath($config.cacheRoot, $PSScriptRoot) } else { Join-Path $PSScriptRoot 'cache' }
    $twRoot = (Resolve-Path -LiteralPath $config.twRoot -ErrorAction Stop).Path.TrimEnd('\')
    $riotExe = (Resolve-Path -LiteralPath $config.riotClientExe -ErrorAction Stop).Path
    $twGame = Join-Path $twRoot 'Game\DATA\FINAL'
    $twPlugins = Join-Path $twRoot 'Plugins'
    $pluginFiles = @('rcp-be-lol-game-data\zh_CN-assets.wad', 'rcp-fe-lol-typekit\zh_CN-assets.wad')
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
            $installed = @(Get-ChildItem -LiteralPath $twGame -Recurse -File -Filter '*.zh_CN.wad.client')
            Write-Output "台服 $twPatch；使用 Riot 官方同补丁 zh_CN 资源，不依赖国服版本。当前已有 $($installed.Count) 个游戏语言文件。此检查不启动或下载资源。"
        }
        exit 0
    }

    $mutex = [Threading.Mutex]::new($false, 'Local\LOL_TWtoCN_Launcher')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw '另一个简中启动器仍在运行，请等待它完成' }

    if ($BackupOnly) {
        if ($ResourceSource -ne 'Riot') { throw '本地备份仅保存 Riot 官方模式已验证的资源' }
        $connection = Get-RiotConnection
        $state = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
        $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
        if ($state.state -ne 'UpToDate' -or -not $state.launchable -or $current -ne 'zh_CN') { throw '请在 Riot 已完成 zh_CN 更新后再建立备份' }
        Save-VerifiedBackup
        exit 0
    }

    if (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue) { throw '对局正在运行，请勿切换语言' }
    if (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue) { throw '请先关闭已打开的 League 客户端' }

    $riotWakeRequested = $false
    if (-not (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue)) {
        if ($ResourceSource -eq 'Riot') {
            try { $null = Restore-MissingBackup } catch { Write-Status ('本地备份未恢复，继续交给 Riot：' + $_.Exception.Message) }
        }
        Write-Status '正在启动 Riot 客户端'
        Start-Process -FilePath $riotExe -WindowStyle Hidden
        $riotWakeRequested = $true
    }

    # Set the product locale as soon as Riot's local API opens. Waiting for
    # launcher eligibility lets the patcher inspect zh_CN assets as extras.
    $deadline = (Get-Date).AddSeconds(120)
    $earlyLocaleSet = $false
    do {
        try {
            $connection = Get-RiotConnection
            $null = Invoke-Riot $connection 'PUT' $localePath '"zh_CN"' 3
            $earlyLocaleSet = $true
            break
        } catch {
            if (-not $riotWakeRequested) {
                Start-Process -FilePath $riotExe -WindowStyle Hidden
                $riotWakeRequested = $true
            }
            Start-Sleep -Milliseconds 250
        }
    } while ((Get-Date) -lt $deadline)
    if (-not $earlyLocaleSet) { throw 'Riot 客户端未能在两分钟内接受语言设置' }
    Write-Status '已在 Riot 启动早期设置 zh_CN'

    $ready = $false
    do {
        try {
            $null = Invoke-Riot $connection 'GET' '/product-launcher/v1/products/league_of_legends/patchlines/live/eligibility'
            $ready = $true
            break
        } catch { Start-Sleep -Seconds 2 }
    } while ((Get-Date) -lt $deadline)
    if (-not $ready) { throw 'Riot 客户端未能在两分钟内准备就绪' }

    $null = Invoke-Riot $connection 'PUT' $localePath '"zh_CN"'
    $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
    if ($current -ne 'zh_CN') { throw "Riot 未接受 zh_CN；当前为 $current" }
    Write-Status '已将台服游戏语言设为 zh_CN'

    $launched = $false
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $resourcesReady = $false
    $patchQueued = $false
    $stableChecks = 0
    $pausedResumes = 0
    $launchRequested = $false
    do {
        try {
            if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) {
                throw 'League 客户端或对局已打开，停止此次语言设置；请关闭客户端后重试'
            }
            $connection = Get-RiotConnection
            $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
            if ($current -ne 'zh_CN') { $patchQueued = $false; $resourcesReady = $false }
            if (-not $patchQueued) {
                Request-CnPatch $connection -ResetJob
                $patchQueued = $true
                $stableChecks = 0
                Start-Sleep -Seconds 2
                continue
            }
            # v1 reports only one patchline. v2 covers game and client updates.
            $patch = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
            if ($null -ne $patch.error -or $patch.state -in @('Error','Failed')) {
                throw "Riot 更新失败（$($patch.state)）；请查看 Riot 客户端中的更新错误后重试"
            }
            if ($patch.launchable -eq $true -and $patch.state -eq 'UpToDate') {
                $stableChecks++
                if ($stableChecks -lt 2) { Start-Sleep -Seconds 2; continue }
                if (-not $resourcesReady) {
                    if ($ResourceSource -eq 'Local') { Sync-Resources } else {
                        # UpToDate is idle. Active patching never receives writes.
                        $restored = $null
                        try { $restored = Restore-MissingBackup } catch { Write-Status ('本地备份不可用，继续检查官方资源：' + $_.Exception.Message) }
                        if ($restored.Restored -gt 0 -or $restored.Rejected -gt 0) {
                            Request-CnPatch $connection -ResetJob
                            $stableChecks = 0
                            Write-Status '已要求 Riot 完整校验恢复后的资源，等待校验完成再启动'
                            Start-Sleep -Seconds 2
                            continue
                        }
                        $installed = @(Get-ChildItem -LiteralPath $twGame -Recurse -File -Filter '*.zh_CN.wad.client')
                        if ($installed.Count -lt 100 -or -not ($installed | Where-Object Name -eq 'Global.zh_CN.wad.client')) {
                            throw "Riot 更新已结束，但 zh_CN 游戏资源不完整：$($installed.Count) 个文件"
                        }
                        foreach ($relative in $pluginFiles) {
                            if (-not (Test-Path -LiteralPath (Join-Path $twPlugins $relative))) { throw "Riot zh_CN 客户端资源缺失：$relative" }
                        }
                        Write-Status "Riot zh_CN 校验与更新已完成：$($installed.Count) 个游戏文件"
                        try { Save-VerifiedBackup } catch { Write-Status ('本地备份未更新，继续启动：' + $_.Exception.Message) }
                    }
                    $resourcesReady = $true
                }
            } else {
                $resourcesReady = $false
                $stableChecks = 0
                $downloaded = [math]::Round($patch.progress.totalBytesDownloaded / 1MB)
                $total = [math]::Round($patch.progress.totalBytesToDownload / 1MB)
                Write-Status "Riot 正在检查或更新资源：$($patch.state)，已下载 $downloaded/$total MB，最多等待 $WaitMinutes 分钟"
                # Launch can pause unfinished voice downloads even when Riot
                # says launchable. Request patching separately and wait fully.
                if ($patch.state -eq 'Paused') {
                    $pausedResumes++
                    if ($pausedResumes -gt 3) { throw '简中更新连续暂停，自动恢复三次仍未完成；请查看 Riot 更新提示' }
                    Request-CnPatch $connection
                    Write-Status "已恢复暂停的简中任务（$pausedResumes/3）"
                }
                Start-Sleep -Seconds 10
                continue
            }
            # Backup hashing can take time; verify Riot is still ready afterward.
            $latest = (Invoke-Riot $connection 'GET' '/patch-proxy/v2/patch-states/products/league_of_legends/patchlines/live').Content | ConvertFrom-Json
            $latestLocale = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
            if ($latest.state -ne 'UpToDate' -or -not $latest.launchable -or $latestLocale -ne 'zh_CN') {
                $resourcesReady = $false
                $stableChecks = 0
                if ($latestLocale -ne 'zh_CN') { $patchQueued = $false }
                continue
            }
            if ($PrepareOnly) {
                Write-Status '简中资源准备与官方校验已完成；未启动 League 客户端'
                exit 0
            }
            $eligible = (Invoke-Riot $connection 'GET' '/product-launcher/v1/products/league_of_legends/patchlines/live/eligibility').Content | ConvertFrom-Json
            if ($eligible -ne $true) {
                Write-Status '简中资源已校验，等待 Riot 登录或启动资格'
                Start-Sleep -Seconds 5
                continue
            }
            $launchRequested = $true
            $null = Invoke-Riot $connection 'POST' '/product-launcher/v1/products/league_of_legends/patchlines/live' '{}' 30
            if ($resourcesReady) { $launched = $true; break }
            if (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue) {
                throw 'Riot 在简中资源准备好之前打开了客户端，请关闭 League 客户端后重试'
            }
        } catch {
            if ($resourcesReady -and (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue)) {
                $launched = $true
                break
            }
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $timedOut = $_.Exception.Message -match 'Timeout|timed out|超时'
            if ($launchRequested -and $resourcesReady -and $timedOut) {
                Write-Status 'Riot 启动请求超时，等待本次启动结果，不重复提交'
                $launched = $true
                break
            }
            if ($status -ne 423 -and $status -ne 424 -and -not $timedOut) { throw }
            $resourcesReady = $false
            $launchRequested = $false
            $stableChecks = 0
            if ($status -eq 424) { $patchQueued = $false }
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
    if ($current -ne 'zh_CN') { throw "客户端已打开，但 Riot 语言变为 $current；简中启动未确认成功" }
    Write-Status '简中客户端已打开，正在检查本次登录错误'
    Start-Sleep -Seconds 12
    $client = Get-Process -Name LeagueClient -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $client) { throw 'League 客户端在启动后退出，请查看 Riot 提示' }
    Assert-ClientLogin $client.Id
    Write-Status '已以 zh_CN 启动台服英雄联盟'
} catch {
    $failure = $_.Exception.Message
    Write-Status ('启动失败：' + $failure)
    if ($ShowErrors -and -not $CheckOnly) {
        try { $null = (New-Object -ComObject WScript.Shell).Popup("$failure`n`n日志：$logPath", 0, '台服 LOL 简中启动失败', 16) } catch { }
    }
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
