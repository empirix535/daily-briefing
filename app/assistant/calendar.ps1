# ================================================================== assistant/calendar.ps1
# Calendar: read-only through the Microsoft 365 connector. Today's meetings are cached by the mail scan
# (data\secretary\meetings.json); the 30-minute prep prompts, the notes meeting tag, and the briefs read from that cache.
# Pre-filled Outlook on the web links and .ics files arrive in the next update. Nothing here writes to the calendar.

function Get-UtcOffsetText([datetime]$Now) {
    $off = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $sign = if ($off.TotalMinutes -lt 0) { "-" } else { "+" }
    return $sign + ([timespan]::FromMinutes([math]::Abs($off.TotalMinutes))).ToString('hh\:mm')
}

# The meeting part of every connector prompt: what to return and in which time zone
function Get-MeetingsPromptPart([datetime]$Day) {
    $day = $Day.Date
    return @"
MEETINGS: use outlook_calendar_search for $($day.ToString('dddd, MMMM d, yyyy', $Inv)) (midnight to midnight, $U's local time, UTC$(Get-UtcOffsetText $day)). Write every time as local time, YYYY-MM-DDTHH:MM with no zone.
Return every event on that day in "meetings" as {"subject": "", "start": "", "end": "", "allDay": false, "people": ["attendee display names, first and last, never email addresses unless no name exists; exclude $U"], "declined": false, "location": "", "link": "the event's web link if the tool gives one, else empty"}. "declined" is true only when $U's own response is declined. An event with no other attendees has an empty people list.
"@
}

# ------------------------------------------------------------------ the meeting cache
function ConvertTo-MeetingList($Raw) {
    $out = @()
    foreach ($m in @($Raw | Where-Object { $_ })) {
        try {
            $s = [datetime]::Parse([string]$m.start, $Inv); $e = [datetime]::Parse([string]$m.end, $Inv)
            $out += @{
                subject = [string]$m.subject; start = $s.ToString('yyyy-MM-ddTHH:mm'); end = $e.ToString('yyyy-MM-ddTHH:mm')
                allDay = [bool]$m.allDay; people = @(@($m.people) | Where-Object { $_ } | ForEach-Object { [string]$_ })
                declined = [bool]$m.declined; location = [string]$m.location; link = [string]$m.link
            }
        } catch { Write-Log "Skipped a meeting with a bad time: $(ConvertTo-Json -InputObject $m -Compress)" "WARN" }
    }
    return @($out | Sort-Object { $_.start })
}
function Save-Meetings($List, [datetime]$Day) {
    Write-JsonFile $MeetingsPath @($List)
    $state.MeetingsDate = $Day.ToString('yyyy-MM-dd'); $state.MeetingsAt = (Get-Date).ToString('s'); Save-State
}
function Get-CachedMeetings {
    return @(Read-JsonFile $MeetingsPath | Where-Object { $_ })
}

# Meetings for a day: today's cache when it is under 20 minutes old, else one connector call. Throws when the call fails.
function Get-DayMeetings([datetime]$Day) {
    $Day = $Day.Date
    if ($Day -eq (Get-Date).Date -and $state.MeetingsDate -eq $Day.ToString('yyyy-MM-dd') -and $state.MeetingsAt -and
        ((Get-Date) - [datetime]$state.MeetingsAt).TotalMinutes -lt 20) { return (Get-CachedMeetings) }
    if (-not (Test-CallBudget)) { throw "today's Claude call limit is reached" }
    $prompt = @"
Read $U's calendar. Call get_granted_scopes first. If it fails, return {"ok": false, "error": "the error text, including any AADSTS code", "meetings": []} and stop.
$(Get-MeetingsPromptPart $Day)
Answer with one JSON object and nothing else: {"ok": true, "error": "", "meetings": [...]}
"@
    $res = ConvertFrom-ModelJson (Invoke-SecConnector $prompt)
    if (-not [bool]$res.ok) { throw "the connector check failed: $([string]$res.error)" }
    $list = ConvertTo-MeetingList $res.meetings
    if ($Day -eq (Get-Date).Date) { Save-Meetings $list $Day }
    return $list
}

function Format-Meetings([datetime]$Day, $List) {
    $label = if ($Day.Date -eq (Get-Date).Date) { "today" } else { $Day.ToString("dddd", $Inv) }
    $rows = @($List | Where-Object { $_ -and -not $_.declined })
    if (-not $rows.Count) { return "No meetings $label." }
    $out = @("Meetings ${label}:")
    foreach ($m in @($rows | Where-Object { $_.allDay })) { $out += "- All day: $($m.subject)" }
    foreach ($m in @($rows | Where-Object { -not $_.allDay } | Sort-Object { [string]$_.start })) {
        $s = [datetime]$m.start; $e = [datetime]$m.end
        $with = if (@($m.people).Count) { " (with " + ((@($m.people) | Select-Object -First 4) -join ", ") + $(if (@($m.people).Count -gt 4) { ", +$(@($m.people).Count - 4)" } else { "" }) + ")" } else { "" }
        $out += "- $($s.ToString('h:mm', $Inv))-$($e.ToString('h:mm tt', $Inv)) $($m.subject)$with"
    }
    return ($out -join "`n")
}

# Morning or day brief: meetings, then to-dos. A failed calendar read never blocks the to-dos.
function Send-DayBrief([datetime]$Day, [string]$Mode = "week") {
    $parts = @()
    try { $parts += Format-Meetings $Day (Get-DayMeetings $Day) }
    catch { Write-Log "Calendar read failed: $($_.Exception.Message)" "WARN"; $parts += "I couldn't read your calendar: $($_.Exception.Message)" }
    try { $parts += Get-TodoAgenda $Day $Mode } catch { Write-Log "To-do agenda failed: $($_.Exception.Message)" "WARN" }
    Send-Chat ($parts -join "`n`n")
}
function Get-NextWorkday([datetime]$From) {
    $d = $From.Date.AddDays(1)
    while (-not (@($Config.SecretaryDays) -contains $d.DayOfWeek.ToString().Substring(0, 3))) { $d = $d.AddDays(1) }
    return $d
}

# ------------------------------------------------------------------ 30-minute prep prompts
# Fires once per meeting in the cache when it is 20 to 30 minutes away (a prompt missed during sleep is not replayed).
# Skips all-day events, declined meetings, and meetings with no other attendees.
Register-AskKind 'prep' {
    param($d, $t)
    if ($t -match '^(?i)(yes|yeah|yep|y|sure|ok|okay|please|prep|yes please)$') { Clear-Ask; Send-PrepBrief $d; return $true }
    if ($t -match '^(?i)(no|nope|nah|n|skip|no thanks|not needed)$') { Clear-Ask; Send-Chat "OK, no prep."; return $true }
    return $false
} { param($d, $why) }

function Invoke-MeetingPrompts([datetime]$Now) {
    foreach ($m in @(Get-CachedMeetings)) {
        if (-not $m -or $m.allDay -or $m.declined -or -not @($m.people).Count) { continue }
        try { $s = [datetime]$m.start } catch { continue }
        $mins = ($s - $Now).TotalMinutes
        if ($mins -gt 30 -or $mins -lt 20) { continue }
        $key = "$($m.subject)|$($m.start)"
        if (@($state.PrepFired) -contains $key) { continue }
        $state.PrepFired = @(@($state.PrepFired) | Where-Object { $_ } | Select-Object -Last 30) + $key
        $state.PrepLast = @{ subject = [string]$m.subject; start = [string]$m.start; end = [string]$m.end; people = @($m.people); link = [string]$m.link }
        Save-State
        if (-not $script:Ask) {
            Set-Ask 'prep' $state.PrepLast 40
            Send-Chat "Need prep for ""$($m.subject)"" at $($s.ToString('h:mm tt', $Inv))? Reply yes for a brief, or no."
        } else {
            Send-Chat "Meeting at $($s.ToString('h:mm tt', $Inv)): ""$($m.subject)"". Type prep for a brief."
        }
    }
}

function Send-PrepBrief($M) {
    if (-not $M) { Send-Chat "I have no meeting waiting for prep."; return }
    if (-not (Test-CallBudget)) { Send-Chat "I've hit today's Claude call limit, so no brief right now."; return }
    $who = (@($M.people) | Select-Object -First 12) -join "; "
    $prompt = @"
Prepare a read-only brief for $U before this meeting. Use only read tools.
Meeting: $($M.subject), starting $($M.start) (local time). Attendees: $who.
1. Find the invite with outlook_calendar_search (use read_resource if you need its body) and note the agenda, any documents linked in it, and where it is held.
2. Search $U's email for the latest messages with those attendees, or about "$($M.subject)", from the last 14 days. Open the two or three that matter with read_resource.
Write plain text for a chat message, no markdown, under 1200 characters: what the meeting is about, what is expected of $U, and the latest relevant emails (who, when, the point). Put a document link on its own line if there is one. If you find nothing, say so in one sentence. Never offer to send, draft, or change anything.
"@
    try { Send-Chat ("Prep for ""$($M.subject)"":`n" + (Invoke-SecConnector $prompt -Plain).Trim()) }
    catch { Write-Log "Prep brief failed: $($_.Exception.Message)" "WARN"; Send-Chat "I couldn't build the brief: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ calendar questions (read-only) and pre-filled events
function Invoke-CalendarRequest([string]$Text, [string]$History) {
    if (-not (Test-CallBudget)) { Send-Chat "I've hit today's Claude call limit, so I can't check your calendar right now."; return }
    $now = Get-Date
    $prompt = @"
$U asked about the calendar. Use read tools only (outlook_calendar_search, find_meeting_availability, and outlook_email_search to find a person's email address).
Now: $($now.ToString("dddd, MMMM d, yyyy h:mm tt", $Inv)) ($U's local time, UTC$(Get-UtcOffsetText $now)).
Dates (use this list; do not work out weekdays yourself):
$(Get-DateTable)

RECENT CONVERSATION
$History

$U's MESSAGE
$Text

You cannot create, move, accept, decline, or cancel anything. For free times, name real slots with day and time. When $U asks to add, schedule, block, or move something, check for conflicts and fill "events"; the app turns each event into a pre-filled link that $U edits and saves or sends. For a move, add the new time as an event and say that $U must delete the old one. Attendees: list an email address only when you found it in $U's mail or calendar; never guess one, and say in "reply" who is missing. Times are local, YYYY-MM-DDTHH:MM. Default length 30 minutes. Recurring events cannot be pre-filled yet: make the first occurrence and say $U sets the repeat.
"reply": plain text under 700 characters, no markdown, no em dashes. Answer with one JSON object and nothing else:
{"reply": "", "events": [{"subject": "", "start": "", "end": "", "attendees": ["email"], "location": "", "body": ""}]}
"@
    try {
        $raw = Invoke-SecConnector $prompt
        $res = $null; try { $res = ConvertFrom-ModelJson $raw } catch { }
        if (-not $res -or $null -eq $res.reply) { Send-Chat ([string]$raw).Trim(); return }
        $evs = @($res.events | Where-Object { $_ -and $_.subject -and $_.start })
        if ([string]$res.reply) { Send-Chat ([string]$res.reply).Trim() }
        foreach ($e in ($evs | Select-Object -First 3)) {
            $s = [datetime]::Parse([string]$e.start, $Inv)
            $en = if ($e.end) { [datetime]::Parse([string]$e.end, $Inv) } else { $s.AddMinutes(30) }
            $url = New-EventLink ([string]$e.subject) $s $en @(@($e.attendees) | Where-Object { $_ -match '^[^@\s]+@[^@\s]+$' }) ([string]$e.location) ([string]$e.body)
            Send-Chat "$($e.subject), $(Format-Time $s) to $($en.ToString('h:mm tt', $Inv))" $url "Open pre-filled event"
        }
        if (-not [string]$res.reply -and -not $evs.Count) { Send-Chat "I couldn't tell what to put on your calendar. Tell me the day, time, and who is invited." }
    } catch { Write-Log "Calendar request failed: $($_.Exception.Message)" "WARN"; Send-Chat "I couldn't read your calendar: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ pre-filled Outlook on the web event link (no write by the bot)
# Wael opens the link, edits, and presses Save or Send himself. Attendees go in as a semicolon-separated list.
function New-EventLink([string]$Subject, [datetime]$Start, [datetime]$End, [string[]]$To = @(), [string]$Location = "", [string]$Body = "") {
    $off = Get-UtcOffsetText $Start
    $esc = { param($x) [uri]::EscapeDataString([string]$x) }
    $url = "https://outlook.office.com/calendar/0/deeplink/compose?path=%2Fcalendar%2Faction%2Fcompose&rru=addevent" +
        "&subject=" + (& $esc $Subject) +
        "&startdt=" + (& $esc ($Start.ToString('yyyy-MM-ddTHH:mm:ss', $Inv) + $off)) +
        "&enddt=" + (& $esc ($End.ToString('yyyy-MM-ddTHH:mm:ss', $Inv) + $off))
    if (@($To).Count) { $url += "&to=" + (& $esc (@($To) -join ";")) }
    if ($Location) { $url += "&location=" + (& $esc $Location) }
    if ($Body) { $url += "&body=" + (& $esc $Body) }
    return $url
}
