# Daily Briefing: shared helpers (loaded into the HTTP thread and the assistant thread; both get $sync)
# Keep this file ASCII-only.

$Config  = $sync.Config
$Root    = $sync.Root
$Utf8    = New-Object System.Text.UTF8Encoding($false)
$Inv     = [System.Globalization.CultureInfo]::InvariantCulture
$TodoPath = Join-Path $Root "todo.json"
if (-not $LogTag) { $LogTag = "" }

function Write-Log([string]$Msg, [string]$Level = "INFO") {
    $line = "{0} [{1}] {2}{3}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $LogTag, $Msg
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.IO.File]::AppendAllText($sync.LogPath, $line, [System.Text.Encoding]::UTF8); return }
        catch { Start-Sleep -Milliseconds 50 }
    }
}

# ------------------------------------------------------------------ JSON files
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path, $Utf8))) }
    catch { Write-Log "Could not read $Path : $($_.Exception.Message)" "WARN"; return $null }
}
function Write-JsonFile([string]$Path, $Obj) {
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Obj -Depth 8), $Utf8)
}
function ConvertTo-Hash($o) {
    $h = @{}
    if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# ------------------------------------------------------------------ Notes tab store: one .md file per page in data\notes
$NotesDir  = Join-Path $Root "notes"
$NotesPath = Join-Path $Root "notes.md"   # the old single-file notes; moved to notes\General.md on first use
function ConvertTo-NoteName([string]$Name) {
    $n = ([string]$Name -replace '[\\/:*?"<>|\r\n\t]', ' ') -replace '\s+', ' '
    $n = $n.Trim().Trim('.').Trim().TrimStart('_').Trim()
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40).Trim() }
    if ($n -match '^(con|prn|aux|nul|com\d|lpt\d)$') { $n = "$n notes" }
    return $n
}
function Initialize-Notes {
    if (-not (Test-Path $NotesDir)) { New-Item -ItemType Directory -Path $NotesDir -Force | Out-Null }
    $gen = Join-Path $NotesDir "General.md"
    if ((Test-Path $NotesPath) -and -not (Test-Path $gen)) { Move-Item $NotesPath $gen }
    if (-not (Test-Path $gen)) { [System.IO.File]::WriteAllText($gen, "", $Utf8) }
}
function Get-NotePages {
    Initialize-Notes
    $names = @(Get-ChildItem $NotesDir -Filter *.md -File | ForEach-Object { $_.BaseName } | Where-Object { $_ -ne "General" } | Sort-Object)
    return @("General") + $names
}
function Get-NoteFile([string]$Name) {
    $n = ConvertTo-NoteName $Name
    if (-not $n) { return $null }
    $existing = Get-ChildItem $NotesDir -Filter *.md -File | Where-Object { $_.BaseName -ieq $n } | Select-Object -First 1
    if ($existing) { return $existing.FullName }
    return (Join-Path $NotesDir "$n.md")
}
function Read-NotePage([string]$Name) {
    Initialize-Notes
    $f = Get-NoteFile $Name
    if ($f -and (Test-Path $f)) { return [System.IO.File]::ReadAllText($f) }
    return ""
}
function Write-NotePage([string]$Name, [string]$Text) {
    Initialize-Notes
    $f = Get-NoteFile $Name
    if (-not $f) { throw "That page name is not valid." }
    [System.IO.File]::WriteAllText($f, $Text, $Utf8)
}
# Adds an entry at the top of a page (creates the page if needed)
function Add-NoteEntry([string]$Page, [string]$Text) {
    $old = (Read-NotePage $Page).TrimEnd()
    Write-NotePage $Page ($Text.Trim() + $(if ($old) { "`r`n`r`n" + $old } else { "" }))
}
function New-NotePage([string]$Name) {
    Initialize-Notes
    $f = Get-NoteFile $Name
    if (-not $f) { return $null }
    if (-not (Test-Path $f)) { [System.IO.File]::WriteAllText($f, "", $Utf8) }
    return [System.IO.Path]::GetFileNameWithoutExtension($f)
}
# Changes whenever any page is edited, added or removed (the dashboard polls this)
function Get-NotesStamp {
    try {
        Initialize-Notes
        $max = 0L; $files = @(Get-ChildItem $NotesDir -Filter *.md -File)
        foreach ($f in $files) { if ($f.LastWriteTimeUtc.Ticks -gt $max) { $max = $f.LastWriteTimeUtc.Ticks } }
        return "$max|$($files.Count)"
    } catch { return "" }
}

# ------------------------------------------------------------------ misc
# Explicit date list for prompts, so the model never has to work out weekdays itself
function Get-DateTable([int]$Days = 21) {
    $d = (Get-Date).Date
    return ((0..$Days | ForEach-Object {
        $x = $d.AddDays($_)
        "{0} = {1}{2}" -f $x.ToString('ddd MMM d', $Inv), $x.ToString('yyyy-MM-dd'), $(if ($_ -eq 0) { ' (today)' } elseif ($_ -eq 1) { ' (tomorrow)' } else { '' })
    }) -join "`n")
}

function Resolve-ClaudeExe {
    if ($Config.ClaudePath -and (Test-Path $Config.ClaudePath)) { return $Config.ClaudePath }
    foreach ($name in @("claude.exe", "claude.cmd")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Path }
    }
    $native = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if (Test-Path $native) { return $native }
    return $null
}

function Write-JsonResponse($Response, [string]$Json) {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Response.ContentType = "application/json"
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.Close()
}

