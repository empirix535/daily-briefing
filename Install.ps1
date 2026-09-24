# Daily Briefing installer. Double-click Install.cmd to run it.
# Safe to run again at any time (for example after updating the files).
$ErrorActionPreference = "Stop"
$Base   = $PSScriptRoot
$App    = Join-Path $Base "app"
$Data   = Join-Path $Base "data"
$Icon   = Join-Path $App "icons\agenda.ico"
$Exe    = Join-Path $Base "DailyBriefing.exe"

function Step($m) { Write-Host ""; Write-Host "> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }

Write-Host "Daily Briefing setup" -ForegroundColor White
Write-Host "Folder: $Base"

if (-not (Test-Path (Join-Path $App "server.ps1"))) { throw "app\server.ps1 is missing. Run Install.cmd from the Daily Briefing folder." }

# Files downloaded from GitHub are marked as coming from the internet; unblock them
Get-ChildItem $Base -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# 1. Stop a running server so files can be moved and rebuilt
Step "Stopping any running Daily Briefing server"
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'server\.ps1' -and $_.CommandLine -like "*$Base*" })
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Ok "Stopped server (process $($p.ProcessId))" }
if (-not $procs.Count) { Ok "None running" }

# 2. data\ folder; move files from the older single-folder layout
Step "Organizing folders"
New-Item -ItemType Directory -Force $Data | Out-Null
foreach ($f in "todo.json", "triage-cache.json", "lastseen.json", "catchup.json", "server.log", "server.prev.log") {
    $src = Join-Path $Base $f
    if (Test-Path $src) {
        if (-not (Test-Path (Join-Path $Data $f))) { Move-Item $src (Join-Path $Data $f); Ok "Moved $f to data\" }
    }
}
$old = Join-Path $Base "old"
foreach ($f in "server.ps1", "Index.html", "launch_dashboard.vbs", "agenda.ico", "app_icon.ico", "server.gemini.bak.ps1", "check_models.ps1") {
    $src = Join-Path $Base $f
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force $old | Out-Null
        Move-Item $src (Join-Path $old $f) -Force
        Ok "Moved the old copy of $f to old\ (safe to delete later)"
    }
}

# 3. Personal settings
$settings = Join-Path $Base "settings.json"
if (-not (Test-Path $settings)) {
    Step "Your settings (saved in settings.json; edit it any time)"
    $s = Get-Content (Join-Path $Base "settings.example.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $name = Read-Host "  Your first name, as you sign emails"
    $desc = Read-Host "  One line about you, e.g. 'a researcher at Example Org'"
    $dom  = Read-Host "  Your organization's email domain, e.g. example.org (blank to skip)"
    if ($name) { $s.UserName = $name; $s.SignName = $name }
    if ($desc) { $s.UserDescription = $desc }
    if ($dom)  { $s.InternalDomains = @($dom.Trim().TrimStart('@')) }
    $s | ConvertTo-Json -Depth 5 | Set-Content $settings -Encoding UTF8
    Ok "Saved settings.json"
} else { Step "Settings"; Ok "Using existing settings.json" }

# 4. Requirements
Step "Checking requirements"
if (Test-Path "Registry::HKEY_CLASSES_ROOT\Outlook.Application") { Ok "Classic Outlook found" }
else { Warn "Classic Outlook not found. The new Outlook for Windows is not supported." }

$browser = $null
foreach ($b in "chrome.exe", "msedge.exe") {
    foreach ($hive in "HKCU:", "HKLM:") {
        try { $v = (Get-ItemProperty "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$b" -ErrorAction Stop).'(default)'; if ($v) { $browser = $b; break } } catch {}
    }
    if ($browser) { break }
}
if ($browser) { Ok "Browser: $browser" } else { Warn "Chrome or Edge not found." }

$bin = Join-Path $env:USERPROFILE ".local\bin"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ((Test-Path (Join-Path $bin "claude.exe")) -and ($userPath -notlike "*$bin*")) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$bin", "User")
    $env:Path += ";$bin"
    Ok "Added Claude Code to your PATH"
}
if ((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $bin "claude.exe"))) { Ok "Claude Code found" }
else { Warn "Claude Code not found. Install it in PowerShell with:  irm https://claude.ai/install.ps1 | iex   then run 'claude' once to sign in." }
if ($env:ANTHROPIC_API_KEY -or [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")) {
    Warn "ANTHROPIC_API_KEY is set. The dashboard ignores it and uses your Claude subscription login."
}

# 5. Build DailyBriefing.exe with the C# compiler included in Windows
Step "Building DailyBriefing.exe"
$csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$useExe = $false
if ($csc) {
    if (Test-Path $Exe) { Remove-Item $Exe -Force }
    & $csc /nologo /target:winexe /optimize+ "/win32icon:$Icon" /r:System.Windows.Forms.dll "/out:$Exe" (Join-Path $App "launcher.cs") | Out-Host
    if ($LASTEXITCODE -eq 0 -and (Test-Path $Exe)) { $useExe = $true; Ok "Built DailyBriefing.exe" }
}
if (-not $useExe) { Warn "Could not build the .exe. Shortcuts will use app\launch.vbs instead." }

# 6. Shortcuts
Step "Creating shortcuts"
$wsh = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$Path, [string]$Arguments = "") {
    $l = $wsh.CreateShortcut($Path)
    if ($useExe) { $l.TargetPath = $Exe; $l.Arguments = $Arguments }
    else { $l.TargetPath = "wscript.exe"; $l.Arguments = "`"$(Join-Path $App 'launch.vbs')`" $($Arguments -replace '--', '/')" }
    $l.WorkingDirectory = $Base
    $l.IconLocation = "$Icon,0"
    $l.Description = "Daily Briefing"
    $l.Save()
}
$lnkStart   = Join-Path ([Environment]::GetFolderPath("Programs")) "Daily Briefing.lnk"
$lnkDesktop = Join-Path ([Environment]::GetFolderPath("Desktop")) "Daily Briefing.lnk"
New-Shortcut $lnkStart;   Ok "Start menu: Daily Briefing"
New-Shortcut $lnkDesktop; Ok "Desktop: Daily Briefing"
if ($useExe) {
    # Same taskbar ID as the dashboard window, so the pinned icon and the open window share one button
    foreach ($l in $lnkStart, $lnkDesktop) { Start-Process $Exe -ArgumentList "--register-shortcut", "`"$l`"" -Wait }
    Ok "Taskbar grouping set up (re-pin from Start if you pinned before)"
}
try { & "$env:WINDIR\System32\ie4uinit.exe" -show; Ok "Refreshed Windows' icon cache" } catch {}

$startup = Join-Path ([Environment]::GetFolderPath("Startup")) "Daily Briefing.lnk"
if (Test-Path $startup) { Ok "Start with Windows is on (turn it off from the tray menu)" }

# 7. Done
Step "Done"
Write-Host "  To pin it: open Start, right-click Daily Briefing, choose Pin to taskbar."
$go = Read-Host "  Open Daily Briefing now? (Y/n)"
if ($go -notmatch '^[nN]') {
    if ($useExe) { Start-Process $Exe } else { Start-Process wscript.exe "`"$(Join-Path $App 'launch.vbs')`"" }
}
