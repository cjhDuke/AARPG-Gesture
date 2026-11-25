param(
	[string]$PythonPath = (Get-Command python -ErrorAction Stop).Source,
	[string]$GodotGui = 'C:\Users\DukeChen\Desktop\Godot_v4.6.3.exe',
	[switch]$CapturePreview
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$checksRoot = Join-Path $project '.stage3_checks'
$e2eRoot = Join-Path $checksRoot 'e2e'
if (-not (Test-Path -LiteralPath (Join-Path $project '.godot\imported'))) {
	throw 'Godot import cache is missing. Ask the main agent to run the unified import before this script.'
}
if (-not (Test-Path -LiteralPath $PythonPath) -or -not (Test-Path -LiteralPath $GodotGui)) {
	throw 'Python or Godot executable path is invalid.'
}

$runId = [Guid]::NewGuid().ToString('N')
$runDir = Join-Path $e2eRoot ('online-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $runId.Substring(0, 8))
$logs = Join-Path $runDir 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$config = Join-Path $runDir 'e2e.json'
$fixtureOut = Join-Path $logs 'fixture.stdout.log'
$fixtureErr = Join-Path $logs 'fixture.stderr.log'
$fixture = $null
$savedAppData = $env:APPDATA
$savedPythonPath = $env:PYTHONPATH

function ConvertTo-Argument([string]$value) {
	if ($value -match '[\s"]') { return '"' + $value.Replace('"', '\"') + '"' }
	return $value
}

function Test-LoopbackPort([int]$port) {
	$client = [System.Net.Sockets.TcpClient]::new()
	try {
		$async = $client.BeginConnect('127.0.0.1', $port, $null, $null)
		if (-not $async.AsyncWaitHandle.WaitOne(200)) { return $false }
		$client.EndConnect($async)
		return $true
	} catch { return $false } finally { $client.Close() }
}

function Invoke-Godot([string]$name, [string]$scene, [string]$appData, [string[]]$userArgs, [string]$marker) {
	$env:APPDATA = $appData
	New-Item -ItemType Directory -Force -Path $appData | Out-Null
	$stdout = Join-Path $logs ($name + '.stdout.log')
	$stderr = Join-Path $logs ($name + '.stderr.log')
	$arguments = @('--audio-driver', 'WASAPI', '--path', $project, $scene, '--') + $userArgs
	if (-not ($CapturePreview -and $name -eq 'c-verify')) { $arguments = @('--headless') + $arguments }
	$argumentLine = (($arguments | ForEach-Object { ConvertTo-Argument ([string]$_) }) -join ' ')
	$process = Start-Process -FilePath $GodotGui -ArgumentList $argumentLine -WorkingDirectory $project -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
	$null = $process.Handle
	if (-not $process.WaitForExit(60000)) {
		Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
		throw "$name timed out; inspect retained logs in $logs"
	}
	$process.WaitForExit()
	$outText = if (Test-Path $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
	$errText = if (Test-Path $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
	if ($process.ExitCode -ne 0 -or $errText -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $outText -match 'SCRIPT ERROR:|Parse Error:|ERROR:|FAILED' -or $outText -notmatch $marker) {
		throw "$name failed (exit=$($process.ExitCode)); inspect retained stdout/stderr in $logs"
	}
	$summary = ($outText -split "`r?`n" | Where-Object { $_ -match $marker } | Select-Object -Last 1)
	Write-Host $summary
}

try {
	$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
	$listener.Start()
	$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
	$listener.Stop()
	$env:PYTHONPATH = (Join-Path $checksRoot 'deps') + $(if ($savedPythonPath) { ';' + $savedPythonPath } else { '' })
	$fixtureArgs = @((Join-Path $project 'tests\leaderboard_test_server.py'), '--config', $config, '--port', [string]$port)
	$fixtureLine = (($fixtureArgs | ForEach-Object { ConvertTo-Argument ([string]$_) }) -join ' ')
	$fixture = Start-Process -FilePath $PythonPath -ArgumentList $fixtureLine -WorkingDirectory $project -WindowStyle Hidden -PassThru -RedirectStandardOutput $fixtureOut -RedirectStandardError $fixtureErr
	$readyDeadline = [DateTime]::UtcNow.AddSeconds(30)
	while ([DateTime]::UtcNow -lt $readyDeadline -and (-not (Test-Path $config) -or -not (Test-LoopbackPort $port))) { Start-Sleep -Milliseconds 100 }
	if (-not (Test-Path $config) -or -not (Test-LoopbackPort $port)) { throw 'Fresh local fixture did not become ready.' }
	$fixtureConfig = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
	$api = [string]$fixtureConfig.api
	$baseArgs = @('--no-gesture-autostart', "--auth-api=$api", "--client-config=$config")
	$oldArgs = $baseArgs + @('--legacy-campaign')
	Invoke-Godot 'bridge' 'tests/account_service_transport_test.tscn' (Join-Path $runDir 'appdata-bridge') (@('--leaderboard-offline') + $baseArgs) 'account_service_transport_test: 12 checks passed'
	Invoke-Godot 'manager' 'tests/leaderboard_manager_test.tscn' (Join-Path $runDir 'appdata-manager') (@('--leaderboard-offline') + $baseArgs) 'LEADERBOARD_MANAGER_TEST checks=\d+ failures=0'
	Invoke-Godot 'a-seed' 'tests/leaderboard_client_test.tscn' (Join-Path $runDir 'appdata-a') ($oldArgs + @('--client-role=a-seed')) 'leaderboard_client_test role=a-seed checks=\d+ passed'
	Invoke-Godot 'b-verify' 'tests/leaderboard_client_test.tscn' (Join-Path $runDir 'appdata-b') ($oldArgs + @('--client-role=b-verify')) 'leaderboard_client_test role=b-verify checks=\d+ passed'
	Invoke-Godot 'a-retry' 'tests/leaderboard_client_test.tscn' (Join-Path $runDir 'appdata-a') ($oldArgs + @('--client-role=a-retry')) 'leaderboard_client_test role=a-retry checks=\d+ passed'
	Invoke-Godot 'c-verify' 'tests/leaderboard_client_test.tscn' (Join-Path $runDir 'appdata-c') ($oldArgs + @('--client-role=c-verify') + $(if ($CapturePreview) { @('--capture-previews') } else { @() })) 'leaderboard_client_test role=c-verify checks=\d+ passed'
	Invoke-Godot 'current-play' 'tests/leaderboard_client_test.tscn' (Join-Path $runDir 'appdata-current') ($baseArgs + @('--client-role=current-play')) 'leaderboard_client_test role=current-play checks=\d+ passed'
	if ((Get-Item -LiteralPath $fixtureErr).Length -gt 0) { throw "Fixture wrote to stderr; inspect retained logs in $logs" }
	Write-Host "Online leaderboard checks passed. Logs retained at $logs"
} catch {
	Write-Error $_.Exception.Message
	Write-Host "Logs retained at $logs"
	exit 1
} finally {
	if ($fixture -and -not $fixture.HasExited) {
		Stop-Process -Id $fixture.Id -Force -ErrorAction SilentlyContinue
		$fixture.WaitForExit()
	}
	$env:APPDATA = $savedAppData
	$env:PYTHONPATH = $savedPythonPath
}
