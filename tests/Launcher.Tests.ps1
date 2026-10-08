# Runs isolated launcher scenarios without contacting Riot or changing game files.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Tests require PowerShell 7' }
$pwsh = (Get-Process -Id $PID).Path
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-TW-LoL-zhCN.ps1'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Resource-Backup.ps1')
$source = Get-Content -LiteralPath $launcher -Raw
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Launcher parse failed: $errors" }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LOL_TWtoCN-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$mocks = @'
$env:LOCALAPPDATA = Join-Path $PSScriptRoot 'local'
$script:patchPoll = 0
$script:testLaunched = $false
$script:testValidated = $false
$script:patchHeld = $false
$script:riotRunning = $env:LOL_TEST_CASE -ne 'cold'
$script:riotFull = $env:LOL_TEST_CASE -notin @('background','background-transition')
if ($env:LOL_TEST_CASE -eq 'background-transition') {
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Config\lockfile')
}
function Get-Item {
    param([string]$LiteralPath)
    if ($env:LOL_TEST_CASE -eq 'native' -and $LiteralPath -like '*\cn\*') { throw 'Native mode read obsolete CN resources' }
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -ErrorAction SilentlyContinue
    if ($LiteralPath -like '*League of Legends.exe') {
        $version = if ($env:LOL_TEST_CASE -eq 'mismatch' -and $LiteralPath -like '*\cn\*') { '16.19.1.0' } else { '16.20.1.0' }
        return [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = $version } }
    }
    return $item
}
function Get-Process {
    param([string[]]$Name)
    if ($Name -contains 'RiotClientServices' -and $script:riotRunning) { return [pscustomobject]@{ Id = 1 } }
    if ($Name -contains 'LeagueClient' -and $script:testLaunched) { return [pscustomobject]@{ Id = 2 } }
}
function Start-Process {
    $script:riotRunning = $true; $script:riotFull = $true
    if ($env:LOL_TEST_CASE -eq 'background-transition') {
        [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Config\lockfile'), 'mock:1:1234:test:https')
    }
}
function Start-Sleep { }
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $SkipCertificateCheck, $NoProxy, $TimeoutSec, $ContentType, $Body)
    if ($Uri -like '*riot-client-lifecycle/v1/quit') {
        $script:riotRunning = $false
        return [pscustomobject]@{ Content = '{}'; StatusCode = 204 }
    }
    if ($Uri -like '*session-patch-lock*') {
        if (-not $script:riotFull -or -not $script:riotRunning) {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock background mode', $response)
        }
        if ($Method -eq 'PUT') {
            if ($script:patchHeld) { throw 'Reacquired a lock already owned by the launcher' }
            if ($Body -ne 'true') { throw 'Exclusive patch lock missing' }
            $script:patchHeld = $true
        } else {
            if ($env:LOL_TEST_CASE -eq 'autounlock' -and -not $script:patchHeld) {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock lock already released', $response)
            }
            $script:patchHeld = $false
        }
        return [pscustomobject]@{ Content='{}'; StatusCode=201 }
    }
    if ($Uri -like '*patch-jobs*' -and $Method -eq 'DELETE') {
        if (-not $script:patchHeld) { throw 'Cancellation without exclusive lock' }
        if ($env:LOL_TEST_CASE -eq 'initializing' -and -not $script:initializingRetried) {
            $script:initializingRetried = $true
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock product registry still initializing', $response)
        }
        return [pscustomobject]@{ Content='{}'; StatusCode=204 }
    }
    if ($Uri -like '*product-locales*') {
        if ($Method -eq 'PUT' -and -not $script:patchHeld) { throw 'Locale modified before patch control' }
        if (-not $script:riotFull) {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock background mode', $response)
        }
        return [pscustomobject]@{ Content = ('"' + $Locale + '"'); StatusCode = 200 }
    }
    if ($Uri -like '*eligibility') { return [pscustomobject]@{ Content = 'true'; StatusCode = 200 } }
    if ($Uri -like '*patch-states*') {
        if ($script:patchHeld) {
            $idleState = if ($env:LOL_TEST_CASE -eq 'cold') { 'OutOfDate' } else { 'Paused' }
            return [pscustomobject]@{ Content=(@{state=$idleState;launchable=$false} | ConvertTo-Json); StatusCode=200 }
        }
        $script:patchPoll++
        if ($env:LOL_TEST_CASE -eq 'restart' -and $script:patchPoll -eq 2) {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock Riot restarting', $response)
        }
        $state = if ($env:LOL_TEST_CASE -in @('updating','partial','restart') -and $script:patchPoll -eq 1) { 'updating' } else { 'up_to_date' }
        $ready = $state -eq 'up_to_date'
        $state = if ($ready) { 'UpToDate' } else { 'Updating' }
        if ($env:LOL_TEST_CASE -eq 'partial' -and $script:patchPoll -eq 1) { $state = 'Paused'; $ready = $true }
        return [pscustomobject]@{ Content = (@{ state=$state; launchable=$ready; progress=@{totalBytesDownloaded=1;totalBytesToDownload=4} } | ConvertTo-Json); StatusCode = 200 }
    }
    if ($Uri -like '*priority-patch*') {
        if (-not $script:patchHeld -or ($Body | ConvertFrom-Json).locale -ne $Locale) { throw 'Patch locale was not explicitly bound under exclusive lock' }
        if ($env:LOL_TEST_CASE -in @('restore','repair')) {
            if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client')) -ne 'NEW!') { throw 'Cache not repaired before explicit patch request' }
        }
        $script:testValidated = $true
        if ($env:LOL_TEST_CASE -eq 'autounlock') { $script:patchHeld = $false }
        return [pscustomobject]@{ Content = '[]'; StatusCode = 201 }
    }
    if ($Method -eq 'POST') {
        if ($script:patchHeld) { throw 'Patch lock leaked into launch' }
        if ($env:LOL_TEST_CASE -eq 'prepare') { throw 'PrepareOnly attempted game launch' }
        if ($env:LOL_TEST_CASE -eq 'restore' -and -not $script:testValidated) { throw 'Launch bypassed validation after restoration' }
        $target = Join-Path $PSScriptRoot "tw\Game\DATA\FINAL\Global.$Locale.wad.client"
        $bytes = [IO.File]::ReadAllText($target)
        if ($env:LOL_TEST_CASE -eq 'updating' -and $script:patchPoll -eq 1) {
            if ($bytes -ne 'OLD!') { throw 'Resources were overwritten while patching' }
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::FailedDependency)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock patch still running', $response)
        }
        if ($bytes -ne 'NEW!') { throw 'Same-size resource was not refreshed' }
        if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "tw\Plugins\rcp-be-lol-game-data\$Locale-assets.wad")) -ne 'NEW!') {
            throw 'Same-size client resource was not refreshed'
        }
        $script:testLaunched = $true
        $logs = Join-Path $PSScriptRoot 'tw\Logs\LeagueClient Logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        $message = if ($env:LOL_TEST_CASE -eq 'vanguard216') {
            "000001.000| ALWAYS| rcp-be-lol-vanguard| Disconnecting from Vanguard client: '216'"
        } else { '000001.000| ALWAYS| rcp-be-lol-vanguard| Successfully logged in to Vanguard client.' }
        [IO.File]::WriteAllText((Join-Path $logs ((Get-Date -Format 'yyyy-MM-ddTHH-mm-ss') + '_2_LeagueClient.log')), $message)
        return [pscustomobject]@{ Content = '{}'; StatusCode = 200 }
    }
    throw 'Unexpected API request'
}
'@
try {
    foreach ($case in @('mismatch', 'ready', 'updating', 'partial', 'native', 'restore', 'traditional', 'restart', 'background', 'background-transition', 'vanguard216','repair','prepare','cold','initializing','autounlock')) {
        $root = Join-Path $testRoot $case
        foreach ($path in @('cn\Game\DATA\FINAL','tw\Game\DATA\FINAL',
            'cn\LeagueClient\Plugins\rcp-be-lol-game-data','cn\LeagueClient\Plugins\rcp-fe-lol-typekit',
            'tw\Plugins\rcp-be-lol-game-data','tw\Plugins\rcp-fe-lol-typekit',
            'local\Riot Games\Riot Client\Config')) {
            New-Item -ItemType Directory -Path (Join-Path $root $path) -Force | Out-Null
        }
        foreach ($side in @('cn','tw')) {
            [IO.File]::WriteAllText((Join-Path $root "$side\Game\League of Legends.exe"), '')
            $patch = if ($case -eq 'mismatch' -and $side -eq 'cn') { '16.19.1' } else { '16.20.1' }
            [IO.File]::WriteAllText((Join-Path $root "$side\Game\content-metadata.json"), ('{"version":"' + $patch + '"}'))
        }
        [IO.File]::WriteAllText((Join-Path $root 'riot.exe'), '')
        [IO.File]::WriteAllText((Join-Path $root 'local\Riot Games\Riot Client\Config\lockfile'), 'mock:1:1234:test:https')
        [IO.File]::WriteAllText((Join-Path $root 'cn\Game\DATA\FINAL\Global.zh_CN.wad.client'), 'NEW!')
        [IO.File]::WriteAllText((Join-Path $root 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client'), 'OLD!')
        1..100 | ForEach-Object {
            [IO.File]::WriteAllText((Join-Path $root "cn\Game\DATA\FINAL\test$_.zh_CN.wad.client"), 'NEW!')
        }
        foreach ($plugin in @('rcp-be-lol-game-data', 'rcp-fe-lol-typekit')) {
            [IO.File]::WriteAllText((Join-Path $root "cn\LeagueClient\Plugins\$plugin\zh_CN-assets.wad"), 'NEW!')
            [IO.File]::WriteAllText((Join-Path $root "tw\Plugins\$plugin\zh_CN-assets.wad"), 'OLD!')
        }
        if ($case -in @('native','restore','traditional','restart','background','background-transition','vanguard216','repair','prepare','cold','initializing','autounlock')) {
            Get-ChildItem -LiteralPath (Join-Path $root 'cn\Game\DATA\FINAL') -File |
                Copy-Item -Destination (Join-Path $root 'tw\Game\DATA\FINAL') -Force
            foreach ($plugin in @('rcp-be-lol-game-data', 'rcp-fe-lol-typekit')) {
                [IO.File]::WriteAllText((Join-Path $root "tw\Plugins\$plugin\zh_CN-assets.wad"), 'NEW!')
            }
        }
        if ($case -eq 'traditional') {
            Get-ChildItem -LiteralPath (Join-Path $root 'tw\Game\DATA\FINAL') -File | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination ($_.FullName.Replace('zh_CN','zh_TW'))
            }
            foreach ($plugin in @('rcp-be-lol-game-data','rcp-fe-lol-typekit')) {
                [IO.File]::WriteAllText((Join-Path $root "tw\Plugins\$plugin\zh_TW-assets.wad"), 'NEW!')
            }
        }
        if ($case -in @('restore','repair')) {
            $null = Save-ResourceBackup (Join-Path $root 'tw') (Join-Path $root 'cache')
            if ($case -eq 'repair') { [IO.File]::WriteAllText((Join-Path $root 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client'), 'BAD!') } else { Remove-Item -LiteralPath (Join-Path $root 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client') }
            Remove-Item -LiteralPath (Join-Path $root 'tw\Game\DATA\FINAL\test1.zh_CN.wad.client')
        }
        $metadataPath = Join-Path $root 'product_settings.yaml'
        @('locale_data:', '    available_locales:', '    - "zh_TW"', '    default_locale: "zh_TW"',
          ('product_install_full_path: "' + (Join-Path $root 'tw').Replace('\','/') + '"'),
          'settings:', '    locale: "zh_TW"', 'patching_policy: "manual"') | Set-Content -LiteralPath $metadataPath
        @{ cnRoot=(Join-Path $root 'cn'); twRoot=(Join-Path $root 'tw'); riotClientExe=(Join-Path $root 'riot.exe'); productSettingsPath=$metadataPath } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.local.json') -Encoding utf8
        $fixture = $source.Insert($ast.ParamBlock.Extent.EndOffset, "`n$mocks`n")
        $fixture = $fixture.Replace("'Local\LOL_TWtoCN_Launcher'", "'Local\LOL_TWtoCN_Test_$([guid]::NewGuid())'")
        $fixturePath = Join-Path $root 'launcher.ps1'
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Resource-Backup.ps1') -Destination (Join-Path $root 'Resource-Backup.ps1')
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Product-Locale.ps1') -Destination (Join-Path $root 'Product-Locale.ps1')
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Vanguard-Status.ps1') -Destination (Join-Path $root 'Vanguard-Status.ps1')
        Set-Content -LiteralPath $fixturePath -Value $fixture -Encoding utf8
        $env:LOL_TEST_CASE = $case
        $mode = if ($case -in @('native','restore','traditional','restart','background','background-transition','vanguard216','repair','prepare','cold','initializing','autounlock')) { 'Riot' } else { 'Local' }
        $testLocale = if ($case -eq 'traditional') { 'zh_TW' } else { 'zh_CN' }
        $extra = @()
        if ($case -eq 'prepare') { $extra = @('-PrepareOnly') }
        $output = & $pwsh -NoProfile -File $fixturePath -ResourceSource $mode -Locale $testLocale @extra 2>&1
        $exitCode = $LASTEXITCODE
        if ($case -eq 'mismatch') {
            if ($exitCode -ne 1 -or "$output" -notmatch '实际补丁不匹配') { throw "Mismatch was not rejected: $output" }
            if ([IO.File]::ReadAllText((Join-Path $root 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client')) -ne 'OLD!') {
                throw 'Mismatch modified game resources'
            }
        } elseif ($case -eq 'prepare') {
            if ($exitCode -ne 0 -or "$output" -notmatch '未启动游戏客户端') { throw "PrepareOnly failed: $output" }
        } elseif ($case -eq 'vanguard216') {
            if ($exitCode -ne 1 -or "$output" -notmatch 'VAN 216' -or "$output" -match "已以 $testLocale 启动") { throw "Vanguard failure was reported as success: $output" }
        } elseif ($exitCode -ne 0 -or "$output" -notmatch "已以 $testLocale 启动") { throw "Scenario $case failed: $output" }
        if ($case -eq 'restart' -and "$output" -notmatch '正在重新连接后台') { throw 'Restart scenario did not exercise reconnection' }
        if ($case -in @('background','background-transition') -and "$output" -notmatch '精简后台模式') { throw 'Background scenario did not wake full Riot mode' }
        Write-Output "PASS $case"
    }
} finally {
    Remove-Item Env:\LOL_TEST_CASE -ErrorAction SilentlyContinue
    # Only remove this test's unique, resolved temporary directory.
    $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
