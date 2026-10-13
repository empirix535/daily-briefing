# ================================================================== assistant/mail.ps1
# Email: read-only through the Microsoft 365 connector. One connector call per scan checks the connector, reads new mail,
# and reads today's meetings. The bot posts alerts to the Teams self-chat and answers questions about threads.
# It drafts nothing, opens nothing, and sends nothing. Nothing here touches Outlook.exe.
#
# State keys: SeenMail (thread signatures already handled), FyiItems (queued FYI lines), LastAlert (numbered list of the
# latest alert), LastScan (last successful scan), ScanSlot (wall-clock slot already tried), GreetDay (day of the last
# greeting), ScanFailAt (start of a failure streak), FyiSlot, ScopeWarnDay, RespTrack (needs-response threads waiting on
# your reply, checked at the noon and 4 PM roundups).

$FyiTimes = @('12:00', '16:00')

function Get-SeenMail {
    if ($state.SeenMail -is [hashtable]) { return $state.SeenMail }
    $h = @{}
    if ($state.SeenMail) { foreach ($p in $state.SeenMail.PSObject.Properties) { $h[$p.Name] = [long]$p.Value } }
    $state.SeenMail = $h
    return $h
}

# One line per thread: who wants what, by when, and the document link if there is one
function Format-MailLine($T) {
    $due = ""
    if ([string]$T.deadline -match '^\d{4}-\d{2}-\d{2}') { try { $due = " (by " + ([datetime][string]$T.deadline).ToString('ddd MMM d', $Inv) + ")" } catch { } }
    $doc = if ([string]$T.doc) { " Doc: $($T.doc)" } else { "" }
    return ([string]$T.line).Trim() + $due + $doc
}

function Get-Greeting { if ((Get-Date).Hour -lt 12) { return "Good morning" } else { return "Good afternoon" } }

function Get-ScanPrompt([datetime]$Now, [datetime]$Since, $SeenSigs) {
    $seenText = if (@($SeenSigs).Count) { (@($SeenSigs) -join "`n") } else { "(none)" }
    return @"
You are checking $U's Outlook for $U, $($Config.UserDescription). Use read tools only. Now: $($Now.ToString("dddd, MMMM d, yyyy h:mm tt", $Inv)) ($U's local time, UTC$(Get-UtcOffsetText $Now)).

STEP 1. Call get_granted_scopes. If it fails, return {"health": {"ok": false, "error": "the error text, including any AADSTS code", "scopes": []}, "threads": [], "meetings": []} and stop. If it works, list the granted scopes in health.scopes.

STEP 2. MAIL. Use outlook_email_search for messages received in the inbox since $($Since.ToString('yyyy-MM-ddTHH:mm', $Inv)) (local time). Ignore messages $U sent, and junk and deleted items. Group them by conversation. Already handled (key|latest); skip these without opening them:
$seenText
For each remaining conversation that is not clearly Noise from its preview, open it with read_resource so you know the whole thread before you write about it.
Each thread object: {"key": "the conversation or thread id from the search", "latest": "received time of the newest message, YYYY-MM-DDTHH:MM local", "from": "sender first name", "subject": "", "category": "Requires Response|FYI|Noise", "resolved": false, "line": "", "deadline": "YYYY-MM-DD or empty", "doc": "link to the document or attachment page the message refers to, else empty", "link": "web link to the message or thread, else empty", "direct": true}
Category:
- "Requires Response": $U needs to reply, decide, review, approve, submit, or act.
- "FYI": relevant work or personal information with no action needed.
- "Noise": spam, marketing, external newsletters, and mass mailings; routine messages from retirement accounts, banks, or health insurance unless they need action; conference and professional-society emails unless they concern $U's own applications, submissions, reviews, registrations, invoices, or payments; automated notifications that need nothing from $U. A person writing to $U directly about work is never Noise. Journal emails about $U's own manuscripts are never Noise (revision requests, reviewer invitations, and proofs are Requires Response).
"direct" is true when $U is on the To line of the newest message and false when $U is only on Cc, Bcc, or a distribution list.
"resolved" is true when $U already replied after the newest message, or the request was clearly settled.
"line" is written to $U in the second person: say "you" and "your", never $U's name. "line" for Requires Response: one sentence saying who wants what from you, in plain words, for example "Sophie wants your thoughts on section 3 of the budget doc." Name people, documents, numbers, and dates. Never write vague topic labels. "line" for FYI: one sentence of at most 30 words on what the message tells you, in the second person, for example "Lee says the site visit moved to Monday." Never refer to $U by name. Leave "line" empty for Noise.

