# Test: post one message into the Teams web self-chat via Chrome's debugging port (9222). No Claude, no connector.
param([string]$Text = "[Assistant] test post via browser")
$page = (Invoke-RestMethod http://localhost:9222/json) | Where-Object { $_.type -eq 'page' -and $_.url -like '*teams*' } | Select-Object -First 1
if (-not $page) { throw "No Teams page found on port 9222. Is the debug Chrome window open?" }
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
$script:n = 0
function Send-Cdp([string]$Method, [hashtable]$Params = @{}) {
    $script:n++
    $req = @{ id = $script:n; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 5
    $buf = [Text.Encoding]::UTF8.GetBytes($req)
    $ws.SendAsync([ArraySegment[byte]]$buf, 'Text', $true, [Threading.CancellationToken]::None).Wait()
    do {
        $sb = New-Object Text.StringBuilder
        do { $rb = New-Object byte[] 65536; $r = $ws.ReceiveAsync([ArraySegment[byte]]$rb, [Threading.CancellationToken]::None).Result; [void]$sb.Append([Text.Encoding]::UTF8.GetString($rb, 0, $r.Count)) } until ($r.EndOfMessage)
        $msg = $sb.ToString() | ConvertFrom-Json
    } until ($msg.id -eq $script:n)
    return $msg.result
}
# Guard: only post when the open chat is the notes-to-self chat, and focus its compose box
$check = @'
(() => {
  if (!/\(You\)/.test(document.title)) return 'NOT_SELF_CHAT: ' + document.title;
  const box = document.querySelector('[data-tid="ckeditor"][contenteditable="true"]') || document.querySelector('[role="textbox"][contenteditable="true"]');
  if (!box) return 'NO_COMPOSE_BOX';
  box.focus();
  return 'OK ' + (box.getAttribute('data-tid') || box.getAttribute('aria-label') || '');
})()
'@
$res = (Send-Cdp 'Runtime.evaluate' @{ expression = $check; returnByValue = $true }).result.value
"Check: $res"
if ($res -notlike 'OK*') { $ws.Dispose(); return }
[void](Send-Cdp 'Input.insertText' @{ text = $Text })
Start-Sleep -Milliseconds 300
[void](Send-Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; text = "`r" })
[void](Send-Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13 })
$ws.Dispose()
"Posted: $Text"
