# Stub test harness for the assistant. Runs without Teams, Chrome, Claude, or Outlook.
# Usage (Windows PowerShell 5.1 or pwsh):  powershell -NoProfile -File app\tests\assistant-tests.ps1
# Loads lib\common.ps1 and the assistant files the same way server.ps1 does, replaces Send-Chat and Invoke-SecClaude
# with stubs, and runs scripted conversations against a throwaway data folder. Keep this file ASCII-only.
param([string]$AppDir = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath() }
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $env:TEMP }
$data = Join-Path $env:TEMP ("assistant-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $data "notes") -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $data "notes\Senegal Remediation Paper.md"), "older entry", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $data "notes\General.md"), "", (New-Object System.Text.UTF8Encoding($false)))

$sync = [hashtable]::Synchronized(@{
    Config = @{ UserName = "Wael"; UserEmail = "wmoussa@fhi360.org"; UserDescription = "a researcher"; ClaudePath = ""; SecretaryModel = "haiku"; SecretaryThinkModel = "sonnet"
                SecretaryPollSec = 30; SecretaryNotesPollSec = 10; SecretaryDebugPort = 9222; SecretaryChromePath = ""
                SecretaryDays = @("Mon", "Tue", "Wed", "Thu", "Fri"); SecretaryStart = "08:00"; SecretaryEnd = "18:00"; SecretaryMaxCallsPerDay = 250 }
    Root = $data; BaseDir = $data; AppDir = $AppDir; LogPath = (Join-Path $data "test.log"); AssistantTestMode = $true
})
$files = @("core.ps1", "teams.ps1", "claude.ps1", "reminders.ps1", "todos.ps1", "notes.ps1", "mail.ps1", "calendar.ps1", "commands.ps1", "main.ps1")
$text = "`$LogTag = '[assistant] '`n" + [System.IO.File]::ReadAllText((Join-Path $AppDir "lib\common.ps1")) + "`n" +
        (($files | ForEach-Object { [System.IO.File]::ReadAllText((Join-Path $AppDir "assistant\$_")) }) -join "`n")
. ([scriptblock]::Create($text))

# ------------------------------------------------------------------ stubs
$script:Out = New-Object System.Collections.ArrayList
$script:ClaudeQueue = New-Object System.Collections.Queue
$script:Prompts = New-Object System.Collections.ArrayList
function Send-Chat([string]$Text, [string]$LinkUrl = "", [string]$LinkText = "") { $t = $Text + $(if ($LinkUrl) { "`n$LinkUrl" } else { "" }); [void]$script:Out.Add($t); Add-ChatLog "Assistant" $t }
function Invoke-SecClaude([string]$Prompt, [string]$Model = "", [switch]$Plain, [int]$TimeoutSec = 120) {
    Add-CallCount; [void]$script:Prompts.Add($Prompt)
    if (-not $script:ClaudeQueue.Count) { throw "Unexpected Claude call: $($Prompt.Substring(0, [math]::Min(120, $Prompt.Length)))" }
    return [string]$script:ClaudeQueue.Dequeue()
}
function Invoke-SecConnector([string]$Prompt, [string]$Model = "", [switch]$Plain, [int]$TimeoutSec = 300) {
    Add-CallCount; [void]$script:Prompts.Add($Prompt)
    if (-not $script:ClaudeQueue.Count) { throw "Unexpected connector call: $($Prompt.Substring(0, [math]::Min(120, $Prompt.Length)))" }
    return [string]$script:ClaudeQueue.Dequeue()
}
function Say([string]$T) { $script:Out.Clear(); Invoke-UserMessages @($T); return (@($script:Out) -join "`n---`n") }

$script:Pass = 0; $script:Fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Got = "") {
    if ($Ok) { $script:Pass++; Write-Host "PASS  $Name" } else { $script:Fail++; Write-Host "FAIL  $Name" -ForegroundColor Red; if ($Got) { Write-Host "      got: $Got" } }
}
function Get-TodoTexts { @((Get-Todos) | ForEach-Object { [string]$_.text; @($_.children | Where-Object { $_ } | ForEach-Object { [string]$_.text }) }) }

