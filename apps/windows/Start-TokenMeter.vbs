' Start-TokenMeter.vbs - launches TokenMeter with no console window.
'
' PowerShell always opens a console, even with -WindowStyle Hidden (it flashes
' before hiding). wscript.exe has no console, and Run(..., 0) starts PowerShell
' hidden from the first frame, so nothing flickers at sign-in.
'
' Arguments are passed through, e.g. "-Background" from the Run key at sign-in.

Option Explicit

Dim shell, fso, here, script, exe, candidates, candidate, args, i

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "TokenMeter.ps1")

' PowerShell 7 scans logs several times faster; Windows PowerShell 5.1 is the
' fallback every Windows install has.
candidates = Array( _
    "%ProgramFiles%\PowerShell\7\pwsh.exe", _
    "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe", _
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
exe = ""
For Each candidate In candidates
    candidate = shell.ExpandEnvironmentStrings(candidate)
    If exe = "" And fso.FileExists(candidate) Then exe = candidate
Next
If exe = "" Then exe = "powershell.exe"

args = ""
For i = 0 To WScript.Arguments.Count - 1
    args = args & " " & WScript.Arguments(i)
Next

shell.Run """" & exe & """ -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """" & args, 0, False
