param(
    [switch]$CheckOnly,
    [switch]$ShowErrors,
    [switch]$BackupOnly,
    [switch]$PrepareOnly,
    [ValidateSet('zh_CN')][string]$Locale = 'zh_CN',
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

function Save-VerifiedBackup {
    Write-Status "正在核对并保存本地 $Locale 备份：$cacheRoot"
    $saved = Save-ResourceBackup $twRoot $cacheRoot $Locale
    Write-Status "本地备份就绪：$($saved.FileCount) 个资源，新增 $($saved.AddedFiles) 个文件（$([math]::Round($saved.AddedBytes / 1MB)) MB）"
}

function Get-FullRiotConnection {
    $started = $false
    $deadline = (Get-Date).AddSeconds(45)
    $nextStatus = (Get-Date).AddSeconds(10)
    do {
        try {
            $connection = Get-RiotConnection
            $null = Invoke-Riot $connection 'GET' $localePath $null 3
            return $connection
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -notin @(0,404,423,424,503)) { throw }
            if (-not $started) {
                Write-Status '正在打开 Riot 简中入口，等待本地语言接口（最多 45 秒）' | Out-Host
                Start-Process -FilePath $riotExe -WindowStyle Hidden
                $started = $true
            }
            if ((Get-Date) -ge $nextStatus) {
                Write-Status 'Riot 本地语言接口仍在初始化，继续等待' | Out-Host
                $nextStatus = (Get-Date).AddSeconds(10)
            }
            Start-Sleep -Milliseconds 500
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Riot 本地语言接口未在 45 秒内就绪，请检查 Riot 的登录或更新提示'
}

function Prepare-SimplifiedPatch {
    $deadline = (Get-Date).AddSeconds(45)
    do {
        try {
            $connection = Get-FullRiotConnection
            $null = Invoke-Riot $connection 'PUT' $localePath '"zh_CN"'
            # Cancel an old default-language job without taking a session lock.
            # No resource files are written while Riot is running.
            $null = Invoke-Riot $connection 'DELETE' '/patch-proxy/v2/patch-jobs/products/league_of_legends/patchlines/live'
            $null = Invoke-Riot $connection 'PUT' $patchRequestPath '{"locale":"zh_CN","createShortcut":false,"isRepair":false}'
            Write-Status '已提交 zh_CN 官方更新请求（简中单入口）' | Out-Host
            return $connection
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -notin @(0,404,423,424,503)) { throw }
            Write-Status 'Riot 正在初始化更新接口，稍后重试简中请求' | Out-Host
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Riot 未在 45 秒内接受简中更新请求，请查看客户端提示'
}

function Prepare-OfflineCache {
    if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) { throw '客户端或对局正在运行，取消资源准备' }
    if ($ResourceSource -eq 'Riot') {
        try {
            $manifest = Read-ResourceBackup $twRoot $cacheRoot 'zh_CN'
            $needsRestore = $false
            if ($null -ne $manifest) {
                foreach ($entry in $manifest.entries) {
                    $path = Get-BackupEntryPath $twRoot $entry.path 'zh_CN'
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                        (Get-Item -LiteralPath $path).Length -ne $entry.length -or
                        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) { $needsRestore = $true; break }
                }
            }
            if (-not $needsRestore) {
                Write-Status '现有资源无需从缓存恢复，保留 Riot 当前登录会话' | Out-Host
                return
            }
        } catch {
            Write-Status ('缓存清单不可用，保留 Riot 会话并使用官方更新：' + $_.Exception.Message) | Out-Host
            return
        }
    }
    if (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) {
        $connection = Get-FullRiotConnection
        Write-Status '正在正常退出 Riot，离线复用简中缓存' | Out-Host
        try { $null = Invoke-Riot $connection 'POST' '/riot-client-lifecycle/v1/quit' } catch {
            if (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) { throw }
        }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
        if (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue) { throw 'Riot 未正常退出，取消缓存写入；请关闭 Riot 后重试' }
    }
    if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) { throw '客户端或对局正在运行，取消资源恢复' }
    if ($ResourceSource -eq 'Riot') {
        try {
            Write-Status '正在核对同版本简中缓存' | Out-Host
            $restored = Restore-ResourceBackup $twRoot $cacheRoot 'zh_CN' -RepairExisting
            Write-Status "简中缓存：复用已匹配资源，恢复 $($restored.Restored) 个文件，拒绝 $($restored.Rejected) 个损坏备份" | Out-Host
        } catch { Write-Status ('本地缓存不可用，交给 Riot 官方更新：' + $_.Exception.Message) | Out-Host }
    }
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
    $Locale = 'zh_CN'
    $localeJson = '"' + $Locale + '"'
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
    Prepare-OfflineCache
    $connection = Prepare-SimplifiedPatch

    $launched = $false
    $launchRequested = $false
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $resourcesReady = $false
    $patchQueued = $true
    $pausedResumes = 0
    $loginWaitSince = $null
    $apiUnavailableSince = $null
    do {
        try {
            if (Get-Process -Name 'League of Legends','LeagueClient' -ErrorAction SilentlyContinue) {
                throw 'League 客户端或对局已打开，停止此次语言设置；请关闭客户端后重试'
            }
            if (-not $patchQueued) {
                $connection = Prepare-SimplifiedPatch
                $patchQueued = $true
            }
            $connection = Get-RiotConnection
            $current = (Invoke-Riot $connection 'GET' $localePath).Content | ConvertFrom-Json
            if ($current -ne $Locale) {
                $connection = Prepare-SimplifiedPatch
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
                if ($patch.state -eq 'Paused') {
                    $pausedResumes++
                    if ($pausedResumes -gt 3) { throw 'Riot 更新任务连续暂停，自动恢复三次仍未完成；请检查 Riot 登录或更新提示后重试' }
                    $null = Invoke-Riot $connection 'PUT' $patchRequestPath '{"locale":"zh_CN","createShortcut":false,"isRepair":false}'
                    Write-Status "已恢复暂停的简中更新任务（$pausedResumes/3）"
                }
                # The explicit-language request is already queued. Do not
                # launch while voice/client downloads are incomplete.
                Start-Sleep -Seconds 10
                continue
            }
            if ($PrepareOnly -and $resourcesReady) {
                Write-Status "已完成 $Locale 资源准备与官方校验；未启动游戏客户端"
                exit 0
            }
            $authorizationReady = $false
            try {
                $auth = Invoke-Riot $connection 'GET' '/rso-auth/v1/authorization' $null 3
                $authorizationReady = $auth.StatusCode -eq 200
            } catch {
                $authStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($authStatus -notin @(0,401,403,404,503)) { throw }
            }
            $eligible = if ($authorizationReady) { (Invoke-Riot $connection 'GET' '/product-launcher/v1/products/league_of_legends/patchlines/live/eligibility').Content | ConvertFrom-Json } else { $false }
            if (-not $authorizationReady -or $eligible -ne $true) {
                if ($null -eq $loginWaitSince) { $loginWaitSince = Get-Date }
                if (((Get-Date) - $loginWaitSince).TotalSeconds -ge 120) { throw '简中资源已就绪，但 Riot 登录会话或启动资格仍未就绪；请在 Riot 中完成登录后再使用入口' }
                Write-Status '简中资源已就绪，等待 Riot 登录会话和启动资格；暂不启动游戏'
                Start-Sleep -Seconds 5
                continue
            }
            $launchRequested = $true
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
            if ($launchRequested -and $resourcesReady -and ($status -eq 0 -or $timedOut)) {
                # A local HTTP timeout does not cancel Riot's launch. Wait for
                # that one request, then verify the client and Vanguard below.
                Write-Status 'Riot 启动请求尚未返回，等待此次客户端启动（不重复提交）'
                $launched = $true
                break
            }
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
    $vanguardConfirmed = Wait-VanguardLogin $twRoot $clientProcess.Id -TimeoutSeconds 15 -AllowPendingLogin
    if ($vanguardConfirmed) {
        Write-Status 'Vanguard 登录已确认正常'
    } else {
        Write-Status '简中客户端已打开；账户或 Vanguard 登录尚未完成，请在客户端完成登录。不重复启动游戏。'
    }
    Write-Status "已以 $Locale 启动台服英雄联盟客户端"
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
