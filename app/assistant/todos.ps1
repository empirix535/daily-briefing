# ================================================================== assistant/todos.ps1
# To-dos in data\todo.json (the dashboard's To-do tab): one adder, check off, due dates, the due-date question, agendas.

# Flattens nested arrays into the list. This also repairs files where an earlier bug nested the old list inside an array.
function Add-TodoFlat($List, $X) {
    if ($null -eq $X) { return }
    if ($X -is [System.Collections.IList]) { foreach ($y in $X) { Add-TodoFlat $List $y }; return }
    if ($X.PSObject.Properties.Name -contains 'text') { [void]$List.Add($X) }
}
# Reads todo.json. Throws if the file can't be parsed, so nothing gets written over it.
function Get-Todos {
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path $TodoPath)) { return ,$list }
    $raw = [System.IO.File]::ReadAllText($TodoPath, $Utf8).Trim()
    if (-not $raw -or $raw -eq '""') { return ,$list }
    $data = ConvertFrom-Json -InputObject $raw
    if ($data -is [string]) {
        if (-not $data.Trim()) { return ,$list }
        try { $data = ConvertFrom-Json -InputObject $data }
        catch { $data = [pscustomobject]@{ id = (New-TodoId); text = $data.Trim(); checked = $false; children = @() } }
    }
    Add-TodoFlat $list $data
    return ,$list
}
function Save-Todos($Todos) { [System.IO.File]::WriteAllText($TodoPath, (ConvertTo-Json -InputObject @($Todos) -Depth 10), $Utf8) }
function New-TodoId { return ([DateTimeOffset]::Now.ToUnixTimeMilliseconds().ToString() + (Get-Random -Minimum 100 -Maximum 999)) }
function Set-TodoField($X, [string]$Name, $Value) {
    if ($X.PSObject.Properties.Name -contains $Name) { $X.$Name = $Value } else { $X | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# The one adder. Each item: text, and optionally parent (existing top-level text), owner, due / due_said, mailLink.
# An item goes under its parent if that exists, else under $DefaultParent (created if needed), else at the top level.
# Returns the confirmation lines. Items without a due date are remembered for the due-date question.
$script:LastTodoAdds = @()
function Add-TodoItems($Items, [string]$DefaultParent = "") {
    $todos = Get-Todos
    $script:LastTodoAdds = @()
    $out = @()
    foreach ($it in @($Items | Where-Object { $_ -and $_.text } | Select-Object -First 15)) {
        $text = [string]$it.text
        if ([string]$it.owner -and [string]$it.owner -notmatch $MeRx -and $text -notmatch [regex]::Escape([string]$it.owner)) { $text = "$($it.owner) to $text" }
        $parent = $null
        if ([string]$it.parent) { $parent = @($todos | Where-Object { ([string]$_.text) -ieq [string]$it.parent }) | Select-Object -First 1 }
        if (-not $parent -and $DefaultParent) {
            $parent = @($todos | Where-Object { ([string]$_.text) -ieq $DefaultParent }) | Select-Object -First 1
            if (-not $parent) { $parent = [pscustomobject]@{ id = (New-TodoId); text = $DefaultParent; checked = $false; children = @() }; [void]$todos.Add($parent) }
        }
        $item = [pscustomobject]@{ id = (New-TodoId); text = $text; checked = $false }
        $due = Resolve-TodoDueField $it
        if ($due) { Set-TodoField $item 'due' $due }
        if ([string]$it.mailLink) { Set-TodoField $item 'mailLink' ([string]$it.mailLink) }
        $script:LastTodoAdds += @(@{ id = $item.id; text = $text; due = $due })
        if ($parent) {
            if (-not ($parent.PSObject.Properties.Name -contains 'children')) { Set-TodoField $parent 'children' @() }
            $parent.children = @(@($parent.children) + $item)
            $out += "$text (under $($parent.text))" + (Format-TodoDue $item)
        } else {
            Set-TodoField $item 'children' @()
            [void]$todos.Add($item)
            $out += $text + (Format-TodoDue $item)
        }
    }
    if ($out) { Save-Todos $todos }
    return $out
}

function Complete-TodoItems($Texts) {
    $todos = Get-Todos
    $done = @()
    foreach ($t in @($Texts | Where-Object { $_ })) {
        $want = ([string]$t).Trim()
        foreach ($top in $todos) {
            if (-not $top.checked -and ([string]$top.text) -ieq $want) { $top.checked = $true; $done += [string]$top.text; break }
            $kid = @($top.children | Where-Object { $_ -and -not $_.checked -and ([string]$_.text) -ieq $want }) | Select-Object -First 1
            if ($kid) { $kid.checked = $true; $done += [string]$kid.text; break }
        }
    }
    if ($done) { Save-Todos $todos }
    return $done
}

# ------------------------------------------------------------------ due dates
# Deletes to-dos by exact text (any state). A top-level item with open sub-items is skipped and reported, never removed with them.
$script:LastTodoSkips = @()
function Remove-TodoItems($Texts) {
    $todos = Get-Todos
    $gone = @(); $script:LastTodoSkips = @()
    foreach ($t in @($Texts | Where-Object { $_ })) {
        $want = ([string]$t).Trim()
        $top = @($todos | Where-Object { ([string]$_.text) -ieq $want }) | Select-Object -First 1
        if ($top) {
            $open = @($top.children | Where-Object { $_ -and -not $_.checked }).Count
            if ($open) { $script:LastTodoSkips += "$($top.text) (has $open open sub-item$(if ($open -ne 1) { 's' }))"; continue }
            [void]$todos.Remove($top); $gone += [string]$top.text; continue
        }
        foreach ($p in $todos) {
            $kid = @($p.children | Where-Object { $_ -and ([string]$_.text) -ieq $want }) | Select-Object -First 1
            if ($kid) { $p.children = @(@($p.children) | Where-Object { $_ -and $_.id -ne $kid.id }); $gone += [string]$kid.text; break }
        }
    }
    if ($gone) { Save-Todos $todos }
    return $gone
}

function Format-TodoDue($Item) {
    $d = [string]$Item.due
    if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { return "" }
    return " (due " + ([datetime]$d).ToString("ddd MMM d", $Inv) + ")"
}
# "today", "tomorrow", "fri", "next week", "end of month", "in 3 days", "oct 20". Returns yyyy-MM-dd, "none" for no date, or $null if not understood.
function ConvertTo-DueDate([string]$Text) {
    $t = ($Text.Trim().ToLowerInvariant() -replace '[.!?]+$', '' -replace '^(by|on|for|due|before|until|sometime|it''s|its|maybe)\s+', '').Trim()
    $today = (Get-Date).Date
    $fri = { param($d) $d.AddDays((5 - [int]$d.DayOfWeek + 7) % 7) }
    if ($t -match '^(no date|none|no due date|skip|whenever|no rush|no deadline|not sure|later|someday|n/a)$') { return "none" }
    if ($t -match '^(today|tonight|asap|now|cob|eod|end of (the )?day|this afternoon|this morning)$') { return $today.ToString('yyyy-MM-dd') }
    if ($t -match '^(tomorrow|tmrw|tmr|tomorrow (morning|afternoon))$') { return $today.AddDays(1).ToString('yyyy-MM-dd') }
    if ($t -match '^(this week|end of (the )?week|eow|this friday|friday this week)$') { return (& $fri $today).ToString('yyyy-MM-dd') }
    if ($t -match '^(next week|end of next week|sometime next week)$') { $f = & $fri $today; if ($today.DayOfWeek -in @('Saturday', 'Sunday')) { return $f.ToString('yyyy-MM-dd') }; return $f.AddDays(7).ToString('yyyy-MM-dd') }
    if ($t -match '^(end of (the )?month|eom|this month)$') {
        $d = $today.AddDays(1 - $today.Day).AddMonths(1).AddDays(-1); while ($d.DayOfWeek -in @('Saturday', 'Sunday')) { $d = $d.AddDays(-1) }; return $d.ToString('yyyy-MM-dd')
    }
    if ($t -match '^(next month|end of next month)$') {
        $m = $today.AddDays(1 - $today.Day).AddMonths(1); $d = $m.AddMonths(1).AddDays(-1); while ($d.DayOfWeek -in @('Saturday', 'Sunday')) { $d = $d.AddDays(-1) }; return $d.ToString('yyyy-MM-dd')
    }
    if ($t -match '^in (\d+|a|one|two|three) (day|days|week|weeks)$') {
        $n = switch ($Matches[1]) { 'a' { 1 } 'one' { 1 } 'two' { 2 } 'three' { 3 } default { [int]$Matches[1] } }
        $mult = if ($Matches[2] -like 'week*') { 7 } else { 1 }
        return $today.AddDays($n * $mult).ToString('yyyy-MM-dd')
    }
    $days = @{ mon = 1; tue = 2; tues = 2; wed = 3; thu = 4; thur = 4; thurs = 4; fri = 5; sat = 6; sun = 0 }
    if ($t -match '^(this |next )?(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*$') {
        $want = [int]$days[$Matches[2]]
        $d = $today.AddDays(($want - [int]$today.DayOfWeek + 7) % 7)
        if ($d -eq $today -and $Matches[1] -ne 'this ') { $d = $d.AddDays(7) }
        if ($Matches[1] -eq 'next ') { $mon = $today.AddDays(-(([int]$today.DayOfWeek + 6) % 7)).AddDays(7); $d = $mon.AddDays(($want + 6) % 7) }
        return $d.ToString('yyyy-MM-dd')
    }
    $dt = [datetime]::MinValue
    foreach ($f in @('MMM d', 'MMMM d', 'MMM d yyyy', 'MMMM d yyyy', 'M/d', 'M/d/yyyy', 'yyyy-MM-dd', 'd MMM', 'd MMMM')) {
        if ([datetime]::TryParseExact(($t -replace '(\d)(st|nd|rd|th)\b', '$1' -replace ',', ''), $f, $Inv, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$dt)) {
            if ($f -notmatch 'yyyy' -and $dt.Date -lt $today) { $dt = $dt.AddYears(1) }
            return $dt.ToString('yyyy-MM-dd')
        }
    }
    return $null
}
# The model's own words for the due date win over its date arithmetic, which can be off; its date is the fallback.
function Resolve-TodoDueField($It) {
    $said = [string]$It.due_said
    if ($said) {
        $d = ConvertTo-DueDate $said
        if ($d -eq 'none') { return "" }
        if ($d) {
            if ([string]$It.due -and [string]$It.due -ne $d) { Write-Log "Due date: model said $($It.due) for ""$said""; using $d." }
            return $d
        }
    }
    if ([string]$It.due -match '^\d{4}-\d{2}-\d{2}$') { return [string]$It.due }
    return ""
}
# Visits every open to-do (top level and children). $Fn gets the item and returns $true when it changed it.
function Update-Todos([scriptblock]$Fn) {
    $todos = Get-Todos
    $hits = @()
    foreach ($top in $todos) {
        foreach ($x in @(@($top) + @($top.children | Where-Object { $_ }))) { if (& $Fn $x) { $hits += $x } }
    }
    if ($hits) { Save-Todos $todos }
    return $hits
}
# set_due from the router: change the due date of existing open to-dos, matched by exact text
function Set-TodoDueByText($Items) {
    $done = @()
    foreach ($it in @($Items | Where-Object { $_ -and [string]$_.text })) {
        $want = ([string]$it.text).Trim(); $due = Resolve-TodoDueField $it; $st = @{ found = $false }
        $hit = @(Update-Todos {
            param($x)
            if ($st.found -or $x.checked -or ([string]$x.text) -ine $want) { return $false }
            $st.found = $true
            if ($due) { Set-TodoField $x 'due' $due } elseif ($x.PSObject.Properties.Name -contains 'due') { $x.PSObject.Properties.Remove('due') }
            return $true
        })
        foreach ($h in $hit) { $done += ([string]$h.text + $(if ($due) { Format-TodoDue $h } else { " (no date)" })) }
    }
    return $done
}
# $Map: id -> yyyy-MM-dd
function Set-TodoDue($Map) {
    $hit = @(Update-Todos { param($x) if (-not $Map.ContainsKey([string]$x.id)) { return $false }; Set-TodoField $x 'due' $Map[[string]$x.id]; return $true })
    return @($hit | ForEach-Object { [string]$_.text + (Format-TodoDue $_) })
}

# ------------------------------------------------------------------ the due-date question after a chat add
# Returns the question to append to the confirmation, or "".
function Request-TodoDue {
    $items = @($script:LastTodoAdds | Where-Object { $_ -and -not ([string]$_.due) })
    $script:LastTodoAdds = @()
    if (-not $items.Count) { return "" }
    Set-Ask 'todo_due' @{ Items = $items }
    if ($items.Count -eq 1) { return "When do you want to get this done? Today, tomorrow, Friday, next week, a date, or no date." }
    return "When do you want to get these done? Today, tomorrow, Friday, next week, a date, or no date. One answer covers all, or go item by item (""1 today, 2 next week"")."
}
Register-AskKind 'todo_due' {
    param($p, [string]$Text)
    # Leave yes/no and bare numbers to other handlers
    if ($Text.Trim() -match '^(?i)(\d+|yes|y|no|n|ok|okay|cancel)[.!]*$') { return $false }
    $items = @($p.Items)
    $map = @{}
    $d = ConvertTo-DueDate $Text
    if ($d -eq 'none') { Clear-Ask; Send-Chat "OK, no date."; return $true }
    if ($d) { foreach ($i in $items) { $map[[string]$i.id] = $d } }
    elseif (@($Text.Trim() -split '\s+').Count -le 8) {
        # Mixed answers ("1 today, 2 next week") or phrasing the code doesn't know: ask Haiku with the date table
        $list = @(); $n = 0; foreach ($i in $items) { $n++; $list += "$n. $($i.text)" }
        $prompt = @"
$U was asked when these to-dos are due and answered: "$Text"
$($list -join "`n")
$(Get-DateTable)
Rules: "next week" means Friday of next week; "this week" means this Friday; "end of month" means its last weekday; a weekday name means its next occurrence. If the answer is not about when the to-dos are due, set understood to false.
Answer with one JSON object and nothing else:
{"understood": true, "dues": [{"n": 1, "due": "YYYY-MM-DD, or empty for no date"}]}
"@
        $r = $null; try { $r = ConvertFrom-ModelJson (Invoke-SecClaude $prompt) } catch { }
        if (-not $r -or -not $r.understood) { return $false }
        foreach ($x in @($r.dues)) {
            $k = [int]$x.n
            if ($k -ge 1 -and $k -le $items.Count -and [string]$x.due -match '^\d{4}-\d{2}-\d{2}$') { $map[[string]$items[$k - 1].id] = [string]$x.due }
        }
        if (-not $map.Count) { Clear-Ask; Send-Chat "OK, no date."; return $true }
    } else { return $false }
    Clear-Ask
    $done = @(Set-TodoDue $map)
    if (-not $done.Count) { Send-Chat "I couldn't find that to-do anymore, so I didn't set a date."; return $true }
    Send-Chat ("Set:`n" + (($done | ForEach-Object { "- $_" }) -join "`n"))
    return $true
} $null

# ------------------------------------------------------------------ lists
# Dated open to-dos. Mode today: due today plus overdue. Mode week: today plus the rest of the week (on Fri-Sun, through next Friday).
function Get-TodoAgenda([datetime]$Day, [string]$Mode = "today") {
    $all = @(); try { $all = Get-Todos } catch { return "I couldn't read your to-do list: $($_.Exception.Message)" }
    $rows = @(); $undated = 0
    foreach ($top in $all) {
        if ($top.checked) { continue }
        $kids = @($top.children | Where-Object { $_ -and -not $_.checked })
        foreach ($x in @(@($top) + $kids)) {
            $d = [string]$x.due
            if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { if ($x -ne $top -or -not $kids.Count) { $undated++ }; continue }
            $ctx = if ($x -ne $top) { " (" + [string]$top.text + ")" } else { "" }
            $rows += [pscustomobject]@{ Due = [datetime]$d; Text = [string]$x.text + $ctx }
        }
    }
    $Day = $Day.Date
    $late = @($rows | Where-Object { $_.Due -lt $Day } | Sort-Object Due)
    $now = @($rows | Where-Object { $_.Due -eq $Day })
    $out = @()
    $label = if ($Day -eq (Get-Date).Date) { "today" } else { $Day.ToString("dddd", $Inv) }
    if ($now.Count -or $late.Count) {
        $out += "To-dos for ${label}:"
        $out += @($now | ForEach-Object { "- $($_.Text)" })
        $out += @($late | ForEach-Object { "- $($_.Text) (overdue, was due $($_.Due.ToString('ddd MMM d', $Inv)))" })
    } else { $out += "No to-dos due $label." }
    if ($Mode -eq 'week') {
        $end = $Day.AddDays((5 - [int]$Day.DayOfWeek + 7) % 7)
        if ($end -le $Day) { $end = $end.AddDays(7) }
        $wk = @($rows | Where-Object { $_.Due -gt $Day -and $_.Due -le $end } | Sort-Object Due)
        if ($wk.Count) {
            $out += ""
            $nextWk = ($end - $Day).TotalDays -gt 6 -or $Day.DayOfWeek -in @('Friday', 'Saturday', 'Sunday')
            $out += $(if ($nextWk) { "Coming up through next Friday:" } else { "Later this week:" })
            $out += @($wk | ForEach-Object { "- $($_.Due.ToString($(if ($nextWk) { 'ddd MMM d' } else { 'ddd' }), $Inv)): $($_.Text)" })
        } else { $out += "Nothing else due through $($end.ToString('ddd MMM d', $Inv))." }
        if ($undated) { $out += "$undated open to-do$(if ($undated -ne 1) { 's have' } else { ' has' }) no date." }
    }
    return ($out -join "`n")
}

# Open to-dos as text: "Project" with its open sub-items indented
function Get-OpenTodoText {
    $lines = @()
    $all = @(); try { $all = Get-Todos } catch { Write-Log "Could not read todo.json: $($_.Exception.Message)" "WARN" }
    foreach ($top in $all) {
        if ($top.checked) { continue }
        $lines += "- " + [string]$top.text + (Format-TodoDue $top)
        foreach ($k in @($top.children | Where-Object { $_ -and -not $_.checked })) { $lines += "    - " + [string]$k.text + (Format-TodoDue $k) }
    }
    return ($lines -join "`n")
}
