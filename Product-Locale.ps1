# Stage the requested language before Riot's patcher opens the installation.
function Set-OfflineProductLocale(
    [string]$GameRoot,
    [ValidateSet('zh_CN','zh_TW')][string]$Locale,
    [string]$MetadataPath = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml')
) {
    $text = [IO.File]::ReadAllText($MetadataPath)
    $install = [regex]::Matches($text, '(?m)^product_install_full_path:[ \t]*(?<path>[^\r\n]+)')
    if ($install.Count -ne 1) { throw 'Riot 产品配置缺少唯一安装路径，取消启动前语言设置' }
    $recordedRoot = $install[0].Groups['path'].Value.Trim().Trim([char[]]@('"',"'"))
    if ([IO.Path]::GetFullPath($recordedRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath($GameRoot).TrimEnd('\')) {
        throw 'Riot 产品配置指向另一安装目录，取消修改；请核对台服安装路径'
    }
    $localeSections = [regex]::Matches($text, '(?m)^locale_data:\r?\n(?<body>(?:[ \t][^\r\n]*\r?\n)*)')
    $settingsSections = [regex]::Matches($text, '(?m)^settings:\r?\n(?<body>(?:[ \t][^\r\n]*\r?\n)*)')
    if ($localeSections.Count -ne 1 -or $settingsSections.Count -ne 1) { throw 'Riot 产品配置结构变化，取消启动前语言设置' }
    $section = $localeSections[0].Value
    $defaults = [regex]::Matches($section, '(?m)^(?<indent>[ \t]+)default_locale:[^\r\n]*')
    $available = [regex]::Matches($section, '(?m)^[ \t]+available_locales:[ \t]*\r?\n(?<entries>(?:[ \t]+-[^\r\n]*\r?\n)+)')
    if ($defaults.Count -ne 1 -or $available.Count -ne 1) { throw 'Riot 产品配置语言字段变化，取消修改' }
    $section = $section.Replace($defaults[0].Value, ($defaults[0].Groups['indent'].Value + 'default_locale: "' + $Locale + '"'))
    if ($available[0].Groups['entries'].Value -notmatch ('["'']' + [regex]::Escape($Locale) + '["'']')) {
        $indent = [regex]::Match($available[0].Groups['entries'].Value, '^(?<indent>[ \t]+)-').Groups['indent'].Value
        $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $section = $section.Replace($available[0].Value, ($available[0].Value + $indent + '- "' + $Locale + '"' + $newline))
    }
    $settings = $settingsSections[0].Value
    $selected = [regex]::Matches($settings, '(?m)^(?<indent>[ \t]+)locale:[^\r\n]*')
    if ($selected.Count -ne 1) { throw 'Riot 产品配置缺少唯一所选语言字段，取消修改' }
    $settings = $settings.Replace($selected[0].Value, ($selected[0].Groups['indent'].Value + 'locale: "' + $Locale + '"'))
    $updated = $text.Replace($localeSections[0].Value, $section).Replace($settingsSections[0].Value, $settings)
    if ($updated -eq $text) { return $false }
    $backup = $MetadataPath + '.LOL_TWtoCN.original'
    if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::Copy($MetadataPath, $backup, $false) }
    $temporary = $MetadataPath + '.' + [guid]::NewGuid() + '.partial'
    try {
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $MetadataPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    return $true
}