# ------------------------------------------------------------------ to-dos
$r = Say "todo: buy printer paper"
Check "todo: adds the item" ((Get-TodoTexts) -contains "buy printer paper") $r
Check "todo: asks when it is due" ($r -match 'When do you want') $r
$r = Say "today"
$it = @((Get-Todos) | Where-Object { $_.text -eq "buy printer paper" })[0]
Check "'today' answers the due question, not the brief" ([string]$it.due -eq (Get-Date).ToString('yyyy-MM-dd')) $r
$r = Say "todos"
Check "todos lists open items" ($r -match 'buy printer paper') $r

# Router path: the model adds a to-do with a due date
$script:ClaudeQueue.Enqueue('{"route":"chat","reply":"","add_reminders":[],"remove_reminders":[],"add_todos":[{"text":"send budget to Rachel","parent":"","due_said":"friday","due":""}],"set_due":[],"complete_todos":[]}')
$r = Say "add send budget to Rachel to my list, due friday"
$it = @((Get-Todos) | Where-Object { $_.text -eq "send budget to Rachel" })[0]
Check "router to-do gets its due date from the words" ([string]$it.due -eq (ConvertTo-DueDate 'friday')) $r
Check "router to-do with a date asks nothing" ($r -notmatch 'When do you want') $r
$script:ClaudeQueue.Enqueue('{"route":"chat","reply":"","add_todos":[],"set_due":[],"complete_todos":["send budget to Rachel"]}')
$r = Say "sent the budget to rachel, mark it done"
Check "complete_todos checks it off" ([bool]@((Get-Todos) | Where-Object { $_.text -eq "send budget to Rachel" })[0].checked) $r

$script:ClaudeQueue.Enqueue('{"route":"chat","reply":"","delete_todos":["send budget to Rachel"]}')
$r = Say "delete the budget to rachel to-do"
Check "delete_todos removes the item" ($r -match 'Deleted from your to-do list' -and (Get-TodoTexts) -notcontains "send budget to Rachel") $r
$script:ClaudeQueue.Enqueue('{"route":"chat","reply":"Deleted.","add_reminders":[],"add_todos":[]}')
$r = Say "delete the thing that does not exist"
Check "a reply that claims an action nobody performed is replaced" ($r -match "didn't change anything" -and $r -notmatch '^Deleted\.') $r

# ------------------------------------------------------------------ quick notes and filing
$r = Say "note: call the landlord about the leak"
Check "note: files to General" ((Read-NotePage General) -match 'landlord') $r
$r = Say "note senegal: endline data arrived"
Check "note PAGE: matches a page by prefix" ((Read-NotePage "Senegal Remediation Paper") -match 'endline data arrived') $r

# ------------------------------------------------------------------ start / end notes
$r = Say "start notes"
Check "start notes acks without a model call" ($r -match 'Taking notes' -and $state.NotesActive) $r
$r = Say "Caitlin will send cost template by wed"
Check "lines in a session are silent" ($r -eq "") $r
$r = Say "I review the CEA draft next week"
$script:ClaudeQueue.Enqueue('{"title":"CEA check-in","page":"Bantwana","page_is_new":true,"summary":"Caitlin sends the cost template.","key_points":[],"decisions":[],"actions":[{"text":"Review the CEA draft","owner":"me","due":"","parent":""},{"text":"send cost template","owner":"Caitlin","due":"","parent":""}]}')
$r = Say "end notes"
Check "end notes adds actions under the title" ((Get-TodoTexts) -contains "Review the CEA draft" -and (Get-TodoTexts) -contains "Caitlin to send cost template") $r
Check "end notes asks where to file a guessed new page" ($r -match 'new page called "Bantwana"') $r
Check "notes buffer had both lines" ($script:Prompts[-1] -match 'cost template' -and $script:Prompts[-1] -match 'CEA draft') ""
$r = Say "yes"
Check "yes creates the page and files the notes" ((Read-NotePage "Bantwana") -match '## CEA check-in') $r

# A filing question replaced by another question files the notes under General
$r = Say "note to Gamma: idea about the tracer study"
Check "unknown page asks to create it" ($r -match "no note page called ""Gamma""") $r
$r = Say "todo: renew passport"
Check "a new question files the earlier note under General" ((Read-NotePage General) -match 'tracer study' -and $r -match 'filed the earlier notes under General') $r
$script:Ask.Until = (Get-Date).AddMinutes(-1)
Resolve-StaleAsk
Check "an expired due question just clears" ($null -eq $script:Ask) ""

