' Daily Briefing fallback launcher (used only if DailyBriefing.exe could not be built).
' 1. Starts classic Outlook minimized if it is not running.
' 2. Starts app\server.ps1 hidden (tray icon only) if it is not already running.
' 3. Opens the dashboard window, unless run with /background.
Option Explicit

Dim sh, fso, appDir, baseDir, url, i, background, arg
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
appDir  = fso.GetParentFolderName(WScript.ScriptFullName)
baseDir = fso.GetParentFolderName(appDir)
url     = "http://localhost:8000/"
background = False
For Each arg In WScript.Arguments
    If LCase(arg) = "/background" Then background = True
Next

Function ServerUp()
    Dim http
    On Error Resume Next
    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.setTimeouts 1000, 1000, 1000, 1000
    http.Open "GET", url & "api/ping", False
    http.Send
    ServerUp = (Err.Number = 0 And http.Status = 200)
    Err.Clear
    On Error GoTo 0
End Function

Function OutlookRunning()
    Dim procs
    Set procs = GetObject("winmgmts:\\.\root\cimv2").ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name = 'OUTLOOK.EXE'")
    OutlookRunning = (procs.Count > 0)
End Function

Sub MinimizeOutlook()
    Dim ol, n
    On Error Resume Next
    For n = 1 To 30
        Set ol = CreateObject("Outlook.Application")
        If Err.Number = 0 Then
            If Not ol.ActiveExplorer Is Nothing Then
                ol.ActiveExplorer.WindowState = 1
                If Err.Number = 0 Then Exit For
            End If
        End If
        Err.Clear
        WScript.Sleep 500
    Next
    Err.Clear
    On Error GoTo 0
End Sub

If Not OutlookRunning() Then
    sh.Run "outlook.exe", 7, False
    MinimizeOutlook
End If

If Not ServerUp() Then
    sh.CurrentDirectory = baseDir
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & appDir & "\server.ps1""", 0, False
    For i = 1 To 60
        WScript.Sleep 500
        If ServerUp() Then Exit For
    Next
    If Not ServerUp() Then
        MsgBox "The Daily Briefing server did not start." & vbCrLf & "Check data\server.log in " & baseDir, vbExclamation, "Daily Briefing"
        WScript.Quit 1
    End If
End If

If Not background Then sh.Run "chrome.exe --app=" & url & " --window-size=960,1350", 1, False
