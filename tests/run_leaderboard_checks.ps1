param(
    [string]$Godot = 'godot',
    [switch]$Visual,
    [switch]$SkipImport
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$checksParent = [IO.Path]::GetFullPath((Join-Path $projectRoot '.stage1_checks'))
$checkRoot = Join-Path $checksParent ('leaderboard-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $checkRoot -Force | Out-Null
$savedAppData = $env:APPDATA
$savedTemp = $env:TEMP
$savedTmp = $env:TMP

function Invoke-GameCheck {
    param([string]$Name, [string[]]$GameArgs, [string]$Profile)
    $env:APPDATA = Join-Path $checkRoot $Profile
    New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
    $outPath = Join-Path $checkRoot ($Name + '.log')
    $errPath = Join-Path $checkRoot ($Name + '.err')
    $process = Start-Process -FilePath $Godot -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -ArgumentList $GameArgs -RedirectStandardOutput $outPath -RedirectStandardError $errPath
    # Windows PowerShell must retain the process handle before it exits.
    $null = $process.Handle
    if (-not $process.WaitForExit(120000)) {
        $process.Kill()
        throw "Timed out: $Name. Logs: $checkRoot"
    }
    $process.WaitForExit()
    $output = Get-Content -LiteralPath $outPath -Raw
    $errors = Get-Content -LiteralPath $errPath -Raw
    if ($process.ExitCode -ne 0 -or $errors -match '(?m)^(SCRIPT ERROR:|ERROR:)') {
        Write-Output $output
        Write-Output $errors
        throw "Failed: $Name (exit $($process.ExitCode)). Logs: $checkRoot"
    }
    Write-Output ($Name + ': ' + ($output.Trim() -split "`n" | Select-Object -Last 1))
}

try {
    $env:TEMP = Join-Path $checkRoot 'temp'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    $baseArgs = @('--headless', '--path', $projectRoot, '--audio-driver', 'Dummy')
    if (-not $SkipImport) {
        Invoke-GameCheck 'import' ($baseArgs + @('--editor', '--import')) 'import'
    }
    $testArgs = @('--', '--no-gesture-autostart', '--leaderboard-offline', '--auth-api=http://127.0.0.1:1/api/v1')
    Invoke-GameCheck 'stats' ($baseArgs + @('res://tests/run_stats_test.tscn') + $testArgs) 'stats'
    Invoke-GameCheck 'seed' ($baseArgs + @('res://tests/run_stats_test.tscn') + $testArgs + @('--run-stats-seed')) 'restart'
    Invoke-GameCheck 'restart' ($baseArgs + @('res://tests/run_stats_test.tscn') + $testArgs + @('--run-stats-verify')) 'restart'
    Invoke-GameCheck 'integration' ($baseArgs + @('res://tests/survival_ranking_test.tscn') + $testArgs + @('--legacy-campaign')) 'integration'
    Invoke-GameCheck 'ui' ($baseArgs + @('res://tests/leaderboard_ui_test.tscn') + $testArgs) 'ui'
    if ($Visual) {
        $visualArgs = @('--path', $projectRoot, '--audio-driver', 'Dummy', '--rendering-method', 'gl_compatibility', '--resolution', '1280x720')
        Invoke-GameCheck 'visual' ($visualArgs + @('res://tests/leaderboard_ui_test.tscn') + $testArgs + @('--capture-previews')) 'visual'
    }
    Write-Output 'LEADERBOARD_CHECKS_PASS'
}
finally {
    $env:APPDATA = $savedAppData
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    Write-Output "Logs and isolated profiles: $checkRoot"
}