# ------------------------------------------------------------------ show and tidy
$r = Say "show general"
Check "show prints a short page" ($r -match 'General notes:' -and $r -match 'landlord') $r
$script:ClaudeQueue.Enqueue("# Home`r`nWed Oct 14  call the landlord about the leak`r`n`r`n# Research`r`nidea about the tracer study")
$before = Read-NotePage General
$r = Say "tidy general"
Check "tidy proposes, writes nothing yet" ((Read-NotePage General) -ceq $before -and $r -match 'Reply yes to apply') $r
$r = Say "yes"
Check "yes applies the tidy and keeps a backup" ((Read-NotePage General) -match '# Home' -and @(Get-ChildItem (Join-Path $NotesDir "_removed")).Count -ge 1) $r

# ------------------------------------------------------------------ reminders
$added = @(Add-Reminders @(@{ text = "Take meds"; kind = "once"; at = "2026-10-14T10:00"; nag_minutes = 15 }))
Check "a reminder saves" ($added.Count -eq 1) ""
$script:Out.Clear(); Invoke-Reminders ([datetime]'2026-10-14 10:00')
Check "it fires at its time" ((@($script:Out) -join ' ') -match 'Reminder: Take meds') (@($script:Out) -join ' ')
$script:Out.Clear(); Invoke-Reminders ([datetime]'2026-10-14 10:20')
Check "it nags until done" ((@($script:Out) -join ' ') -match 'Reminder \(again\): Take meds') (@($script:Out) -join ' ')
$r = Say "done"
Check "done marks it" ($r -match 'marked done' -and [bool]$added[0].done) $r
$r = Say "reminders"
Check "reminders lists none open" ($r -match 'No reminders set') $r

# ------------------------------------------------------------------ typos and note sessions the router opens
Check "typo phrases match" ((Get-NotesPhrase "start ntoes" 'start') -eq "" -and (Get-NotesPhrase "Strat notes." 'start') -eq "" -and (Get-NotesPhrase "edn notes" 'end') -eq "") ""
Check "look-alike phrases do not" ($null -eq (Get-NotesPhrase "send notes" 'end') -and $null -eq (Get-NotesPhrase "and notes" 'end') -and $null -eq (Get-NotesPhrase "start nodes today" 'start')) ""
$r = Say "end notes"
Check "end notes with no session says so, no model call" ($r -match 'No notes session is open') $r
$script:ClaudeQueue.Enqueue('{"title":"Oven repair","page":"General","page_is_new":false,"summary":"The oven repair person has not called.","key_points":[],"decisions":[],"actions":[]}')
$script:Out.Clear(); Invoke-UserMessages @("start ntoes", "oven repair has not called", "end ntoes")
Check "start ntoes opens a session in the same batch" ((@($script:Out) -join ' ') -match 'Taking notes') (@($script:Out) -join ' | ')
Check "end ntoes closes it and cleans up the lines" (-not $state.NotesActive -and $script:Prompts[-1] -match 'oven repair has not called' -and (@($script:Out) -join ' ') -match 'Notes "Oven repair"') (@($script:Out) -join ' | ')
if ($script:Ask) { $r = Say "general" }
$script:ClaudeQueue.Enqueue('{"route":"notes_start","reply":""}')
$script:Out.Clear(); $state.NotesActive = $false; Invoke-UserMessages @("can you take some notes for me", "first line of the meeting")
Check "router notes_start opens the session and keeps the next lines" ($state.NotesActive -and ([System.IO.File]::ReadAllText($NotesBufferPath)) -match 'first line of the meeting') (@($script:Out) -join ' | ')
$r = Say "cancel notes"
Check "cancel notes discards" (-not $state.NotesActive -and $r -match 'discarded') $r