STEP 3. $(Get-MeetingsPromptPart $Now)

Answer with one JSON object and nothing else: {"health": {"ok": true, "error": "", "scopes": [...]}, "threads": [...], "meetings": [...]}
"@
}

# One scan. Mode: normal (silent unless something needs $U), greeting (first scan of the workday), catchup (after a gap),
# manual (the user asked; always answers). Returns $true when the scan worked.
function Invoke-MailScan([datetime]$Now, [string]$Mode) {
    if (-not (Test-CallBudget)) {
        Write-Log "Skipped a scan: daily Claude call limit reached." "WARN"
        if ($Mode -eq 'manual') { Send-Chat "I've hit today's Claude call limit, so I can't check email until tomorrow." }
        return $false
    }
    $since = if ($state.LastScan) { [datetime]$state.LastScan } else { $Now.AddHours(-16) }
    if ($since -lt $Now.AddDays(-3)) { $since = $Now.AddDays(-3) }
    $gapFrom = $since
    $seen = Get-SeenMail
    $sigs = @($seen.Keys | Sort-Object { $seen[$_] } | Select-Object -Last 80)
    $today = $Now.ToString('yyyy-MM-dd')

    $res = $null; $why = ""
    try {
        $res = ConvertFrom-ModelJson (Invoke-SecConnector (Get-ScanPrompt $Now $since.AddMinutes(-5) $sigs))
        if (-not $res.health -or -not [bool]$res.health.ok) { $why = [string]$res.health.error; if (-not $why) { $why = "the connector did not confirm its scopes" } }
    } catch { $why = $_.Exception.Message }

    if ($why) {
        if ($why.Length -gt 400) { $why = $why.Substring(0, 400) }
        Write-Log "Scan failed: $why" "WARN"
        $first = -not $state.ScanFailAt
        if ($first) { $state.ScanFailAt = $Now.ToString('s') }
        $greetFail = ($Mode -eq 'greeting' -and $state.GreetFailDay -ne $today)
        if ($greetFail) { $state.GreetFailDay = $today }
        Save-State
        if ($first -or $greetFail -or $Mode -eq 'manual') {
            Send-Chat ($(if ($Mode -eq 'greeting') { "$(Get-Greeting). " } else { "" }) + "The email connector check failed: $why`nI'll retry every 15 minutes and stay quiet until it works. Reminders and to-dos still run.")
        }
        return $false
    }

    $wasFailing = [bool]$state.ScanFailAt
    $state.ScanFailAt = $null; $state.LastScan = $Now.ToString('s')

    # Guardrail: the bot only uses read tools, but say so if the granted scopes ever include a write scope
    $writeScopes = @(@($res.health.scopes) | Where-Object { [string]$_ -match '(?i)(ReadWrite|\.Send|\.Write|Create|Delete)' })
    if ($writeScopes.Count -and $state.ScopeWarnDay -ne $today) {
        $state.ScopeWarnDay = $today
        Send-Chat ("Heads up: the Microsoft 365 connector now grants write scopes (" + ($writeScopes -join ", ") + "). I only use read tools and cannot send or change anything, but check that this is expected.")
    }

    try { Save-Meetings (ConvertTo-MeetingList $res.meetings) $Now.Date } catch { Write-Log "Could not save meetings: $($_.Exception.Message)" "WARN" }

    $need = @(); $fyi = @()
    foreach ($t in @($res.threads | Where-Object { $_ -and $_.key })) {
        $sig = "$($t.key)|$($t.latest)"
        if ($seen.ContainsKey($sig)) { continue }
        $seen[$sig] = $Now.Ticks
        if ([string]$t.category -eq 'Requires Response' -and -not [bool]$t.resolved) { $need += $t; Add-ReplyTrack $t $Now }
        elseif ([string]$t.category -eq 'Requires Response' -and [bool]$t.resolved) { Remove-ReplyTrack ([string]$t.key) }
        elseif ([string]$t.category -eq 'FYI') { $fyi += $t }
    }
    if ($seen.Count -gt 500) { foreach ($k in @($seen.Keys | Sort-Object { $seen[$_] } | Select-Object -First ($seen.Count - 400))) { $seen.Remove($k) } }
    if ($fyi.Count) {
        $q = @($state.FyiItems | Where-Object { $_ })
        foreach ($t in $fyi) { $q = @($q | Where-Object { [string]$_.key -ne [string]$t.key }) + [pscustomobject]@{ key = [string]$t.key; line = (Format-MailLine $t); from = [string]$t.from; subject = [string]$t.subject; link = [string]$t.link } }
        $state.FyiItems = $q
    }
    Save-State
    Write-Log "Scan ($Mode): $(@($res.threads).Count) thread(s) seen, $($need.Count) need you, $($fyi.Count) FYI."

    $at = $Now.ToString('h:mm tt', $Inv)
    if ($wasFailing -and $Mode -ne 'greeting' -and $Mode -ne 'manual') { Send-Chat "The email connector is working again." }
    switch ($Mode) {
        'greeting' {
            Send-Chat "$(Get-Greeting). The connector check passed at $at, so email and calendar are being watched."
            Send-DayBrief $Now.Date 'week'
            if ($need.Count) { Send-MailAlert $need "Since $(Format-Time $gapFrom), $($need.Count) $(if ($need.Count -eq 1) { 'email needs' } else { 'emails need' }) your attention:" }
            else { Send-Chat "No email needs your attention since $(Format-Time $gapFrom)." }
            $state.GreetDay = $today; Save-State
        }
        'catchup' {
            $span = "$($gapFrom.ToString('h:mm', $Inv)) to $at"
            $head = if ($wasFailing) { "Since my last good check ($span)" } else { "While you were away ($span)" }
            if ($need.Count) { Send-MailAlert $need "$head, $($need.Count) $(if ($need.Count -eq 1) { 'email needs' } else { 'emails need' }) your attention:" }
            else { Send-Chat "$head, nothing needed your attention." }
        }
        'manual' {
            if ($need.Count) { Send-MailAlert $need "$($need.Count) $(if ($need.Count -eq 1) { 'email needs' } else { 'emails need' }) your attention:" }
            else { Send-Chat "Checked at $at. Nothing new needs your attention." }
        }
        default {
            if ($need.Count) { Send-MailAlert $need "$($need.Count) new $(if ($need.Count -eq 1) { 'email needs' } else { 'emails need' }) your attention:" }
        }
    }
    return $true
}

