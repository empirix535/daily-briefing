# ================================================================== assistant/teams.ps1
# Teams transport (lifted unchanged from v34): the assistant's own Chrome window, read the self-chat, post into it.

function Get-TeamsTarget {
    try { $list = Invoke-RestMethod "http://localhost:$Port/json" -TimeoutSec 3 } catch { return $null }
    return @($list | Where-Object { $_.type -eq 'page' -and $_.url -match 'teams\.cloud\.microsoft|teams\.microsoft\.com|login\.microsoftonline' }) | Select-Object -First 1
}

# Hide or show the assistant's Chrome window (Win32). Only touches the Chrome started with the assistant's profile.
Add-Type -Language CSharp -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class SecWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static bool Minimized(IntPtr h) { return IsIconic(h); }
    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top }; }
    // Move, size, and keep above other windows (or release); never takes focus
    public static void Place(IntPtr h, int x, int y, int w, int ht, bool top) { SetWindowPos(h, new IntPtr(top ? -1 : -2), x, y, w, ht, 0x10 | 0x40); }
    public static void Top(IntPtr h, bool top) { SetWindowPos(h, new IntPtr(top ? -1 : -2), 0, 0, 0, 0, 0x1 | 0x2 | 0x10); }
    public static IntPtr[] Find(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && GetWindow(h, 4) == IntPtr.Zero && GetWindowTextLength(h) > 0) {
                var sb = new StringBuilder(256); GetClassName(h, sb, 256);
                if (sb.ToString() == "Chrome_WidgetWin_1") list.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
"@

$ProfileDir = Join-Path $env:LOCALAPPDATA "DailyBriefing\teams-profile"
function Get-TeamsChromePid {
    $p = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" -and $_.CommandLine -notlike "*--type=*" } |
        Select-Object -First 1
    if ($p) { return [uint32]$p.ProcessId } else { return $null }
}
# $true shows and focuses the window; $false hides it (no taskbar button)
function Set-TeamsWindow([bool]$Show) {
    $procId = Get-TeamsChromePid
    if (-not $procId) { return }
    foreach ($h in [SecWin]::Find($procId)) {
        $vis = [SecWin]::IsWindowVisible($h)
        if ($Show -and -not $vis) { [void][SecWin]::ShowWindow($h, 9); [void][SecWin]::SetForegroundWindow($h) }
        elseif (-not $Show -and $vis) { [void][SecWin]::ShowWindow($h, 0) }
    }
}

# Pinned chat window: the same Chrome window, small, on top of other windows, and back where you left it.
# Size and place it once by hand; the assistant remembers it (state.ChatRect) and restores it after a restart.
try { Add-Type -AssemblyName System.Windows.Forms } catch {}
$script:PinHandle = [IntPtr]::Zero
$script:PinForce  = $false
function Get-ChatRect {
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    $r = @(([string]$state.ChatRect).Split(',') | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
    if ($r.Count -eq 4 -and $r[2] -gt 250 -and $r[3] -gt 250) {
        $box = New-Object System.Drawing.Rectangle($r[0], $r[1], $r[2], $r[3])
        if (@($screens | Where-Object { $_.WorkingArea.IntersectsWith($box) }).Count) { return $r }
    }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = 460; $h = [math]::Min(760, $wa.Height - 80)
    return @(($wa.Right - $w - 12), ($wa.Top + 40), $w, $h)
}
function Set-TeamsPinned([bool]$On) {
    $procId = Get-TeamsChromePid
    if (-not $procId) { return }
    foreach ($h in [SecWin]::Find($procId)) {
        if ($On) {
            if (-not $script:PinHandle.Equals($h) -or $script:PinForce) {
                $r = Get-ChatRect
                [void][SecWin]::ShowWindow($h, 9)
                [SecWin]::Place($h, $r[0], $r[1], $r[2], $r[3], $true)
                $script:PinHandle = $h; $script:PinForce = $false
            } elseif ([SecWin]::IsWindowVisible($h) -and -not [SecWin]::Minimized($h)) {
                $r = [SecWin]::Rect($h)
                $txt = $r -join ','
                if ($r[2] -gt 250 -and $r[3] -gt 250 -and $txt -ne [string]$state.ChatRect) { $state.ChatRect = $txt; Save-State }
            }
        } elseif ($script:PinHandle.Equals($h)) {
            [SecWin]::Top($h, $false); $script:PinHandle = [IntPtr]::Zero
        }
    }
}

function Start-TeamsBrowser {
    $chrome = $Config.SecretaryChromePath
    if (-not $chrome -or -not (Test-Path $chrome)) {
        $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $chrome) { throw "Chrome not found. Set SecretaryChromePath in settings.json." }
    Start-Process -FilePath $chrome -WindowStyle Minimized -ArgumentList @(
        "--remote-debugging-port=$Port", "--user-data-dir=`"$ProfileDir`"", "--no-first-run", "--no-default-browser-check", "--app=$ChatUrl")   # app mode: no tab strip or address bar
    Write-Log "Started the Teams window."
}

# Run a list of CDP calls on one connection. Each item: @{ Method = ...; Params = @{...} } or @{ Sleep = ms }
function Invoke-Cdp($Target, [object[]]$Calls) {
    $ws  = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource 20000
    try {
        $ws.ConnectAsync([Uri]$Target.webSocketDebuggerUrl, $cts.Token).Wait()
        $results = New-Object System.Collections.ArrayList
        $id = 0
        foreach ($c in $Calls) {
            if ($c.Sleep) { Start-Sleep -Milliseconds $c.Sleep; continue }
            $id++
            $p = if ($c.Params) { $c.Params } else { @{} }
            $buf = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ id = $id; method = $c.Method; params = $p } -Compress -Depth 6))
            $ws.SendAsync([ArraySegment[byte]]$buf, 'Text', $true, $cts.Token).Wait()
            do {
                $ms = New-Object System.IO.MemoryStream
                do {
                    $rb = New-Object byte[] 65536
                    $r = $ws.ReceiveAsync([ArraySegment[byte]]$rb, $cts.Token).Result
                    $ms.Write($rb, 0, $r.Count)
                } until ($r.EndOfMessage)
                $msg = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            } until ($msg.id -eq $id)
            if ($msg.error) { throw "CDP $($c.Method): $($msg.error.message)" }
            [void]$results.Add($msg.result)
        }
        return ,$results
    } finally { try { $ws.Dispose() } catch {}; $cts.Dispose() }
}

function Invoke-TeamsJs($Target, [string]$Js) {
    $r = Invoke-Cdp $Target @(@{ Method = 'Runtime.evaluate'; Params = @{ expression = $Js; returnByValue = $true } })
    return $r[0].result.value
}

$ReadJs = @'
(() => {
  const alt = (el) => { const c = el.cloneNode(true); c.querySelectorAll('img[alt]').forEach(i => i.replaceWith(document.createTextNode(i.alt))); return (c.textContent || '').trim().slice(0, 40); };
  return JSON.stringify({
    title: document.title,
    url: location.href,
    msgs: [...document.querySelectorAll('[data-tid="chat-pane-message"]')].slice(-20)
      .map(e => ({ mid: e.dataset.mid || '', text: (e.innerText || '').trim().slice(0, 4000), alt: alt(e) }))
  });
})()
'@

$NavJs = @'
(() => {
  const clickable = (el) => el.closest('button, a, [role="treeitem"], [role="option"], [role="listitem"], [role="link"], [tabindex]') || el;
  const web = [...document.querySelectorAll('button, a')].find(b => /use the web app instead/i.test(b.innerText || ''));
  if (web) { web.click(); return 'CLICKED_WEB_APP'; }
  const cands = [...document.querySelectorAll('[title], [aria-label], span, div')]
    .filter(e => /\(You\)/.test(e.getAttribute('title') || e.getAttribute('aria-label') || (e.children.length === 0 ? e.textContent : '') || ''))
    .filter(e => !e.closest('[data-tid="chat-pane-message"]'));
  if (!cands.length) {
    const chatBtn = [...document.querySelectorAll('button, [role="tab"], [role="button"]')].find(b => /^chat\b/i.test((b.getAttribute('aria-label') || b.innerText || '').trim()));
    if (chatBtn) { chatBtn.click(); return 'OPENED_CHAT_LIST'; }
    return 'NOT_FOUND';
  }
  clickable(cands[0]).click();
  return 'CLICKED_SELF_CHAT';
})()
'@

function Get-Normalized([string]$Text) {
    $t = $Text.Replace($Tag, "") -replace '\s+', ' '
    $t = ($t.Trim() -replace '^(?i)assistant:\s*', '').ToLowerInvariant()
    if ($t.Length -gt 80) { $t = $t.Substring(0, 80) }
    return $t
}

# Post into the notes-to-self chat as "<robot> **Assistant:** text". Refuses if the open chat is not the self-chat.
# Formatting goes in by a synthetic paste of HTML (Teams keeps bold); plain typing is the fallback.
function Send-Chat([string]$Text, [string]$LinkUrl = "", [string]$LinkText = "") {
    # Long messages go out in parts at line breaks (Teams does not always send a long pasted message on Enter)
    if ($Text.Length -gt 1100) {
        $parts = @(); $cur = ""
        foreach ($ln in ($Text -replace "`r", "").Split("`n")) {
            if ($cur -and ($cur.Length + $ln.Length + 1) -gt 1000) { $parts += $cur; $cur = $ln } else { $cur = if ($cur) { "$cur`n$ln" } else { $ln } }
        }
        if ($cur) { $parts += $cur }
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($i -eq $parts.Count - 1) { Send-Chat $parts[$i] $LinkUrl $LinkText } else { Send-Chat $parts[$i] }
            Start-Sleep -Milliseconds 800
        }
        return
    }
    $tgt = Get-TeamsTarget
    if (-not $tgt) { throw "Teams window not available." }
    if ($Text.Length -gt 3500) { $Text = $Text.Substring(0, 3500) + " ..." }
    $body = (($Text -replace "`r", "").Split("`n") | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_) }) -join "<br>"
    if ($LinkUrl) {
        $lt = if ($LinkText) { $LinkText } else { $LinkUrl }
        $body += "<br><a href=`"$([System.Net.WebUtility]::HtmlEncode($LinkUrl))`">$([System.Net.WebUtility]::HtmlEncode($lt))</a>"
    }
    $html = "<p>$Tag <b>Assistant:</b> $body</p>"
    $pasteJs = @"
(() => {
  if (!/\(You\)/.test(document.title)) return 'NOT_SELF_CHAT';
  const b = document.querySelector('[data-tid="ckeditor"][contenteditable="true"]') || document.querySelector('[role="textbox"][contenteditable="true"]');
  if (!b) return 'NO_COMPOSE_BOX';
  b.focus();
  const html = $(ConvertTo-Json -InputObject $html);
  const ok = () => (b.innerText.match(/Assistant:/g) || []).length === 1;
  const ed = b.ckeditorInstance;
  if (ed && ed.setData) { ed.setData(html); if (ok()) return 'PASTED'; }
  else {
    const dt = new DataTransfer();
    dt.setData('text/html', html);
    b.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    if (ok()) return 'PASTED';
  }
  if (ed && ed.setData) ed.setData(''); else { document.execCommand('selectAll'); document.execCommand('delete'); }
  return 'NOT_CLEAN';
})()
"@
    $res = Invoke-TeamsJs $tgt $pasteJs
    if ($res -eq 'NOT_SELF_CHAT' -or $res -eq 'NO_COMPOSE_BOX') { throw "Not posting: $res" }
    $calls = New-Object System.Collections.ArrayList
    if ($res -ne 'PASTED') {
        # Fallback: type plain text, Shift+Enter between lines
        Write-Log "Formatted paste did not take ($res). Typing plain text." "WARN"
        $lines = ("$Tag Assistant: $Text" + $(if ($LinkUrl) { "`n$LinkUrl" } else { "" }) -replace "`r", "").Split("`n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i]) { [void]$calls.Add(@{ Method = 'Input.insertText'; Params = @{ text = $lines[$i] } }) }
            if ($i -lt $lines.Count - 1) {
                [void]$calls.Add(@{ Method = 'Input.dispatchKeyEvent'; Params = @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; modifiers = 8 } })
                [void]$calls.Add(@{ Method = 'Input.dispatchKeyEvent'; Params = @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; modifiers = 8 } })
            }
        }
    }
    [void]$calls.Add(@{ Sleep = 400 })
    [void]$calls.Add(@{ Method = 'Input.dispatchKeyEvent'; Params = @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; text = "`r" } })
    [void]$calls.Add(@{ Method = 'Input.dispatchKeyEvent'; Params = @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13 } })
    [void](Invoke-Cdp $tgt @($calls))
    # Confirm it went out: the compose box should be empty. If not, press the Send button; if still stuck, clear it and report.
    $leftJs = "(() => { const b = document.querySelector('[data-tid=""ckeditor""][contenteditable=""true""]'); return b ? (b.innerText || '').trim().length : 0; })()"
    Start-Sleep -Milliseconds 700
    if ([int](Invoke-TeamsJs $tgt $leftJs) -gt 0) {
        [void](Invoke-TeamsJs $tgt "(() => { const s = document.querySelector('[data-tid=""newMessageCommands-send""], button[name=""send""], button[aria-label^=""Send""]'); if (s) s.click(); return !!s; })()")
        Start-Sleep -Milliseconds 900
        if ([int](Invoke-TeamsJs $tgt $leftJs) -gt 0) {
            [void](Invoke-TeamsJs $tgt "(() => { const b = document.querySelector('[data-tid=""ckeditor""][contenteditable=""true""]'); if (b && b.ckeditorInstance) b.ckeditorInstance.setData(''); return 1; })()")
            throw "Teams did not send the message."
        }
    }
    $state.Posted = @(@($state.Posted) + (Get-Normalized $Text) | Select-Object -Last 30)
    Save-State
    Add-ChatLog "Assistant" $Text
}

function Test-Ours($m) {
    $t = [string]$m.text; $a = [string]$m.alt
    if ($t.StartsWith($Tag) -or $a.StartsWith($Tag) -or $a -match '^\s*:?robot') { return $true }
    return (@($state.Posted) -contains (Get-Normalized $t))
}
