# 云存档本地回归

`storage_safety.gd` 覆盖 21 项本地存储与同步保护检查。先导入项目，然后在 Windows PowerShell 中从项目根目录运行：

```powershell
$previousAppData = $env:APPDATA
$env:APPDATA = Join-Path (Get-Location) ('.stage1_checks/storage-' + [guid]::NewGuid())
try {
    godot --headless --audio-driver Dummy --path . --script res://tests/cloud/storage_safety.gd -- --no-gesture-autostart --auth-api=http://127.0.0.1:1/api/v1 --leaderboard-offline
} finally {
    $env:APPDATA = $previousAppData
}
```