# The numbered alert. The numbers become what "what does 2 want" refers to, until the next alert replaces them.
function Send-MailAlert($Need, [string]$Head) {
    $n = 0; $store = @(); $lines = @()
    foreach ($t in @($Need | Select-Object -First 12)) {
        $n++
        $lines += "$n. " + (Format-MailLine $t)
        $store += [pscustomobject]@{ n = $n; key = [string]$t.key; from = [string]$t.from; subject = [string]$t.subject; link = [string]$t.link }
    }
    $state.LastAlert = $store; Save-State
    Send-Chat ($Head + "`n" + ($lines -join "`n") + "`n" + $(if ($n -gt 1) { "Ask what 1 wants, or for a play by play on 2." } else { "Ask what 1 wants, or for a play by play." }))
}

# Wall-clock scan for the slots :00, :15, :30, :45 during working hours. The scan starts one minute early (:14, :29, :44, :59)
# so the result lands on the slot. Each slot is tried once; a failed slot retries at the next.
function Invoke-MailWatch([datetime]$Now) {
    $t = $Now.AddMinutes(1)   # the slot this scan is for
    if (-not (Test-ActiveHours $t)) { return }
    $slot = $t.ToString('yyyy-MM-dd HH:', $Inv) + (15 * [int][math]::Floor($t.Minute / 15)).ToString('00')
    if ($state.ScanSlot -eq $slot) { return }
    $state.ScanSlot = $slot; Save-State
    $mode = 'normal'
    if ($state.GreetDay -ne $Now.ToString('yyyy-MM-dd')) { $mode = 'greeting' }
    elseif ($state.LastScan -and ($Now - [datetime]$state.LastScan).TotalMinutes -gt 20) { $mode = 'catchup' }
    [void](Invoke-MailScan $Now $mode)
}

