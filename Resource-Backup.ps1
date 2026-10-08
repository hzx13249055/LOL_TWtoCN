# Local, content-addressed backups. No Riot credentials or databases are saved.
function Assert-BackupLocation([string]$GameRoot, [string]$CacheRoot) {
    $game = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\') + '\'
    $cache = [IO.Path]::GetFullPath($CacheRoot).TrimEnd('\') + '\'
    if ($cache.StartsWith($game, [StringComparison]::OrdinalIgnoreCase)) { throw '备份目录必须位于游戏安装目录之外' }
}

function Get-BackupVersionKey([string]$GameRoot) {
    $metadata = Join-Path $GameRoot 'Game\content-metadata.json'
    $version = (Get-Content -LiteralPath $metadata -Raw -Encoding utf8 | ConvertFrom-Json).version
    if ($version -notmatch '^\d+\.\d+\.[A-Za-z0-9+._-]+$') { throw '无法识别完整游戏资源版本，跳过本地备份' }
    $identity = [Collections.Generic.List[string]]::new()
    $identity.Add($version)
    foreach ($relative in @('Game.manifest','LeagueClient.manifest','Game\code-metadata.json')) {
        $path = Join-Path $GameRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { $identity.Add((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) }
    }
    $client = Join-Path $GameRoot 'LeagueClient.exe'
    if (Test-Path -LiteralPath $client -PathType Leaf) {
        $identity.Add((Get-Item -LiteralPath $client).VersionInfo.FileVersion)
    }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($identity -join "`n"))))
    return (($version -split '\+')[0] + '-' + $digest)
}

function Get-BackupEntryPath([string]$GameRoot, [string]$RelativePath, [ValidateSet('zh_CN','zh_TW')][string]$Locale = 'zh_CN') {
    $relative = $RelativePath.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($relative) -or '..' -in ($relative -split '/') -or $relative.Contains(':') -or
        ($relative -notmatch ('^Game/DATA/FINAL/.+\.' + [regex]::Escape($Locale) + '\.wad\.client$') -and
         $relative -notin @("Plugins/rcp-be-lol-game-data/$Locale-assets.wad","Plugins/rcp-fe-lol-typekit/$Locale-assets.wad"))) {
        throw "备份中的资源路径无效：$RelativePath"
    }
    $root = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw '备份路径超出游戏目录' }
    return $path
}

function Save-ResourceBackup([string]$GameRoot, [string]$CacheRoot, [ValidateSet('zh_CN','zh_TW')][string]$Locale = 'zh_CN') {
    Assert-BackupLocation $GameRoot $CacheRoot
    $key = Get-BackupVersionKey $GameRoot
    $gameFiles = @(Get-ChildItem -LiteralPath (Join-Path $GameRoot 'Game\DATA\FINAL') -Recurse -File -Filter "*.$Locale.wad.client")
    if ($gameFiles.Count -lt 100 -or -not ($gameFiles | Where-Object Name -eq "Global.$Locale.wad.client")) { throw "$Locale 资源不完整，不能更新备份" }
    $resourceFiles = @($gameFiles) + @(
        (Get-Item -LiteralPath (Join-Path $GameRoot "Plugins\rcp-be-lol-game-data\$Locale-assets.wad") -ErrorAction Stop),
        (Get-Item -LiteralPath (Join-Path $GameRoot "Plugins\rcp-fe-lol-typekit\$Locale-assets.wad") -ErrorAction Stop)
    )
    $root = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\')
    $entries = @($resourceFiles | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($root.Length + 1).Replace('\','/')
            length = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    })
    $objects = Join-Path $CacheRoot 'objects'
    $versions = Join-Path $CacheRoot 'versions'
    New-Item -ItemType Directory -Path $objects,$versions -Force | Out-Null
    $added = 0
    $addedBytes = 0L
    foreach ($entry in $entries) {
        $source = Get-BackupEntryPath $GameRoot $entry.path $Locale
        $object = Join-Path $objects ($entry.sha256 + '.wad')
        if ((Test-Path -LiteralPath $object -PathType Leaf) -and
            (Get-Item -LiteralPath $object).Length -eq $entry.length -and
            (Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash -eq $entry.sha256) { continue }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($CacheRoot)))
        if ($drive.AvailableFreeSpace -lt $entry.length + 64MB) { throw "备份磁盘空间不足：$CacheRoot" }
        $temporary = $object + '.' + [guid]::NewGuid() + '.partial'
        try {
            [IO.File]::Copy($source, $temporary, $false)
            if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $entry.sha256) { throw '备份期间资源发生变化，未发布新的备份清单' }
            [IO.File]::Move($temporary, $object, $true)
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
        $added++
        $addedBytes += $entry.length
    }
    if ((Get-BackupVersionKey $GameRoot) -ne $key) { throw '备份期间游戏版本发生变化，未发布新的备份清单' }
    $index = Join-Path $versions ($key + '.' + $Locale + '.cache.json')
    $temporaryIndex = $index + '.' + [guid]::NewGuid() + '.partial'
    try {
        @{ schema=1; versionKey=$key; locale=$Locale; createdUtc=[DateTime]::UtcNow.ToString('o'); entries=$entries } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryIndex -Encoding utf8
        [IO.File]::Move($temporaryIndex, $index, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryIndex) { Remove-Item -LiteralPath $temporaryIndex -Force }
    }
    return [pscustomobject]@{ FileCount=$entries.Count; AddedFiles=$added; AddedBytes=$addedBytes; VersionKey=$key }
}

