# ================================================================== assistant/notes.ps1
# Notes: start notes / end notes (one Sonnet call at the end), quick "note: X", filing with confirmation,
# and two page commands, tidy and show. Notes land in the dashboard's Notes tab (data\notes\*.md).

$NotesBufferPath = Join-Path $SecDir "notes-buffer.txt"

# The meeting happening now (or starting within 10 minutes), from the meeting cache the scan writes. No Outlook call.
function Get-CurrentMeeting {
    $list = @(Read-JsonFile $MeetingsPath)
    $now = Get-Date
    foreach ($m in $list) {
        if (-not $m -or $m.allDay -or -not @($m.people).Count) { continue }
        try { $s = [datetime]$m.start; $e = [datetime]$m.end } catch { continue }
        if ($s -le $now.AddMinutes(10) -and $e -gt $now) {
            return @{ Subject = [string]$m.subject; People = ((@($m.people) | Select-Object -First 12) -join "; "); When = "$($s.ToString('h:mm tt', $Inv))-$($e.ToString('h:mm tt', $Inv))" }
        }
    }
    return $null
}

function Start-Notes {
    $m = $null; try { $m = Get-CurrentMeeting } catch { }
    $state.NotesActive = $true
    $state.NotesStarted = (Get-Date).ToString("s")
    $state.NotesMeeting = if ($m) { "$($m.Subject) ($($m.When)); with $($m.People)" } else { "" }
    Save-State
    [System.IO.File]::WriteAllText($NotesBufferPath, "", $Utf8)
    $for = if ($m) { " for ""$($m.Subject)""" } else { "" }
    Send-Chat "Taking notes$for."
}
function Add-NoteLine([string]$Text) {
    [System.IO.File]::AppendAllText($NotesBufferPath, ("[{0}] {1}`n" -f (Get-Date).ToString("HH:mm"), $Text), $Utf8)
}
function Stop-Notes {
    $state.NotesActive = $false; Save-State
    Remove-Item $NotesBufferPath -ErrorAction SilentlyContinue
}

