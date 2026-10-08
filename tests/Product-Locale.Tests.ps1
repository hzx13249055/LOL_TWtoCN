$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Product-Locale.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LOL-product-locale-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $gameRoot = Join-Path $testRoot 'game'
    $metadata = Join-Path $testRoot 'product_settings.yaml'
    $original = (@('locale_data:', '    available_locales:', '    - "zh_TW"', '    default_locale: "zh_TW"',
        ('product_install_full_path: "' + $gameRoot.Replace('\','/') + '"'),
        'settings:', '    locale: "zh_TW"', '    other_setting: true', 'patching_policy: "manual"') -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($metadata, $original)
    $null = Set-OfflineProductLocale $gameRoot zh_CN $metadata
    $updated = [IO.File]::ReadAllText($metadata)
    if ($updated -notmatch 'default_locale: "zh_CN"' -or $updated -notmatch '(?m)^    locale: "zh_CN"' -or
        $updated -notmatch 'other_setting: true' -or $updated -notmatch 'patching_policy: "manual"') { throw 'Incomplete or destructive language staging' }
    if ([IO.File]::ReadAllText($metadata + '.LOL_TWtoCN.original') -ne $original) { throw 'Original configuration backup differs' }
    if (Set-OfflineProductLocale $gameRoot zh_CN $metadata) { throw 'Repeated staging changed metadata' }
    if ([regex]::Matches($updated, '- "zh_CN"').Count -ne 1) { throw 'Locale list was duplicated' }
    $null = Set-OfflineProductLocale $gameRoot zh_TW $metadata
    if ([IO.File]::ReadAllText($metadata) -notmatch 'default_locale: "zh_TW"') { throw 'Traditional staging failed' }
    Write-Output 'PASS language staging, idempotence, original backup'

    $before = [IO.File]::ReadAllText($metadata)
    $rejected = $false
    try { $null = Set-OfflineProductLocale (Join-Path $testRoot 'another-game') zh_CN $metadata } catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($metadata) -ne $before) { throw 'Other installation was modified' }
    [IO.File]::WriteAllText($metadata, $before.Replace('default_locale:', 'unexpected_field:'))
    $before = [IO.File]::ReadAllText($metadata)
    $rejected = $false
    try { $null = Set-OfflineProductLocale $gameRoot zh_CN $metadata } catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($metadata) -ne $before) { throw 'Unknown metadata layout was modified' }
    Write-Output 'PASS installation and layout guards'
} finally {
    $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
