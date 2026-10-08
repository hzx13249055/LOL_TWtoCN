# Runs isolated launcher scenarios without contacting Riot or changing game files.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Tests require PowerShell 7' }
$pwsh = (Get-Process -Id $PID).Path
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-TW-LoL-zhCN.ps1'
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
    if ($Name -contains 'RiotClientServices') { return [pscustomobject]@{ Id = 1 } }
    if ($Name -contains 'LeagueClient' -and $script:testLaunched) { return [pscustomobject]@{ Id = 2 } }
}
function Start-Process { throw 'Test attempted to start a real program' }
function Start-Sleep { }
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $SkipCertificateCheck, $NoProxy, $TimeoutSec, $ContentType, $Body)
    if ($Uri -like '*product-locales*') { return [pscustomobject]@{ Content = '"zh_CN"'; StatusCode = 200 } }
    if ($Uri -like '*eligibility') { return [pscustomobject]@{ Content = 'true'; StatusCode = 200 } }
    if ($Uri -like '*patch-states*') {
        $script:patchPoll++
        $state = if ($env:LOL_TEST_CASE -in @('updating','partial') -and $script:patchPoll -eq 1) { 'updating' } else { 'up_to_date' }
        $ready = $state -eq 'up_to_date'
        $state = if ($ready) { 'UpToDate' } else { 'Updating' }
        if ($env:LOL_TEST_CASE -eq 'partial' -and $script:patchPoll -eq 1) { $state = 'Paused'; $ready = $true }
        return [pscustomobject]@{ Content = (@{ state=$state; launchable=$ready; progress=@{totalBytesDownloaded=1;totalBytesToDownload=4} } | ConvertTo-Json); StatusCode = 200 }
    }
    if ($Uri -like '*priority-patch*') {
        $target = Join-Path $PSScriptRoot 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client'
        if ([IO.File]::ReadAllText($target) -ne 'OLD!') { throw 'Resources were overwritten while patching' }
        return [pscustomobject]@{ Content = '[]'; StatusCode = 201 }
    }
    if ($Method -eq 'POST') {
        $target = Join-Path $PSScriptRoot 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client'
        $bytes = [IO.File]::ReadAllText($target)
        if ($env:LOL_TEST_CASE -eq 'updating' -and $script:patchPoll -eq 1) {
            if ($bytes -ne 'OLD!') { throw 'Resources were overwritten while patching' }
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::FailedDependency)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Mock patch still running', $response)
        }
        if ($bytes -ne 'NEW!') { throw 'Same-size resource was not refreshed' }
        if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tw\Plugins\rcp-be-lol-game-data\zh_CN-assets.wad')) -ne 'NEW!') {
            throw 'Same-size client resource was not refreshed'
        }
        $script:testLaunched = $true
        return [pscustomobject]@{ Content = '{}'; StatusCode = 200 }
    }
    throw 'Unexpected API request'
}
'@
try {
    foreach ($case in @('mismatch', 'ready', 'updating', 'partial', 'native')) {
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
        if ($case -eq 'native') {
            Get-ChildItem -LiteralPath (Join-Path $root 'cn\Game\DATA\FINAL') -File |
                Copy-Item -Destination (Join-Path $root 'tw\Game\DATA\FINAL') -Force
            foreach ($plugin in @('rcp-be-lol-game-data', 'rcp-fe-lol-typekit')) {
                [IO.File]::WriteAllText((Join-Path $root "tw\Plugins\$plugin\zh_CN-assets.wad"), 'NEW!')
            }
        }
        @{ cnRoot=(Join-Path $root 'cn'); twRoot=(Join-Path $root 'tw'); riotClientExe=(Join-Path $root 'riot.exe') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.local.json') -Encoding utf8
        $fixture = $source.Insert($ast.ParamBlock.Extent.EndOffset, "`n$mocks`n")
        $fixture = $fixture.Replace("'Local\LOL_TWtoCN_Launcher'", "'Local\LOL_TWtoCN_Test_$([guid]::NewGuid())'")
        $fixturePath = Join-Path $root 'launcher.ps1'
        Set-Content -LiteralPath $fixturePath -Value $fixture -Encoding utf8
        $env:LOL_TEST_CASE = $case
        $mode = if ($case -eq 'native') { 'Riot' } else { 'Local' }
        $output = & $pwsh -NoProfile -File $fixturePath -ResourceSource $mode 2>&1
        $exitCode = $LASTEXITCODE
        if ($case -eq 'mismatch') {
            if ($exitCode -ne 1 -or "$output" -notmatch '实际补丁不匹配') { throw "Mismatch was not rejected: $output" }
            if ([IO.File]::ReadAllText((Join-Path $root 'tw\Game\DATA\FINAL\Global.zh_CN.wad.client')) -ne 'OLD!') {
                throw 'Mismatch modified game resources'
            }
        } elseif ($exitCode -ne 0 -or "$output" -notmatch '已以 zh_CN 启动') { throw "Scenario $case failed: $output" }
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