# ------------------------------------------------------------------ FYI batches at noon and 4 PM
function Send-FyiBatch([switch]$Asked) {
    $q = @($state.FyiItems | Where-Object { $_ })
    $state.FyiItems = @(); Save-State
    if (-not $q.Count) { if ($Asked) { Send-Chat "No FYI email waiting." }; return }
    # Numbered like an alert, so "what does 2 say" and "make a todo from 3" work on the roundup
    $n = 0; $store = @(); $lines = @()
    foreach ($i in $q) {
        $n++
        $lines += "$n. " + [string]$i.line
        $store += [pscustomobject]@{ n = $n; key = [string]$i.key; from = [string]$i.from; subject = [string]$i.subject; link = [string]$i.link }
    }
    $state.LastAlert = $store; $script:RoundupBase = $n; Save-State
    Send-Chat ("FYI email since the last roundup:`n`n" + ($lines -join "`n`n") + "`n`nAsk about any number, or say ""make a todo from $(if ($n -gt 1) { '2' } else { '1' })"".")
}
function Invoke-FyiBatch([datetime]$Now) {
    if (-not (@($Config.SecretaryDays) -contains $Now.DayOfWeek.ToString().Substring(0, 3))) { return }
    $slot = $null
    foreach ($t in $FyiTimes) {
        $at = [datetime]::ParseExact($t, 'HH:mm', $Inv).TimeOfDay
        if ($Now.TimeOfDay -ge $at -and $Now.TimeOfDay -lt $at.Add([timespan]::FromHours(2))) { $slot = $Now.ToString('yyyy-MM-dd', $Inv) + " " + $t }
    }
    if (-not $slot -or $state.FyiSlot -eq $slot) { return }
    $state.FyiSlot = $slot; Save-State
    $script:RoundupBase = 0
    Send-FyiBatch
    try { Send-ReplyCheck $Now } catch { Write-Log "Reply check failed: $($_.Exception.Message)" "WARN" }
    $script:RoundupBase = 0
}

# ------------------------------------------------------------------ unanswered email (asked at the noon and 4 PM roundups)
# Every thread the scan flags "Requires Response" (addressed to you) is tracked. At the roundup, one connector call checks
# which ones you have since answered. The rest are listed once, and you say what you plan to do. Nothing posts when nothing is open.
$script:RoundupBase = 0
$ReplyMinHours = 3     # a flag must be at least this old before the roundup asks about it
$ReplyMaxItems = 5     # most items per roundup
$ReplyReaskDays = 3    # one second ask after this many days, then never again

function Get-ReplyTrack { return @($state.RespTrack | Where-Object { $_ }) }
function Add-ReplyTrack($T, [datetime]$Now) {
    if ($T.direct -is [bool] -and -not $T.direct) { return }
    $keep = @(Get-ReplyTrack | Where-Object { [string]$_.key -ne [string]$T.key -and ([datetime][string]$_.flagged) -gt $Now.AddDays(-14) })
    $rec = [pscustomobject]@{ key = [string]$T.key; from = [string]$T.from; subject = [string]$T.subject; line = (Format-MailLine $T)
        link = [string]$T.link; flagged = $Now.ToString('s'); asks = 0; lastAsk = ""; skip = $false }
    $state.RespTrack = @($keep + $rec | Select-Object -Last 40)
}
function Remove-ReplyTrack([string]$Key) { $state.RespTrack = @(Get-ReplyTrack | Where-Object { [string]$_.key -ne $Key }) }

function Get-ReplyCandidates([datetime]$Now, [bool]$All) {
    $links = @()
    try { $links = @((Get-Todos) | Where-Object { [string]$_.mailLink } | ForEach-Object { [string]$_.mailLink }) } catch { }
    $out = @()
    foreach ($r in (Get-ReplyTrack)) {
        if ([bool]$r.skip) { continue }
        if ([string]$r.link -and $links -contains [string]$r.link) { continue }   # already a to-do
        if (-not $All) {
            if (([datetime][string]$r.flagged) -gt $Now.AddHours(-$ReplyMinHours)) { continue }
            if ([int]$r.asks -ge 2) { continue }
            if ([int]$r.asks -eq 1 -and ([datetime][string]$r.lastAsk) -gt $Now.AddDays(-$ReplyReaskDays)) { continue }
        }
        $out += $r
    }
    return @($out | Sort-Object { [datetime][string]$_.flagged } | Select-Object -First $ReplyMaxItems)
}

