param(
    [string]$CnRoot,
    [string]$CacheRoot,
    [Parameter(Mandatory = $true)][string]$TwRoot,
    [string]$RiotClientExe = 'C:\Riot Games\Riot Client\RiotClientServices.exe',
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) '台服 LOL 简体中文.lnk'),
    [string]$TraditionalShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) '台服 LOL 繁体中文.lnk')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw '请使用 PowerShell 7 (pwsh) 运行安装脚本。' }

$pwsh = (Get-Process -Id $PID -ErrorAction Stop).Path
$cn = if ($CnRoot) { (Resolve-Path -LiteralPath $CnRoot -ErrorAction Stop).Path.TrimEnd('\') } else { $null }
$tw = (Resolve-Path -LiteralPath $TwRoot -ErrorAction Stop).Path.TrimEnd('\')
$riot = (Resolve-Path -LiteralPath $RiotClientExe -ErrorAction Stop).Path
$launcher = Join-Path $PSScriptRoot 'Start-TW-LoL-zhCN.ps1'

foreach ($path in @(
    (Join-Path $tw 'LeagueClient.exe'),
    (Join-Path $tw 'Game\League of Legends.exe'),
    (Join-Path $tw 'Game\DATA\FINAL'),
    (Join-Path $tw 'Plugins'),
    (Join-Path $PSScriptRoot 'Resource-Backup.ps1'),
    (Join-Path $PSScriptRoot 'Product-Locale.ps1'),
    (Join-Path $PSScriptRoot 'Vanguard-Status.ps1'),
    $launcher
)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少所需文件或目录：$path" }
}

$configPath = Join-Path $PSScriptRoot 'config.local.json'
$previousConfig = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
$cache = if ($CacheRoot) { [IO.Path]::GetFullPath($CacheRoot, $PSScriptRoot) } elseif ($previousConfig.cacheRoot) { $previousConfig.cacheRoot } else { Join-Path $PSScriptRoot 'cache' }
$config = [ordered]@{
    cnRoot = $cn
    twRoot = $tw
    riotClientExe = $riot
    cacheRoot = $cache
}
$config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configPath -Encoding utf8

foreach ($entry in @(@{Path=$ShortcutPath;Locale='zh_CN'},@{Path=$TraditionalShortcutPath;Locale='zh_TW'})) {
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($entry.Path)
    $shortcut.TargetPath = $pwsh
    $shortcut.Arguments = '-NoProfile -File "' + $launcher + '" -Locale ' + $entry.Locale + ' -ShowErrors'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = (Join-Path $tw 'LeagueClient.exe') + ',0'
    $shortcut.Description = '使用 ' + $entry.Locale + ' 资源启动台服英雄联盟'
    $shortcut.Save()
    Write-Output "已创建桌面入口：$($entry.Path)"
}

Write-Output "已保存本机配置：$configPath"
& $pwsh -NoProfile -File $launcher -CheckOnly
if ($LASTEXITCODE -ne 0) { throw '只读检查未通过，请核对游戏版本及资源。' }
