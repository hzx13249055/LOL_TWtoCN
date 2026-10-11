$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Vanguard-Status.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('LOL-vanguard-state-' + [guid]::NewGuid())
$logs = Join-Path $testRoot 'Logs\LeagueClient Logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
try {
    $now = [datetime]::new(2026,10,8,23,0,0)
    $errorFile = Join-Path $logs '2026-10-08T22-55-00_1_LeagueClient.log'
    [IO.File]::WriteAllText($errorFile, "000011.941| ALWAYS| rcp-be-lol-vanguard| Disconnecting from Vanguard client: '216'")
    $until = Get-VanguardCooldown $testRoot $now
    if ($until -ne $now.AddMinutes(25).AddSeconds(11.941)) { throw '216 cooldown timestamp is incorrect' }
    if ((Get-VanguardCooldown $testRoot $now) -ne $until) { throw 'Reading cooldown restarted the timer' }
    if ($null -ne (Get-VanguardCooldown $testRoot $now.AddMinutes(31))) { throw 'Expired cooldown was retained' }
    Write-Output 'PASS VAN 216 cooldown and expiry'

    $newerAttempt = Join-Path $logs '2026-10-08T22-59-00_2_LeagueClient.log'
    [IO.File]::WriteAllText($newerAttempt, '000001.000| ALWAYS| rcp-be-lol-vanguard| Begin connect')
    if ((Get-VanguardCooldown $testRoot $now) -ne $now.AddMinutes(29)) { throw 'Later actual launch did not extend cooldown' }
    [IO.File]::WriteAllText($newerAttempt, '000012.000| ALWAYS| rcp-be-lol-vanguard| Successfully logged in to Vanguard client.')
    if ($null -ne (Get-VanguardCooldown $testRoot $now)) { throw 'Successful recovery retained old cooldown' }
    $state = Read-VanguardLogState $newerAttempt
    if (-not $state.Ready -or $null -ne $state.ErrorCode) { throw 'Successful login was not recognized' }
    [IO.File]::AppendAllText($newerAttempt, "`n000015.000| ALWAYS| rcp-be-lol-vanguard| Disconnecting from Vanguard client: '216'")
    $state = Read-VanguardLogState $newerAttempt
    if ($state.Ready -or $state.ErrorCode -ne 216) { throw 'Disconnect after login was ignored' }
    Write-Output 'PASS later attempts, recovery, post-login disconnect'

    function Get-Process { param($Name) [pscustomobject]@{Id=3} }
    function Start-Sleep { }
    $pending = Join-Path $logs '2026-10-08T23-10-00_3_LeagueClient.log'
    [IO.File]::WriteAllText($pending, '000001.000| ALWAYS| rcp-be-lol-vanguard| Begin connect')
    if ((Wait-VanguardLogin $testRoot 3 -TimeoutSeconds 0 -AllowPendingLogin) -ne $false) { throw 'Pending login was reported as confirmed' }
    [IO.File]::WriteAllText($pending, '000012.000| ALWAYS| rcp-be-lol-vanguard| Successfully logged in to Vanguard client.')
    if ((Wait-VanguardLogin $testRoot 3 -TimeoutSeconds 0 -AllowPendingLogin) -ne $true) { throw 'Confirmed login was not reported' }
    [IO.File]::WriteAllText($pending, "000015.000| ALWAYS| rcp-be-lol-vanguard| Disconnecting from Vanguard client: '152'")
    $rejected = $false
    try { $null = Wait-VanguardLogin $testRoot 3 -TimeoutSeconds 0 -AllowPendingLogin } catch { $rejected = $_.Exception.Message -match 'VAN 152' }
    if (-not $rejected) { throw 'Pending-login allowance hid a Vanguard error' }
    Write-Output 'PASS pending login without hiding Vanguard errors'
} finally {
    $resolvedRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
