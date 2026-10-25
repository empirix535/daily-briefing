# ================================================================== assistant/core.ps1
# Otis (v2). Runs in its own thread of server.ps1 ($sync is shared; lib\common.ps1 is loaded first).
# It watches the Teams notes-to-self chat through a dedicated Chrome window, answers with Claude, and posts
# reminders and alerts. It only ever writes to the notes-to-self chat and to local files. It never sends email,
# never opens Outlook, and never messages anyone else. Keep every assistant file ASCII-only.

$U    = if ($Config.UserName) { [string]$Config.UserName } else { "the user" }
$MeRx = "^(?i)(me|myself|i|" + [regex]::Escape($U) + ")$"   # action-item owner meaning the user
$SecDir = Join-Path $Root "secretary"
if (-not (Test-Path $SecDir)) { New-Item -ItemType Directory -Path $SecDir | Out-Null }
$StatePath     = Join-Path $SecDir "state.json"
$RemindersPath = Join-Path $SecDir "reminders.json"
$RulesPath     = Join-Path $SecDir "rules.md"
$VoicePath     = Join-Path $SecDir "voice.md"
$ChatLogPath   = Join-Path $SecDir "chat-log.jsonl"
$MeetingsPath  = Join-Path $SecDir "meetings.json"     # today's meetings, written by the scan (next update)
$WorkDir       = Join-Path $env:TEMP "otis-claude"
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

$Tag     = [char]::ConvertFromUtf32(0x1F419)   # octopus: the marker at the start of every bot message
$OldTags = @([char]::ConvertFromUtf32(0x1F916), [char]::ConvertFromUtf32(0x1F4CE), [char]::ConvertFromUtf32(0x1F43B))   # robot, paperclip, bear: earlier messages in the chat still carry these
$BotName = if ($Config.BotName) { [string]$Config.BotName } else { "Otis" }   # name shown before each bot message (setting: BotName)
$Port    = [int]$Config.SecretaryDebugPort
$ChatUrl = "https://teams.cloud.microsoft/"

# ------------------------------------------------------------------ state
$state = @{ Paused = $false; Posted = @(); NextReminderId = 1; LastReminderId = 0; Introduced = $false; CallsDay = ""; Calls = 0 }
$saved = Read-JsonFile $StatePath
if ($saved) { foreach ($p in $saved.PSObject.Properties) { $state[$p.Name] = $p.Value } }
# Keys only the old build used
foreach ($k in @('MailSeen', 'MailPrimed', 'FyiQueue', 'FyiSlot', 'EveningDay', 'TodoDay', 'LastMid', 'ChatPin', 'ChatRect')) { $state.Remove($k) }
$state.Posted  = @($state.Posted)
function Save-State { Write-JsonFile $StatePath $state }

