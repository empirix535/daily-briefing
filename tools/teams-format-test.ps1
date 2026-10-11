# Test: paste one formatted (HTML) message into the Teams web self-chat via Chrome's debugging port (9222).
param([string]$Color = "#6b7280", [string]$Size = "12px")
$page = (Invoke-RestMethod http://localhost:9222/json) | Where-Object { $_.type -eq 'page' -and $_.url -like '*teams*' } | Select-Object -First 1
if (-not $page) { throw "No Teams page found on port 9222." }
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
$script:n = 0
function Send-Cdp([string]$Method, [hashtable]$Params = @{}) {
    $script:n++
    $buf = [Text.Encoding]::UTF8.GetBytes((@{ id = $script:n; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 5))
    $ws.SendAsync([ArraySegment[byte]]$buf, 'Text', $true, [Threading.CancellationToken]::None).Wait()
    do {
        $ms = New-Object IO.MemoryStream
        do { $rb = New-Object byte[] 65536; $r = $ws.ReceiveAsync([ArraySegment[byte]]$rb, [Threading.CancellationToken]::None).Result; $ms.Write($rb, 0, $r.Count) } until ($r.EndOfMessage)
        $msg = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    } until ($msg.id -eq $script:n)
    return $msg.result
}
$robot = [char]::ConvertFromUtf32(0x1F916)
$html = "<p><span style=`"color:$Color;font-size:$Size`">$robot Format test: grey, smaller text. <b>Bold works?</b> <i>Italic?</i></span></p>"
$js = @"
(() => {
  if (!/\(You\)/.test(document.title)) return 'NOT_SELF_CHAT';
  const b = document.querySelector('[data-tid="ckeditor"][contenteditable="true"]');
  if (!b) return 'NO_COMPOSE_BOX';
  b.focus();
  const dt = new DataTransfer();
  dt.setData('text/html', $(ConvertTo-Json $html));
  dt.setData('text/plain', 'Format test');
  b.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
  return 'PASTED';
})()
"@
$res = (Send-Cdp 'Runtime.evaluate' @{ expression = $js; returnByValue = $true }).result.value
"Paste: $res"
if ($res -eq 'PASTED') {
    Start-Sleep -Milliseconds 400
    [void](Send-Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; text = "`r" })
    [void](Send-Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13 })
    "Sent."
}
$ws.Dispose()
