# Removes Daily Briefing's shortcuts and the built .exe. Your files (app\, data\, settings.json) are kept.
$Base = $PSScriptRoot
Write-Host "Removing Daily Briefing shortcuts" -ForegroundColor Cyan
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'server\.ps1' -and $_.CommandLine -like "*$Base*" })) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "  Stopped the running server" -ForegroundColor Green
}
foreach ($dir in "Programs", "Desktop", "Startup") {
    $l = Join-Path ([Environment]::GetFolderPath($dir)) "Daily Briefing.lnk"
    if (Test-Path $l) { Remove-Item $l -Force; Write-Host "  Removed $dir shortcut" -ForegroundColor Green }
}
$exe = Join-Path $Base "DailyBriefing.exe"
if (Test-Path $exe) { Remove-Item $exe -Force; Write-Host "  Removed DailyBriefing.exe" -ForegroundColor Green }
Write-Host ""
Write-Host "Done. Your notes, settings, and caches are still in this folder. Delete the folder to remove everything." -ForegroundColor White