function Complete-Notes([string]$PageHint = "") {
    $raw = if (Test-Path $NotesBufferPath) { [System.IO.File]::ReadAllText($NotesBufferPath, $Utf8).Trim() } else { "" }
    $meeting = [string]$state.NotesMeeting
    $started = [datetime]$state.NotesStarted
    $state.NotesActive = $false; Save-State
    if (-not $raw) { Send-Chat "Notes closed. There was nothing to save."; return }

    $parents = @((Get-Todos) | Where-Object { -not $_.checked } | ForEach-Object { [string]$_.text })
    $prompt = @"
You are $U's admin assistant. Clean up the raw notes $U typed on the go into lean, accurate notes. Keep $U's facts and numbers exactly; fix typos and shorthand only where the meaning is clear; do not invent anything.
Now: $((Get-Date).ToString("dddd, MMMM d, yyyy h:mm tt", $Inv)). Notes started $($started.ToString("h:mm tt", $Inv)).
$(if ($meeting) { "Meeting: $meeting" } else { "No calendar meeting was running." })
Dates (use this list for due dates):
$(Get-DateTable)

EXISTING TOP-LEVEL TASKS IN $U'S LIST (to file action items under the right project)
$(if ($parents) { ($parents | ForEach-Object { "- $_" }) -join "`n" } else { "(none)" })

NOTE PAGES IN $U'S DASHBOARD (each holds notes on one topic; General is the catch-all)
$((Get-NotePages) -join ", ")

ABOUT $U (people and current projects)
$(if (Test-Path $RulesPath) { [System.IO.File]::ReadAllText($RulesPath, $Utf8) })

RAW NOTES
$raw

Answer with one JSON object and nothing else:
{"title": "3-7 word title",
 "page": "the existing note page these notes belong on, copied exactly; if none fits and they are about a specific project or topic, a short new page name; General for one-off or general notes",
 "page_is_new": false,
 "summary": "one sentence with the gist",
 "key_points": ["facts and context NOT already stated in the summary"],
 "decisions": ["only what was actually agreed or decided; a proposal that is still open is a key point, not a decision"],
 "actions": [{"text": "short imperative task", "owner": "me or the person's name", "due": "YYYY-MM-DD or empty", "parent": "an EXISTING task text copied exactly if this clearly belongs to it, else empty"}]}
Say each fact once. The summary gives the gist; key points add what the summary leaves out; a decision appears only under decisions; a task appears only under actions. Never restate the same fact in two sections, and prefer an empty section over a repeat. Short notes may need only the summary and one or two key points.
Only list actions that the notes actually imply. Use empty arrays when there is nothing.
"@
    $n = ConvertFrom-ModelJson (Invoke-SecClaude $prompt $Config.SecretaryThinkModel -TimeoutSec 180)
    $title = ([string]$n.title -replace '[\\/:*?"<>|]', '').Trim()
    if (-not $title) { $title = "Notes" }
    $sec = { param($h, $xs) if (@($xs | Where-Object { $_ }).Count) { "$h`r`n" + ((@($xs | Where-Object { $_ }) | ForEach-Object { "- $_" }) -join "`r`n") + "`r`n`r`n" } else { "" } }
    $actLines = @($n.actions | Where-Object { $_ -and $_.text } | ForEach-Object { "$($_.text)" + $(if ([string]$_.owner -and [string]$_.owner -notmatch $MeRx) { " [$($_.owner)]" } else { "" }) + $(if ($_.due) { " (by $($_.due))" } else { "" }) })
    $body = "$($started.ToString('dddd, MMMM d, yyyy h:mm tt', $Inv))" + $(if ($meeting) { "`r`nMeeting: $meeting" } else { "" }) + "`r`n`r`n" +
            "$([string]$n.summary)`r`n`r`n" + (& $sec "KEY POINTS" $n.key_points) + (& $sec "DECISIONS" $n.decisions) + (& $sec "ACTION ITEMS" $actLines)
    $entry = "## $title`r`n" + $body.TrimEnd()
    # Action items go to the To-do tab (due dates become chips; the deliverable alerts cover them)
    $added = @(); try { $added = @(Add-TodoItems $n.actions $title) } catch { Write-Log "Could not add note actions: $($_.Exception.Message)" "WARN" }
    $fileMsg = Request-NoteFiling $entry $PageHint ([string]$n.page) ([bool]$n.page_is_new) $true

    $msg = "Notes ""$title"": $([string]$n.summary)"
    if ($added) { $msg += "`nAdded to your to-do list:`n" + (($added | ForEach-Object { "- $_" }) -join "`n") }
    $msg += "`n" + $fileMsg
    Send-Chat $msg
    Remove-Item $NotesBufferPath -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ where a note belongs, with a confirmation when I'm guessing
# Existing page for a name the user typed: exact, then a unique prefix, then a unique "contains". $null if none.
function Find-NotePage([string]$Name) {
    $n = ([string]$Name).Trim().ToLowerInvariant()
    if (-not $n) { return $null }
    $pages = @(Get-NotePages)
    $x = @($pages | Where-Object { $_.ToLowerInvariant() -eq $n }) | Select-Object -First 1
    if ($x) { return [string]$x }
    $m = @($pages | Where-Object { $_.ToLowerInvariant().StartsWith($n) })
    if ($m.Count -eq 1) { return [string]$m[0] }
    $m = @($pages | Where-Object { $_.ToLowerInvariant().Contains($n) })
    if ($m.Count -eq 1) { return [string]$m[0] }
    return $null
}
# Cheap guess for a quick note: a page name that appears as a whole word in the text, else General
function Get-NoteGuess([string]$Text) {
    $low = $Text.ToLowerInvariant(); $hits = @()
    foreach ($p in @(Get-NotePages | Where-Object { $_ -ne 'General' })) {
        if ($low -match ('(?<![a-z0-9])' + [regex]::Escape($p.ToLowerInvariant()) + '(?![a-z0-9])')) { $hits += $p }
    }
    if ($hits.Count -eq 1) { return [string]$hits[0] }
    return "General"
}
# Files an entry, or asks where it belongs. Returns the text to put in the chat reply.
#   $Hint = a page the user named; $Guess = my best guess; $AskGeneral = ask even when the guess is General (meeting notes)
function Request-NoteFiling([string]$Entry, [string]$Hint, [string]$Guess, [bool]$GuessIsNew, [bool]$AskGeneral) {
    if ($Hint) {
        $found = Find-NotePage $Hint
        if ($found) { Add-NoteEntry $found $Entry; return "Filed under ""$found"" in your Notes tab." }
        $name = ConvertTo-NoteName $Hint
        if (-not $name) { $name = "General" }
        Set-Ask 'note_filing' @{ Entry = $Entry; Page = $name; IsNew = $true }
        return "There's no note page called ""$name"". Create it and file this there?"
    }
    $g = if ($Guess) { $Guess } else { "General" }
    $found = Find-NotePage $g
    $isNew = $false
    if ($found) { $g = $found }
    else { $g = ConvertTo-NoteName $g; if (-not $g -or $g -ieq 'General') { $g = "General" } else { $isNew = $true } }
    if ($g -eq "General" -and -not $AskGeneral) { Add-NoteEntry "General" $Entry; return "Saved to General in your Notes tab." }
    Set-Ask 'note_filing' @{ Entry = $Entry; Page = $g; IsNew = $isNew }
    if ($isNew) { return "Start a new page called ""$g"" for this?" }
    return "File this under ""$g""?"
}
Register-AskKind 'note_filing' {
    param($p, [string]$Text)
    $tt = $Text.Trim()
    $dest = $null; $create = $false
    if ($tt -match '^(?i)(yes|y|yep|yeah|ok|okay|sure|confirm|go ahead|do it)[.!]*$') { $dest = [string]$p.Page; $create = [bool]$p.IsNew }
    elseif ($tt -match '^(?i)(no|n|nope|general|gen)[.!]*$') { $dest = "General" }
    elseif ($tt -match '^(?i)(?:new|create)\s+(?:note\s+)?(?:page\s+|tab\s+)?(.+)$') {
        $f = Find-NotePage $Matches[1]
        if ($f) { $dest = $f } else { $dest = ConvertTo-NoteName $Matches[1]; $create = $true }
    }
    elseif ($tt -match '^(?i)(?:to|in|under|page)\s+(.+)$') { $f = Find-NotePage $Matches[1]; if ($f) { $dest = $f } }
    else { $f = Find-NotePage $tt; if ($f) { $dest = $f } }
    if (-not $dest) { return $false }
    Clear-Ask
    if ($create) { $made = New-NotePage $dest; if ($made) { $dest = $made } }
    Add-NoteEntry $dest ([string]$p.Entry)
    Send-Chat "Filed under ""$dest"" in your Notes tab."
    return $true
} {
    # No answer after 30 minutes, or another question replaced this one: file under General so nothing is lost
    param($p, [string]$Why)
    Add-NoteEntry "General" ([string]$p.Entry)
    if ($Why -eq 'expired') { Send-Chat "No answer on where those notes belong, so I filed them under General." }
    else { Send-Chat "I filed the earlier notes under General." }
}

function Add-QuickNote([string]$Text, [string]$Hint = "") {
    $entry = "{0}  {1}" -f (Get-Date).ToString("ddd MMM d, h:mm tt", $Inv), $Text
    Send-Chat ("Noted. " + (Request-NoteFiling $entry $Hint (Get-NoteGuess $Text) $false $false))
}

# ------------------------------------------------------------------ show and tidy a page
function Show-NotePage([string]$Name, [bool]$Full) {
    $page = Find-NotePage $Name
    if (-not $page) { Send-Chat "I don't have a note page called ""$Name"". Pages: $((Get-NotePages) -join ', ')."; return }
    $t = ((Read-NotePage $page) -replace '\r\n', "`n").Trim()
    if (-not $t) { Send-Chat "The $page page is empty."; return }
    if ($t.Length -le 2000 -or $Full) {
        if ($t.Length -gt 4500) { $t = $t.Substring(0, 4500).TrimEnd() + "`n...(the rest is in the Notes tab)" }
        Send-Chat ("$page notes:`n" + $t); return
    }
    $sum = Invoke-SecClaude ("Summarize this note page for $U in plain text with no markdown: 5 to 10 short lines grouped by topic, newest items first. Keep names, numbers and dates exact.`n`nPAGE ""$page""`n$t") -Plain
    Send-Chat ("$page notes, summarized ($(@($t -split '\s+').Count) words).`n" + $sum.Trim())
}

# An entry is a paragraph, except that a "## " entry keeps its summary paragraph and its KEY POINTS / DECISIONS / ACTION ITEMS paragraphs.
function Split-NoteBlocks([string]$Text) {
    $Text = [regex]::Replace($Text, '(?m)^(# [^#\r\n][^\r\n]*)\r?\n(?=\S)', ('$1' + "`r`n`r`n"))
    $paras = @([regex]::Split($Text.Trim(), '(?:\r?\n){2,}') | Where-Object { $_.Trim() })
    $blocks = New-Object System.Collections.ArrayList
    $h = -1; $after = 0
    foreach ($p in $paras) {
        if ($p -match '^## ') { [void]$blocks.Add($p); $h = $blocks.Count - 1; $after = 0; continue }
        if ($h -ge 0 -and ($after -eq 0 -or $p -match '^(KEY POINTS|DECISIONS|ACTION ITEMS)\s*(\r?\n|$)')) {
            $blocks[$h] = [string]$blocks[$h] + "`r`n`r`n" + $p; $after++; continue
        }
        $h = -1; [void]$blocks.Add($p)
    }
    return @($blocks.ToArray())
}
function ConvertTo-NoteNorm([string]$S) { return (($S.ToLowerInvariant() -replace '\s+', ' ').Trim()) }
# Lines of the old text whose wording does not appear anywhere in the new text
function Get-RemovedLines([string]$Old, [string]$New) {
    $have = @{}
    foreach ($l in ($New -split '\r?\n')) { $n = ConvertTo-NoteNorm $l; if ($n) { $have[$n] = 1 } }
    $out = @()
    foreach ($l in ($Old -split '\r?\n')) { $n = ConvertTo-NoteNorm $l; if ($n -and -not $have.ContainsKey($n)) { $out += $l.Trim() } }
    return ,$out
}
# Numbers and dates in the old text that are not in the new text
function Get-MissingTokens([string]$Old, [string]$New) {
    $tok = { param($s) @([regex]::Matches($s, '\d[\d.,:/%-]*\d|\d') | ForEach-Object { $_.Value.TrimEnd('.', ',', ':', '-') } | Where-Object { $_ } | Select-Object -Unique) }
    $have = @{}; foreach ($t in (& $tok $New)) { $have[$t] = 1 }
    $miss = @(); foreach ($t in (& $tok $Old)) { if (-not $have.ContainsKey($t)) { $miss += $t } }
    return ,$miss
}
function Get-NoteReplyLines($Lines, [int]$Max = 8) {
    $l = @($Lines | Where-Object { $_ })
    $out = @($l | Select-Object -First $Max | ForEach-Object { "- $_" })
    if ($l.Count -gt $Max) { $out += "- ...and $($l.Count - $Max) more" }
    return ($out -join "`n")
}
function Backup-NotePage([string]$Page) {
    $f = Get-NoteFile $Page
    if (-not $f -or -not (Test-Path $f)) { return $null }
    $dir = Join-Path $NotesDir "_removed"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $dst = Join-Path $dir ("{0} {1}.md" -f $Page, (Get-Date).ToString("yyyy-MM-dd HHmmss"))
    Copy-Item $f $dst
    return (Split-Path $dst -Leaf)
}

# Proposes a tidied page; nothing is written until "yes"
function Invoke-NoteTidy([string]$Name) {
    $page = Find-NotePage $Name
    if (-not $page) { Send-Chat "I don't have a note page called ""$Name"". Pages: $((Get-NotePages) -join ', ')."; return }
    $orig = Read-NotePage $page
    if (-not $orig.Trim()) { Send-Chat "The $page page is empty."; return }
    if ($orig.Length -gt 60000) { Send-Chat "The $page page is too long to tidy in one go."; return }
    Send-Chat "Tidying $page. I'll show you what changes before anything is saved."
    $tp = @"
Reorganize $U's note page "$page". Rules:
- Keep every fact, number, date, name, link and decision. Do not add anything.
- Group entries by topic under short headings written as a single line starting with "# " (one hash).
- Merge duplicate or near-duplicate entries into one, keeping the most complete wording.
- Within an entry, say each fact once: drop a key point, decision or summary line that only restates another line of the same entry.
- Fix typos and shorthand only where the meaning is clear.
- Within each group, order entries newest first. An entry with no date keeps its original relative position.
- Keep each "## " entry's lines and its KEY POINTS, DECISIONS and ACTION ITEMS together.
Output only the revised page text. No commentary and no code fences.

PAGE TEXT
$orig
"@
    $new = Invoke-SecClaude $tp $Config.SecretaryThinkModel -Plain -TimeoutSec 180
    $new = (($new -replace '(?s)^\s*```[a-z]*\s*', '') -replace '(?s)\s*```\s*$', '').Trim() -replace '\r?\n', "`r`n"
    if (-not $new) { Send-Chat "Claude returned nothing for that, so I left $page as it is."; return }
    if ((ConvertTo-NoteNorm $new) -eq (ConvertTo-NoteNorm $orig)) { Send-Chat "The $page page is already tidy. Nothing to change."; return }
    $ob = @(Split-NoteBlocks $orig)
    $heads = @($new -split '\r?\n' | Where-Object { $_ -match '^# [^#]' })
    $nb = @(Split-NoteBlocks (($new -split '\r?\n' | Where-Object { $_ -notmatch '^# [^#]' }) -join "`r`n"))
    $merged = [math]::Max(0, $ob.Count - $nb.Count)
    $gone = Get-RemovedLines $orig $new
    $miss = Get-MissingTokens $orig $new
    $ol = ($orig -replace '\s', '').Length; $nl = ($new -replace '\s', '').Length
    $shrink = if ($ol) { 1 - ($nl / [double]$ol) } else { 0 }
    $sm = "Proposed for ""$page"": grouped $($nb.Count) entries under $($heads.Count) headings; merged $merged duplicates"
    if (-not $gone.Count -and $shrink -le 0.2) { $sm += "; no text removed." } else { $sm += "." }
    if ($shrink -gt 0.2) { $sm += "`nHeads up: the new version is $([int][math]::Round($shrink * 100))% shorter than the original." }
    if ($gone.Count) { $sm += "`nLines that are gone or reworded:`n" + (Get-NoteReplyLines $gone 10) }
    if ($miss.Count) { $sm += "`nNumbers or dates from the original that I can't find in the new version: " + (($miss | Select-Object -First 12) -join ', ') + "." }
    if ($heads.Count) { $sm += "`nHeadings: " + (($heads | ForEach-Object { $_.Substring(2).Trim() }) -join ', ') + "." }
    Set-Ask 'note_edit' @{ Page = $page; Orig = $orig; New = $new }
    Send-Chat ($sm + "`nApply it?")
}
Register-AskKind 'note_edit' {
    param($p, [string]$Text)
    $tt = $Text.Trim()
    $yes = $tt -match '^(?i)(yes|y|yep|yeah|ok|okay|sure|confirm|go ahead|do it|apply)[.!]*$'
    $no  = $tt -match '^(?i)(no|n|nope|cancel|never ?mind|leave it)[.!]*$'
    if (-not $yes -and -not $no) { return $false }
    Clear-Ask
    if ($no) { Send-Chat "OK, your notes are unchanged."; return $true }
    if ((Read-NotePage $p.Page) -cne [string]$p.Orig) { Send-Chat "The $($p.Page) page changed after I proposed that, so I left it."; return $true }
    $b = Backup-NotePage $p.Page
    Write-NotePage $p.Page ([string]$p.New)
    Send-Chat ("Done." + $(if ($b) { " Previous version saved as: $b." } else { "" }))
    return $true
} {
    param($p, [string]$Why)
    if ($Why -eq 'expired') { Send-Chat "No answer on the proposed tidy of $($p.Page), so I dropped it. Nothing was changed." }
    else { Send-Chat "(I dropped the proposed tidy of $($p.Page).)" }
}
