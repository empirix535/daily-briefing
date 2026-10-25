# ================================================================== assistant/reminders.ps1
# Reminders: once, daily, weekdays, weekly, snooze, nag (repeat until done), yes/done to confirm. Lifted from v34
# without conditional (if_calendar) reminders.

$Reminders = New-Object System.Collections.ArrayList
foreach ($r in @(Read-JsonFile $RemindersPath)) { if ($r) { [void]$Reminders.Add((ConvertTo-Hash $r)) } }
function Save-Reminders { Write-JsonFile $RemindersPath @($Reminders) }

function Get-Occurrence($r, [datetime]$Now) {
    try {
        if ($r.kind -eq 'once') { return [datetime]::ParseExact([string]$r.at, 'yyyy-MM-ddTHH:mm', $Inv) }
        $t = [datetime]::ParseExact([string]$r.time, 'HH:mm', $Inv)
        $d = $Now.DayOfWeek.ToString().Substring(0, 3)
        if ($r.kind -eq 'weekdays' -and ($d -eq 'Sat' -or $d -eq 'Sun')) { return $null }
        if ($r.kind -eq 'weekly' -and -not (@($r.days) -contains $d)) { return $null }
        return $Now.Date.AddHours($t.Hour).AddMinutes($t.Minute)
    } catch { return $null }
}

function Format-Reminder($r) {
    $when = switch ($r.kind) {
        'once'     { Format-Time ([datetime]::ParseExact([string]$r.at, 'yyyy-MM-ddTHH:mm', $Inv)) }
        'daily'    { "daily $($r.time)" }
        'weekdays' { "weekdays $($r.time)" }
        'weekly'   { "$(@($r.days) -join '/') $($r.time)" }
    }
    $nag = if ([int]$r.nag_minutes -gt 0) { ", repeats every $($r.nag_minutes) min until done" } else { "" }
    return "#$($r.id) $when$nag : $($r.text)"
}

function Send-Reminder($r, [string]$Note) {
    Send-Toast ("Reminder: " + [string]$r.text)
    Send-Chat ("Reminder{0}: {1}" -f $(if ($Note) { " $Note" } else { "" }), [string]$r.text)
    $r.lastFired = (Get-Date).ToString("s")
    $state.LastReminderId = [int]$r.id
    Save-State
}

function Invoke-Reminders([datetime]$Now) {
    $changed = $false
    foreach ($r in @($Reminders)) {
        if ($r.done) { continue }
        if ($r.snoozeUntil) {
            if ($Now -ge [datetime]$r.snoozeUntil) { Send-Reminder $r "(snoozed)"; $r.snoozeUntil = $null; Save-Reminders }
            continue
        }
        $occ = Get-Occurrence $r $Now
        if (-not $occ) { continue }
        $age = ($Now - $occ).TotalHours
        if ($age -lt 0) { continue }
        if ($age -gt 12) { if ($r.kind -eq 'once') { $r.done = $true; $changed = $true }; continue }
        $key = $occ.ToString("s")
        if ($r.lastOcc -ne $key) {
            Send-Reminder $r ""
            $r.lastOcc = $key; $r.acked = $false; $r.nags = 0
            Save-Reminders; continue
        }
        if (-not $r.acked -and [int]$r.nag_minutes -gt 0 -and [int]$r.nags -lt 3 -and (Test-ActiveHours $Now) -and
            ($Now - [datetime]$r.lastFired).TotalMinutes -ge [int]$r.nag_minutes) {
            Send-Reminder $r "(again)"; $r.nags = [int]$r.nags + 1; Save-Reminders
        }
    }
    # Drop finished one-off reminders after a week
    foreach ($r in @($Reminders)) {
        if ($r.done -and $r.lastFired -and ((Get-Date) - [datetime]$r.lastFired).TotalDays -gt 7) { $Reminders.Remove($r); $changed = $true }
    }
    if ($changed) { Save-Reminders }
}

function Get-LastReminder {
    $r = @($Reminders | Where-Object { [int]$_.id -eq [int]$state.LastReminderId }) | Select-Object -First 1
    if ($r -and $r.lastFired -and ((Get-Date) - [datetime]$r.lastFired).TotalHours -lt 12) { return $r }
    return $null
}

