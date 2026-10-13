# ================================================================== assistant/main.ps1
# Daily backup and the main loop.

# Daily backup of personal data to OneDrive (restored by Install.cmd)
$BackupFiles = @("settings.json", "data\todo.json",
                 "data\secretary\rules.md", "data\secretary\voice.md", "data\secretary\reminders.json",
                 "data\secretary\state.json", "data\secretary\chat-log.jsonl")
function Backup-PersonalData {
    $od = @($env:OneDriveCommercial, $env:OneDrive) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $od) { Write-Log "No OneDrive folder found; skipped the backup." "WARN"; return }
    $root = Join-Path $od "Daily Briefing backup"
    $latest = Join-Path $root "latest"
    $n = 0
    foreach ($rel in $BackupFiles) {
        $src = Join-Path $sync.BaseDir $rel
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $latest $rel
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item $src $dst -Force; $n++
    }
    if (Test-Path $NotesDir) {
        $dstN = Join-Path $latest "data\notes"
        if (-not (Test-Path $dstN)) { New-Item -ItemType Directory -Path $dstN -Force | Out-Null }
        foreach ($f in Get-ChildItem $NotesDir -Filter *.md -File) { Copy-Item $f.FullName (Join-Path $dstN $f.Name) -Force; $n++ }
    }
    $hist = Join-Path $root "history"
    if (-not (Test-Path $hist)) { New-Item -ItemType Directory -Path $hist -Force | Out-Null }
    Compress-Archive -Path (Join-Path $latest "*") -DestinationPath (Join-Path $hist ((Get-Date).ToString("yyyy-MM-dd") + ".zip")) -Force
    Get-ChildItem $hist -Filter *.zip | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Log "Backed up $n file(s) to $root."
}

$script:LastLaunch = [datetime]::MinValue
$script:LastNav    = [datetime]::MinValue

function Invoke-Step {
    if ($sync.SecretaryPauseToggle) {
        $sync.SecretaryPauseToggle = $false
        $state.Paused = -not $state.Paused; Save-State
        try { Send-Chat $(if ($state.Paused) { "Paused from the tray. Type resume to turn me back on." } else { "Back on." }) } catch {}
    }
    $sync.SecretaryPaused = [bool]$state.Paused
    if ($sync.SecretaryPinToggle) {
        $sync.SecretaryPinToggle = $false
        $state.ChatPin = -not [bool]$state.ChatPin
        if ($state.ChatPin) { $script:PinForce = $true }
        Save-State
    }
    $sync.SecretaryChatPin = [bool]$state.ChatPin

    # Keep the Teams window hidden unless Wael asked to see it (tray) or Teams needs a sign-in
    $wantShow = [bool]$sync.SecretaryShowWindow
    $tgt = Get-TeamsTarget
    if ($tgt -and $tgt.url -match 'login\.microsoftonline') { $wantShow = $true }
    try {
        if ($wantShow) { Set-TeamsWindow $true }
        elseif ($state.ChatPin) { Set-TeamsPinned $true }
        else { Set-TeamsPinned $false; Set-TeamsWindow $false }
    } catch { Write-Log "Could not change the Teams window: $($_.Exception.Message)" "WARN" }
    if (-not $tgt) {
        if (((Get-Date) - $script:LastLaunch).TotalMinutes -ge 2) { $script:LastLaunch = Get-Date; Start-TeamsBrowser }
        Set-Status "Starting the Teams window."
        return
    }
    if ($tgt.url -match 'login\.microsoftonline') {
        Set-Status "Teams needs you to sign in. The Teams window is open; sign in there and it will hide again." $true
        return
    }
    $snap = (Invoke-TeamsJs $tgt $ReadJs) | ConvertFrom-Json
    if ($snap.title -notmatch '\(You\)') {
        # Get past the "open the desktop app?" page, then select the notes-to-self chat in the chat list
        $nav = Invoke-TeamsJs $tgt $NavJs
        if ($nav -eq 'NOT_FOUND' -and ((Get-Date) - $script:LastNav).TotalMinutes -ge 10) {
            $script:LastNav = Get-Date
            [void](Invoke-Cdp $tgt @(@{ Method = 'Page.navigate'; Params = @{ url = $ChatUrl } }))
        }
        Write-Log "Teams window was not on the self-chat ($($snap.title)): $nav"
        if ($nav -eq 'NOT_FOUND') { Set-Status "Can't find your notes-to-self chat. Use Show Teams window and open it." $true }
        else { Set-Status "Opening your notes-to-self chat." }
        return
    }

    $msgs = @($snap.msgs | Where-Object { $_.mid -match '^\d+$' } | Sort-Object { [long]$_.mid })
    if ([long]$state.LastMid -eq 0) {
        # First run: ignore the chat history
        if ($msgs) { $state.LastMid = [long]$msgs[-1].mid }
        Save-State
    }
    if (-not $state.Introduced) {
        $state.Introduced = $true; Save-State
        Send-Chat "Assistant is on. I'll post reminders here and answer your questions. Type help for commands."
    }

    $new = @($msgs | Where-Object { [long]$_.mid -gt [long]$state.LastMid })
    if ($new) {
        $state.LastMid = [long]$new[-1].mid; Save-State   # saved first so a failure never loops
        $texts = @($new | Where-Object { -not (Test-Ours $_) -and $_.text } | ForEach-Object { [string]$_.text })
        if ($texts) {
            Write-Log "New message(s) from $($U): $($texts.Count)"
            Invoke-UserMessages $texts
        }
    }

    if (-not $state.Paused) {
        Invoke-Reminders (Get-Date)
        foreach ($job in @('Invoke-MeetingPrompts', 'Invoke-FyiBatch', 'Invoke-MailWatch')) {
            try { & $job (Get-Date) } catch { Write-Log "$job failed: $($_.Exception.Message)" "WARN" }
        }
        try { Resolve-StaleAsk } catch { Write-Log "Pending question check failed: $($_.Exception.Message)" "WARN" }
    }
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($state.BackupDay -ne $today) {
        $state.BackupDay = $today; Save-State
        try { Backup-PersonalData } catch { Write-Log "Backup failed: $($_.Exception.Message)" "WARN" }
    }
    Set-Status $(if ($state.Paused) { "Paused." } elseif ($state.NotesActive) { "Taking notes." } else { "Watching your self-chat." })
}

if ($sync.AssistantTestMode) { return }   # the test harness loads the functions without starting the loop

Write-Log "Started (v2). Polling every $($Config.SecretaryPollSec)s on port $Port."
$fails = 0
while (-not $sync.Stopping) {
    try {
        Invoke-Step
        $fails = 0
    } catch {
        $fails++
        Write-Log "Step failed ($fails in a row): $($_.Exception.Message)" "WARN"
        if ($fails -ge 3) { Set-Status "The assistant can't read Teams: $($_.Exception.Message)" $true }
    }
    $wait = if ($state.NotesActive) { [int]$Config.SecretaryNotesPollSec } else { [int]$Config.SecretaryPollSec }
    for ($i = 0; $i -lt $wait -and -not $sync.Stopping; $i++) { Start-Sleep -Seconds 1 }
}
Write-Log "Stopped."
