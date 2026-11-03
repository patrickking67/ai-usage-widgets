#Requires -Version 5.1
<#
uninstall.ps1 - removes TokenMeter for the current user.

    powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\TokenMeter\uninstall.ps1" [-RemoveData]

Quits the app, removes the Start menu shortcut, the sign-in entry and the
program folder. The data folder (%LOCALAPPDATA%\TokenMeter: board.json,
settings, the log-scan cache) is kept unless you pass -RemoveData; it holds
no credentials either way.
#>
[CmdletBinding()]
param(
    [switch]$RemoveData,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TokenMeter')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'This uninstalls TokenMeter for Windows.' }

# Ask the running app to quit, so it removes its own tray icon; force it only
# if it has not gone after a few seconds.
$quit = $null
if ([System.Threading.EventWaitHandle]::TryOpenExisting("Local\TokenMeter.Quit.$([Environment]::UserName)", [ref]$quit)) {
    [void]$quit.Set(); $quit.Dispose()
    Start-Sleep -Seconds 3
}
Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*TokenMeter.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TokenMeter' -ErrorAction SilentlyContinue
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TokenMeter.lnk'
Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue

# This script may be running from inside the folder it removes; PowerShell has
# already read it, so deleting it is safe.
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
Write-Host "Removed TokenMeter from $InstallDir"

$data = Join-Path $env:LOCALAPPDATA 'TokenMeter'
if ($RemoveData) {
    if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
    Write-Host "Removed data folder $data"
} elseif (Test-Path -LiteralPath $data) {
    Write-Host "Kept data folder $data (run with -RemoveData to delete it)."
}
