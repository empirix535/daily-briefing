# Otis server (v2, 2026-10-13 restart)
# Main thread: tray icon + watchdog. Background threads: the HTTP listener (To-do, Notes, Streams) and the assistant.
# Nothing here touches Outlook. Keep this file ASCII-only.
Add-Type -AssemblyName System.Web, System.Windows.Forms, System.Drawing

# ============================ CONFIG ============================
$Config = @{
    # About you (set these in settings.json, not here)
    UserName        = "the user"
    UserDescription = "a professional"
    # Claude Code CLI (uses your claude.ai subscription login, no API key)
    ClaudePath      = ""        # optional full path to claude.exe; auto-detected if blank
    # Assistant (Teams notes-to-self chat)
    SecretaryEnabled        = $true
    SecretaryModel          = "haiku"   # quick chat answers
    SecretaryThinkModel     = "sonnet"  # meeting notes clean-up, page tidy
    SecretaryPollSec        = 30        # how often the self-chat is checked (free, no Claude call)
    SecretaryNotesPollSec   = 10        # faster checks while a notes session is open (free)
    SecretaryDebugPort      = 9222
    SecretaryChromePath     = ""        # auto-detected if blank
    SecretaryDays           = @("Mon", "Tue", "Wed", "Thu", "Fri")
    SecretaryStart          = "08:00"   # working hours: scans, nags, alerts
    SecretaryEnd            = "18:00"
    SecretaryMaxCallsPerDay = 250       # Claude calls per day (chat answers and scans)
    BotEmojiCode        = ":otis:"  # custom Teams emoji typed at the start of each bot message; "" = use the standard emoji. Falls back to it if Teams does not convert the code.
    ToastAlerts         = $true     # Windows pop-up from the tray icon for reminders, meeting prompts and emails that need you (Teams never notifies for your own self-chat)
    MinimizeToTray      = $true     # minimizing the dashboard window hides it; the tray icon brings it back
    # Streams tab: work pipeline file (also edited by Claude Code); item paths are relative to its parent's parent (root)
    StreamsPath         = "$(if ($env:OneDriveCommercial) { $env:OneDriveCommercial } else { "$env:USERPROFILE\OneDrive" })\root\_admin\streams.json"   # override in settings.json
    Port                = 8000
    HeartbeatTimeoutSec = 150
    CloseGraceSec       = 8
}
# ================================================================
# Folders: app\ holds the code and icons, data\ holds notes, to-dos, the assistant's state, and logs
$AppDir     = $PSScriptRoot
$BaseDir    = Split-Path -Parent $AppDir
$DataDir    = Join-Path $BaseDir "data"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$ScriptPath = $PSCommandPath
# settings.json (next to the app folder) overrides the defaults above. Keys the new app does not use are ignored.
$SettingsPath  = Join-Path $BaseDir "settings.json"
$SettingsError = $null
if (Test-Path $SettingsPath) {
    try {
        $s = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $s.PSObject.Properties) {
            if ($prop.Name -like "_*") { continue }
            $Config[$prop.Name] = if ($prop.Value -is [array]) { @($prop.Value) } else { $prop.Value }
        }
    } catch { $SettingsError = $_.Exception.Message }
}
$LogPath = Join-Path $DataDir "server.log"
$Url     = "http://localhost:$($Config.Port)/"
$sync = [hashtable]::Synchronized(@{
    Config        = $Config
    SecretaryToasts = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Root          = $DataDir
    AppDir        = $AppDir
    BaseDir       = $BaseDir
    LogPath       = $LogPath
    LastHeartbeat = Get-Date
    EverConnected = $false
    CloseAt       = $null
    Busy          = $false
})

function Write-Log([string]$Msg, [string]$Level = "INFO") {
    $line = "{0} [{1}] {2}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.IO.File]::AppendAllText($sync.LogPath, $line, [System.Text.Encoding]::UTF8); return }
        catch { Start-Sleep -Milliseconds 50 }
    }
}

# Shared helpers, and the assistant's files in load order
$LibText = [System.IO.File]::ReadAllText((Join-Path $AppDir "lib\common.ps1"))
$AssistantFiles = @("core.ps1", "teams.ps1", "claude.ps1", "reminders.ps1", "todos.ps1", "notes.ps1", "mail.ps1", "calendar.ps1", "commands.ps1", "main.ps1")