# ------------------------------------------------------------------ help, routes
$r = Say "help"
Check "help is generated from the table" ($r -match 'NOTES:' -and $r -match 'tidy PAGE' -and $r -match 'REMINDERS:') $r
$script:ClaudeQueue.Enqueue('{"route":"calendar","reply":""}')
$script:ClaudeQueue.Enqueue('You are free Thursday 10:00 to 11:30 AM and after 2:00 PM.')
$r = Say "when am I free thursday?"
Check "calendar route answers from the connector" ($r -match 'free Thursday') $r
Check "calendar prompt is read-only" ($script:Prompts[-1] -match 'cannot create, move, accept') ""
$script:ClaudeQueue.Enqueue('{"route":"calendar","reply":""}')
$script:ClaudeQueue.Enqueue('{"reply":"Thursday 2:00 PM is open. I could not find Ana email.","events":[{"subject":"Survey check-in","start":"2026-10-15T14:00","end":"2026-10-15T14:30","attendees":["sophie@fhi360.org","Ana"],"location":"Teams","body":"Agenda"}]}')
$r = Say "schedule a survey check-in with Sophie and Ana Thursday at 2"
Check "calendar request posts a pre-filled link for the event" ($r -match 'Survey check-in' -and $r -match 'deeplink/compose' -and $r -match 'to=sophie%40fhi360.org' -and $r -notmatch 'to=[^&]*Ana') $r

# ------------------------------------------------------------------ connector: scan, alerts, meetings, Q&A
function Json($o) { ConvertTo-Json -InputObject $o -Depth 8 -Compress }
$now = Get-Date
$s1 = $now.AddMinutes(25).ToString('yyyy-MM-ddTHH:mm'); $e1 = $now.AddMinutes(55).ToString('yyyy-MM-ddTHH:mm')
$latest = $now.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm')
$scan1 = Json @{
    health = @{ ok = $true; error = ""; scopes = @("Mail.Read", "Calendars.Read") }
    threads = @(
        @{ key = "T1"; latest = $latest; from = "Sophie"; subject = "Budget"; category = "Requires Response"; resolved = $false; line = "Sophie wants your thoughts on section 3 of the budget doc."; deadline = "2026-10-20"; doc = "https://x/doc1"; link = "https://x/mail1" }
        @{ key = "T2"; latest = $latest; from = "Ana"; subject = "Review"; category = "Requires Response"; resolved = $false; line = "Ana needs your sign-off on the survey tool."; deadline = ""; doc = ""; link = "https://x/mail2" }
        @{ key = "T3"; latest = $latest; from = "Lee"; subject = "Update"; category = "FYI"; resolved = $false; line = "Lee says the site visit moved to Monday."; deadline = ""; doc = ""; link = "" }
        @{ key = "T4"; latest = $latest; from = "News"; subject = "Digest"; category = "Noise"; resolved = $false; line = ""; deadline = ""; doc = ""; link = "" }
        @{ key = "T5"; latest = $latest; from = "Raj"; subject = "Done"; category = "Requires Response"; resolved = $true; line = "Raj asked; you replied."; deadline = ""; doc = ""; link = "" })
    meetings = @(
        @{ subject = "Budget sync"; start = $s1; end = $e1; allDay = $false; people = @("Sophie", "Ana"); declined = $false; location = "Teams"; link = "https://x/ev1" }
        @{ subject = "Office closed"; start = $now.Date.ToString('yyyy-MM-ddT00:00'); end = $now.Date.AddDays(1).ToString('yyyy-MM-ddT00:00'); allDay = $true; people = @(); declined = $false; location = ""; link = "" }) }
$script:ClaudeQueue.Enqueue($scan1)
$script:Out.Clear(); $ok = Invoke-MailScan $now 'greeting'
$txt = @($script:Out) -join "`n---`n"
Check "greeting scan succeeds and greets" ($ok -and $txt -match 'Good (morning|afternoon)' -and $txt -match 'connector check passed') $txt
Check "greeting brief lists meetings and to-dos from the cache (no extra call)" ($txt -match 'Meetings today' -and $txt -match 'Budget sync' -and $txt -match 'All day: Office closed' -and $txt -match 'To-dos for today|No to-dos due') $txt
Check "alert is numbered, action-framed, with deadline and doc" ($txt -match '1\. Sophie wants your thoughts on section 3' -and $txt -match '\(by Tue Oct 20\)' -and $txt -match 'Doc: https://x/doc1' -and $txt -match '2\. Ana needs') $txt
Check "resolved and noise are left out; FYI is queued" ($txt -notmatch 'Raj' -and $txt -notmatch 'Digest' -and @($state.FyiItems).Count -eq 1 -and @($state.LastAlert).Count -eq 2) $txt
Check "needs-response threads are tracked for the roundup; resolved and FYI are not" ((@(Get-ReplyTrack | ForEach-Object { $_.key }) -join ',') -eq 'T1,T2') ((@(Get-ReplyTrack | ForEach-Object { $_.key }) -join ','))
Check "scan saved the meeting cache and greeting day" ((Get-CachedMeetings).Count -eq 2 -and $state.GreetDay -eq $now.ToString('yyyy-MM-dd')) ""
Check "scan prompt checks the connector first and stays read-only" ($script:Prompts[-1] -match 'get_granted_scopes' -and $script:Prompts[-1] -match 'read tools only') ""