# Vague times in a reminder request get a random time inside a window, so reminders do not all land on the same minute.
# "before noon" 11:00-11:30, "before COB / end of day" 15:30-16:30, "this afternoon" 14:30-15:30. Only the time of day changes; the date stays as the model read it.
$FuzzyWindows = @(
    @{ Rx = '(?i)\b(?:before|by)\s+noon\b';                                             From = '11:00'; To = '11:30' },
    @{ Rx = '(?i)\b(?:before|by)\s+(?:cob|c\.o\.b|close of business|eod|end of (?:the )?day)\b'; From = '15:30'; To = '16:30' },
    @{ Rx = '(?i)\bthis afternoon\b';                                                    From = '14:30'; To = '15:30' }
)
function Set-FuzzyTimes($Items, [string]$Text, [datetime]$Now = (Get-Date)) {
    $w = $FuzzyWindows | Where-Object { $Text -match $_.Rx } | Select-Object -First 1
    if (-not $w) { return }
    foreach ($it in @($Items | Where-Object { $_ -and [string]$_.kind -eq 'once' })) {
        $day = $Now.Date
        try { $day = [datetime]::ParseExact(([string]$it.at).Substring(0, 10), 'yyyy-MM-dd', $Inv) } catch { }
        $lo = $day + [datetime]::ParseExact($w.From, 'HH:mm', $Inv).TimeOfDay
        $hi = $day + [datetime]::ParseExact($w.To, 'HH:mm', $Inv).TimeOfDay
        if ($day -eq $Now.Date -and $lo -lt $Now.AddMinutes(2)) { $lo = $Now.AddMinutes(2) }   # the window may be partly over today
        if ($hi -le $lo) { continue }                                                         # window already over: keep the time the model chose
        $mins = [int][math]::Floor(($hi - $lo).TotalMinutes)
        $at = $lo.AddMinutes((Get-Random -Minimum 0 -Maximum ($mins + 1)))
        $it.at = $at.ToString('yyyy-MM-ddTHH:mm', $Inv)
    }
}

function Add-Reminders($Items) {
    $added = @()
    foreach ($it in @($Items) | Select-Object -First 5) {
        if (-not $it -or -not $it.text) { continue }
        $kind = [string]$it.kind
        if ($kind -notin @('once', 'daily', 'weekdays', 'weekly')) { continue }
        $r = @{ id = [int]$state.NextReminderId; text = [string]$it.text; kind = $kind; nag_minutes = [int]$it.nag_minutes; created = (Get-Date).ToString("s") }
        try {
            if ($kind -eq 'once') { $r.at = ([datetime]::ParseExact([string]$it.at, 'yyyy-MM-ddTHH:mm', $Inv)).ToString('yyyy-MM-ddTHH:mm') }
            else { $r.time = ([datetime]::ParseExact([string]$it.time, 'HH:mm', $Inv)).ToString('HH:mm') }
            if ($kind -eq 'weekly') {
                $r.days = @(@($it.days) | ForEach-Object { ([string]$_).Substring(0, 3) } | Where-Object { $_ -in @('Mon','Tue','Wed','Thu','Fri','Sat','Sun') })
                if (-not $r.days) { continue }
            }
        } catch { Write-Log "Skipped a reminder with a bad time: $(ConvertTo-Json -InputObject $it -Compress)" "WARN"; continue }
        $state.NextReminderId = [int]$state.NextReminderId + 1
        [void]$Reminders.Add($r); $added += $r
    }
    if ($added) { Save-Reminders; Save-State }
    return $added
}

function Remove-ReminderById([int]$Id) {
    $r = @($Reminders | Where-Object { [int]$_.id -eq $Id }) | Select-Object -First 1
    if ($r) { $Reminders.Remove($r); Save-Reminders }
    return $r
}

# "yes", "done" and variants confirm the reminder that just fired; "snooze 30m" delays it. $true when handled.
$YesRx  = '^(yes|yeah|yep|yup|yea|ya|sure|ok|okay|k|y|done|did it|i did|i did it|did|taken|took it|i took it|took them|done and done|finished|completed|handled|got it|all done|ok done|yes done|yes i did|yes i have|yes i do)$'
$DoneRx = '^(done|did it|i did|i did it|did|taken|took it|i took it|took them|finished|completed|handled|all done|ok done|yes done|yes i did|yes i have)$'
function Resolve-ReminderReply([string]$t) {
    $last = Get-LastReminder
    if (-not $last) { return $false }
    # Once a reminder is confirmed, a stray "yes" is left for other handlers; "done" still counts.
    if ($t -match $YesRx -and ($t -match $DoneRx -or -not $last.acked)) {
        $last.acked = $true; $last.snoozeUntil = $null
        if ($last.kind -eq 'once') { $last.done = $true }
        Save-Reminders; Send-Chat "Noted, marked done (reminder #$($last.id))."; return $true
    }
    if ($t -match '^snooze(?: (\d+) ?(m|min|mins|minutes|h|hr|hrs|hour|hours)?)?$') {
        $n = if ($Matches[1]) { [int]$Matches[1] } else { 30 }
        $mins = if ($Matches[2] -and $Matches[2].StartsWith('h')) { $n * 60 } else { $n }
        $until = (Get-Date).AddMinutes($mins)
        $last.snoozeUntil = $until.ToString("s"); Save-Reminders
        Send-Chat "Snoozed until $(Format-Time $until)."; return $true
    }
    return $false
}