# ------------------------------------------------------------------
# Background thread: the HTTP server
# ------------------------------------------------------------------
$ServerLoop = {
    $listener = $sync.Listener
    Write-Log "Server running at http://localhost:$($Config.Port)/"

    while ($listener.IsListening) {
        try {
            $context  = $listener.GetContext()
            $request  = $context.Request
            $response = $context.Response
            $sync.Busy = $true
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")
            if ($request.HttpMethod -eq "OPTIONS") { $response.StatusCode = 200; $response.Close(); continue }

            # Lifecycle: launcher ping, page errors, dashboard heartbeat, dashboard closing
            if ($request.RawUrl -eq "/api/ping") { Write-JsonResponse $response '{"ok":true}'; continue }
            if ($request.RawUrl -eq "/api/clientlog" -and $request.HttpMethod -eq "POST") {
                $txt = (New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
                Write-Log "Dashboard error: $($txt.Substring(0, [math]::Min(1500, $txt.Length)))" "WARN"
                Write-JsonResponse $response '{"ok":true}'; continue
            }
            if ($request.RawUrl -eq "/api/heartbeat") {
                $sync.LastHeartbeat = Get-Date; $sync.CloseAt = $null; $sync.EverConnected = $true
                Write-JsonResponse $response '{"ok":true}'; continue
            }
            if ($request.RawUrl -eq "/api/closing") {
                $sync.CloseAt = (Get-Date).AddSeconds($Config.CloseGraceSec)
                $response.StatusCode = 204; $response.Close(); continue
            }
            $sync.LastHeartbeat = Get-Date; $sync.CloseAt = $null; $sync.EverConnected = $true

            # App icons
            if ($request.RawUrl -match '^/icons/([\w.-]+)(\?.*)?$') {
                $file = Join-Path (Join-Path $sync.AppDir "icons") $Matches[1]
                if (Test-Path $file) {
                    $bytes = [System.IO.File]::ReadAllBytes($file)
                    $response.ContentType = if ($file -like "*.png") { "image/png" } else { "image/x-icon" }
                    $response.AddHeader("Cache-Control", "max-age=86400")
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                } else { $response.StatusCode = 404 }
                $response.Close(); continue
            }

            # The page
            if ($request.RawUrl -eq "/" -or $request.RawUrl -eq "/index.html") {
                $htmlPath = Join-Path $sync.AppDir "Index.html"
                if (Test-Path $htmlPath) {
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes((Get-Content $htmlPath -Raw -Encoding UTF8))
                    $response.ContentType = "text/html"
                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                $response.Close(); continue
            }

            # Cheap change check for the page's poll: to-dos and notes edited by the assistant
            if ($request.RawUrl -eq "/api/changes") {
                $todo = ""; try { if (Test-Path $TodoPath) { $todo = [string](Get-Item $TodoPath).LastWriteTimeUtc.Ticks } } catch {}
                Write-JsonResponse $response (@{ status = "success"; changes = @{ Todo = $todo; Notes = (Get-NotesStamp) } } | ConvertTo-Json -Depth 4)
                continue
            }

            # Streams tab (lifted unchanged). GET returns the file text, its write time, and last-activity facts per active item.
            # POST saves the page's edited JSON only if the file has not changed since the page read it (else 409).
            if ($request.RawUrl -like "/api/streams*") {
                $sp = [string]$Config.StreamsPath
                $utf8 = New-Object System.Text.UTF8Encoding($false)
                try {
                    if (-not (Test-Path $sp)) { throw "streams.json not found at $sp" }
                    if ($request.HttpMethod -eq "POST") {
                        $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $body = $reader.ReadToEnd() | ConvertFrom-Json
                        $now = [string](Get-Item $sp).LastWriteTimeUtc.Ticks
                        if ([string]$body.Base -ne $now) {
                            $response.StatusCode = 409
                            Write-JsonResponse $response (@{ status = "conflict" } | ConvertTo-Json); continue
                        }
                        $text = [string]$body.Text
                        [void]($text | ConvertFrom-Json)   # refuse to write anything that is not valid JSON
                        $tmp = "$sp.tmp"
                        [System.IO.File]::WriteAllText($tmp, $text, $utf8)
                        Move-Item -LiteralPath $tmp -Destination $sp -Force
                        Write-Log "Streams: $([string]$body.What)"
                        Write-JsonResponse $response (@{ status = "success"; mtime = [string](Get-Item $sp).LastWriteTimeUtc.Ticks } | ConvertTo-Json)
                    } else {
                        $text = [System.IO.File]::ReadAllText($sp)
                        $mt = [string](Get-Item $sp).LastWriteTimeUtc.Ticks
                        $root = Split-Path (Split-Path $sp -Parent) -Parent
                        $act = @{}
                        foreach ($it in @(($text | ConvertFrom-Json).items | Where-Object { $_.status -eq "active" -and $_.path })) {
                            $dir = Join-Path $root ([string]$it.path -replace '/', '\')
                            if (-not (Test-Path -LiteralPath $dir)) { $act[[string]$it.id] = @{ missing = $true }; continue }
                            # newest file, skipping folders whose names start with "_"
                            $best = $null; $stack = New-Object System.Collections.Stack; $stack.Push((Get-Item -LiteralPath $dir))
                            while ($stack.Count) {
                                $d = $stack.Pop()
                                foreach ($e in @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
                                    if ($e.PSIsContainer) { if (-not $e.Name.StartsWith("_")) { $stack.Push($e) } }
                                    elseif (-not $best -or $e.LastWriteTime -gt $best.LastWriteTime) { $best = $e }
                                }
                            }
                            $act[[string]$it.id] = if ($best) { @{ file = $best.Name; when = $best.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ss"); days = [int][math]::Floor(((Get-Date) - $best.LastWriteTime).TotalDays) } } else { @{ empty = $true } }
                        }
                        Write-JsonResponse $response (@{ status = "success"; text = $text; mtime = $mt; activity = $act } | ConvertTo-Json -Depth 5)
                    }
                } catch {
                    Write-Log "Streams failed: $($_.Exception.Message)" "WARN"
                    Write-JsonResponse $response (@{ status = "error"; message = $_.Exception.Message } | ConvertTo-Json)
                }
                continue
            }

            # Notes tab (one .md file per page in data\notes)
            if ($request.RawUrl -like "/api/notes*") {
                $apiPath = $request.RawUrl.Split('?')[0]
                if ($apiPath -eq "/api/notes/ai") {
                    try {
                        if ($request.HttpMethod -eq "POST") {
                            $req = (New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                            $who = [string]$Config.UserName
                            $id = Start-ClaudeJob (New-NotesAiPrompt $req $who) ([string]$Config.SecretaryThinkModel)
                            Write-JsonResponse $response (@{ status = "started"; id = $id } | ConvertTo-Json)
                        } else {
                            Write-JsonResponse $response ((Get-ClaudeJob ([string]$request.QueryString["id"])) | ConvertTo-Json -Depth 4)
                        }
                    } catch {
                        Write-Log "Notes AI failed: $($_.Exception.Message)" "WARN"
                        Write-JsonResponse $response (@{ status = "error"; message = $_.Exception.Message } | ConvertTo-Json)
                    }
                    continue
                }
                if ($apiPath -eq "/api/notes/pages" -and $request.HttpMethod -eq "POST") {
                    $req = (New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $out = @{ status = "success"; message = ""; page = "" }
                    try {
                        $name = ConvertTo-NoteName ([string]$req.Name)
                        $cur = @(Get-NotePages | Where-Object { $_ -ieq $name }) | Select-Object -First 1
                        switch ([string]$req.Action) {
                            "create" {
                                if (-not $name) { throw "Give the page a name." }
                                $out.page = New-NotePage $name
                            }
                            "rename" {
                                $new = ConvertTo-NoteName ([string]$req.NewName)
                                if (-not $cur -or $cur -eq "General") { throw "That page can't be renamed." }
                                if (-not $new) { throw "Give the page a name." }
                                if (@(Get-NotePages | Where-Object { $_ -ieq $new -and $_ -ine $cur }).Count) { throw "A page called $new already exists." }
                                Move-Item (Get-NoteFile $cur) (Join-Path $NotesDir "$new.md")
                                $out.page = $new
                            }
                            "remove" {
                                if (-not $cur -or $cur -eq "General") { throw "That page can't be removed." }
                                $gone = Join-Path $NotesDir "_removed"
                                if (-not (Test-Path $gone)) { New-Item -ItemType Directory -Path $gone | Out-Null }
                                Move-Item (Get-NoteFile $cur) (Join-Path $gone ("{0} {1}.md" -f $cur, (Get-Date).ToString("yyyyMMdd-HHmmss")))
                                $out.page = "General"
                            }
                            default { throw "Unknown action." }
                        }
                    } catch { $out.status = "error"; $out.message = $_.Exception.Message }
                    $out.pages = @(Get-NotePages)
                    $out.stamp = Get-NotesStamp
                    Write-JsonResponse $response ($out | ConvertTo-Json -Depth 4)
                } elseif ($request.HttpMethod -eq "POST") {
                    $req = (New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $pg = @(Get-NotePages | Where-Object { $_ -ieq [string]$req.Page }) | Select-Object -First 1
                    if (-not $pg) { Write-JsonResponse $response (@{ status = "error"; message = "Page not found" } | ConvertTo-Json) }
                    else {
                        if ($req.Backup) { Backup-NotePage $pg }
                        Write-NotePage $pg ([string]$req.Text)
                        Write-JsonResponse $response (@{ status = "success"; stamp = (Get-NotesStamp) } | ConvertTo-Json)
                    }
                } else {
                    $want = [string]$request.QueryString["page"]
                    $pages = @(Get-NotePages)
                    $pg = @($pages | Where-Object { $_ -ieq $want }) | Select-Object -First 1
                    if (-not $pg) { $pg = "General" }
                    Write-JsonResponse $response (@{ text = (Read-NotePage $pg); page = $pg; pages = $pages; stamp = (Get-NotesStamp) } | ConvertTo-Json -Depth 4)
                }
                continue
            }

            # To-do tab (todo.json)
            if ($request.RawUrl -eq "/api/todo") {
                if ($request.HttpMethod -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    [System.IO.File]::WriteAllText($TodoPath, $reader.ReadToEnd(), $Utf8)
                    Write-JsonResponse $response '{"status":"success"}'
                } else {
                    $json = if (Test-Path $TodoPath) { [System.IO.File]::ReadAllText($TodoPath) } else { '""' }
                    if (-not $json.Trim()) { $json = '""' }
                    Write-JsonResponse $response $json
                }
                continue
            }

            # Assistant status line for the page header
            if ($request.RawUrl -eq "/api/status") {
                Write-JsonResponse $response (@{ assistant = [string]$sync.SecretaryStatus; alert = [string]$sync.SecretaryAlert; paused = [bool]$sync.SecretaryPaused } | ConvertTo-Json)
                continue
            }

            $response.StatusCode = 404
            $response.Close()
        } catch {
            if (-not $sync.Stopping) { Write-Log "Error handling request: $_" "ERROR" }
            if ($null -ne $response) { try { $response.Close() } catch {} }
        } finally {
            $sync.Busy = $false
        }
    }
    Write-Log "Listener stopped."
}

# ------------------------------------------------------------------
# Main thread: start listener, assistant, tray icon, watchdog
# ------------------------------------------------------------------
# One server at a time. A second launch (for example the Startup shortcut and the launcher firing together) exits quietly
# before it touches the log, so the running server keeps its log and no warning box appears.
$script:InstanceMutex = New-Object System.Threading.Mutex($false, "Local\DailyBriefingServer-$($Config.Port)")
$gotInstance = $false
try { $gotInstance = $script:InstanceMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $gotInstance = $true } catch { $gotInstance = $true }
if (-not $gotInstance) { exit 0 }

try { if (Test-Path $LogPath) { Copy-Item $LogPath (Join-Path $DataDir "server.prev.log") -Force } } catch {}
[System.IO.File]::WriteAllText($LogPath, "", [System.Text.Encoding]::UTF8)
Write-Log "Starting Otis (v2)."
if ($SettingsError) { Write-Log "settings.json could not be read, using defaults: $SettingsError" "WARN" }

$listener = $null
for ($i = 0; $i -lt 10 -and -not $listener; $i++) {
    try { $l = New-Object System.Net.HttpListener; $l.Prefixes.Add($Url); $l.Start(); $listener = $l }
    catch { Start-Sleep -Seconds 1 }
}
if (-not $listener) {
    Write-Log "Port $($Config.Port) is in use. Another server may already be running." "ERROR"
    [void][System.Windows.Forms.MessageBox]::Show("Port $($Config.Port) is already in use. Otis may already be running (check the system tray).", "Otis", "OK", "Warning")
    exit 1
}
$sync.Listener = $listener

function Start-Thread([string]$Script, [bool]$Sta) {
    $r = [runspacefactory]::CreateRunspace()
    if ($Sta) { $r.ApartmentState = "STA" }
    $r.ThreadOptions = "ReuseThread"
    $r.Open()
    $r.SessionStateProxy.SetVariable("sync", $sync)
    $p = [powershell]::Create()
    $p.Runspace = $r
    [void]$p.AddScript($Script)
    return @{ PS = $p; Handle = $p.BeginInvoke() }
}

$srv = Start-Thread ($LibText + "`n" + $ServerLoop.ToString()) $false

# Assistant: lib + the area files, run as one script in its own thread
$sec = $null
if ($Config.SecretaryEnabled) {
    $missing = @($AssistantFiles | Where-Object { -not (Test-Path (Join-Path $AppDir "assistant\$_")) })
    if ($missing) { Write-Log "Assistant files missing: $($missing -join ', '). Assistant is off." "WARN" }
    else {
        $text = "`$LogTag = '[assistant] '`n" + $LibText + "`n" + (($AssistantFiles | ForEach-Object { [System.IO.File]::ReadAllText((Join-Path $AppDir "assistant\$_")) }) -join "`n")
        # Catch a load-time failure inside the thread too, so its message and line land in server.log
        $text = "try {`n$text`n} catch { Write-Log ""Assistant failed: `$(`$_.Exception.Message) `$(`$_.InvocationInfo.PositionMessage)"" 'ERROR'; throw }"
        $sec = Start-Thread $text $true
    }
}

# Tray icon
$notify = New-Object System.Windows.Forms.NotifyIcon
$iconPath = @("icons\agenda.ico", "icons\app_icon.ico") | ForEach-Object { Join-Path $AppDir $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
try { $notify.Icon = New-Object System.Drawing.Icon($iconPath, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
catch { $notify.Icon = [System.Drawing.SystemIcons]::Application }
$notify.Text = "Otis (localhost:$($Config.Port))"

function Get-BrowserPath {
    foreach ($exe in "chrome.exe", "msedge.exe") {
        foreach ($hive in "HKCU:", "HKLM:") {
            $k = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
            try { $v = (Get-ItemProperty $k -ErrorAction Stop).'(default)'; if ($v -and (Test-Path $v)) { return $v } } catch {}
        }
    }
    return "chrome.exe"
}
# Minimize to tray: a minimized dashboard window is hidden (no taskbar button). The tray icon, the launcher, and Open Dashboard restore it.
Add-Type -TypeDefinition @"
using System; using System.Diagnostics; using System.Runtime.InteropServices; using System.Text;
public static class DashWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    public static IntPtr Find(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            if (sb.ToString() != title) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            try {
                string n = Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant();
                if (n == "chrome" || n == "msedge") { found = h; return false; }
            } catch { }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static bool ShouldHide(IntPtr h) { return IsWindowVisible(h) && IsIconic(h); }
    public static void Hide(IntPtr h) { ShowWindow(h, 0); }
    public static void Restore(IntPtr h) { ShowWindow(h, 9); SetForegroundWindow(h); }
}
"@
$script:DashHidden = [IntPtr]::Zero
function Hide-DashboardIfMinimized {
    if (-not $Config.MinimizeToTray) { return }
    if (-not $script:DashHidden.Equals([IntPtr]::Zero)) {
        # Still hidden: nothing to do. Gone, or brought back by the launcher: start watching again.
        if ([DashWin]::Alive($script:DashHidden) -and -not [DashWin]::Visible($script:DashHidden)) { return }
        $script:DashHidden = [IntPtr]::Zero
    }
    $h = [DashWin]::Find("Otis")
    if (-not $h.Equals([IntPtr]::Zero) -and [DashWin]::ShouldHide($h)) { [DashWin]::Hide($h); $script:DashHidden = $h }
}
# $true when a hidden dashboard window was brought back
function Restore-Dashboard {
    $h = $script:DashHidden
    if ($h.Equals([IntPtr]::Zero)) { return $false }
    $script:DashHidden = [IntPtr]::Zero
    if (-not [DashWin]::Alive($h)) { return $false }
    [DashWin]::Restore($h)
    return $true
}
function Open-Dashboard {
    if (Restore-Dashboard) { return }
    $exe = Join-Path $BaseDir "DailyBriefing.exe"
    if (Test-Path $exe) { Start-Process $exe } else { Start-Process (Get-BrowserPath) "--app=$Url --window-size=960,1350" }
}
function Show-Log {
    $cmd = "`$host.UI.RawUI.WindowTitle = 'Otis log'; Get-Content -Path '$LogPath' -Wait -Tail 80"
    Start-Process powershell.exe -ArgumentList @("-NoProfile", "-Command", $cmd)
}

$script:ShuttingDown = $false
function Stop-Server([string]$Reason, [bool]$Restart = $false) {
    if ($script:ShuttingDown) { return }
    $script:ShuttingDown = $true
    $timer.Stop(); $winTimer.Stop()
    [void](Restore-Dashboard)   # never leave the dashboard window hidden with no server behind it
    Write-Log "Shutting down: $Reason"
    $sync.Stopping = $true
    try { $listener.Stop(); $listener.Close() } catch {}
    try { [void]$srv.Handle.AsyncWaitHandle.WaitOne(3000) } catch {}
    if ($Restart) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$ScriptPath`"")
    }
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add("Open Otis")
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miOpen.add_Click({ Open-Dashboard })
$miLog = $menu.Items.Add("View log")
$miLog.add_Click({ Show-Log })

# Start with Windows: a shortcut in the Startup folder that runs the launcher in the background
$StartupLnk  = Join-Path ([Environment]::GetFolderPath("Startup")) "Otis.lnk"
# The app used to be called Daily Briefing. Rename its old shortcuts (Startup, Start menu, Desktop) once; the targets stay the same.
foreach ($f in "Startup", "Programs", "Desktop") {
    try {
        $dir = [Environment]::GetFolderPath($f); $old = Join-Path $dir "Daily Briefing.lnk"; $new = Join-Path $dir "Otis.lnk"
        if ((Test-Path $old) -and -not (Test-Path $new)) { Move-Item -LiteralPath $old -Destination $new; Write-Log "Renamed the $f shortcut to Otis." }
    } catch { }
}
$LauncherExe = Join-Path $BaseDir "DailyBriefing.exe"
$LauncherVbs = Join-Path $AppDir "launch.vbs"
$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem("Start with Windows")
$miStartup.Checked = Test-Path $StartupLnk
$miStartup.add_Click({
    try {
        if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force; Write-Log "Start with Windows: off." }
        else {
            $wsh = New-Object -ComObject WScript.Shell
            $lnk = $wsh.CreateShortcut($StartupLnk)
            if (Test-Path $LauncherExe) { $lnk.TargetPath = $LauncherExe; $lnk.Arguments = "--background" }
            else { $lnk.TargetPath = "wscript.exe"; $lnk.Arguments = "`"$LauncherVbs`" /background" }
            $lnk.WorkingDirectory = $BaseDir
            if ($iconPath) { $lnk.IconLocation = "$iconPath,0" }
            $lnk.Description = "Otis (starts in the background)"
            $lnk.Save()
            Write-Log "Start with Windows: on."
        }
    } catch { Write-Log "Could not change Start with Windows: $($_.Exception.Message)" "WARN" }
    $miStartup.Checked = Test-Path $StartupLnk
})
[void]$menu.Items.Add($miStartup)
$miPause = New-Object System.Windows.Forms.ToolStripMenuItem("Pause Otis")
$miPause.add_Click({ $sync.SecretaryPauseToggle = $true })
$miShowTeams = New-Object System.Windows.Forms.ToolStripMenuItem("Show Teams window")
$miShowTeams.add_Click({ $sync.SecretaryShowWindow = -not [bool]$sync.SecretaryShowWindow; $miShowTeams.Checked = [bool]$sync.SecretaryShowWindow })
if ($sec) { [void]$menu.Items.Add($miPause); [void]$menu.Items.Add($miShowTeams) }
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miRestart = $menu.Items.Add("Restart Otis")
$miRestart.add_Click({ Stop-Server "Restart requested from tray" $true })
$miExit = $menu.Items.Add("Exit")
$miExit.add_Click({ Stop-Server "Exit requested from tray" })
$notify.ContextMenuStrip = $menu
$notify.add_DoubleClick({ Open-Dashboard })
$notify.Visible = $true

# Window watcher: hides a minimized dashboard window (half a second apart, so the taskbar button barely shows)
$winTimer = New-Object System.Windows.Forms.Timer
$winTimer.Interval = 500
$winTimer.add_Tick({ try { Hide-DashboardIfMinimized } catch { } })
$winTimer.Start()

# Watchdog: crash checks and tray alerts. With the assistant on, closing the dashboard keeps the server running.
$script:LastTick = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
    $now = Get-Date
    if (($now - $script:LastTick).TotalSeconds -gt 30) { $sync.LastHeartbeat = $now; Write-Log "Resumed from sleep." }
    $script:LastTick = $now
    if ($srv.Handle.IsCompleted -and -not $script:CrashSeen) {
        $script:CrashSeen = $true
        Write-Log "Listener thread stopped unexpectedly. $(($srv.PS.Streams.Error | Out-String).Trim())" "ERROR"
        $notify.ShowBalloonTip(8000, "Otis", "Otis hit a server error. Right-click the tray icon and choose Restart Otis.", [System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    if ($sec) {
        $miPause.Checked = [bool]$sync.SecretaryPaused
        # Pop-ups queued by the assistant. Several at once become one, so none is lost behind the next.
        if ($sync.SecretaryToasts.Count -gt 0) {
            $items = @(); while ($sync.SecretaryToasts.Count -gt 0) { try { $items += $sync.SecretaryToasts.Dequeue() } catch { break } }
            if ($items.Count) {
                $txt = [string]$items[0]; if ($items.Count -gt 1) { $txt += " (+$($items.Count - 1) more)" }
                if ($txt.Length -gt 250) { $txt = $txt.Substring(0, 247) + "..." }
                try { $notify.ShowBalloonTip(10000, "Otis", $txt, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
            }
        }
        if ($sync.SecretaryAlert -and $sync.SecretaryAlert -ne $script:LastSecAlert) {
            $script:LastSecAlert = $sync.SecretaryAlert
            $notify.ShowBalloonTip(8000, "Otis", $sync.SecretaryAlert, [System.Windows.Forms.ToolTipIcon]::Warning)
        } elseif (-not $sync.SecretaryAlert) { $script:LastSecAlert = $null }
        if ($sec.Handle.IsCompleted -and -not $script:SecCrashSeen) {
            $script:SecCrashSeen = $true
            $why = ($sec.PS.Streams.Error | Out-String).Trim()
            try { [void]$sec.PS.EndInvoke($sec.Handle) } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $why = "$why $($e.Message) $($e.ErrorRecord.InvocationInfo.PositionMessage)".Trim() }
            Write-Log "Assistant thread stopped unexpectedly. $why" "ERROR"
            $notify.ShowBalloonTip(8000, "Otis", "Otis stopped. Right-click the tray icon and choose Restart Otis.", [System.Windows.Forms.ToolTipIcon]::Error)
        }
    }
    if ($sync.CloseAt -and $now -gt $sync.CloseAt) {
        $sync.CloseAt = $null; $sync.EverConnected = $false
        if (-not $sec) { Stop-Server "Dashboard window closed" }
        return
    }
    if ($sync.EverConnected -and -not $sync.Busy -and ($now - $sync.LastHeartbeat).TotalSeconds -gt $Config.HeartbeatTimeoutSec) {
        $sync.EverConnected = $false
        if (-not $sec) { Stop-Server "Dashboard stopped responding for $($Config.HeartbeatTimeoutSec)s" }
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run()
Write-Log "Server exited."
[Environment]::Exit(0)
