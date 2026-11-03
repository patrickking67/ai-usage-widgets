#Requires -Version 5.1
<#
install.ps1 - installs TokenMeter for the current user. No admin rights needed.

    powershell -ExecutionPolicy Bypass -File .\install.ps1 [-StartAtLogin] [-NoLaunch]

Copies the app to %LOCALAPPDATA%\Programs\TokenMeter, adds a Start menu
shortcut and, with -StartAtLogin, a per-user Run entry. Nothing is written
outside your user profile, and nothing touches Claude Code's, Codex's or
GitHub's credentials.
#>
[CmdletBinding()]
param(
    [switch]$StartAtLogin,
    [switch]$NoLaunch,
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\TokenMeter')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'TokenMeter for Windows installs on Windows only.' }

$source = $PSScriptRoot
$files = 'TokenMeter.ps1', 'TokenMeter.Core.psm1', 'Start-TokenMeter.vbs', 'uninstall.ps1', 'README.md'

# A running copy would keep the old code in memory; ask it to quit first
# (the same event uninstall.ps1 uses), so its tray icon goes away cleanly.
function Stop-TokenMeter {
    $quit = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting("Local\TokenMeter.Quit.$([Environment]::UserName)", [ref]$quit)) {
        [void]$quit.Set(); $quit.Dispose()
        Start-Sleep -Seconds 2
    }
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*TokenMeter.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host "Installing TokenMeter to $Destination"
Stop-TokenMeter
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach ($f in $files) {
    $from = Join-Path $source $f
    if (-not (Test-Path -LiteralPath $from)) { throw "Missing $f next to install.ps1." }
    Copy-Item -LiteralPath $from -Destination (Join-Path $Destination $f) -Force
}
# Files from a downloaded zip carry the internet zone mark, which would stop
# PowerShell loading the module under the default RemoteSigned policy.
Get-ChildItem -LiteralPath $Destination -File | Unblock-File

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$vbs = Join-Path $Destination 'Start-TokenMeter.vbs'
$pwsh = @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'), (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TokenMeter.lnk'
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcut)
$lnk.TargetPath = $wscript
$lnk.Arguments = '"{0}"' -f $vbs
$lnk.WorkingDirectory = $Destination
$lnk.Description = 'TokenMeter: AI coding plan limits and token activity'
if ($pwsh) { $lnk.IconLocation = "$pwsh,0" }
$lnk.Save()
Write-Host "  Start menu shortcut: $shortcut"

if ($StartAtLogin) {
    $cmd = '"{0}" "{1}" -Background' -f $wscript, $vbs
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TokenMeter' -Value $cmd
    Write-Host '  Starts when you sign in (Settings > Start TokenMeter when I sign in turns it off).'
}

if (-not $NoLaunch) {
    Start-Process -FilePath $wscript -ArgumentList ('"{0}"' -f $vbs)
    Write-Host '  Launched. Look for the number in the notification area.'
}
Write-Host 'Done. To remove: run uninstall.ps1 from the install folder.'