$script:ClaudeQueue.Enqueue($scan1)
$script:Out.Clear(); $ok = Invoke-MailScan $now 'normal'
Check "a repeat scan is silent (threads already seen)" ($ok -and @($script:Out).Count -eq 0) (@($script:Out) -join ' | ')
Check "second scan passes the seen list to the model" ($script:Prompts[-1] -match 'T1\|') ""

# Failure streak: one message, then quiet, then recovery
$bad = Json @{ health = @{ ok = $false; error = "AADSTS65001 consent required"; scopes = @() }; threads = @(); meetings = @() }
$script:ClaudeQueue.Enqueue($bad); $script:Out.Clear(); $ok = Invoke-MailScan $now 'normal'
Check "connector failure posts the AADSTS error" (-not $ok -and (@($script:Out) -join ' ') -match 'AADSTS65001') (@($script:Out) -join ' ')
$script:ClaudeQueue.Enqueue($bad); $script:Out.Clear(); [void](Invoke-MailScan $now 'normal')
Check "second failure stays quiet" (@($script:Out).Count -eq 0) (@($script:Out) -join ' ')
$late = Json @{ health = @{ ok = $true; error = ""; scopes = @("Mail.Read") }
    threads = @(@{ key = "T9"; latest = $now.ToString('yyyy-MM-ddTHH:mm'); from = "Kim"; subject = "Contract"; category = "Requires Response"; resolved = $false; line = "Kim wants you to sign the contract."; deadline = ""; doc = ""; link = "" }); meetings = @() }
$state.LastScan = $now.AddMinutes(-70).ToString('s')
$script:ClaudeQueue.Enqueue($late); $script:Out.Clear(); [void](Invoke-MailScan $now 'catchup')
$txt = @($script:Out) -join "`n---`n"
Check "recovery says so and catch-up lists what was missed" ($txt -match 'working again' -and $txt -match 'Since my last good check' -and $txt -match '1\. Kim wants') $txt
$script:ClaudeQueue.Enqueue((Json @{ health = @{ ok = $true; error = ""; scopes = @("Mail.Read") }; threads = @(); meetings = @() }))
$state.LastScan = $now.AddMinutes(-70).ToString('s'); $script:Out.Clear(); [void](Invoke-MailScan $now 'catchup')
Check "catch-up with nothing says nothing needed attention" ((@($script:Out) -join ' ') -match 'While you were away.*nothing needed') (@($script:Out) -join ' ')
$script:ClaudeQueue.Enqueue((Json @{ health = @{ ok = $true; error = ""; scopes = @("Mail.Read", "Mail.ReadWrite") }; threads = @(); meetings = @() }))
$script:Out.Clear(); [void](Invoke-MailScan $now 'normal')
Check "a write scope in the grant triggers a warning" ((@($script:Out) -join ' ') -match 'write scopes \(Mail.ReadWrite\)') (@($script:Out) -join ' ')