# ------------------------------------------------------------------ Notes editor (dashboard): non-blocking Claude calls
# The HTTP loop must not block for the length of a model call, so the call starts here and the dashboard polls for it.
# No tools and no MCP servers on this call; the model only sees the text the dashboard sends.
$global:ClaudeJobs = @{}
function Start-ClaudeJob([string]$Prompt, [string]$Model) {
    $exe = Resolve-ClaudeExe
    if (-not $exe) { throw "Claude Code CLI not found." }
    $work = Join-Path $env:TEMP "briefing-claude"
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work | Out-Null }
    $sys = "You are a careful writing assistant. Follow the instructions in the user message exactly and answer with JSON only."
    $cliArgs = "-p --output-format json --model $Model --tools `"`" --strict-mcp-config --system-prompt `"$sys`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -like "*.exe") { $psi.FileName = $exe; $psi.Arguments = $cliArgs }
    else { $psi.FileName = "cmd.exe"; $psi.Arguments = "/d /s /c `"`"$exe`" $cliArgs`"" }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = $work
    [void]$psi.EnvironmentVariables.Remove("ANTHROPIC_API_KEY")   # stay on the subscription
    $psi.EnvironmentVariables["MAX_THINKING_TOKENS"] = "0"
    $psi.EnvironmentVariables["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
    $proc = [System.Diagnostics.Process]::Start($psi)
    $job = @{ Proc = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $proc.StandardError.ReadToEndAsync(); Started = Get-Date }
    $bytes = $Utf8.GetBytes($Prompt)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    foreach ($k in @($global:ClaudeJobs.Keys)) { if (((Get-Date) - $global:ClaudeJobs[$k].Started).TotalMinutes -gt 10) { $global:ClaudeJobs.Remove($k) } }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $global:ClaudeJobs[$id] = $job
    return $id
}

# @{ status = pending | done | error; text; message }
function Get-ClaudeJob([string]$Id) {
    $job = $global:ClaudeJobs[$Id]
    if (-not $job) { return @{ status = "error"; message = "That request expired. Ask again." } }
    if (-not $job.Proc.HasExited) {
        if (((Get-Date) - $job.Started).TotalSeconds -gt 170) {
            try { $job.Proc.Kill() } catch {}
            $global:ClaudeJobs.Remove($Id)
            return @{ status = "error"; message = "Claude took too long. Try a shorter selection." }
        }
        return @{ status = "pending" }
    }
    $job.Proc.WaitForExit()
    $global:ClaudeJobs.Remove($Id)
    $o = $null; try { $o = $job.Out.Result | ConvertFrom-Json } catch {}
    if (-not $o) { return @{ status = "error"; message = "Claude returned nothing. $($job.Err.Result)".Trim() } }
    if ($o.is_error -or $job.Proc.ExitCode -ne 0) { return @{ status = "error"; message = "Claude error: $($o.result)" } }
    return @{ status = "done"; text = [string]$o.result }
}

# The prompt for the Notes editor. $Req carries Page, Text, Selection, Message, History (role, text).
function New-NotesAiPrompt($Req, [string]$UserName) {
    $page = [string]$Req.Text
    if ($page.Length -gt 60000) { $page = $page.Substring(0, 60000) + "`n[page truncated]" }
    $sel = [string]$Req.Selection
    $hist = @(@($Req.History) | Where-Object { $_ } | Select-Object -Last 6 | ForEach-Object {
        $t = [string]$_.text; if ($t.Length -gt 1500) { $t = $t.Substring(0, 1500) + "..." }
        "$([string]$_.role): $t" }) -join "`n"
    if (-not $hist) { $hist = "(none)" }
    $selBlock = if ($sel) { "SELECTED TEXT (the part $UserName highlighted)`n<<<`n$sel`n>>>" } else { "SELECTED TEXT: (nothing selected)" }
    return @"
You are the editor inside $UserName's Notes tab. $UserName is reading his note page and talks to you about it. Today is $((Get-Date).ToString("dddd, MMMM d, yyyy", [System.Globalization.CultureInfo]::InvariantCulture)).
Page: "$([string]$Req.Page)"

FULL PAGE
<<<
$page
>>>

$selBlock

RECENT CONVERSATION
$hist

$UserName'S MESSAGE
$([string]$Req.Message)

Rules
- Questions, brainstorming, critique, and summaries get a reply and no edit. Be concrete and brief; no markdown headers.
- Change the page only when $UserName asks for a change ("tighten", "rewrite", "add", "fix", "turn into"). Then put the new text in "edit".
- Keep $UserName's own wording wherever he did not ask for a rewrite. Match his voice: plain, direct, no em dashes, no filler, no intensifiers.
- With text selected, an edit applies to the selection (mode replace_selection) unless he says to add something (insert_after_selection). With nothing selected, a request to change existing text applies to the whole page (replace_page), but if the page is longer than about 6000 characters, ask him to select the part instead and make no edit. New material with nothing selected goes at the end (append).
- "edit.text" is the final text exactly as it should appear, with no commentary and no quotation marks around it. Never include the surrounding unchanged text for replace_selection or insert_after_selection.
- "reply" says in one or two sentences what you did or answers the question. Never claim an edit that is not in "edit".

Answer with one JSON object and nothing else:
{"reply": "text for $UserName", "edit": null}
or
{"reply": "what you changed", "edit": {"mode": "replace_selection|insert_after_selection|replace_page|append", "text": "..."}}
"@
}

# Copies a page to data\notes\_removed with a timestamp (used before the dashboard applies an editor change)
function Backup-NotePage([string]$Page) {
    $src = Get-NoteFile $Page
    if (-not $src -or -not (Test-Path $src)) { return }
    $gone = Join-Path $NotesDir "_removed"
    if (-not (Test-Path $gone)) { New-Item -ItemType Directory -Path $gone | Out-Null }
    Copy-Item $src (Join-Path $gone ("{0} {1} before-edit.md" -f $Page, (Get-Date).ToString("yyyyMMdd-HHmmss"))) -Force
}
