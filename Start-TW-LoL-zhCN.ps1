param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'config.local.json'
$localePath = '/riotclient/product-locales/products/league_of_legends/patchlines/live'
$logDir = Join-Path $env:LOCALAPPDATA 'LOL_TWtoCN'
$logPath = Join-Path $logDir 'launcher.log'

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

function Invoke-Riot([hashtable]$connection, [string]$method, [string]$path, [string]$body = $null) {
    $args = @{
        Uri = $connection.Base + $path
        Method = $method
        Headers = @{ Authorization = $connection.Authorization }
        SkipCertificateCheck = $true
        TimeoutSec = 15
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('body')) {
        $args.ContentType = 'application/json'
        $args.Body = $body
    }
    return Invoke-WebRequest @args
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '需要 PowerShell 7 (pwsh)' }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    $cnRoot = (Resolve-Path -LiteralPath $config.cnRoot -ErrorAction Stop).Path.TrimEnd('\')
    $twRoot = (Resolve-Path -LiteralPath $config.twRoot -ErrorAction Stop).Path.TrimEnd('\')
    $riotExe = (Resolve-Path -LiteralPath $config.riotClientExe -ErrorAction Stop).Path
    $cnGame = Join-Path $cnRoot 'Game\DATA\FINAL'
    $twGame = Join-Path $twRoot 'Game\DATA\FINAL'
    $cnPlugins = Join-Path $cnRoot 'LeagueClient\Plugins'
    $twPlugins = Join-Path $twRoot 'Plugins'

    $cnVersion = (Get-Item -LiteralPath (Join-Path $cnRoot 'Game\League of Legends.exe') -ErrorAction Stop).VersionInfo.FileVersion
    $twVersion = (Get-Item -LiteralPath (Join-Path $twRoot 'Game\League of Legends.exe') -ErrorAction Stop).VersionInfo.FileVersion
    $cnPatch = ($cnVersion -split '\.')[0..1] -join '.'
    $twPatch = ($twVersion -split '\.')[0..1] -join '.'
    if ($cnPatch -ne $twPatch) { throw "国服版本 $cnPatch 与台服版本 $twPatch 不匹配；请先更新两端" }

    $files = @(Get-ChildItem -LiteralPath $cnGame -Recurse -File -Filter '*.zh_CN.wad.client')
    if ($files.Count -lt 100 -or -not ($files | Where-Object Name -eq 'Global.zh_CN.wad.client')) {
        throw "国服简中游戏资源不完整：仅找到 $($files.Count) 个文件"
    }
    $pluginFiles = @('rcp-be-lol-game-data\zh_CN-assets.wad', 'rcp-fe-lol-typekit\zh_CN-assets.wad')
    foreach ($relative in $pluginFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $cnPlugins $relative))) {
            throw "国服客户端资源缺失：$relative"
        }
    }
    if ($CheckOnly) {
        Write-Output "检查通过：两端均为 $cnPatch；找到 $($files.Count) 个简中游戏资源和 $($pluginFiles.Count) 个客户端资源。"
        exit 0
    }

    if (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue) { throw '对局正在运行，请勿切换语言' }
    if (Get-Process -Name 'LeagueClient' -ErrorAction SilentlyContinue) { throw '请先关闭已打开的 League 客户端' }

    if (-not (Get-Process -Name 'RiotClientServices' -ErrorAction SilentlyContinue)) {
        Write-Status '正在启动 Riot 客户端'
        Start-Process -FilePath $riotExe -ArgumentList @('--launch-product=league_of_legends', '--launch-patchline=live') -WindowStyle Hidden
    }

    $deadline = (Get-Date).AddSeconds(120)
    $ready = $false
    do {
        try {
            $connection = Get-RiotConnection
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

    $copied = 0
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($cnGame.Length + 1)
        $destination = Join-Path $twGame $relative
        $parent = Split-Path -Path $destination -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $existing = Get-Item -LiteralPath $destination -ErrorAction SilentlyContinue
        if ($null -eq $existing -or $existing.Length -ne $file.Length) {
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
            $copied++
        }
    }
    foreach ($relative in $pluginFiles) {
        $source = Join-Path $cnPlugins $relative
        $destination = Join-Path $twPlugins $relative
        $parent = Split-Path -Path $destination -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $existing = Get-Item -LiteralPath $destination -ErrorAction SilentlyContinue
        $sourceItem = Get-Item -LiteralPath $source -ErrorAction Stop
        if ($null -eq $existing -or $existing.Length -ne $sourceItem.Length) {
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        }
    }
    Write-Status "简中资源就绪：$($files.Count) 个游戏文件，本次复制 $copied 个"

    $launched = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $null = Invoke-Riot $connection 'PUT' $localePath '"zh_CN"'
            $null = Invoke-Riot $connection 'POST' '/product-launcher/v1/products/league_of_legends/patchlines/live' '{}'
            $launched = $true
            break
        } catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -ne 424 -or $attempt -eq 6) { throw }
            Write-Status "Riot 正在完成修复，稍后重试（$attempt/6）"
            Start-Sleep -Seconds 10
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($cnGame.Length + 1)
                $destination = Join-Path $twGame $relative
                if (-not (Test-Path -LiteralPath $destination)) {
                    Copy-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
                }
            }
        }
    }
    if (-not $launched) { throw 'Riot 未接受游戏启动请求' }
    Write-Status '已以 zh_CN 启动台服英雄联盟'
} catch {
    Write-Status ('启动失败：' + $_.Exception.Message)
    exit 1
}