# Wall-clock slots
$mon = [datetime]'2026-10-12 10:14'
$state.GreetDay = "2026-10-12"; $state.LastScan = '2026-10-12T09:50:00'; $state.ScanSlot = ""
$script:ClaudeQueue.Enqueue((Json @{ health = @{ ok = $true; error = ""; scopes = @("Mail.Read") }; threads = @(); meetings = @() }))
$script:Prompts.Clear(); Invoke-MailWatch $mon
Check "watch starts at 10:14 for the 10:15 slot" ($script:Prompts.Count -eq 1 -and $state.ScanSlot -eq '2026-10-12 10:15') $state.ScanSlot
Invoke-MailWatch ([datetime]'2026-10-12 10:14:40')
Check "same slot does not scan twice" ($script:Prompts.Count -eq 1) ""
Invoke-MailWatch ([datetime]'2026-10-12 17:59'); Invoke-MailWatch ([datetime]'2026-10-12 19:00'); Invoke-MailWatch ([datetime]'2026-10-17 10:00')
Check "no scan after hours or on weekends" ($script:Prompts.Count -eq 1) ""

# Questions about email, numbered from the latest alert
$script:ClaudeQueue.Enqueue((Json @{ health = @{ ok = $true; error = ""; scopes = @("Mail.Read") }; threads = @(@{ key = "T11"; latest = $latest; from = "Sophie"; subject = "Budget"; category = "Requires Response"; resolved = $false; line = "Sophie wants section 3 reviewed."; deadline = ""; doc = ""; link = "https://x/m11" }); meetings = @() }))
[void](Invoke-MailScan $now 'manual')
$script:ClaudeQueue.Enqueue('{"route":"mail","reply":""}')
$script:ClaudeQueue.Enqueue('{"reply":"Sophie wants your comments on section 3 by Friday.\nhttps://x/doc1","todos":[]}')
$r = Say "what does 1 want exactly?"
Check "mail question resolves the number and answers" ($r -match 'Sophie wants your comments' -and $script:Prompts[-1] -match 'key=T11') $r
$script:ClaudeQueue.Enqueue('{"route":"mail","reply":""}')
$script:ClaudeQueue.Enqueue('{"reply":"Done.","todos":[{"text":"Review section 3 of the budget doc","due_said":"friday","due":"","link":"https://x/m11"}]}')
$r = Say "make a to-do from 1, due friday"
$it = @((Get-Todos) | Where-Object { $_.text -eq "Review section 3 of the budget doc" })[0]
Check "to-do from an email keeps the mail link and due date" ($it -and [string]$it.mailLink -eq "https://x/m11" -and [string]$it.due -eq (ConvertTo-DueDate 'friday')) $r
$script:ClaudeQueue.Enqueue('{"route":"mail","reply":""}')
$script:ClaudeQueue.Enqueue('{"reply":"","todos":[{"text":"Reply to Sophie about section 3","due_said":"","due":"","link":""}]}')
$r = Say "make a todo from 1 to reply to sophie"
$it = @((Get-Todos) | Where-Object { $_.text -eq "Reply to Sophie about section 3" })[0]
Check "an empty model link falls back to the numbered alert's link" ($it -and [string]$it.mailLink -eq "https://x/m11") $r
$script:Ask = $null
$script:ClaudeQueue.Enqueue('{"route":"chat","reply":"","add_todos":[{"text":"Decline the review","parent":"","due_said":"friday","due":""}]}')
$r = Say "make a todo from 1 to decline the review by friday"
$it = @((Get-Todos) | Where-Object { $_.text -eq "Decline the review" })[0]
Check "router to-do from a numbered email gets the mail link" ($it -and [string]$it.mailLink -eq "https://x/m11") $r
$script:ClaudeQueue.Enqueue('{"route":"mail","reply":""}'); $script:ClaudeQueue.Enqueue('{"reply":"","todos":[]}')
$r = Say "what did Priya say?"
Check "an unknown thread gets a nudge, not silence" ($r -match 'sender or subject') $r

# FYI batch
$state.FyiItems = @([pscustomobject]@{ key = "T3"; line = "Lee says the site visit moved to Monday." })
$script:Out.Clear(); Send-FyiBatch
Check "FYI batch lists queued items and empties the queue" ((@($script:Out) -join ' ') -match 'FYI email since' -and @($state.FyiItems).Count -eq 0) (@($script:Out) -join ' ')
$state.FyiSlot = ""; $state.FyiItems = @([pscustomobject]@{ key = "T3"; line = "x" })
$script:Out.Clear(); Invoke-FyiBatch ([datetime]'2026-10-12 12:05')
Check "noon slot sends the batch once" ((@($script:Out) -join ' ') -match 'FYI email since') ""
$script:Out.Clear(); Invoke-FyiBatch ([datetime]'2026-10-12 12:20'); Check "and not twice" (@($script:Out).Count -eq 0) ""

