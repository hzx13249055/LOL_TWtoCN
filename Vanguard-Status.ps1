function Read-VanguardLogState([string]$Path) {
    $name = [IO.Path]::GetFileName($Path)
    if ($name -notmatch '^(?<stamp>\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})_\d+_LeagueClient\.log$') { return $null }
    $launchAt = [datetime]::ParseExact($Matches.stamp, 'yyyy-MM-ddTHH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $disconnects = [regex]::Matches($text, '(?m)^(?<offset>\d+(?:\.\d+)?)\|[^\r\n]*rcp-be-lol-vanguard\|\s*Disconnecting from Vanguard client:\s*''(?<code>-?\d+)''')
    $successes = [regex]::Matches($text, '(?m)^(?<offset>\d+(?:\.\d+)?)\|[^\r\n]*rcp-be-lol-vanguard\|\s*Successfully logged in to Vanguard client\.')
    $last216At = $null
    foreach ($match in $disconnects) {
        if ($match.Groups['code'].Value -eq '216') {
            $last216At = $launchAt.AddSeconds([double]::Parse($match.Groups['offset'].Value, [Globalization.CultureInfo]::InvariantCulture))
        }
    }
    $ready = $successes.Count -gt 0 -and ($disconnects.Count -eq 0 -or $successes[-1].Index -gt $disconnects[-1].Index)
    $healthyAt = if ($ready) { $launchAt.AddSeconds([double]::Parse($successes[-1].Groups['offset'].Value, [Globalization.CultureInfo]::InvariantCulture)) } else { $null }
    $errorCode = if (-not $ready -and $disconnects.Count -gt 0) { [int]$disconnects[-1].Groups['code'].Value } else { $null }
    return [pscustomobject]@{LaunchAt=$launchAt;Last216At=$last216At;HealthyAt=$healthyAt;Ready=$ready;ErrorCode=$errorCode}
}

function Get-VanguardCooldown([string]$GameRoot, [datetime]$Now = [datetime]::Now) {
    $logRoot = Join-Path $GameRoot 'Logs\LeagueClient Logs'
    $states = @(Get-ChildItem -LiteralPath $logRoot -File -Filter '*_LeagueClient.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 30 | ForEach-Object {
            try { Read-VanguardLogState $_.FullName } catch { }
        })
    $lastError = $states | Where-Object Last216At | Sort-Object Last216At -Descending | Select-Object -First 1
    if ($null -eq $lastError) { return $null }
    if ($states | Where-Object { $_.HealthyAt -gt $lastError.Last216At }) { return $null }
    $latestLaunch = $states | Sort-Object LaunchAt -Descending | Select-Object -First 1
    $since = if ($latestLaunch.LaunchAt -gt $lastError.Last216At) { $latestLaunch.LaunchAt } else { $lastError.Last216At }
    $until = $since.AddMinutes(30)
    if ($until -le $Now) { return $null }
    return $until
}

function Assert-VanguardCooldown([string]$GameRoot) {
    $until = Get-VanguardCooldown $GameRoot
    if ($null -ne $until) {
        $retryAt = $until.AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss')
        throw "检测到 Vanguard VAN 216 启动频率限制。请等到 $retryAt 后再启动；冷却期间请勿在 Riot 中点击开始。此次入口已在启动 Riot 前停止，不会增加启动次数。"
    }
}

function Wait-VanguardLogin([string]$GameRoot, [int]$ClientId, [int]$TimeoutSeconds = 60) {
    $logRoot = Join-Path $GameRoot 'Logs\LeagueClient Logs'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $file = Get-ChildItem -LiteralPath $logRoot -File -Filter "*_${ClientId}_LeagueClient.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $state = if ($file) { Read-VanguardLogState $file.FullName } else { $null }
        if ($null -ne $state.ErrorCode) {
            if ($state.ErrorCode -eq 216) { Assert-VanguardCooldown $GameRoot }
            throw "Vanguard 返回 VAN $($state.ErrorCode)，客户端未通过反作弊登录；请处理客户端提示后再启动"
        }
        if (-not (Get-Process -Name LeagueClient -ErrorAction SilentlyContinue | Where-Object Id -eq $ClientId)) {
            throw 'League 客户端已退出，尚未确认 Vanguard 登录成功'
        }
        if ($state.Ready) {
            Start-Sleep -Seconds 3
            $confirmed = Read-VanguardLogState $file.FullName
            if ($confirmed.Ready -and (Get-Process -Name LeagueClient -ErrorAction SilentlyContinue | Where-Object Id -eq $ClientId)) { return }
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw '一分钟内未确认 Vanguard 登录正常，请查看客户端或 Vanguard 提示；此次启动不报告成功'
}
