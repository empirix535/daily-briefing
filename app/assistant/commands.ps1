# ================================================================== assistant/commands.ps1
# The one command table (plain patterns, no model call), the cheat sheet generated from it, and the router for
# everything else. Early commands run before a waiting question gets its answer; Late commands run after it, so an
# answer like "today" to "when is this due?" is not taken as the "today" brief.

$Commands = @(
    @{ When = 'Early'; Area = 'NOTES'; Use = 'start notes / end notes [page] / cancel notes'; Rx = '^(?i)(start|take|begin) notes?$'
       Do = { Start-Notes } }
    @{ When = 'Early'; Area = 'TO-DOS'; Use = 'todo: X'; Raw = $true; Rx = '^(?i)(?:todo|to-do|task):\s*(.+)$'
       Do = { param($m) $a = @(Add-TodoItems @(@{ text = $m[1].Trim() })); Send-Chat ("Added to your to-do list: " + ($a -join "; ") + "`n" + (Request-TodoDue)).Trim() } }
    @{ When = 'Early'; Area = 'TO-DOS'; Use = 'todos'; Rx = '^(?i)(?:show\s+)?(?:my\s+)?(todos|to-dos|tasks|to-do list|todo list)$'
       Do = { $o = Get-OpenTodoText; Send-Chat $(if ($o) { "Open to-dos:`n$o" } else { "Your to-do list has no open items." }) } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'new note page X'; Rx = '^(?i)(?:new|create|add|make)\s+(?:a\s+|an\s+)?(?:new\s+)?notes?\s*(?:tab|page)s?(?:\s+(?:called|named|for))?:?\s*(.+)$'
       Do = { param($m)
              $name = ConvertTo-NoteName $m[1]
              if (-not $name) { Send-Chat "What should the page be called?"; return }
              $have = Find-NotePage $name
              if ($have -and $have -ieq $name) { Send-Chat "There's already a note page called ""$have""."; return }
              $made = New-NotePage $name
              Send-Chat "Created the note page ""$made"". I'll file notes there when you name it (note $made`: ...) or when I guess it." } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'note pages'; Rx = '^(?i)(notes? ?(tabs|pages)|list notes)$'
       Do = { Send-Chat ("Note pages: " + ((Get-NotePages) -join ", ")) } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'note to PAGE: X'; Raw = $true; Rx = '^(?i)note\s+(?:to|in|for|on)\s+([^:]{1,40}):\s*(.+)$'
       Do = { param($m) Add-QuickNote $m[2] $m[1].Trim() } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'note PAGE: X'; Raw = $true; Rx = '^(?i)note:?\s*([^:\s][^:]{0,39}):\s*(.+)$'
       Do = { param($m) if (-not (Find-NotePage $m[1])) { return $false }; Add-QuickNote $m[2] $m[1].Trim() } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'note: X'; Raw = $true; Rx = '^(?i)note:\s*(.+)$'
       Do = { param($m) Add-QuickNote $m[1] } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'tidy PAGE'; Rx = '^(?i)(?:tidy|tidy up|clean up|organize|reorganize)\s+(?:my\s+|the\s+)?(.+?)(?:\s+(?:notes?|page))?$'
       Do = { param($m) Invoke-NoteTidy $m[1] } }
    @{ When = 'Early'; Area = 'NOTES'; Use = 'show PAGE / show full PAGE'; Rx = '^(?i)(?:show|read)\s+(?:me\s+)?(?:my\s+|the\s+)?(full\s+)?(.+?)(?:\s+(?:notes?|page))?$'
       Do = { param($m) if (-not (Find-NotePage $m[2])) { return $false }; Show-NotePage $m[2] ([bool]$m[1]) } }
    @{ When = 'Early'; Area = 'EMAIL'; Use = 'check email (runs a scan now)'; Rx = '^(?i)(?:check|scan)(?:\s+(?:my|the))?\s*(?:e-?mails?|mail|inbox)$|^(?i)scan$'
       Do = { [void](Invoke-MailScan (Get-Date) 'manual') } }
    @{ When = 'Early'; Area = 'EMAIL'; Use = 'reply to 2 by Friday (a to-do to reply to that email; the date is optional)'; Rx = '^(?i)reply\s+(?:to\s+)?(?:(?:email|mail|item|number|no\.?|#)\s*)?(\d+)(?:\s+(?:by\s+|on\s+|for\s+|due\s+)?(.+?))?[.!]*$'
       Do = { param($m)
              $a = @($state.LastAlert | Where-Object { $_ -and [int]$_.n -eq [int]$m[1] }) | Select-Object -First 1
              if (-not $a) { Send-Chat "I don't have a numbered email $($m[1]). Ask me to check email, or name the sender."; return }
              $text = "Reply to $($a.from)" + $(if ([string]$a.subject) { ": $($a.subject)" } else { "" })
              $done = @(Add-TodoItems @(@{ text = $text; due_said = [string]$m[2]; mailLink = [string]$a.link }))
              Send-Chat ("Added to your to-do list: " + ($done -join "; ") + "`n" + (Request-TodoDue)).Trim() } }
    @{ When = 'Early'; Area = 'EMAIL'; Use = 'skip 2 / skip all (stop asking about unanswered email)'; Rx = '^(?i)(?:skip|drop|dismiss)\s+(all|\d+(?:\s*(?:,|and|&)\s*\d+)*)$'
       Do = { param($m) Set-ReplySkip $m[1] } }
    @{ When = 'Late'; Area = 'EMAIL'; Use = 'unanswered (email still waiting on your reply)'; Rx = '^(?i)(?:unanswered|unreplied|owed replies)$'
       Do = { Send-ReplyCheck (Get-Date) -Asked } }
    @{ When = 'Late'; Area = 'EMAIL'; Use = 'fyi (the queued FYI email)'; Rx = '^(?i)fyi$'
       Do = { Send-FyiBatch -Asked; $script:RoundupBase = 0 } }
    @{ When = 'Late'; Area = 'CALENDAR'; Use = 'prep (brief for the meeting I just asked about)'; Rx = '^(?i)prep(?:\s+(?:brief|me))?$'
       Do = { Send-PrepBrief $state.PrepLast } }
    @{ When = 'Late'; Area = 'CALENDAR'; Use = 'test event link (one pre-filled sample to try)'; Rx = '^(?i)test (?:event|calendar) link$'
       Do = { $d = (Get-NextWorkday (Get-Date)).AddHours(10)
              $me = [string]$Config.UserEmail   # set UserEmail in settings.json
              Send-Chat "Sample event for tomorrow 10:00, with you as the only attendee. Click the link and check that the subject, times, location, body, and attendee are filled in. Do not press Send unless you want the invite." `
                  (New-EventLink "Test event from assistant" $d $d.AddMinutes(30) @(@($me) | Where-Object { $_ }) "Teams" "Sample body line one.") "Open pre-filled event" } }
    @{ When = 'Late'; Area = 'BRIEFS'; Use = 'morning (also: today, brief)'; Rx = '^(?i)(morning|brief|today)$'
       Do = { Send-DayBrief (Get-Date).Date 'week' } }
    @{ When = 'Late'; Area = 'BRIEFS'; Use = 'tomorrow'; Rx = '^(?i)tomorrow$'
       Do = { Send-DayBrief (Get-NextWorkday (Get-Date)) 'today' } }
    @{ When = 'Late'; Area = 'REMINDERS'; Use = 'reminders'; Rx = '^(?i)(?:list |show |my )?reminders$'
       Do = { $list = @($Reminders | Where-Object { -not $_.done } | ForEach-Object { Format-Reminder $_ })
              Send-Chat $(if ($list) { "Your reminders:`n" + ($list -join "`n") } else { "No reminders set." }) } }
    @{ When = 'Late'; Area = 'REMINDERS'; Use = 'delete reminder 3'; Rx = '^(?i)(?:delete|remove|cancel)(?: reminder)? ?#?(\d+)$'
       Do = { param($m) $id = [int]$m[1]; $r = Remove-ReminderById $id
              Send-Chat $(if ($r) { "Deleted reminder #$id ($($r.text))." } else { "I don't have a reminder #$id." }) } }
    @{ When = 'Late'; Area = 'OTHER'; Use = 'pause / resume'; Rx = '^(?i)(pause|resume)$'
       Do = { param($m) $state.Paused = ($m[1] -ieq 'pause'); Save-State
              Send-Chat $(if ($state.Paused) { "Paused. No reminders until you type resume." } else { "Back on." }) } }
    @{ When = 'Late'; Area = 'OTHER'; Use = 'help'; Rx = '^(?i)(help|commands|cheat ?sheet)$'
       Do = { Send-Chat (Get-CheatSheet) } }
)

# The cheat sheet, generated from the table plus the things that need no command
function Get-CheatSheet {
    $areas = [ordered]@{ 'NOTES' = @(); 'TO-DOS' = @(); 'REMINDERS' = @(); 'EMAIL' = @(); 'CALENDAR' = @(); 'BRIEFS' = @(); 'OTHER' = @() }
    foreach ($c in $Commands) { $areas[$c.Area] += $c.Use }
    $areas['TO-DOS']    += 'or just say it: add X to my to-dos due Friday | X is due Thursday | mark X done'
    $areas['EMAIL']     += 'or just ask: what does 1 want | play by play on 3 | what did Sophie say about the budget | make a to-do from 2'
    $areas['CALENDAR']  += 'or just ask: when am I free Thursday | what is on Friday'
    $areas['REMINDERS'] += 'yes or done (after a reminder) | snooze 30m | remind me Thu at 2 to ... | every weekday at 9 ... | ...until I say done'
    $out = @(); foreach ($k in $areas.Keys) { $out += "$k`: " + ($areas[$k] -join ' | ') }
    return ($out -join "`n")
}

# Typo-tolerant "start notes" / "end notes" (for example "start ntoes", "edn notes"). Get-NotesPhrase returns $null when
# the text is not that phrase, else "". Optimal string alignment distance: a swap of two letters counts once.
function Get-EditDistance([string]$a, [string]$b) {
    # Flat array, row-major: cell (i, j) sits at i * $w + j. Plain index arithmetic parses on Windows PowerShell 5.1.
    $w = $b.Length + 1
    $d = New-Object int[] (($a.Length + 1) * $w)
    for ($i = 0; $i -le $a.Length; $i++) { $d[$i * $w] = $i }
    for ($j = 0; $j -le $b.Length; $j++) { $d[$j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $c = 1; if ($a[$i - 1] -eq $b[$j - 1]) { $c = 0 }
            $up = $d[($i - 1) * $w + $j] + 1
            $left = $d[$i * $w + $j - 1] + 1
            $diag = $d[($i - 1) * $w + $j - 1] + $c
            $v = $up; if ($left -lt $v) { $v = $left }; if ($diag -lt $v) { $v = $diag }
            if ($i -gt 1 -and $j -gt 1 -and $a[$i - 1] -eq $b[$j - 2] -and $a[$i - 2] -eq $b[$j - 1]) {
                $swap = $d[($i - 2) * $w + $j - 2] + 1
                if ($swap -lt $v) { $v = $swap }
            }
            $d[$i * $w + $j] = $v
        }
    }
    return $d[$a.Length * $w + $b.Length]
}
function Get-NotesPhrase([string]$Text, [string]$Kind) {
    # Exactly two words. The verb may have two letters swapped ("strat", "edn"); the noun may be one edit off "notes"
    # and must start with n. Stricter than that would miss typos; looser would catch "send notes" or "and notes".
    $w = @(($Text.ToLowerInvariant() -replace '[^a-z ]', ' ').Trim() -split '\s+' | Where-Object { $_ })
    if ($w.Count -ne 2) { return $null }
    $verbs = if ($Kind -eq 'start') { @('start', 'take', 'begin') } else { @('end', 'stop', 'finish') }
    $sorted = { param($x) -join (([char[]]$x) | Sort-Object) }
    $ok = @($verbs | Where-Object { $w[0] -eq $_ -or ((& $sorted $w[0]) -eq (& $sorted $_) -and (Get-EditDistance $w[0] $_) -le 1) }).Count
    if (-not $ok) { return $null }
    if (-not $w[1].StartsWith('n') -or ((Get-EditDistance $w[1] 'notes') -gt 1 -and (Get-EditDistance $w[1] 'note') -gt 1)) { return $null }
    return ""
}

# Runs the first table entry of the given phase that matches. $true when handled.
function Invoke-CommandTable([string]$Text, [string]$Phase) {
    $raw = $Text.Trim()
    $t = $raw -replace '[.!]+$', ''
    foreach ($c in @($Commands | Where-Object { $_.When -eq $Phase })) {
        $s = if ($c.Raw) { $raw } else { $t }
        if ($s -notmatch $c.Rx) { continue }
        $m = $Matches.Clone()
        $r = @(& $c.Do $m)
        if ($r.Count -and $r[-1] -is [bool] -and -not $r[-1]) { continue }   # the entry declined (e.g. no such page)
        return $true
    }
    return $false
}

function Invoke-ChatCommand([string]$Text) {
    $t = $Text.Trim().ToLowerInvariant() -replace '[.!]+$', ''
    # Note-taking mode: everything is a note until "end notes" or "cancel notes"
    if ($state.NotesActive) {
        if ($Text.Trim() -match '^(?i)(?:end|stop|finish|done with) notes?(?:\s+(?:to|in|for|on))?\s*(.*)$') { Complete-Notes ($Matches[1].Trim()); return $true }
        if ($null -ne (Get-NotesPhrase $Text 'end')) { Complete-Notes ""; return $true }
        if ($t -match '^(cancel|discard) notes?$') { Stop-Notes; Send-Chat "Notes discarded."; return $true }
        Add-NoteLine $Text; return $true
    }
    if ($null -ne (Get-NotesPhrase $Text 'start')) { Start-Notes; return $true }
    if ($null -ne (Get-NotesPhrase $Text 'end')) { Send-Chat "No notes session is open, so there was nothing to end. Type start notes to begin one."; return $true }
    if (Invoke-CommandTable $Text 'Early') { return $true }
    if (Resolve-AskAnswer $Text) { return $true }
    if (Invoke-CommandTable $Text 'Late') { return $true }
    if (Resolve-ReminderReply $t) { return $true }
    return $false
}

# ------------------------------------------------------------------ the router: everything that is not a command
function Get-AssistantReply([string[]]$NewMessages, [string]$Recent) {
    if (-not (Test-CallBudget)) {
        return @{ route = "chat"; reply = "I've hit today's limit of $($Config.SecretaryMaxCallsPerDay) Claude calls, so I can only handle commands (type help) until tomorrow." }
    }
    $rules = [System.IO.File]::ReadAllText($RulesPath, $Utf8)
    $voice = [System.IO.File]::ReadAllText($VoicePath, $Utf8)
    $rem = (@($Reminders | Where-Object { -not $_.done } | ForEach-Object { Format-Reminder $_ }) -join "`n")
    if (-not $rem) { $rem = "(none)" }
    $now = Get-Date
    $prompt = @"
You are $U's admin assistant inside $U's Daily Briefing app. You talk only with $U, in $U's Teams notes-to-self chat.
You cannot send email, draft email, change the calendar, or message anyone else. You reply with text and manage $U's reminders and to-dos.

Now: $($now.ToString("dddd, MMMM d, yyyy h:mm tt", $Inv)) ($U's local time)
Dates (use this list; do not work out weekdays yourself; a weekday name alone means its next date here):
$(Get-DateTable)
Times: "close of business" or "COB" = 17:00; "morning" with no time = 09:00; "end of day" = 17:00.
Working hours: $(@($Config.SecretaryDays) -join ',') $($Config.SecretaryStart)-$($Config.SecretaryEnd)

RULES
$rules

VOICE
$voice

CURRENT REMINDERS
$rem

OPEN TO-DOS ($U's dashboard To-do tab; top-level lines are projects)
$(Get-OpenTodoText)

RECENT CONVERSATION (oldest first)
$Recent

NEW MESSAGE(S) FROM $U
$($NewMessages -join "`n")

Answer with one JSON object and nothing else:
{"route": "chat",
 "reply": "plain text for $U, no markdown",
 "add_reminders": [{"text": "...", "kind": "once|daily|weekdays|weekly", "at": "YYYY-MM-DDTHH:MM (once only)", "time": "HH:MM 24h (recurring only)", "days": ["Mon","Tue"] (weekly only), "nag_minutes": 0}],
 "remove_reminders": [reminder numbers],
 "add_todos": [{"text": "short task", "parent": "an existing top-level to-do copied exactly if it clearly belongs there, else empty", "due_said": "$U's own words for when it is due, e.g. Wednesday, by Friday, next week; else empty", "due": "YYYY-MM-DD from the date list, else empty"}],
 "set_due": [{"text": "exact text of an existing open to-do whose due date $U changes or sets", "due_said": "$U's words", "due": "YYYY-MM-DD from the date list, or empty to clear"}],
 "complete_todos": ["exact text of an open to-do $U says is done"],
 "delete_todos": ["exact text of a to-do $U asks to delete or remove from the list"]}
route: "mail" if $U asks about an email or thread (what someone said, wants, sent, or decided; a summary or play by play), or to turn an email into a to-do. Leave reply empty.
"calendar" if $U asks about free times, or to schedule, block, add, move, or cancel something on the calendar. Leave reply empty.
"today" if $U asks what is on today, what $U is doing today, or wants the brief; "tomorrow" for the next workday. Leave reply empty for these too.
"notes_start" if $U wants to start taking notes or start a note-taking session (any wording or typo). Leave reply empty; the app opens the session.
Otherwise "chat". "Remind me ..." is always a reminder ("chat"), not a calendar entry.
Never say you did something (started notes, saved, added, scheduled) unless it is in the arrays above; the app does the actions and confirms them.
To-dos: use add_todos only when $U explicitly asks for a to-do, a task, or something on the list. Never turn a remark, an update, or an observation into a to-do; reply to it instead. Write the task itself, never $U's instruction to you. Fill due_said and due only when $U gives a time for the task (today, tomorrow, by Friday, next week = Friday of next week, end of month = its last weekday); look the date up in the date list and leave the time out of the task text. A to-do with a due date is not a reminder: do not add reminders for to-dos unless $U asks to be reminded. When $U only adds or changes to-dos, leave reply empty (the app confirms). When $U changes when an existing to-do is due, use set_due. When $U says a to-do is done, finished, or to check it off, use complete_todos with the exact existing text. When $U asks to delete or remove a to-do, use delete_todos with the exact existing text.
Use nag_minutes > 0 only when $U asks to be reminded repeatedly until $U confirms (default 15 if no interval is given).
Resolve "it", "that", or "this" from the recent conversation and write a self-contained reminder text.
Never say you added or removed a reminder unless it is in add_reminders or remove_reminders; the app confirms what was saved, so keep the reply short. If something is unclear, ask instead of adding. Leave the arrays empty when nothing changes.
"@
    return (ConvertFrom-ModelJson (Invoke-SecClaude $prompt))
}

function Invoke-UserMessages([string[]]$Texts) {
    $recent = Get-RecentChat 12
    foreach ($x in $Texts) { Add-ChatLog "$U" $x }
    $rest = @()
    foreach ($x in $Texts) {
        try { if (-not (Invoke-ChatCommand $x)) { $rest += $x } }
        catch { Write-Log "Command failed: $($_.Exception.Message)" "WARN"; Send-Chat "Something went wrong: $($_.Exception.Message)" }
    }
    if (-not $rest) { return }
    if ($state.Paused) { Send-Chat "I'm paused. Type resume to turn me back on."; return }
    try { $ans = Get-AssistantReply $rest $recent }
    catch {
        Write-Log "Reply failed: $($_.Exception.Message)" "WARN"
        Send-Chat "I couldn't reach Claude just now. Try again in a few minutes."
        return
    }
    $route = [string]$ans.route
    $msgText = ($rest -join "`n")
    try {
        switch ($route) {
            'notes_start' { Start-Notes; foreach ($x in @($rest | Select-Object -Skip 1)) { Add-NoteLine $x }; return }
            'mail'     { Invoke-MailRequest $msgText $recent; return }
            'calendar' { Invoke-CalendarRequest $msgText $recent; return }
            'today'    { Send-DayBrief (Get-Date).Date 'week'; return }
            'tomorrow' { Send-DayBrief (Get-NextWorkday (Get-Date)) 'today'; return }
        }
    } catch { Write-Log "Route $route failed: $($_.Exception.Message)" "WARN"; Send-Chat "Something went wrong: $($_.Exception.Message)"; return }

    $todoReq = @($ans.add_todos | Where-Object { $_ }).Count -or @($ans.set_due | Where-Object { $_ }).Count -or @($ans.delete_todos | Where-Object { $_ }).Count
    if ($todoReq -and @($ans.add_reminders | Where-Object { $_ }).Count -and $msgText -notmatch '(?i)remind') {
        Write-Log "Dropped $(@($ans.add_reminders).Count) reminder(s) the model added alongside to-dos without being asked."
        $ans.add_reminders = @()
    }
    $added = Add-Reminders $ans.add_reminders
    $removed = @()
    foreach ($id in @($ans.remove_reminders | Where-Object { $_ })) { if (Remove-ReminderById ([int]$id)) { $removed += [int]$id } }
    $todoAdded = @(); $todoDone = @(); $todoDue = @(); $todoGone = @(); $todoSkip = @(); $todoErr = $null
    try {
        if ($ans.add_todos) {
            $ref = Get-AlertRef $msgText
            if ($ref) { foreach ($it in @($ans.add_todos | Where-Object { $_ })) { if (-not [string]$it.mailLink) { Add-Member -InputObject $it -NotePropertyName mailLink -NotePropertyValue ([string]$ref.link) -Force } } }
            $todoAdded = @(Add-TodoItems $ans.add_todos)
        }
        if ($ans.complete_todos) { $todoDone = @(Complete-TodoItems $ans.complete_todos) }
        if ($ans.set_due) { $todoDue = @(Set-TodoDueByText $ans.set_due) }
        if ($ans.delete_todos) { $todoGone = @(Remove-TodoItems $ans.delete_todos); $todoSkip = @($script:LastTodoSkips) }
    } catch { $todoErr = "I couldn't read your to-do list, so I left it untouched: $($_.Exception.Message)"; Write-Log $todoErr "WARN" }
    $reply = [string]$ans.reply
    if ($todoReq -and $msgText -notmatch '\?') { $reply = "" }   # to-do changes get the app's confirmation only
    $conf = @()
    if ($added) { $conf += "Saved:`n" + ((@($added) | ForEach-Object { Format-Reminder $_ }) -join "`n") }
    if ($removed) { $conf += "Removed reminder(s): " + (($removed | ForEach-Object { "#$_" }) -join ", ") }
    if ($todoAdded) {
        $conf += "Added to your to-do list:`n" + (($todoAdded | ForEach-Object { "- $_" }) -join "`n")
        $q = Request-TodoDue; if ($q) { $conf += $q }
    }
    if ($todoDue) { $conf += "Due date set:`n" + (($todoDue | ForEach-Object { "- $_" }) -join "`n") }
    if ($todoDone) { $conf += "Checked off:`n" + (($todoDone | ForEach-Object { "- $_" }) -join "`n") }
    if ($todoGone) { $conf += "Deleted from your to-do list:`n" + (($todoGone | ForEach-Object { "- $_" }) -join "`n") }
    if ($todoSkip) { $conf += "Not deleted (finish or delete the sub-items first):`n" + (($todoSkip | ForEach-Object { "- $_" }) -join "`n") }
    if ($ans.delete_todos -and -not $todoGone -and -not $todoSkip -and -not $todoErr) { $conf += "I couldn't find that to-do. Give me its exact words." }
    if ($todoErr) { $conf += $todoErr }
    if (-not $conf -and $reply -match '(?i)^\s*(deleted|removed|added|saved|done|marked|checked off|set)\b[^?]{0,40}$') {
        Write-Log "Dropped a reply that claimed an action nothing performed: $reply" "WARN"
        $reply = "I didn't change anything. Tell me which item, in its own words."
    }
    $out = @(@($reply) + $conf | Where-Object { $_ })
    Send-Chat $(if ($out) { $out -join "`n" } else { "OK." })
}