if (-not (Test-Path $RulesPath)) {
    [System.IO.File]::WriteAllText($RulesPath, @"
# Assistant rules (edit freely)
- You assist $U, $($Config.UserDescription). You talk only with $U.
- Keep replies short: one to four sentences unless $U asks for more.
- Never claim to have done something you cannot do, such as sending email, accepting meetings, or messaging others.
"@, $Utf8)
}
if (-not (Test-Path $VoicePath)) {
    [System.IO.File]::WriteAllText($VoicePath, "# Voice (edit freely)`r`nDirect, warm, collegial. Plain sentences, no markdown, no em dashes, no filler.`r`n", $Utf8)
}

# ------------------------------------------------------------------ chat log (for context in prompts)
function Add-ChatLog([string]$Who, [string]$Text) {
    $line = (ConvertTo-Json -InputObject @{ t = (Get-Date).ToString("s"); who = $Who; text = $Text } -Compress) + "`n"
    [System.IO.File]::AppendAllText($ChatLogPath, $line, $Utf8)
}
function Get-RecentChat([int]$N = 12) {
    if (-not (Test-Path $ChatLogPath)) { return "" }
    $lines = Get-Content -Path $ChatLogPath -Tail $N -Encoding UTF8
    return (@($lines | ForEach-Object { try { $o = $_ | ConvertFrom-Json; "{0} ({1}): {2}" -f $o.who, $o.t, $o.text } catch {} }) -join "`n")
}

# ------------------------------------------------------------------ time helpers
function Test-ActiveHours([datetime]$Now) {
    $d = $Now.DayOfWeek.ToString().Substring(0, 3)
    if (-not (@($Config.SecretaryDays) -contains $d)) { return $false }
    $s = [datetime]::ParseExact($Config.SecretaryStart, 'HH:mm', $Inv).TimeOfDay
    $e = [datetime]::ParseExact($Config.SecretaryEnd, 'HH:mm', $Inv).TimeOfDay
    return ($Now.TimeOfDay -ge $s -and $Now.TimeOfDay -lt $e)
}
function Format-Time([datetime]$T) {
    if ($T.Date -eq (Get-Date).Date) { return $T.ToString("h:mm tt", $Inv) }
    return $T.ToString("ddd MMM d, h:mm tt", $Inv)
}
# Plain-language version of an error for the chat. The log keeps the raw text.
function Get-PlainError([string]$Msg) {
    $m = ([string]$Msg -replace '^\s*Claude error:\s*', '').Trim()
    if ($m -match '(?i)oauth|failed to authenticate|not logged in|/login') { return "Claude's sign-in expired. In a terminal, run claude and then /login." }
    if ($m -match '(?i)timed out') { return "Claude took too long to answer." }
    if ($m -match '(?i)cli not found') { return "I can't find Claude on this PC." }
    if ($m -match '(?i)returned no json|invalid json|primitive') { return "Claude's answer wasn't in a form I could read." }
    if ($m.Length -gt 220) { $m = $m.Substring(0, 220) + "..." }
    return $m
}
# Windows pop-up from the tray icon (the server's timer shows it). Teams does not notify for messages you post to yourself.
function Send-Toast([string]$Text) {
    try {
        if ($Config.ToastAlerts -eq $false -or -not $sync.SecretaryToasts) { return }
        $t = ($Text -replace '\s+', ' ').Trim()
        if ($t) { $sync.SecretaryToasts.Enqueue($t) }
    } catch { }
}
function Set-Status([string]$Text, [bool]$Alert = $false) {
    $sync.SecretaryStatus = $Text
    $sync.SecretaryAlert  = if ($Alert) { $Text } else { $null }
}

# ------------------------------------------------------------------ the one pending question
# At most one question waits for an answer at a time. Kinds: todo_due, note_filing, note_edit.
# Each kind registers how to read an answer (Answer) and what to do when it expires or is replaced (Expire).
$script:Ask = $null
$AskKinds = @{}
function Register-AskKind([string]$Kind, [scriptblock]$Answer, [scriptblock]$Expire) { $AskKinds[$Kind] = @{ Answer = $Answer; Expire = $Expire } }
function Set-Ask([string]$Kind, $Data, [int]$Minutes = 30) {
    if ($script:Ask) { Close-Ask "replaced" }
    $script:Ask = @{ Kind = $Kind; Data = $Data; Until = (Get-Date).AddMinutes($Minutes) }
}
function Clear-Ask { $script:Ask = $null }
# Runs the kind's expiry step (for example, file unfiled notes under General), then clears the slot
function Close-Ask([string]$Why) {
    $a = $script:Ask; $script:Ask = $null
    if ($a -and $AskKinds[$a.Kind] -and $AskKinds[$a.Kind].Expire) {
        try { & $AskKinds[$a.Kind].Expire $a.Data $Why } catch { Write-Log "Closing the $($a.Kind) question failed: $($_.Exception.Message)" "WARN" }
    }
}
# $true when the message answered the waiting question
function Resolve-AskAnswer([string]$Text) {
    $a = $script:Ask
    if (-not $a) { return $false }
    if ((Get-Date) -ge $a.Until) { Close-Ask "expired"; return $false }
    $r = @(& $AskKinds[$a.Kind].Answer $a.Data $Text)   # the last value is the answer; anything before it is stray output
    return ($r.Count -gt 0 -and [bool]$r[-1])
}
function Resolve-StaleAsk {
    if ($script:Ask -and (Get-Date) -ge $script:Ask.Until) { Close-Ask "expired" }
}