# Unanswered email: tracked at scan time, checked at the roundup
$state.RespTrack = @(
    [pscustomobject]@{ key = "R1"; from = "Sophie"; subject = "Budget"; line = "Sophie wants your thoughts on section 3."; link = "https://x/r1"; flagged = '2026-10-12T08:00:00'; asks = 0; lastAsk = ""; skip = $false },
    [pscustomobject]@{ key = "R2"; from = "Ana"; subject = "Review"; line = "Ana needs your sign-off on the survey tool."; link = "https://x/r2"; flagged = '2026-10-12T08:30:00'; asks = 0; lastAsk = ""; skip = $false },
    [pscustomobject]@{ key = "R3"; from = "Lee"; subject = "Fresh"; line = "Lee wants a number."; link = "https://x/r3"; flagged = '2026-10-12T11:30:00'; asks = 0; lastAsk = ""; skip = $false },
    [pscustomobject]@{ key = "R4"; from = "Raj"; subject = "Todo"; line = "Raj wants a date."; link = "https://x/r4"; flagged = '2026-10-12T08:00:00'; asks = 0; lastAsk = ""; skip = $false })
[void](Add-TodoItems @(@{ text = "Reply to Raj"; mailLink = "https://x/r4" }))
$script:ClaudeQueue.Enqueue((Json @{ results = @(@{ key = "R1"; replied = $true }, @{ key = "R2"; replied = $false }) }))
$script:Out.Clear(); $script:Prompts.Clear(); Send-ReplyCheck ([datetime]'2026-10-12 12:00')
$txt = @($script:Out) -join ' '
Check "roundup asks only about unanswered, old enough, not already a to-do" ($txt -match "haven't replied" -and $txt -match 'Ana needs' -and $txt -notmatch 'Sophie' -and $txt -notmatch 'Lee wants' -and $txt -notmatch 'Raj') $txt
Check "answered thread leaves the tracker; asked one is counted" (@(Get-ReplyTrack | Where-Object { $_.key -eq 'R1' }).Count -eq 0 -and (Get-ReplyTrack | Where-Object { $_.key -eq 'R2' }).asks -eq 1 -and @($state.LastAlert)[0].key -eq 'R2') ""
$script:ClaudeQueue.Enqueue((Json @{ results = @() }))
$script:Out.Clear(); Send-ReplyCheck ([datetime]'2026-10-12 16:00')
$txt = @($script:Out) -join ' '
Check "at 4 PM an earlier ask is not repeated, and the newly old item is asked" ($txt -match 'Lee wants' -and $txt -notmatch 'Ana needs') $txt
$script:Out.Clear(); $script:Prompts.Clear(); Send-ReplyCheck ([datetime]'2026-10-12 16:05')
Check "with nothing new to ask, no call is made and nothing posts" (@($script:Out).Count -eq 0 -and $script:Prompts.Count -eq 0) (@($script:Out) -join ' ')
$script:ClaudeQueue.Enqueue((Json @{ results = @() }))
$script:Out.Clear(); Send-ReplyCheck ([datetime]'2026-10-15 12:00')
Check "a second ask comes after three days" ((@($script:Out) -join ' ') -match 'Ana needs') (@($script:Out) -join ' ')
$script:Out.Clear(); $r = Say "skip 1"
Check "skip stops the asking" ($r -match "won't ask about 1" -and (Get-ReplyTrack | Where-Object { $_.key -eq 'R2' }).skip -eq $true) $r
foreach ($r in (Get-ReplyTrack)) { $r.skip = $true }
$script:Out.Clear(); Send-ReplyCheck ([datetime]'2026-10-20 12:00')
Check "a skipped item stays quiet" (@($script:Out).Count -eq 0) ""
$script:Out.Clear(); $r = Say "unanswered"
Check "unanswered on demand answers even when nothing is open" ($r -match 'Nothing is waiting') $r

