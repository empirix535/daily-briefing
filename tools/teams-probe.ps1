# Read-only probe: reads the last messages of the open Teams web chat via Chrome's debugging port (9222).
param([int]$Count = 3)
$page = (Invoke-RestMethod http://localhost:9222/json) | Where-Object { $_.type -eq 'page' -and $_.url -like '*teams*' } | Select-Object -First 1
if (-not $page) { throw "No Teams page found on port 9222. Is the debug Chrome window open?" }
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
$js = @"
(() => {
  const els = [...document.querySelectorAll('[data-tid="chat-pane-message"]')].slice(-$Count);
  return JSON.stringify({
    title: document.title,
    visibility: document.visibilityState,
    msgs: els.map(e => ({
      ids: [e, e.parentElement, e.closest('[id]')].filter(Boolean).map(x => x.id).filter(Boolean).join(' / '),
      attrs: [...e.attributes].map(a => a.name + '=' + a.value.slice(0, 80)).join(' | '),
      text: e.innerText.slice(0, 200)
    }))
  });
})()
"@
$req = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $js; returnByValue = $true } } | ConvertTo-Json -Compress
$buf = [Text.Encoding]::UTF8.GetBytes($req)
$ws.SendAsync([ArraySegment[byte]]$buf, 'Text', $true, [Threading.CancellationToken]::None).Wait()
$sb = New-Object Text.StringBuilder
do { $rb = New-Object byte[] 65536; $r = $ws.ReceiveAsync([ArraySegment[byte]]$rb, [Threading.CancellationToken]::None).Result; [void]$sb.Append([Text.Encoding]::UTF8.GetString($rb, 0, $r.Count)) } until ($r.EndOfMessage)
$ws.Dispose()
$out = ($sb.ToString() | ConvertFrom-Json).result.result.value | ConvertFrom-Json
"Title: $($out.title)   Visibility: $($out.visibility)"
$out.msgs | Format-List