# Returns the keys $U has already answered, or $null when the check failed
function Get-RepliedKeys($Cands, [datetime]$Now) {
    $list = ($Cands | ForEach-Object { "- key=$($_.key) | from $($_.from) | $($_.subject) | flagged $(([datetime][string]$_.flagged).ToString('yyyy-MM-ddTHH:mm', $Inv)) | link $($_.link)" }) -join "`n"
    $prompt = @"
You are checking $U's Outlook for $U. Use read tools only (outlook_email_search, read_resource). Now: $($Now.ToString("dddd, MMMM d, yyyy h:mm tt", $Inv)).
For each thread below, decide whether $U has already dealt with it: $U sent a reply in that thread after the flagged time, or the request was clearly settled afterwards. Open the thread with read_resource (or search Sent Items by subject and recipient) to see. When you cannot tell, answer false.
$list
Answer with one JSON object and nothing else: {"results": [{"key": "the key as given", "replied": true}]}
"@
    $res = ConvertFrom-ModelJson (Invoke-SecConnector $prompt)
    return @(@($res.results) | Where-Object { $_ -and [bool]$_.replied } | ForEach-Object { [string]$_.key })
}

function Send-ReplyCheck([datetime]$Now = (Get-Date), [switch]$Asked) {
    if (-not $Asked -and -not (@($Config.SecretaryDays) -contains $Now.DayOfWeek.ToString().Substring(0, 3))) { return }
    $c = @(Get-ReplyCandidates $Now ([bool]$Asked))
    if (-not $c.Count) { if ($Asked) { Send-Chat "Nothing is waiting on a reply from you." }; return }
    if (-not (Test-CallBudget)) { if ($Asked) { Send-Chat "I've hit today's Claude call limit, so I can't check your replies until tomorrow." }; return }
    $done = $null
    try { $done = @(Get-RepliedKeys $c $Now) }
    catch { Write-Log "Reply check could not run: $($_.Exception.Message)" "WARN"; if ($Asked) { Send-Chat "I couldn't check your sent mail: $($_.Exception.Message)" }; return }
    foreach ($k in $done) { Remove-ReplyTrack $k }
    $open = @($c | Where-Object { $done -notcontains [string]$_.key })
    if (-not $open.Count) { if ($Asked) { Send-Chat "You have answered everything I was watching." }; return }
    $base = [int]$script:RoundupBase   # the FYI list posted just before this one, if any; numbering continues after it
    $n = $base; $store = @($state.LastAlert | Where-Object { $_ -and $base -gt 0 -and [int]$_.n -le $base }); $lines = @()
    foreach ($r in $open) {
        $n++
        $lines += "$n. $($r.line) (flagged $(([datetime][string]$r.flagged).ToString('ddd h:mm tt', $Inv)))"
        $store += [pscustomobject]@{ n = $n; key = [string]$r.key; from = [string]$r.from; subject = [string]$r.subject; link = [string]$r.link }
        $rec = Get-ReplyTrack | Where-Object { [string]$_.key -eq [string]$r.key } | Select-Object -First 1
        if ($rec) { $rec.asks = [int]$rec.asks + 1; $rec.lastAsk = $Now.ToString('s') }
    }
    $state.LastAlert = $store; Save-State
    Send-Chat ("You haven't replied to $(if ($n -eq 1) { 'this email' } else { 'these emails' }) yet:`n" + ($lines -join "`n") +
        "`nAre you planning to reply? Say ""reply to $($base + 1) by Friday"" to be reminded, or ""skip $($base + 1)"" (or ""skip all"") and I will stop asking.")
}

# "skip 2", "skip 1 and 3", "skip all": stop asking about numbered items from the latest list
function Set-ReplySkip([string]$Which) {
    $alert = @($state.LastAlert | Where-Object { $_ })
    if (-not $alert.Count) { Send-Chat "There is no numbered list to skip from."; return }
    $nums = if ($Which -match '^(?i)all$') { @($alert | ForEach-Object { [int]$_.n }) } else { @([regex]::Matches($Which, '\d+') | ForEach-Object { [int]$_.Value }) }
    $hit = @()
    foreach ($a in @($alert | Where-Object { $nums -contains [int]$_.n })) {
        $rec = Get-ReplyTrack | Where-Object { [string]$_.key -eq [string]$a.key } | Select-Object -First 1
        if ($rec) { $rec.skip = $true; $hit += [int]$a.n }
    }
    Save-State
    Send-Chat $(if ($hit.Count) { "Okay, I won't ask about " + ($hit -join ", ") + " again. A new message in that thread brings it back." } else { "I couldn't match that to the latest list." })
}

