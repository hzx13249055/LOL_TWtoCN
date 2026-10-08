$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Tests require PowerShell 7' }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Resource-Backup.ps1')
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LOL-backup-tests-' + [guid]::NewGuid())
$gameRoot = Join-Path $testRoot 'game'
$cacheRoot = Join-Path $testRoot 'cache'
$final = Join-Path $gameRoot 'Game\DATA\FINAL'
$globalFile = Join-Path $final 'Global.zh_CN.wad.client'
$voiceFile = Join-Path $final 'Champions\test1.zh_CN.wad.client'
$metadata = Join-Path $gameRoot 'Game\content-metadata.json'
try {
    New-Item -ItemType Directory -Path (Join-Path $final 'Champions') -Force | Out-Null
    [IO.File]::WriteAllText($metadata, '{"version":"16.20.1+content.release"}')
    [IO.File]::WriteAllText($globalFile, 'original')
    1..100 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $final "Champions\test$_.zh_CN.wad.client"), 'voice') }
    foreach ($plugin in @('rcp-be-lol-game-data','rcp-fe-lol-typekit')) {
        $path = Join-Path $gameRoot "Plugins\$plugin\zh_CN-assets.wad"
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'text')
    }
    $first = Save-ResourceBackup $gameRoot $cacheRoot
    Assert ($first.FileCount -eq 103 -and $first.AddedFiles -eq 3) 'Backup failed to deduplicate identical resources'
    $second = Save-ResourceBackup $gameRoot $cacheRoot
    Assert ($second.AddedFiles -eq 0) 'Unchanged backup copied resources again'
    Write-Output 'PASS backup and deduplication'

    Remove-Item -LiteralPath $globalFile
    [IO.File]::WriteAllText($voiceFile, 'existing file must be preserved')
    $restored = Restore-ResourceBackup $gameRoot $cacheRoot
    Assert ($restored.Restored -eq 1 -and [IO.File]::ReadAllText($globalFile) -eq 'original') 'Missing file was not restored'
    Assert ([IO.File]::ReadAllText($voiceFile) -eq 'existing file must be preserved') 'Restore overwrote an existing file'
    [IO.File]::WriteAllText($voiceFile, 'voice')
    Write-Output 'PASS missing-only restoration'

    Remove-Item -LiteralPath $globalFile
    [IO.File]::WriteAllText($metadata, '{"version":"16.20.2+content.release"}')
    $wrongVersion = Restore-ResourceBackup $gameRoot $cacheRoot
    Assert (-not $wrongVersion.Found -and -not (Test-Path -LiteralPath $globalFile)) 'Backup crossed full resource versions'
    [IO.File]::WriteAllText($metadata, '{"version":"16.20.1+content.release"}')
    $indexPath = Join-Path $cacheRoot ('versions\' + $first.VersionKey + '.zh_CN.cache.json')
    $indexText = Get-Content -LiteralPath $indexPath -Raw
    $index = $indexText | ConvertFrom-Json
    $globalEntry = $index.entries | Where-Object path -eq 'Game/DATA/FINAL/Global.zh_CN.wad.client'
    $objectPath = Join-Path $cacheRoot ('objects\' + $globalEntry.sha256 + '.wad')
    [IO.File]::WriteAllText($objectPath, 'corrupt!')
    $bad = Restore-ResourceBackup $gameRoot $cacheRoot
    Assert ($bad.Rejected -eq 1 -and -not (Test-Path -LiteralPath $globalFile)) 'Corrupted object was restored'
    Write-Output 'PASS version and checksum guards'

    $index.entries += [pscustomobject]@{ path='Game/DATA/FINAL/../../outside.zh_CN.wad.client'; length=8; sha256=$globalEntry.sha256 }
    $index | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $indexPath -Encoding utf8
    $blocked = $false
    try { $null = Restore-ResourceBackup $gameRoot $cacheRoot } catch { $blocked = $true }
    Assert ($blocked -and -not (Test-Path -LiteralPath $globalFile)) 'Malformed paths were not rejected before restoration'
    [IO.File]::WriteAllText($indexPath, $indexText)
    [IO.File]::WriteAllText($globalFile, 'original')
    $repaired = Save-ResourceBackup $gameRoot $cacheRoot
    Assert ($repaired.AddedFiles -eq 1 -and [IO.File]::ReadAllText($objectPath) -eq 'original') 'Backup did not repair a corrupted cache object'
    Write-Output 'PASS path validation and cache repair'

    [IO.File]::WriteAllText((Join-Path $final 'Global.zh_TW.wad.client'), 'traditional')
    1..100 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $final "Champions\test$_.zh_TW.wad.client"), 'tw voice') }
    foreach ($plugin in @('rcp-be-lol-game-data','rcp-fe-lol-typekit')) {
        [IO.File]::WriteAllText((Join-Path $gameRoot "Plugins\$plugin\zh_TW-assets.wad"), 'tw text')
    }
    $traditional = Save-ResourceBackup $gameRoot $cacheRoot 'zh_TW'
    Assert ($traditional.FileCount -eq 103 -and (Test-Path -LiteralPath (Join-Path $cacheRoot ('versions\' + $traditional.VersionKey + '.zh_TW.cache.json')))) 'Traditional language did not get its own index'
    $released = Release-BackedUpLanguage $gameRoot $cacheRoot 'zh_CN'
    Assert ($released.Released -eq 103 -and -not (Test-Path -LiteralPath $globalFile) -and
        (Test-Path -LiteralPath (Join-Path $final 'Global.zh_TW.wad.client'))) 'Releasing CN touched TW files or left verified CN resources'
    $cnRestored = Restore-ResourceBackup $gameRoot $cacheRoot 'zh_CN'
    Assert ($cnRestored.Restored -eq 103 -and [IO.File]::ReadAllText($globalFile) -eq 'original') 'CN restore did not preserve its separate resource content'
    [IO.File]::WriteAllText($objectPath, 'corrupt!')
    $protected = Release-BackedUpLanguage $gameRoot $cacheRoot 'zh_CN'
    Assert ($protected.Unverified -eq 1 -and (Test-Path -LiteralPath $globalFile)) 'Release deleted a resource whose cache was corrupted'
    $null = Restore-ResourceBackup $gameRoot $cacheRoot 'zh_CN'
    $null = Save-ResourceBackup $gameRoot $cacheRoot 'zh_CN'
    $legacyIndex = Join-Path $cacheRoot ('versions\' + $first.VersionKey + '.cache.json')
    Move-Item -LiteralPath $indexPath -Destination $legacyIndex
    Remove-Item -LiteralPath $voiceFile
    $legacy = Restore-ResourceBackup $gameRoot $cacheRoot 'zh_CN'
    Assert ($legacy.Restored -eq 1 -and (Test-Path -LiteralPath $voiceFile)) 'Existing CN-only backup was not compatible'
    $null = Save-ResourceBackup $gameRoot $cacheRoot 'zh_CN'
    Write-Output 'PASS language isolation, safe release and legacy compatibility'

    [IO.File]::WriteAllText($metadata, '{"version":"16.20.2+content.release"}')
    [IO.File]::WriteAllText($globalFile, 'new version')
    $next = Save-ResourceBackup $gameRoot $cacheRoot
    Assert ($next.AddedFiles -eq 1 -and (Test-Path -LiteralPath $indexPath)) 'Next version failed to reuse unchanged objects or retain the previous version'
    Write-Output 'PASS multiple-version reuse'
} finally {
    $resolved = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