# "reply to N by DAY" makes a reply to-do with the email link
$state.LastAlert = @([pscustomobject]@{ n = 1; key = "Q1"; from = "Sophie"; subject = "Budget"; link = "https://x/q1" })
$script:Out.Clear(); $script:Ask = $null; $r = Say "reply to 1 by friday"
$td = @((Get-Todos) | Where-Object { [string]$_.text -eq 'Reply to Sophie: Budget' }) | Select-Object -First 1
Check "reply to 1 by friday adds a dated reply to-do with the link" ($td -and $td.mailLink -eq 'https://x/q1' -and $td.due -match '^\d{4}-\d{2}-\d{2}$') $r
$script:Ask = $null; $r = Say "reply 1"
Check "reply 1 with no date asks when" ($r -match 'When do you want') $r
$script:Ask = $null; $r = Say "reply to 7"
Check "reply to an unknown number says so" ($r -match "don't have a numbered email 7") $r
$script:Ask = $null

# Pre-meeting prompt and brief
$script:Ask = $null
Save-Meetings (ConvertTo-MeetingList @(@{ subject = "Budget sync"; start = $s1; end = $e1; allDay = $false; people = @("Sophie"); declined = $false; location = ""; link = "" },
    @{ subject = "Solo block"; start = $s1; end = $e1; allDay = $false; people = @(); declined = $false; location = ""; link = "" },
    @{ subject = "Declined one"; start = $s1; end = $e1; allDay = $false; people = @("Ana"); declined = $true; location = ""; link = "" })) $now.Date
$state.PrepFired = @()
$script:Out.Clear(); Invoke-MeetingPrompts $now
Check "prep prompt fires for a meeting with people, once" (@($script:Out).Count -eq 1 -and $script:Out[0] -match 'Need prep for "Budget sync"') (@($script:Out) -join ' | ')
$script:Out.Clear(); Invoke-MeetingPrompts $now
Check "prep prompt does not repeat" (@($script:Out).Count -eq 0) ""
$script:ClaudeQueue.Enqueue("Budget sync covers section 3. Sophie emailed Tuesday asking for comments.")
$r = Say "yes"
Check "yes returns a read-only brief" ($r -match 'Prep for "Budget sync"' -and $script:Prompts[-1] -match 'read-only brief' -and $null -eq $script:Ask) $r

# Tomorrow's brief reads the calendar through the connector
$script:ClaudeQueue.Enqueue((Json @{ ok = $true; error = ""; meetings = @(@{ subject = "Kickoff"; start = $now.AddDays(1).Date.AddHours(10).ToString('yyyy-MM-ddTHH:mm'); end = $now.AddDays(1).Date.AddHours(11).ToString('yyyy-MM-ddTHH:mm'); allDay = $false; people = @("Ana"); declined = $false; location = ""; link = "" }) }))
$r = Say "tomorrow"
Check "tomorrow brief includes that day's meetings" ($r -match 'Kickoff' -and $r -match 'Meetings ') $r
$script:ClaudeQueue.Enqueue((Json @{ ok = $false; error = "AADSTS70043 token expired"; meetings = @() }))
$r = Say "tomorrow"
Check "a calendar failure still sends the to-dos" ($r -match "couldn't read your calendar" -and $r -match 'AADSTS70043') $r

$r = Say "test event link"
Check "event link is pre-filled with subject, times, attendee" ($r -match 'deeplink/compose' -and $r -match 'subject=Test%20event' -and $r -match 'startdt=\d{4}-\d{2}-\d{2}T10%3A00%3A00' -and $r -match 'to=wmoussa%40fhi360.org') $r
Check "event link stays under 2000 characters" ((($r -split "`n")[-1]).Length -lt 2000) ""
$script:ClaudeQueue.Enqueue((Json @{ health = @{ ok = $true; error = ""; scopes = @("Mail.Read") }; threads = @(); meetings = @() }))
$r = Say "check email"
Check "check email runs a scan now and answers" ($r -match 'Nothing new needs your attention') $r
$r = Say "help"
Check "help lists email and calendar" ($r -match 'EMAIL:' -and $r -match 'CALENDAR:' -and $r -match 'check email') $r
$r = Say "morning"
Check "morning brief lists meetings and to-dos" ($r -match 'To-dos for today|No to-dos due') $r

Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$script:Pass passed, $script:Fail failed"
if ($script:Fail) { exit 1 }