# ------------------------------------------------------------------ questions about email
# "What does 1 want exactly", "play by play on 3", "what did Sophie say about the budget", "make a to-do from 2".
function Invoke-MailRequest([string]$Text, [string]$History) {
    if (-not (Test-CallBudget)) { Send-Chat "I've hit today's Claude call limit, so I can't read email right now."; return }
    $alert = @($state.LastAlert | Where-Object { $_ })
    $alertText = if ($alert.Count) { ($alert | ForEach-Object { "$($_.n). key=$($_.key) | from $($_.from) | $($_.subject) | link $($_.link)" }) -join "`n" } else { "(no alert yet)" }
    $now = Get-Date
    $prompt = @"
$U asks about email. Use read tools only (outlook_email_search, read_resource). Read the whole thread before you answer.
Now: $($now.ToString("dddd, MMMM d, yyyy h:mm tt", $Inv)) ($U's local time).
Numbers $U uses refer to the latest alert:
$alertText

RECENT CONVERSATION
$History

$U's MESSAGE
$Text

Find the thread: by its number in the list above (open it with read_resource), else by searching for the sender, subject, or topic $U names. If you cannot tell which thread $U means, ask one short question.
Answer what $U asked: a summary, a message-by-message play by play (oldest first, who said what and when), or the specific answer. Say who wants what from $U, by when, and give any document link on its own line. Plain text for a chat message, no markdown, no em dashes, under 1500 characters unless a play by play needs more. You cannot draft, send, reply to, or open email, and you never offer to.
Add to-dos only when $U explicitly asks for a to-do or task from an email: {"text": "the task, not $U's instruction", "due_said": "$U's words for when, else empty", "due": "YYYY-MM-DD, else empty", "link": "the thread's web link, copied exactly from the numbered list above or from the thread; never empty when known"}.
Answer with one JSON object and nothing else: {"reply": "plain text for $U", "todos": []}
"@
    $res = $null
    try { $res = ConvertFrom-ModelJson (Invoke-SecConnector $prompt) }
    catch { Write-Log "Mail request failed: $($_.Exception.Message)" "WARN"; Send-Chat "I couldn't read your email: $($_.Exception.Message)"; return }
    $out = @([string]$res.reply)
    $items = @($res.todos | Where-Object { $_ -and $_.text } | ForEach-Object {
        @{ text = [string]$_.text; due_said = [string]$_.due_said; due = [string]$_.due; mailLink = [string]$_.link } })
    # The model sometimes leaves the link empty: fall back to the alert item the user numbered (or the only item)
    $num = if ($Text -match '(?<![\d:])(\d{1,2})(?![\d:])') { [int]$Matches[1] } else { 0 }
    $hit = @($alert | Where-Object { [int]$_.n -eq $num -and $_.link }) | Select-Object -First 1
    if (-not $hit -and $alert.Count -eq 1 -and $alert[0].link) { $hit = $alert[0] }
    if ($hit) { foreach ($it in $items) { if (-not $it.mailLink) { $it.mailLink = [string]$hit.link } } }
    if ($items.Count) {
        $added = @(Add-TodoItems $items)
        if ($added) { $out += "Added to your to-do list:`n" + (($added | ForEach-Object { "- $_" }) -join "`n"); $q = Request-TodoDue; if ($q) { $out += $q } }
    }
    $msg = (@($out | Where-Object { $_ }) -join "`n").Trim()
    Send-Chat $(if ($msg) { $msg } else { "I couldn't find that thread. Tell me the sender or subject." })
}

# The alert item a message points at ("from 1", "email 2", "#3"), else $null. Used to attach the email link to a to-do.
function Get-AlertRef([string]$Text) {
    $alert = @($state.LastAlert | Where-Object { $_ })
    if (-not $alert.Count -or $Text -notmatch '(?i)\b(?:from|email|mail|message|item|number|no\.?|#)\s*#?(\d{1,2})\b') { return $null }
    $n = [int]$Matches[1]
    return (@($alert | Where-Object { [int]$_.n -eq $n -and $_.link }) | Select-Object -First 1)
}
