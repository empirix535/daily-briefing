# ================================================================== assistant/claude.ps1
# Claude through the Claude Code CLI on the subscription. No tools and no MCP servers on these calls.
# Invoke-SecConnector (below) is the one read-only path to Outlook through the Microsoft 365 connector.

# Every call counts toward the daily cap; the router and scans check the cap before calling.
function Add-CallCount {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($state.CallsDay -ne $today) { $state.CallsDay = $today; $state.Calls = 0 }
    $state.Calls = [int]$state.Calls + 1; Save-State
}
function Test-CallBudget {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($state.CallsDay -ne $today) { return $true }
    return ([int]$state.Calls -lt [int]$Config.SecretaryMaxCallsPerDay)
}

# One CLI call. $ToolArgs differs between the plain call (no tools, no MCP) and the connector call (read-only allowlist).
function Invoke-ClaudeCli([string]$Prompt, [string]$Model, [string]$Sys, [string]$ToolArgs, [bool]$McpOn, [int]$TimeoutSec) {
    $exe = Resolve-ClaudeExe
    if (-not $exe) { throw "Claude Code CLI not found." }
    $cliArgs = "-p --output-format json --model $Model $ToolArgs --system-prompt `"$Sys`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -like "*.exe") { $psi.FileName = $exe; $psi.Arguments = $cliArgs }
    else { $psi.FileName = "cmd.exe"; $psi.Arguments = "/d /s /c `"`"$exe`" $cliArgs`"" }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = $WorkDir
    [void]$psi.EnvironmentVariables.Remove("ANTHROPIC_API_KEY")   # stay on the subscription
    $psi.EnvironmentVariables["MAX_THINKING_TOKENS"] = "0"
    $psi.EnvironmentVariables["ENABLE_CLAUDEAI_MCP_SERVERS"] = $(if ($McpOn) { "true" } else { "false" })

    # A slow call (connector or the think model) made while answering Wael's message gets one short "working" line first.
    if ($script:AckPending -and ($McpOn -or $Model -ne $Config.SecretaryModel)) {
        $script:AckPending = $false
        try { Send-Chat (Get-Random -InputObject @("On it.", "One sec, looking.", "Checking now.", "Give me a minute on this one.")) } catch { }
    }

    Add-CallCount
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $bytes = $Utf8.GetBytes($Prompt)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) { try { $proc.Kill() } catch {}; throw "Claude timed out." }
    $proc.WaitForExit()
    $o = $null; try { $o = $outTask.Result | ConvertFrom-Json } catch {}
    if (-not $o) { throw "Claude returned no JSON. $($errTask.Result)" }
    if ($o.is_error -or $proc.ExitCode -ne 0) { throw "Claude error: $($o.result)" }
    $u = $o.usage
    Write-Log ("Claude ({0}{1}): {2} tokens in, {3} out." -f $Model, $(if ($McpOn) { ", connector" } else { "" }), ([int]$u.input_tokens + [int]$u.cache_creation_input_tokens + [int]$u.cache_read_input_tokens), [int]$u.output_tokens)
    return [string]$o.result
}

# No tools, no MCP servers.
function Invoke-SecClaude([string]$Prompt, [string]$Model = $Config.SecretaryModel, [switch]$Plain, [int]$TimeoutSec = 120) {
    $sys = if ($Plain) { "You are an administrative assistant. Follow the instructions in the user message exactly." } else { "You are an administrative assistant. Follow the instructions in the user message exactly and answer with JSON only." }
    return (Invoke-ClaudeCli $Prompt $Model $sys "--tools `"`" --strict-mcp-config" $false $TimeoutSec)
}

# The Microsoft 365 connector, read tools only. Built-in tools stay unlisted, so the headless run cannot use them,
# and any write tool the connector might gain is not on the list either. Returns the model's text.
$ConnectorToolNames = @('get_me', 'outlook_email_search', 'outlook_calendar_search', 'read_resource', 'find_meeting_availability')
function Invoke-SecConnector([string]$Prompt, [string]$Model = $Config.SecretaryThinkModel, [switch]$Plain, [int]$TimeoutSec = 300) {
    $allow = ($ConnectorToolNames | ForEach-Object { "mcp__claude_ai_Microsoft_365__$_" }) -join ","
    $sys = if ($Plain) { "You are an administrative assistant with read-only access to the user's Microsoft 365 data. Follow the instructions in the user message exactly." } else { "You are an administrative assistant with read-only access to the user's Microsoft 365 data. Follow the instructions in the user message exactly. After using the tools, answer with JSON only." }
    return (Invoke-ClaudeCli $Prompt $Model $sys "--allowedTools `"$allow`"" $true $TimeoutSec)
}

function ConvertFrom-ModelJson([string]$Text) {
    $t = $Text -replace '(?s)^\s*```(?:json)?\s*', '' -replace '(?s)\s*```\s*$', ''
    $s = $t.IndexOf('{'); $e = $t.LastIndexOf('}')
    if ($s -ge 0 -and $e -gt $s) { $t = $t.Substring($s, $e - $s + 1) }
    return (ConvertFrom-Json -InputObject $t)
}