function Read-ResourceBackup([string]$GameRoot, [string]$CacheRoot, [ValidateSet('zh_CN','zh_TW')][string]$Locale = 'zh_CN') {
    Assert-BackupLocation $GameRoot $CacheRoot
    $key = Get-BackupVersionKey $GameRoot
    $index = Join-Path (Join-Path $CacheRoot 'versions') ($key + '.' + $Locale + '.cache.json')
    if ($Locale -eq 'zh_CN' -and -not (Test-Path -LiteralPath $index -PathType Leaf)) {
        # Keep existing single-language backups usable after upgrading.
        $index = Join-Path (Join-Path $CacheRoot 'versions') ($key + '.cache.json')
    }
    if (-not (Test-Path -LiteralPath $index -PathType Leaf)) { return $null }
    $manifest = Get-Content -LiteralPath $index -Raw -Encoding utf8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.versionKey -ne $key -or $manifest.locale -ne $Locale) { throw '本地备份清单与当前完整资源版本或语言不匹配' }
    # Validate every path before writing any file; indexes are data, never code.
    $entries = @($manifest.entries)
    foreach ($entry in $entries) {
        $null = Get-BackupEntryPath $GameRoot $entry.path $Locale
        if ($entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or $entry.length -lt 0) { throw '本地备份清单内容无效' }
    }
    return $manifest
}

function Restore-ResourceBackup([string]$GameRoot, [string]$CacheRoot, [ValidateSet('zh_CN','zh_TW')][string]$Locale = 'zh_CN', [switch]$RepairExisting) {
    $manifest = Read-ResourceBackup $GameRoot $CacheRoot $Locale
    if ($null -eq $manifest) { return [pscustomobject]@{ Restored=0; Rejected=0; Found=$false } }
    $restored = 0
    $rejected = 0
    foreach ($entry in $manifest.entries) {
        $destination = Get-BackupEntryPath $GameRoot $entry.path $Locale
        if (Test-Path -LiteralPath $destination) {
            if (-not $RepairExisting) { continue }
            if ((Get-Item -LiteralPath $destination).Length -eq $entry.length -and
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $entry.sha256) { continue }
        }
        $object = Join-Path (Join-Path $CacheRoot 'objects') ($entry.sha256.ToUpperInvariant() + '.wad')
        if (-not (Test-Path -LiteralPath $object -PathType Leaf) -or
            (Get-Item -LiteralPath $object).Length -ne $entry.length -or
            (Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash -ne $entry.sha256) { $rejected++; continue }
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        $temporary = $destination + '.' + [guid]::NewGuid() + '.partial'
        try {
            [IO.File]::Copy($object, $temporary, $false)
            # RepairExisting is only used while the caller holds Riot's exclusive
            # session patch lock and has confirmed the old patch job is idle.
            [IO.File]::Move($temporary, $destination, [bool]$RepairExisting)
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
        $restored++
    }
    return [pscustomobject]@{ Restored=$restored; Rejected=$rejected; Found=$true }
}

function Release-BackedUpLanguage([string]$GameRoot, [string]$CacheRoot, [ValidateSet('zh_CN','zh_TW')][string]$Locale) {
    $manifest = Read-ResourceBackup $GameRoot $CacheRoot $Locale
    if ($null -eq $manifest) { return [pscustomobject]@{ Released=0; Bytes=0; Unverified=0 } }
    $approved = [Collections.Generic.List[object]]::new()
    $unverified = 0
    foreach ($entry in $manifest.entries) {
        $path = Get-BackupEntryPath $GameRoot $entry.path $Locale
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $object = Join-Path (Join-Path $CacheRoot 'objects') ($entry.sha256.ToUpperInvariant() + '.wad')
        if (-not (Test-Path -LiteralPath $object -PathType Leaf) -or
            (Get-Item -LiteralPath $object).Length -ne $entry.length -or
            (Get-Item -LiteralPath $path).Length -ne $entry.length -or
            (Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash -ne $entry.sha256 -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) { $unverified++; continue }
        $approved.Add([pscustomobject]@{ Path=$path; Length=$entry.length })
    }
    if ((Get-BackupVersionKey $GameRoot) -ne $manifest.versionKey) { throw '版本已变化，取消释放语言资源' }
    $bytes = 0L
    foreach ($file in $approved) {
        # Every exact file has a separate, verified copy in the cache.
        Remove-Item -LiteralPath $file.Path -ErrorAction Stop
        $bytes += $file.Length
    }
    return [pscustomobject]@{ Released=$approved.Count; Bytes=$bytes; Unverified=$unverified }
}
