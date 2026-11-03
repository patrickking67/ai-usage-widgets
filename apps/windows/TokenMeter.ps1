#Requires -Version 5.1
<#
TokenMeter.ps1 - the Windows app: tray icon, main window, desktop widget,
settings and alerts, over TokenMeter.Core.psm1.

    Start-TokenMeter.vbs            launch without a console window
    TokenMeter.ps1 -Background      start in the tray only (used at sign-in)

The shell only draws. Every number comes from the Core module, which also
writes the board (spec/board.md) that the Claude Code plugin and any other
TokenMeter client read. Network reads (Claude, Copilot) and the log scan run
on a background runspace pool, so the UI thread never waits on disk or wire.

Look and behaviour follow the macOS app: apps/macos/App/App.swift and
Shared/MeterViews.swift, ActivityViews.swift.

WPF and WinForms need Windows; this file does not run on macOS or Linux.
Source is ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI),
so non-ASCII glyphs are built from code points.
#>
[CmdletBinding()]
param([switch]$Background)

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'TokenMeter.ps1 is the Windows app (WPF). On other platforms use TokenMeter.Core.psm1 directly.'
    exit 1
}

# WPF needs a single-threaded apartment. The launcher passes -STA; anything
# else (a double-click, a plain pwsh) is relaunched with it, hidden.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $exe = (Get-Process -Id $PID).Path
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Background) { $relaunch += '-Background' }
    Start-Process -FilePath $exe -ArgumentList $relaunch -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot 'TokenMeter.Core.psm1') -Force -DisableNameChecking

# ---------------------------------------------------------------- one instance
#
# A second launch (the Start menu shortcut while the tray icon is running)
# asks the first to open its window and exits. uninstall.ps1 uses the quit
# event to close the app cleanly, so no ghost icon is left in the tray.

$script:User = [Environment]::UserName
$created = $false
$script:OpenEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, "Local\TokenMeter.Open.$script:User", [ref]$created)
$script:QuitEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, "Local\TokenMeter.Quit.$script:User", [ref]$created)
$script:Mutex = [System.Threading.Mutex]::new($false, "Local\TokenMeter.$script:User")
$owns = $false
try { $owns = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owns = $true }
if (-not $owns) {
    if (-not $Background) { [void]$script:OpenEvent.Set() }
    exit 0
}

# ---------------------------------------------------------------- native bits

if (-not ('TokenMeter.Native' -as [type])) {
    Add-Type -Namespace TokenMeter -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
}

# ---------------------------------------------------------------- state

$script:P = Get-TMPaths
$script:FirstRun = -not (Test-Path -LiteralPath $script:P.SettingsPath)
$script:Settings = Get-TMSettings -Path $script:P.SettingsPath
$script:AlertState = Read-TMJsonFile $script:P.AlertsPath

$script:Board = $null
$script:Fingerprint = $null
$script:Live = $null              # last Claude snapshot: @{ Meters; Extra; FetchedAt }
$script:LiveProblem = $null
$script:LiveNext = 0.0            # unix seconds: at most every 3 min, 30 min after a 429
$script:Copilot = $null           # last Copilot provider
$script:CopilotProblem = $null
$script:CopilotNext = 0.0
$script:Activity = $null
$script:LastScan = 0.0
$script:Tab = 'limits'
$script:ShowAllDrivers = $false
$script:Quitting = $false
$script:BalloonQueue = [System.Collections.Generic.Queue[object]]::new()
$script:LastBalloon = [DateTime]::MinValue
$script:TrayStamp = $null

$script:G = @{
    Dot     = [string][char]0x00B7
    Flame   = [char]::ConvertFromUtf32(0x1F525)
    Warn    = [string][char]0x26A0
    Bulb    = [char]::ConvertFromUtf32(0x1F4A1)
    Info    = [string][char]0x24D8
    Clock   = [string][char]0x25F7
    Refresh = [string][char]0x21BB
    Gear    = [string][char]0x2699
    Card    = [string][char]0x25AD
    Dash    = [string][char]0x2014
    Ellipsis = [string][char]0x2026
}
$script:VendorGlyph = @{ claude = [string][char]0x2733; codex = [string][char]0x25CE; copilot = '>_' }
$script:UsageUrls = @{
    claude  = 'https://claude.ai/settings/usage'
    codex   = 'https://chatgpt.com/codex/settings/usage'
    copilot = 'https://github.com/settings/copilot'
}

function Write-Log([string]$Message) { Write-TMLog -Message $Message -Path $script:P.LogPath }

function Invoke-Safely([string]$What, [scriptblock]$Block) {
    <# Event handlers must never take the app down; log and carry on. #>
    try { & $Block } catch { Write-Log ("{0}: {1}" -f $What, $_.Exception.Message) }
}

# ---------------------------------------------------------------- theme
#
# Follows the Windows app theme (Settings > Personalisation > Colours).
# The dark palette is the macOS app's; the light one darkens the accents,
# because the pale cyan and amber that read well on dark vanish on white.

function Test-TMDarkMode {
    try {
        return (Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme') -eq 0
    } catch { return $false }
}

function Get-TMThemeColors([bool]$Dark) {
    if ($Dark) {
        return @{ WindowBg = '#202020'; Card = '#2B2B2B'; Text = '#F3F3F3'; Secondary = '#B4B4B4'; Tertiary = '#8A8A8A'
                  Divider = '#363636'; Track = '#3A3A3A'; Border = '#474747'; Hover = '#343434'; Notch = '#E6E6E6'
                  Scroll = '#5A5A5A'; OnAccent = '#101010'; WidgetBg = '#E61E1E1E'; WidgetBorder = '#33FFFFFF'; Subtle = '#14FFFFFF'
                  Accent = '#7DCFFF'; Amber = '#E0B069'; Red = '#F7758F'; Clay = '#D97857'; Codex = '#4D85FA'; Copilot = '#A371F7' }
    }
    return @{ WindowBg = '#F3F3F3'; Card = '#FFFFFF'; Text = '#1B1B1B'; Secondary = '#5C5C5C'; Tertiary = '#8C8C8C'
              Divider = '#E3E3E3'; Track = '#E2E2E2'; Border = '#CFCFCF'; Hover = '#E8E8E8'; Notch = '#5F5F5F'
              Scroll = '#C2C2C2'; OnAccent = '#FFFFFF'; WidgetBg = '#EDFBFBFB'; WidgetBorder = '#26000000'; Subtle = '#0D000000'
              Accent = '#0F8FD6'; Amber = '#B7791F'; Red = '#D6335A'; Clay = '#C4623F'; Codex = '#2F6FEB'; Copilot = '#8250DF' }
}

function Set-TMTheme {
    <# Loads brushes into application resources. Returns $true when the theme changed. #>
    $dark = Test-TMDarkMode
    if ($null -ne $script:T -and $script:ThemeDark -eq $dark) { return $false }
    $script:ThemeDark = $dark
    $script:T = @{}
    $colors = Get-TMThemeColors $dark
    foreach ($k in $colors.Keys) {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$k]))
        $b.Freeze()
        $script:T[$k] = $b
        $script:App.Resources["TM.$k"] = $b
    }
    foreach ($w in @($script:Main, $script:SettingsWindow)) { if ($w) { Set-TMTitleBar $w } }
    return $true
}

function Set-TMTitleBar($Window) {
    <# Dark title bar to match (Windows 10 20H1+ and 11); a no-op elsewhere. #>
    try {
        $h = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $v = [int][bool]$script:ThemeDark
        if ([TokenMeter.Native]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) -ne 0) {
            [void][TokenMeter.Native]::DwmSetWindowAttribute($h, 19, [ref]$v, 4)
        }
    } catch { }
}

function Get-TMTintBrush([string]$Tint) {
    switch ($Tint) { 'red' { $script:T.Red } 'amber' { $script:T.Amber } default { $script:T.Accent } }
}

function Get-TMVendorBrush([string]$Vendor) {
    switch ($Vendor) { 'claude' { $script:T.Clay } 'codex' { $script:T.Codex } 'copilot' { $script:T.Copilot } default { $script:T.Tertiary } }
}

# ---------------------------------------------------------------- element helpers

function New-Thickness([double]$L, [double]$T = $L, [double]$R = $L, [double]$B = $T) { [System.Windows.Thickness]::new($L, $T, $R, $B) }

function New-Text {
    param([string]$Text, [double]$Size = 11, $Brush, [string]$Weight = 'Normal', [switch]$Tabular, [switch]$Wrap,
          [switch]$Trim, [string]$Font)
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = if ($Brush) { $Brush } else { $script:T.Text }
    $tb.FontWeight = [System.Windows.FontWeights]::$Weight
    $tb.VerticalAlignment = 'Center'
    if ($Font) { $tb.FontFamily = [System.Windows.Media.FontFamily]::new($Font) }
    if ($Tabular) { [System.Windows.Documents.Typography]::SetNumeralAlignment($tb, [System.Windows.FontNumeralAlignment]::Tabular) }
    if ($Wrap) { $tb.TextWrapping = 'Wrap' }
    if ($Trim) { $tb.TextTrimming = 'CharacterEllipsis' }
    return $tb
}

function New-Glyph([string]$Glyph, [double]$Size, $Brush) {
    New-Text -Text $Glyph -Size $Size -Brush $Brush -Font 'Segoe UI Emoji, Segoe UI Symbol, Segoe UI'
}

function New-Grid {
    <# A grid with the given columns: '*', 'Auto' or a pixel width. #>
    param([string[]]$Columns)
    $g = [System.Windows.Controls.Grid]::new()
    foreach ($c in $Columns) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = switch ($c) {
            '*' { [System.Windows.GridLength]::new(1, 'Star') }
            'Auto' { [System.Windows.GridLength]::Auto }
            default { [System.Windows.GridLength]::new([double]$c) }
        }
        $g.ColumnDefinitions.Add($cd)
    }
    return $g
}

function Add-ToGrid($Grid, $Element, [int]$Column) {
    [System.Windows.Controls.Grid]::SetColumn($Element, $Column)
    [void]$Grid.Children.Add($Element)
}

function New-Stack([string]$Orientation = 'Vertical') {
    $s = [System.Windows.Controls.StackPanel]::new()
    $s.Orientation = $Orientation
    return $s
}

function New-Divider([double]$Top = 12, [double]$Bottom = 12) {
    $b = [System.Windows.Controls.Border]::new()
    $b.Height = 1; $b.Background = $script:T.Divider; $b.Margin = New-Thickness 0 $Top 0 $Bottom
    return $b
}

function New-Bar {
    <#
    Thin capsule meter, after the usage bars in the Claude app. `Pace` draws
    a notch where the bar would sit with perfectly even use across the window:
    fill past the notch is running hot, short of it is headroom.
    #>
    param([double]$Width, [double]$Height = 5, [double]$Fraction, $Tint, $Pace, [double]$Opacity = 1)
    $g = [System.Windows.Controls.Grid]::new()
    $g.Width = $Width; $g.Height = $Height + 4; $g.Opacity = $Opacity
    $track = [System.Windows.Controls.Border]::new()
    $track.Height = $Height; $track.CornerRadius = [System.Windows.CornerRadius]::new($Height / 2)
    $track.Background = $script:T.Track; $track.VerticalAlignment = 'Center'
    [void]$g.Children.Add($track)
    $f = [Math]::Min([Math]::Max($Fraction, 0), 1)
    if ($f -gt 0) {
        $fill = [System.Windows.Controls.Border]::new()
        $fill.Height = $Height; $fill.Width = [Math]::Max($Width * $f, $Height)
        $fill.CornerRadius = [System.Windows.CornerRadius]::new($Height / 2)
        $fill.Background = $Tint; $fill.HorizontalAlignment = 'Left'; $fill.VerticalAlignment = 'Center'
        [void]$g.Children.Add($fill)
    }
    if ($null -ne $Pace -and $Pace -gt 0.02 -and $Pace -lt 0.98) {
        $notch = [System.Windows.Shapes.Rectangle]::new()
        $notch.Width = 1.5; $notch.Height = $Height + 4; $notch.RadiusX = 0.75; $notch.RadiusY = 0.75
        $notch.Fill = $script:T.Notch; $notch.Opacity = 0.75
        $notch.HorizontalAlignment = 'Left'; $notch.Margin = New-Thickness ($Width * $Pace - 0.75) 0 0 0
        [void]$g.Children.Add($notch)
    }
    return $g
}

function New-Badge([string]$Vendor, [double]$Size = 22) {
    <# The vendor's colour with a glyph: crisp at any DPI, no image files to ship. #>
    $b = [System.Windows.Controls.Border]::new()
    $b.Width = $Size; $b.Height = $Size
    $b.CornerRadius = [System.Windows.CornerRadius]::new($Size * 0.26)
    $b.Background = Get-TMVendorBrush $Vendor
    $glyph = $script:VendorGlyph[$Vendor]; if (-not $glyph) { $glyph = $Vendor.Substring(0, 1).ToUpperInvariant() }
    $size = if ($glyph.Length -gt 1) { $Size * 0.42 } else { $Size * 0.62 }
    $t = New-Text -Text $glyph -Size $size -Brush ([System.Windows.Media.Brushes]::White) -Weight 'Bold' -Font 'Segoe UI Symbol, Consolas, Segoe UI'
    $t.HorizontalAlignment = 'Center'; $t.TextAlignment = 'Center'
    $b.Child = $t
    return $b
}

function Set-Hover($Element) {
    <# Button-like borders get a subtle hover background. #>
    $Element.Cursor = [System.Windows.Input.Cursors]::Hand
    if ($null -eq $Element.Background) { $Element.Background = [System.Windows.Media.Brushes]::Transparent }
    $Element.Add_MouseEnter({ param($s, $e) if (-not $s.Tag -or $s.Tag -ne 'selected') { $s.Background = $script:T.Hover } })
    $Element.Add_MouseLeave({ param($s, $e) if (-not $s.Tag -or $s.Tag -ne 'selected') { $s.Background = [System.Windows.Media.Brushes]::Transparent } })
}

function New-SectionTitle([string]$Title, [string]$Trailing) {
    $g = New-Grid @('*', 'Auto')
    Add-ToGrid $g (New-Text -Text $Title -Size 12 -Weight 'SemiBold') 0
    if ($Trailing) { Add-ToGrid $g (New-Text -Text $Trailing -Size 10.5 -Brush $script:T.Secondary -Tabular) 1 }
    return $g
}

# ---------------------------------------------------------------- limits view

$script:W = 372        # content width of the main window

function New-FreshnessBadge($Provider, [double]$Now, [double]$Size = 10) {
    <# "Live" with a dot, or "4d ago" with a clock once the vendor has gone quiet. #>
    $u = Get-TMNumber $Provider.updatedAt
    if ($null -eq $u) { return $null }
    $stale = Test-TMProviderStale $Provider $Now
    $s = New-Stack 'Horizontal'
    $s.VerticalAlignment = 'Center'
    $ago = Format-TMAgo ($Now - $u)
    if ($stale) {
        [void]$s.Children.Add((New-Glyph $script:G.Clock ($Size - 1) $script:T.Secondary))
        $t = New-Text -Text (' ' + $ago) -Size $Size -Brush $script:T.Secondary -Tabular
        [void]$s.Children.Add($t)
        $s.ToolTip = "Last reported $ago; this number may be out of date."
    } else {
        $dot = [System.Windows.Shapes.Ellipse]::new()
        $dot.Width = 5; $dot.Height = 5; $dot.Fill = $script:T.Accent; $dot.Margin = New-Thickness 0 0 4 0; $dot.VerticalAlignment = 'Center'
        [void]$s.Children.Add($dot)
        [void]$s.Children.Add((New-Text -Text $ago -Size $Size -Brush $script:T.Tertiary -Tabular))
    }
    return $s
}

function New-MeterRow($Meter, [double]$Now, [bool]$Stale, [double]$Width) {
    <# "Current  37%", the bar with its pace notch, then "Resets in 4h 13m   On pace for 64%". #>
    $f = Get-TMMeterFraction $Meter $Now
    $tint = Get-TMTintBrush (Get-TMMeterTint $Meter $Now)
    $row = New-Stack
    $row.Margin = New-Thickness 0 0 0 10

    $head = New-Grid @('*', 'Auto', 'Auto')
    Add-ToGrid $head (New-Text -Text $Meter.label -Size 11.5 -Brush $script:T.Secondary -Weight 'Medium') 0
    # Colour carries "near the limit"; the glyph carries it for colour-blind eyes.
    if ($f -ge 0.9) {
        $w = New-Glyph $script:G.Warn 10 $tint; $w.Margin = New-Thickness 0 0 4 0
        Add-ToGrid $head $w 1
    }
    $pctBrush = if ($Stale) { $script:T.Secondary } else { $script:T.Text }
    Add-ToGrid $head (New-Text -Text ('{0}%' -f [long][Math]::Round($f * 100)) -Size 14 -Brush $pctBrush -Weight 'SemiBold' -Tabular) 2
    [void]$row.Children.Add($head)

    $pace = if ($Stale) { $null } else { Get-TMElapsedFraction $Meter $Now }
    $bar = New-Bar -Width $Width -Height 5 -Fraction $f -Tint $tint -Pace $pace -Opacity $(if ($Stale) { 0.55 } else { 1 })
    $bar.Margin = New-Thickness 0 3 0 3
    [void]$row.Children.Add($bar)

    $foot = New-Grid @('*', 'Auto')
    Add-ToGrid $foot (New-Text -Text (Get-TMResetText $Meter $Now) -Size 10.5 -Brush $script:T.Tertiary -Tabular) 0
    if (-not $Stale) {
        $note = Get-TMPaceNote $Meter $Now
        if ($note) {
            if ($note.Hot) {
                $s = New-Stack 'Horizontal'
                [void]$s.Children.Add((New-Glyph $script:G.Flame 9.5 $tint))
                [void]$s.Children.Add((New-Text -Text (' ' + $note.Text) -Size 10.5 -Brush $tint -Tabular))
                Add-ToGrid $foot $s 1
            } else {
                Add-ToGrid $foot (New-Text -Text $note.Text -Size 10.5 -Brush $script:T.Tertiary -Tabular) 1
            }
        }
    }
    [void]$row.Children.Add($foot)
    return $row
}

function New-ExtraRow($Extra, [double]$Width) {
    <# Pay-as-you-go spend beyond the plan, with a bar when there is a cap. #>
    $s = New-Stack
    $g = New-Grid @('Auto', '*', 'Auto')
    Add-ToGrid $g (New-Text -Text 'Extra usage' -Size 10.5 -Brush $script:T.Secondary -Weight 'Medium') 0
    Add-ToGrid $g (New-Text -Text (Get-TMExtraText $Extra) -Size 10.5 -Tabular) 2
    [void]$s.Children.Add($g)
    $frac = Get-TMExtraFraction $Extra
    if ($null -ne $frac) {
        $brush = if ($frac -ge 0.9) { $script:T.Red } else { $script:T.Clay }
        $bar = New-Bar -Width $Width -Height 3 -Fraction $frac -Tint $brush
        $bar.Margin = New-Thickness 0 3 0 0
        [void]$s.Children.Add($bar)
    }
    return $s
}

function New-ProviderCard($Provider, [double]$Now) {
    <# Badge + vendor + account, freshness on the right, then each meter. #>
    $stale = Test-TMProviderStale $Provider $Now
    $card = New-Stack

    $header = New-Grid @('Auto', '*', 'Auto')
    $header.Margin = New-Thickness 0 0 0 12
    $header.Background = [System.Windows.Media.Brushes]::Transparent
    $badge = New-Badge ([string]$Provider.vendor) 24
    $badge.Margin = New-Thickness 0 0 9 0
    Add-ToGrid $header $badge 0
    $names = New-Stack
    [void]$names.Children.Add((New-Text -Text (Get-TMVendorName ([string]$Provider.vendor)) -Size 13 -Weight 'SemiBold'))
    $line = Get-TMAccountLine $Provider
    if ($line) { [void]$names.Children.Add((New-Text -Text $line -Size 10.5 -Brush $script:T.Secondary -Trim)) }
    Add-ToGrid $header $names 1
    $fresh = New-FreshnessBadge $Provider $Now
    if ($fresh) { Add-ToGrid $header $fresh 2 }
    # The header opens the vendor's own usage page.
    $url = $script:UsageUrls[[string]$Provider.vendor]
    if ($url) {
        $header.Cursor = [System.Windows.Input.Cursors]::Hand
        $header.Tag = $url
        $header.ToolTip = 'Open {0} usage' -f (Get-TMVendorName ([string]$Provider.vendor))
        $header.Add_MouseLeftButtonUp({ param($s, $e) Invoke-Safely 'open usage page' { Start-Process $s.Tag } })
    }
    [void]$card.Children.Add($header)

    if ($Provider.note) {
        $n = New-Text -Text $Provider.note -Size 11 -Brush $script:T.Secondary -Wrap
        $n.Margin = New-Thickness 0 -4 0 10
        [void]$card.Children.Add($n)
    }
    $meters = @($Provider.meters)
    if ($meters.Count -eq 0 -and -not $Provider.note) {
        $t = New-Text -Text 'No limits reported yet' -Size 10.5 -Brush $script:T.Tertiary
        $t.Margin = New-Thickness 0 -4 0 10
        [void]$card.Children.Add($t)
    }
    foreach ($m in $meters) { [void]$card.Children.Add((New-MeterRow $m $Now $stale $script:W)) }
    if ($Provider.extra) { [void]$card.Children.Add((New-ExtraRow $Provider.extra $script:W)) }
    return $card
}

function New-ProblemLine([string]$Text) {
    $s = New-Stack 'Horizontal'
    $s.Margin = New-Thickness 0 2 0 0
    [void]$s.Children.Add((New-Glyph $script:G.Info 10 $script:T.Secondary))
    $t = New-Text -Text (' ' + $Text) -Size 10 -Brush $script:T.Secondary -Wrap
    $t.MaxWidth = $script:W - 16
    [void]$s.Children.Add($t)
    return $s
}

function Update-LimitsView($Body, [double]$Now) {
    $providers = @($script:Board.providers)
    if ($providers.Count -eq 0) {
        [void]$Body.Children.Add((New-Text -Text 'Waiting for Claude Code, Codex or GitHub Copilot to report limits.' -Size 11.5 -Brush $script:T.Secondary -Wrap))
    }
    for ($i = 0; $i -lt $providers.Count; $i++) {
        $p = $providers[$i]
        [void]$Body.Children.Add((New-ProviderCard $p $Now))
        if ($p.vendor -eq 'claude' -and $script:LiveProblem) { [void]$Body.Children.Add((New-ProblemLine $script:LiveProblem)) }
        if ($p.vendor -eq 'copilot' -and $script:CopilotProblem) { [void]$Body.Children.Add((New-ProblemLine $script:CopilotProblem)) }
        if ($i -lt $providers.Count - 1) { [void]$Body.Children.Add((New-Divider 8 16)) }
    }
    # Copilot enabled but never read (no gh, not signed in): say why once.
    if ($script:Settings.providers.copilot -and -not $script:Copilot -and $script:CopilotProblem) {
        [void]$Body.Children.Add((New-Divider 8 12))
        [void]$Body.Children.Add((New-ProblemLine ('GitHub Copilot: ' + $script:CopilotProblem)))
    }
}

# ---------------------------------------------------------------- activity view

function Get-NiceMax([double]$Value) {
    <# The next 1, 2, 2.5 or 5 x 10^n at or above the value, so axis labels are round. #>
    if ($Value -le 0) { return 1.0 }
    $exp = [Math]::Pow(10, [Math]::Floor([Math]::Log10($Value)))
    foreach ($m in 1, 2, 2.5, 5, 10) { if ($m * $exp -ge $Value) { return $m * $exp } }
    return 10 * $exp
}

function New-RangeToggle {
    <# 7d / 30d. The board keeps 30 days; views default to 7. #>
    $outer = [System.Windows.Controls.Border]::new()
    $outer.CornerRadius = [System.Windows.CornerRadius]::new(5); $outer.Background = $script:T.Track; $outer.Padding = New-Thickness 2
    $s = New-Stack 'Horizontal'
    foreach ($r in 7, 30) {
        $b = [System.Windows.Controls.Border]::new()
        $b.CornerRadius = [System.Windows.CornerRadius]::new(4); $b.Padding = New-Thickness 7 1 7 1
        $b.Child = New-Text -Text ('{0}d' -f $r) -Size 10 -Brush $script:T.Text
        $b.Tag = $r
        if ([int]$script:Settings.activityRange -eq $r) { $b.Background = $script:T.Card } else { $b.Background = [System.Windows.Media.Brushes]::Transparent; $b.Cursor = [System.Windows.Input.Cursors]::Hand }
        $b.Add_MouseLeftButtonUp({ param($sender, $e) Invoke-Safely 'range toggle' {
            $script:Settings.activityRange = [int]$sender.Tag
            Save-TMSettings -Settings $script:Settings -Path $script:P.SettingsPath
            Update-MainView
        } })
        [void]$s.Children.Add($b)
    }
    $outer.Child = $s
    return $outer
}

function New-WeekChart($Activity, [int]$Range, [double]$Width, [double]$Height = 110) {
    <# Stacked bars per local day, drawn with shapes; the axis sits on the right like the macOS chart. #>
    $all = @($Activity.days)
    $days = if ($all.Count -gt $Range) { $all[($all.Count - $Range)..($all.Count - 1)] } else { $all }
    $n = [Math]::Max($days.Count, 1)
    $vendors = @('claude', 'codex', 'copilot')
    $max = 0.0
    foreach ($d in $days) { $t = 0.0; foreach ($v in $vendors) { $t += [double]$d[$v] }; if ($t -gt $max) { $max = $t } }
    $top = Get-NiceMax $max

    $axisW = 40.0; $plotW = $Width - $axisW; $labelH = 16.0
    $c = [System.Windows.Controls.Canvas]::new()
    $c.Width = $Width; $c.Height = $Height + $labelH
    foreach ($i in 0, 1, 2) {
        $y = [Math]::Round($Height - $Height * $i / 2) + 0.5
        $line = [System.Windows.Shapes.Line]::new()
        $line.X1 = 0; $line.X2 = $plotW; $line.Y1 = $y; $line.Y2 = $y
        $line.Stroke = $script:T.Divider; $line.StrokeThickness = 1
        [void]$c.Children.Add($line)
        $lab = New-Text -Text (Format-TMTokens ($top * $i / 2)) -Size 9.5 -Brush $script:T.Tertiary -Tabular
        [System.Windows.Controls.Canvas]::SetLeft($lab, $plotW + 6); [System.Windows.Controls.Canvas]::SetTop($lab, $y - 7)
        [void]$c.Children.Add($lab)
    }
    $slot = $plotW / $n
    $barW = [Math]::Max(2, $slot * $(if ($n -le 7) { 0.56 } else { 0.66 }))
    $inv = [Globalization.CultureInfo]::InvariantCulture
    for ($i = 0; $i -lt $days.Count; $i++) {
        $d = $days[$i]
        $x = $i * $slot + ($slot - $barW) / 2
        $y = $Height
        $date = [DateTimeOffset]::FromUnixTimeSeconds([long]$d.day).ToLocalTime()
        $tip = @($date.ToString('ddd d MMM', $inv))
        foreach ($v in $vendors) {
            $val = [double]$d[$v]
            if ($val -gt 0) { $tip += '{0}: {1}' -f (Get-TMVendorName $v), (Format-TMTokens $val) }
            $h = $Height * $val / $top
            if ($h -lt 0.5) { continue }
            $r = [System.Windows.Shapes.Rectangle]::new()
            $r.Width = $barW; $r.Height = $h; $r.RadiusX = 1.5; $r.RadiusY = 1.5
            $r.Fill = Get-TMVendorBrush $v
            [System.Windows.Controls.Canvas]::SetLeft($r, $x); [System.Windows.Controls.Canvas]::SetTop($r, $y - $h)
            [void]$c.Children.Add($r)
            $y -= $h
        }
        # A transparent column the full height, so the tooltip is easy to hit.
        $hit = [System.Windows.Shapes.Rectangle]::new()
        $hit.Width = $slot; $hit.Height = $Height; $hit.Fill = [System.Windows.Media.Brushes]::Transparent
        $hit.ToolTip = ($tip -join "`n")
        [System.Windows.Controls.Canvas]::SetLeft($hit, $i * $slot); [System.Windows.Controls.Canvas]::SetTop($hit, 0)
        [void]$c.Children.Add($hit)
        $label = if ($n -le 7) { $date.ToString('ddd', $inv).Substring(0, 1) }
                 elseif (($days.Count - 1 - $i) % 7 -eq 0) { $date.ToString('M/d', $inv) } else { $null }
        if ($label) {
            $lt = New-Text -Text $label -Size 9.5 -Brush $script:T.Tertiary
            $lt.Width = [Math]::Max($slot, 32); $lt.TextAlignment = 'Center'
            [System.Windows.Controls.Canvas]::SetLeft($lt, $i * $slot + $slot / 2 - $lt.Width / 2); [System.Windows.Controls.Canvas]::SetTop($lt, $Height + 3)
            [void]$c.Children.Add($lt)
        }
    }
    return $c
}

function New-Legend($Activity) {
    $s = New-Stack 'Horizontal'
    $s.Margin = New-Thickness 0 4 0 0
    foreach ($v in 'claude', 'codex', 'copilot') {
        $any = $v -ne 'copilot' -or @($Activity.days | Where-Object { [double]$_[$v] -gt 0 }).Count -gt 0
        if (-not $any) { continue }
        $sq = [System.Windows.Controls.Border]::new()
        $sq.Width = 8; $sq.Height = 8; $sq.CornerRadius = [System.Windows.CornerRadius]::new(2); $sq.Background = Get-TMVendorBrush $v
        $sq.Margin = New-Thickness 0 0 4 0
        [void]$s.Children.Add($sq)
        $t = New-Text -Text (Get-TMVendorName $v) -Size 10 -Brush $script:T.Secondary
        $t.Margin = New-Thickness 0 0 12 0
        [void]$s.Children.Add($t)
    }
    return $s
}

function New-Insight($Share, [string]$Text) {
    $v = Get-TMNumber $Share
    if ($null -eq $v -or $v -lt 0.05) { return $null }
    $s = New-Stack 'Horizontal'
    $s.Margin = New-Thickness 0 2 0 2
    $brush = if ($v -ge 0.5) { $script:T.Amber } else { $script:T.Text }
    [void]$s.Children.Add((New-Text -Text ('{0}%' -f [long][Math]::Round($v * 100)) -Size 11.5 -Weight 'SemiBold' -Brush $brush -Tabular))
    [void]$s.Children.Add((New-Text -Text (' ' + $Text) -Size 11 -Brush $script:T.Secondary))
    return $s
}

function New-DriversList($Activity) {
    <# What drove Claude Code's work, by share of tokens spent while it was active. #>
    $s = New-Stack
    [void]$s.Children.Add((New-SectionTitle "What's using your limits?" '24h'))
    $sub = New-Text -Text "Last 24h $($script:G.Dot) approximate, overlapping $($script:G.Dot) this machine only, not claude.ai" -Size 9.5 -Brush $script:T.Tertiary -Wrap
    $sub.Margin = New-Thickness 0 2 0 6
    [void]$s.Children.Add($sub)
    foreach ($i in @((New-Insight $Activity.longContextShare 'ran above 150k context'), (New-Insight $Activity.subagentShare 'came from subagents'))) {
        if ($i) { [void]$s.Children.Add($i) }
    }
    $drivers = @($Activity.drivers)
    if ($drivers.Count -eq 0) {
        [void]$s.Children.Add((New-Text -Text 'No MCP servers, skills or subagents used in the last 24h.' -Size 10.5 -Brush $script:T.Tertiary))
    }
    $limit = if ($script:ShowAllDrivers) { 12 } else { 5 }
    foreach ($d in ($drivers | Select-Object -First $limit)) {
        $g = New-Grid @('*', 'Auto', '86', '38')
        $g.Margin = New-Thickness 0 3 0 3
        $names = New-Stack 'Horizontal'
        $nm = New-Text -Text $d.name -Size 11 -Trim; $nm.MaxWidth = 170
        [void]$names.Children.Add($nm)
        $kind = New-Text -Text ('  ' + $d.kind) -Size 10 -Brush $script:T.Tertiary
        [void]$names.Children.Add($kind)
        Add-ToGrid $g $names 0
        $bar = New-Bar -Width 80 -Height 4 -Fraction ([double]$d.share) -Tint $script:T.Accent
        $bar.Margin = New-Thickness 6 0 0 0
        Add-ToGrid $g $bar 2
        $pct = New-Text -Text ('{0}%' -f [long][Math]::Round([double]$d.share * 100)) -Size 11 -Tabular
        $pct.HorizontalAlignment = 'Right'
        Add-ToGrid $g $pct 3
        $g.ToolTip = '{0} {1} {2} calls in 24h' -f $d.kind, $script:G.Dot, $d.calls
        [void]$s.Children.Add($g)
    }
    if ($drivers.Count -gt 5) {
        $more = [System.Windows.Controls.Border]::new()
        $more.HorizontalAlignment = 'Left'; $more.Padding = New-Thickness 0 2 0 0
        $label = if ($script:ShowAllDrivers) { 'Show less' } else { 'Show {0} more' -f ([Math]::Min($drivers.Count, 12) - 5) }
        $more.Child = New-Text -Text $label -Size 10.5 -Brush $script:T.Accent
        $more.Cursor = [System.Windows.Input.Cursors]::Hand
        $more.Add_MouseLeftButtonUp({ param($x, $e) $script:ShowAllDrivers = -not $script:ShowAllDrivers; Update-MainView })
        [void]$s.Children.Add($more)
    }
    return $s
}

function New-BreakdownTable([string]$Title, $Tokens) {
    $s = New-Stack
    $hit = Get-TMCacheHit $Tokens
    $trailing = if ($null -ne $hit) { 'Cache hit {0}%' -f [long][Math]::Round($hit * 100) } else { $null }
    $t = New-SectionTitle $Title $trailing
    $t.Margin = New-Thickness 0 0 0 4
    [void]$s.Children.Add($t)
    $rows = @(@('Input', $Tokens.input), @('Output', $Tokens.output), @('Cache read', $Tokens.cacheRead), @('Cache write', $Tokens.cacheWrite), @('Requests', $Tokens.requests))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $g = New-Grid @('*', 'Auto')
        $g.Margin = New-Thickness 0 3 0 3
        Add-ToGrid $g (New-Text -Text $rows[$i][0] -Size 11 -Brush $script:T.Secondary) 0
        Add-ToGrid $g (New-Text -Text (Format-TMTokens ([double]$rows[$i][1])) -Size 11 -Tabular) 1
        [void]$s.Children.Add($g)
        if ($i -lt $rows.Count - 1) { [void]$s.Children.Add((New-Divider 0 0)) }
    }
    return $s
}

function New-ModelsList($Activity) {
    $s = New-Stack
    [void]$s.Children.Add((New-SectionTitle 'Tokens by model' '7d'))
    $top = @($Activity.models | Select-Object -First 5)
    $max = if ($top.Count) { [double]$top[0].tokens } else { 1 }
    foreach ($m in $top) {
        $g = New-Grid @('Auto', '*', '76', '50')
        $g.Margin = New-Thickness 0 4 0 0
        $badge = New-Badge ([string]$m.vendor) 14
        $badge.Margin = New-Thickness 0 0 7 0
        Add-ToGrid $g $badge 0
        Add-ToGrid $g (New-Text -Text (Get-TMModelDisplayName ([string]$m.model)) -Size 11 -Trim) 1
        Add-ToGrid $g (New-Bar -Width 70 -Height 4 -Fraction ([double]$m.tokens / [Math]::Max($max, 1)) -Tint (Get-TMVendorBrush ([string]$m.vendor))) 2
        $tok = New-Text -Text (Format-TMTokens ([double]$m.tokens)) -Size 11 -Tabular
        $tok.HorizontalAlignment = 'Right'
        Add-ToGrid $g $tok 3
        [void]$s.Children.Add($g)
    }
    return $s
}

function New-TipCard([string]$Text) {
    $b = [System.Windows.Controls.Border]::new()
    $b.Background = $script:T.Subtle; $b.CornerRadius = [System.Windows.CornerRadius]::new(8); $b.Padding = New-Thickness 9
    $b.Margin = New-Thickness 0 14 0 0
    $g = New-Grid @('Auto', '*')
    $bulb = New-Glyph $script:G.Bulb 11 $script:T.Amber
    $bulb.VerticalAlignment = 'Top'; $bulb.Margin = New-Thickness 0 0 7 0
    Add-ToGrid $g $bulb 0
    Add-ToGrid $g (New-Text -Text $Text -Size 10.5 -Brush $script:T.Secondary -Wrap) 1
    $b.Child = $g
    return $b
}

function Update-ActivityView($Body) {
    $a = $script:Activity
    if (-not $a) {
        $s = New-Stack
        $s.Margin = New-Thickness 0 20 0 0
        $pb = [System.Windows.Controls.ProgressBar]::new()
        $pb.IsIndeterminate = $true; $pb.Height = 3; $pb.Margin = New-Thickness 0 0 0 10
        [void]$s.Children.Add($pb)
        [void]$s.Children.Add((New-Text -Text "Reading local Claude Code, Codex and Copilot logs$($script:G.Ellipsis) the first pass takes a minute or two." -Size 11.5 -Brush $script:T.Secondary -Wrap))
        [void]$Body.Children.Add($s)
        return
    }
    $range = if ([int]$script:Settings.activityRange -eq 30) { 30 } else { 7 }
    $days = @($a.days)
    $shown = if ($days.Count -gt $range) { $days[($days.Count - $range)..($days.Count - 1)] } else { $days }
    $total = 0.0
    foreach ($d in $shown) { $total += [double]$d.claude + [double]$d.codex + [double]$d.copilot }

    $title = New-Grid @('*', 'Auto', 'Auto')
    Add-ToGrid $title (New-Text -Text ('Last {0} days' -f $range) -Size 12 -Weight 'SemiBold') 0
    $tot = New-Text -Text ('{0} tokens' -f (Format-TMTokens $total)) -Size 10.5 -Brush $script:T.Secondary -Tabular
    $tot.Margin = New-Thickness 0 0 10 0
    Add-ToGrid $title $tot 1
    Add-ToGrid $title (New-RangeToggle) 2
    $title.Margin = New-Thickness 0 0 0 8
    [void]$Body.Children.Add($title)
    [void]$Body.Children.Add((New-WeekChart $a $range $script:W 110))
    [void]$Body.Children.Add((New-Legend $a))
    [void]$Body.Children.Add((New-Divider 14 14))
    [void]$Body.Children.Add((New-DriversList $a))
    [void]$Body.Children.Add((New-Divider 14 14))
    [void]$Body.Children.Add((New-BreakdownTable "Claude $($script:G.Dot) last 24h" $a.claude24h))
    $codexTotal = [double]$a.codex24h.input + [double]$a.codex24h.output + [double]$a.codex24h.cacheRead + [double]$a.codex24h.cacheWrite
    if ($codexTotal -gt 0) {
        $t = New-BreakdownTable "Codex $($script:G.Dot) last 24h" $a.codex24h
        $t.Margin = New-Thickness 0 14 0 0
        [void]$Body.Children.Add($t)
    }
    [void]$Body.Children.Add((New-Divider 14 14))
    [void]$Body.Children.Add((New-ModelsList $a))
    $tip = Get-TMActivityTip $a
    if ($tip) { [void]$Body.Children.Add((New-TipCard $tip)) }
}

# ---------------------------------------------------------------- windows (XAML)

function Import-Xaml([string]$Xaml) {
    $reader = [System.Xml.XmlReader]::Create([IO.StringReader]::new($Xaml))
    try { return [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
}

$script:SharedStyles = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <!-- A thin scrollbar that suits both themes; the stock one is light grey on dark. -->
  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="8"/>
    <Setter Property="MinWidth" Value="8"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border CornerRadius="3" Background="{DynamicResource TM.Scroll}" Margin="2,0"/>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <!-- CheckBox drawn as a switch, like the macOS popover's toggles. -->
  <Style x:Key="Switch" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource TM.Text}"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Margin" Value="0,5"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ContentPresenter VerticalAlignment="Center" Margin="0,0,14,0" RecognizesAccessKey="True"/>
            <Border x:Name="Track" Grid.Column="1" Width="36" Height="20" CornerRadius="10"
                    Background="{DynamicResource TM.Track}" BorderBrush="{DynamicResource TM.Border}" BorderThickness="1">
              <Ellipse x:Name="Knob" Width="12" Height="12" Fill="{DynamicResource TM.Secondary}"
                       HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Border>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Track" Property="Background" Value="{DynamicResource TM.Accent}"/>
              <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource TM.Accent}"/>
              <Setter TargetName="Knob" Property="Fill" Value="{DynamicResource TM.OnAccent}"/>
              <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource TM.Text}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.5"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="Background" Value="{DynamicResource TM.Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource TM.Text}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource TM.Border}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource TM.Text}"/>
    <Setter Property="Padding" Value="6,4"/>
    <Setter Property="FontSize" Value="12"/>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="{DynamicResource TM.Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource TM.Text}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource TM.Border}"/>
  </Style>
</ResourceDictionary>
'@

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TokenMeter" Width="440" Height="680" MinWidth="440" MaxWidth="440" MinHeight="420"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource TM.WindowBg}"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <DockPanel Margin="18,14,14,12">
    <Grid DockPanel.Dock="Top" Margin="0,0,4,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="TokenMeter" FontSize="16" FontWeight="SemiBold" Foreground="{DynamicResource TM.Text}" VerticalAlignment="Center"/>
      <Border Grid.Column="1" CornerRadius="7" Background="{DynamicResource TM.Track}" Padding="2" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <Border x:Name="TabLimits" CornerRadius="5" Padding="12,3">
            <TextBlock Text="Limits" FontSize="12" Foreground="{DynamicResource TM.Text}"/>
          </Border>
          <Border x:Name="TabActivity" CornerRadius="5" Padding="12,3">
            <TextBlock Text="Activity" FontSize="12" Foreground="{DynamicResource TM.Text}"/>
          </Border>
        </StackPanel>
      </Border>
      <Border x:Name="RefreshBtn" Grid.Column="2" CornerRadius="5" Width="28" Height="26" Margin="8,0,0,0" ToolTip="Refresh">
        <TextBlock Text="&#x21BB;" FontSize="14" Foreground="{DynamicResource TM.Secondary}" HorizontalAlignment="Center" VerticalAlignment="Center"
                   FontFamily="Segoe UI Symbol, Segoe UI"/>
      </Border>
      <Border x:Name="SettingsBtn" Grid.Column="3" CornerRadius="5" Width="28" Height="26" Margin="2,0,0,0" ToolTip="Settings">
        <TextBlock Text="&#x2699;" FontSize="14" Foreground="{DynamicResource TM.Secondary}" HorizontalAlignment="Center" VerticalAlignment="Center"
                   FontFamily="Segoe UI Symbol, Segoe UI"/>
      </Border>
    </Grid>
    <Border DockPanel.Dock="Bottom" BorderThickness="0,1,0,0" BorderBrush="{DynamicResource TM.Divider}" Padding="0,8,0,0" Margin="0,8,4,0">
      <TextBlock x:Name="Footer" FontSize="10" Foreground="{DynamicResource TM.Tertiary}"/>
    </Border>
    <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
      <StackPanel x:Name="Body" Width="372" HorizontalAlignment="Left" Margin="0,0,0,8"/>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

$script:WidgetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TokenMeter widget" Width="250" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" ShowActivated="False"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border x:Name="Card" CornerRadius="12" Background="{DynamicResource TM.WidgetBg}" BorderBrush="{DynamicResource TM.WidgetBorder}"
          BorderThickness="1" Padding="12,11,12,10" Margin="6">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.28"/>
    </Border.Effect>
    <StackPanel x:Name="WidgetBody"/>
  </Border>
</Window>
'@

$script:SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TokenMeter settings" Width="440" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource TM.WindowBg}"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <StackPanel Margin="22,18,22,18">
    <TextBlock Text="Notifications" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource TM.Secondary}" Margin="0,0,0,2"/>
    <CheckBox x:Name="Alerts" Style="{DynamicResource Switch}" Content="Alerts at 80%, 95% and when a window resets"/>

    <TextBlock Text="Claude Code" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource TM.Secondary}" Margin="0,14,0,2"/>
    <CheckBox x:Name="LiveClaude" Style="{DynamicResource Switch}" Content="Read Claude limits directly"/>
    <TextBlock FontSize="10.5" Foreground="{DynamicResource TM.Tertiary}" TextWrapping="Wrap" Margin="0,0,50,0"
               Text="Asks Anthropic for your plan limits with Claude Code's own sign-in, every few minutes. Read only: TokenMeter never refreshes or stores the token."/>

    <TextBlock Text="Startup and widget" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource TM.Secondary}" Margin="0,14,0,2"/>
    <CheckBox x:Name="StartAtLogin" Style="{DynamicResource Switch}" Content="Start TokenMeter when I sign in"/>
    <CheckBox x:Name="WidgetOnStart" Style="{DynamicResource Switch}" Content="Show the desktop widget at startup"/>
    <CheckBox x:Name="WidgetTopmost" Style="{DynamicResource Switch}" Content="Keep the widget above other windows"/>

    <TextBlock Text="Providers" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource TM.Secondary}" Margin="0,14,0,2"/>
    <CheckBox x:Name="ProvClaude" Style="{DynamicResource Switch}" Content="Claude Code"/>
    <CheckBox x:Name="ProvCodex" Style="{DynamicResource Switch}" Content="Codex"/>
    <CheckBox x:Name="ProvCopilot" Style="{DynamicResource Switch}" Content="GitHub Copilot (needs the gh CLI, signed in)"/>

    <TextBlock Text="Workspace names" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource TM.Secondary}" Margin="0,14,0,6"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="110"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Text="Codex" FontSize="12" Foreground="{DynamicResource TM.Text}" VerticalAlignment="Center"/>
      <TextBox x:Name="CodexName" Grid.Column="1" Margin="0,0,0,6"/>
      <TextBlock Grid.Row="1" Text="GitHub Copilot" FontSize="12" Foreground="{DynamicResource TM.Text}" VerticalAlignment="Center"/>
      <TextBox x:Name="CopilotName" Grid.Row="1" Grid.Column="1"/>
    </Grid>
    <TextBlock FontSize="10.5" Foreground="{DynamicResource TM.Tertiary}" TextWrapping="Wrap" Margin="0,6,0,0"
               Text="Shown for workspace plans. Neither sign-in carries the workspace name, so TokenMeter shows only the plan unless you name it here."/>

    <Grid Margin="0,20,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="OpenData" Text="Open data folder" FontSize="11" Foreground="{DynamicResource TM.Accent}" Cursor="Hand" VerticalAlignment="Center"/>
      <Border x:Name="CancelBtn" Grid.Column="1" CornerRadius="5" Padding="16,5" Margin="0,0,8,0" BorderThickness="1" BorderBrush="{DynamicResource TM.Border}">
        <TextBlock Text="Cancel" FontSize="12" Foreground="{DynamicResource TM.Text}"/>
      </Border>
      <Border x:Name="SaveBtn" Grid.Column="2" CornerRadius="5" Padding="18,5" Background="{DynamicResource TM.Accent}" Cursor="Hand">
        <TextBlock Text="Save" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource TM.OnAccent}"/>
      </Border>
    </Grid>
  </StackPanel>
</Window>
'@

# ---------------------------------------------------------------- main window

function Update-MainView {
    if (-not $script:Main -or -not $script:Main.IsVisible) { return }
    $now = Get-TMNow
    $body = $script:MainBody
    $body.Children.Clear()
    foreach ($pair in @(@($script:TabLimits, 'limits'), @($script:TabActivity, 'activity'))) {
        if ($script:Tab -eq $pair[1]) { $pair[0].Background = $script:T.Card; $pair[0].Tag = 'selected' }
        else { $pair[0].Background = [System.Windows.Media.Brushes]::Transparent; $pair[0].Tag = $null }
    }
    if ($script:Tab -eq 'activity') {
        Update-ActivityView $body
        $script:Footer.Text = if ($script:Activity) {
            $ago = Format-TMAgo ($now - [double]$script:Activity.generatedAt)
            "This machine only $($script:G.Dot) logs read {0}" -f $(if ($ago -eq 'Live') { 'just now' } else { $ago })
        } else { 'This machine only' }
    } else {
        Update-LimitsView $body $now
        $script:Footer.Text = "Notch on a bar = even pace $($script:G.Dot) click a header for the vendor's usage page"
    }
}

function New-MainWindow {
    $w = Import-Xaml $script:MainXaml
    $script:MainBody = $w.FindName('Body')
    $script:Footer = $w.FindName('Footer')
    $script:TabLimits = $w.FindName('TabLimits')
    $script:TabActivity = $w.FindName('TabActivity')
    foreach ($b in @($script:TabLimits, $script:TabActivity, $w.FindName('RefreshBtn'), $w.FindName('SettingsBtn'))) { Set-Hover $b }
    $script:TabLimits.Add_MouseLeftButtonUp({ $script:Tab = 'limits'; Update-MainView })
    $script:TabActivity.Add_MouseLeftButtonUp({ $script:Tab = 'activity'; Update-MainView })
    $w.FindName('RefreshBtn').Add_MouseLeftButtonUp({ Invoke-Safely 'refresh' { Request-Refresh } })
    $w.FindName('SettingsBtn').Add_MouseLeftButtonUp({ Invoke-Safely 'settings' { Show-Settings } })
    $w.Add_SourceInitialized({ param($s, $e) Set-TMTitleBar $s })
    # Closing the window hides it; the app lives in the tray until Quit.
    $w.Add_Closing({ param($s, $e) if (-not $script:Quitting) { $e.Cancel = $true; $s.Hide() } })
    $w.Add_IsVisibleChanged({ param($s, $e) if ($s.IsVisible) { Update-MainView } })
    return $w
}

function Show-Main {
    if ($script:Main.WindowState -eq 'Minimized') { $script:Main.WindowState = 'Normal' }
    $script:Main.Show()
    [void]$script:Main.Activate()
    Update-MainView
}

# ---------------------------------------------------------------- widget
#
# A small card on the desktop with each provider's hottest meter. Borderless,
# draggable, optionally above other windows, and kept out of Alt+Tab.

function Update-WidgetView {
    if (-not $script:Widget -or -not $script:Widget.IsVisible) { return }
    $now = Get-TMNow
    $body = $script:WidgetBody
    $body.Children.Clear()
    $providers = @($script:Board.providers)
    if ($providers.Count -eq 0) {
        [void]$body.Children.Add((New-Text -Text 'Waiting for Claude Code, Codex or Copilot.' -Size 10.5 -Brush $script:T.Secondary -Wrap))
        return
    }
    # 250 window - 2 x 6 shadow margin - 2 x 1 border - 2 x 12 padding.
    $width = 212
    for ($i = 0; $i -lt $providers.Count; $i++) {
        $p = $providers[$i]
        $stale = Test-TMProviderStale $p $now
        $m = Get-TMHottestMeter $p $now
        $block = New-Stack
        if ($i -gt 0) { $block.Margin = New-Thickness 0 10 0 0 }

        $head = New-Grid @('Auto', '*', 'Auto', 'Auto')
        $badge = New-Badge ([string]$p.vendor) 16
        $badge.Margin = New-Thickness 0 0 7 0
        Add-ToGrid $head $badge 0
        Add-ToGrid $head (New-Text -Text (Get-TMVendorName ([string]$p.vendor)) -Size 11.5 -Weight 'SemiBold' -Trim) 1
        if ($m -and -not $stale -and ($null -ne (Get-TMLimitDate $m $now))) {
            $fl = New-Glyph $script:G.Flame 9.5 (Get-TMTintBrush (Get-TMMeterTint $m $now)); $fl.Margin = New-Thickness 0 0 4 0
            Add-ToGrid $head $fl 2
        }
        if ($m) {
            $f = Get-TMMeterFraction $m $now
            $brush = if ($stale) { $script:T.Secondary } else { $script:T.Text }
            Add-ToGrid $head (New-Text -Text ('{0}%' -f [long][Math]::Round($f * 100)) -Size 15 -Weight 'SemiBold' -Brush $brush -Tabular) 3
        }
        [void]$block.Children.Add($head)

        if ($m) {
            $f = Get-TMMeterFraction $m $now
            $pace = if ($stale) { $null } else { Get-TMElapsedFraction $m $now }
            $bar = New-Bar -Width $width -Height 4 -Fraction $f -Tint (Get-TMTintBrush (Get-TMMeterTint $m $now)) -Pace $pace -Opacity $(if ($stale) { 0.55 } else { 1 })
            $bar.Margin = New-Thickness 0 4 0 2
            [void]$block.Children.Add($bar)
            $sub = if ($stale) { '{0} {1} {2}' -f $m.label, $script:G.Dot, (Format-TMAgo ($now - [double]$p.updatedAt)) }
                   else { '{0} {1} {2}' -f $m.label, $script:G.Dot, (Get-TMResetText $m $now) }
            [void]$block.Children.Add((New-Text -Text $sub -Size 10 -Brush $script:T.Tertiary -Tabular -Trim))
        } elseif ($p.note) {
            $n = New-Text -Text $p.note -Size 10 -Brush $script:T.Tertiary -Trim
            $n.Margin = New-Thickness 0 3 0 0
            [void]$block.Children.Add($n)
        } else {
            [void]$block.Children.Add((New-Text -Text 'No limits reported yet' -Size 10 -Brush $script:T.Tertiary))
        }
        [void]$body.Children.Add($block)
    }
}

function Save-WidgetPosition {
    if (-not $script:Widget) { return }
    $script:Settings.widgetLeft = [Math]::Round($script:Widget.Left)
    $script:Settings.widgetTop = [Math]::Round($script:Widget.Top)
    Invoke-Safely 'save widget position' { Save-TMSettings -Settings $script:Settings -Path $script:P.SettingsPath }
}

function Set-WidgetOnScreen {
    <# A saved position can point at a monitor that has since been unplugged. #>
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vr = $vl + [System.Windows.SystemParameters]::VirtualScreenWidth
    $vb = $vt + [System.Windows.SystemParameters]::VirtualScreenHeight
    $w = $script:Widget
    if ($w.Left + 60 -gt $vr -or $w.Left + $w.Width - 60 -lt $vl -or $w.Top + 30 -gt $vb -or $w.Top -lt $vt - 10) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.Left = $wa.Right - $w.Width - 16; $w.Top = $wa.Top + 16
    }
}

function New-WidgetWindow {
    $w = Import-Xaml $script:WidgetXaml
    $script:WidgetBody = $w.FindName('WidgetBody')
    $w.Topmost = [bool]$script:Settings.widgetTopmost
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w.Left = if ($null -ne $script:Settings.widgetLeft) { [double]$script:Settings.widgetLeft } else { $wa.Right - 266 }
    $w.Top = if ($null -ne $script:Settings.widgetTop) { [double]$script:Settings.widgetTop } else { $wa.Top + 16 }

    $w.Add_SourceInitialized({ param($s, $e)
        # WS_EX_TOOLWINDOW keeps the widget out of Alt+Tab and the taskbar.
        try {
            $h = [System.Windows.Interop.WindowInteropHelper]::new($s).Handle
            $ex = [TokenMeter.Native]::GetWindowLong($h, -20)
            [void][TokenMeter.Native]::SetWindowLong($h, -20, (($ex -bor 0x80) -band (-bnot 0x40000)))
        } catch { }
    })
    $w.Add_MouseLeftButtonDown({ param($s, $e)
        if ($e.ClickCount -ge 2) { Show-Main; return }
        try { $s.DragMove() } catch { }
        Save-WidgetPosition
    })

    $menu = [System.Windows.Controls.ContextMenu]::new()
    $miOpen = [System.Windows.Controls.MenuItem]::new(); $miOpen.Header = 'Open TokenMeter'; $miOpen.Add_Click({ Show-Main })
    $script:MiWidgetTop = [System.Windows.Controls.MenuItem]::new(); $script:MiWidgetTop.Header = 'Keep on top'; $script:MiWidgetTop.IsCheckable = $true
    $script:MiWidgetTop.IsChecked = [bool]$script:Settings.widgetTopmost
    $script:MiWidgetTop.Add_Click({ param($s, $e) Set-WidgetTopmost $s.IsChecked })
    $miRefresh = [System.Windows.Controls.MenuItem]::new(); $miRefresh.Header = 'Refresh'; $miRefresh.Add_Click({ Request-Refresh })
    $miHide = [System.Windows.Controls.MenuItem]::new(); $miHide.Header = 'Hide widget'; $miHide.Add_Click({ Set-WidgetVisible $false })
    foreach ($mi in @($miOpen, $script:MiWidgetTop, $miRefresh)) { [void]$menu.Items.Add($mi) }
    [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
    [void]$menu.Items.Add($miHide)
    $w.ContextMenu = $menu
    $w.Add_IsVisibleChanged({ param($s, $e) if ($s.IsVisible) { Set-WidgetOnScreen; Update-WidgetView } })
    return $w
}

function Set-WidgetVisible([bool]$On) {
    if ($On) { $script:Widget.Show() } else { $script:Widget.Hide() }
    if ($script:TrayWidgetItem) { $script:TrayWidgetItem.Checked = $On }
}

function Set-WidgetTopmost([bool]$On) {
    $script:Settings.widgetTopmost = $On
    $script:Widget.Topmost = $On
    if ($script:MiWidgetTop) { $script:MiWidgetTop.IsChecked = $On }
    Save-TMSettings -Settings $script:Settings -Path $script:P.SettingsPath
}

# ---------------------------------------------------------------- settings window

$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-StartAtLogin {
    try { return [bool](Get-ItemProperty -Path $script:RunKey -Name 'TokenMeter' -ErrorAction Stop).TokenMeter } catch { return $false }
}

function Set-StartAtLogin([bool]$On) {
    <# A per-user Run value pointing at the hidden launcher; nothing machine-wide. #>
    if ($On) {
        $vbs = Join-Path $PSScriptRoot 'Start-TokenMeter.vbs'
        $cmd = '"{0}" "{1}" -Background' -f (Join-Path $env:SystemRoot 'System32\wscript.exe'), $vbs
        Set-ItemProperty -Path $script:RunKey -Name 'TokenMeter' -Value $cmd
    } else {
        Remove-ItemProperty -Path $script:RunKey -Name 'TokenMeter' -ErrorAction SilentlyContinue
    }
}

function Show-Settings {
    if ($script:SettingsWindow) { [void]$script:SettingsWindow.Activate(); return }
    $w = Import-Xaml $script:SettingsXaml
    $script:SettingsWindow = $w
    $s = $script:Settings
    $f = @{}
    foreach ($n in 'Alerts', 'LiveClaude', 'StartAtLogin', 'WidgetOnStart', 'WidgetTopmost', 'ProvClaude', 'ProvCodex', 'ProvCopilot',
                   'CodexName', 'CopilotName', 'OpenData', 'CancelBtn', 'SaveBtn') { $f[$n] = $w.FindName($n) }
    $f.Alerts.IsChecked = [bool]$s.alertsEnabled
    $f.LiveClaude.IsChecked = [bool]$s.liveClaude
    $f.StartAtLogin.IsChecked = Get-StartAtLogin
    $f.WidgetOnStart.IsChecked = [bool]$s.widgetOnStart
    $f.WidgetTopmost.IsChecked = [bool]$s.widgetTopmost
    $f.ProvClaude.IsChecked = [bool]$s.providers.claude
    $f.ProvCodex.IsChecked = [bool]$s.providers.codex
    $f.ProvCopilot.IsChecked = [bool]$s.providers.copilot
    $f.CodexName.Text = [string]$s.codexAccountName
    $f.CopilotName.Text = [string]$s.copilotAccountName
    $w.Tag = $f
    Set-Hover $f.CancelBtn

    $f.OpenData.Add_MouseLeftButtonUp({ Invoke-Safely 'open data folder' {
        if (-not (Test-Path -LiteralPath $script:P.DataDir)) { New-Item -ItemType Directory -Path $script:P.DataDir -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:P.DataDir)
    } })
    $f.CancelBtn.Add_MouseLeftButtonUp({ $script:SettingsWindow.Close() })
    $f.SaveBtn.Add_MouseLeftButtonUp({ Invoke-Safely 'save settings' {
        $f = $script:SettingsWindow.Tag
        $s = $script:Settings
        $liveWas = [bool]$s.liveClaude
        $s.alertsEnabled = [bool]$f.Alerts.IsChecked
        $s.liveClaude = [bool]$f.LiveClaude.IsChecked
        $s.widgetOnStart = [bool]$f.WidgetOnStart.IsChecked
        $s.providers.claude = [bool]$f.ProvClaude.IsChecked
        $s.providers.codex = [bool]$f.ProvCodex.IsChecked
        $s.providers.copilot = [bool]$f.ProvCopilot.IsChecked
        $s.codexAccountName = $f.CodexName.Text.Trim()
        $s.copilotAccountName = $f.CopilotName.Text.Trim()
        Save-TMSettings -Settings $s -Path $script:P.SettingsPath
        Set-WidgetTopmost ([bool]$f.WidgetTopmost.IsChecked)
        if ((Get-StartAtLogin) -ne [bool]$f.StartAtLogin.IsChecked) { Set-StartAtLogin ([bool]$f.StartAtLogin.IsChecked) }
        if (-not $s.liveClaude) { $script:Live = $null; $script:LiveProblem = $null }
        elseif (-not $liveWas) { $script:LiveNext = 0 }
        if ($s.copilotAccountName -ne $script:CopilotAccountSeen) { $script:CopilotNext = 0 }
        $script:SettingsWindow.Close()
        $script:LastScan = 0      # provider set may have changed: rescan logs
        Update-Data
    } })
    $w.Add_SourceInitialized({ param($x, $e) Set-TMTitleBar $x })
    $w.Add_Closed({ $script:SettingsWindow = $null })
    $w.Show()
    [void]$w.Activate()
}

# ---------------------------------------------------------------- tray

function New-TrayIconImage([string]$Text, [string]$Tint) {
    <#
    Draws the hottest percentage into the tray icon, coloured by pace. The
    background is always dark so the colours read on either taskbar theme.
    #>
    $colors = Get-TMThemeColors $true
    $hex = switch ($Tint) { 'red' { $colors.Red } 'amber' { $colors.Amber } 'none' { '#C8C8C8' } default { $colors.Accent } }
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 8
        $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc(31 - $r * 2, 0, $r * 2, $r * 2, 270, 90)
        $path.AddArc(31 - $r * 2, 31 - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, 31 - $r * 2, $r * 2, $r * 2, 90, 90)
        $path.CloseFigure()
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#1E1E1E'))
        $g.FillPath($bg, $path)
        $size = if ($Text.Length -ge 3) { 12.5 } else { 17 }
        $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fg = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $g.DrawString($Text, $font, $fg, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $fmt)
        $font.Dispose(); $fg.Dispose(); $bg.Dispose(); $path.Dispose(); $fmt.Dispose()
    } finally { $g.Dispose() }
    $h = $bmp.GetHicon()
    try { return [System.Drawing.Icon]::FromHandle($h).Clone() }
    finally { [void][TokenMeter.Native]::DestroyIcon($h); $bmp.Dispose() }
}

function Update-Tray {
    <# "37" in the tray; the tooltip lists every provider, within the 63-character limit. #>
    $now = Get-TMNow
    $best = $null; $bestF = -1.0; $parts = @()
    foreach ($p in @($script:Board.providers)) {
        $m = Get-TMHottestMeter $p $now
        if (-not $m) { continue }
        $f = Get-TMMeterFraction $m $now
        $parts += '{0} {1}%' -f @{ claude = 'Claude'; codex = 'Codex'; copilot = 'Copilot' }[[string]$p.vendor], [long][Math]::Round($f * 100)
        if (-not (Test-TMProviderStale $p $now) -and $f -gt $bestF) { $best = $m; $bestF = $f }
    }
    if ($best) { $text = '{0}' -f [long][Math]::Round($bestF * 100); $tint = Get-TMMeterTint $best $now }
    else { $text = '--'; $tint = 'none' }
    $stamp = "$text|$tint"
    if ($stamp -ne $script:TrayStamp) {
        $old = $script:Tray.Icon
        $script:Tray.Icon = New-TrayIconImage $text $tint
        if ($old) { $old.Dispose() }
        $script:TrayStamp = $stamp
    }
    $tip = if ($parts.Count) { 'TokenMeter ' + $script:G.Dot + ' ' + ($parts -join " $($script:G.Dot) ") } else { 'TokenMeter' }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + $script:G.Ellipsis }
    $script:Tray.Text = $tip
}

function New-Tray {
    $t = New-Object System.Windows.Forms.NotifyIcon
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $open = $menu.Items.Add('Open TokenMeter')
    $open.Font = New-Object System.Drawing.Font($open.Font, [System.Drawing.FontStyle]::Bold)
    $open.Add_Click({ Show-Main })
    $script:TrayWidgetItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Show widget'
    $script:TrayWidgetItem.CheckOnClick = $true
    $script:TrayWidgetItem.Add_Click({ param($s, $e) Set-WidgetVisible $s.Checked })
    [void]$menu.Items.Add($script:TrayWidgetItem)
    $settings = $menu.Items.Add('Settings' + $script:G.Ellipsis); $settings.Add_Click({ Show-Settings })
    $refresh = $menu.Items.Add('Refresh now'); $refresh.Add_Click({ Request-Refresh })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $quit = $menu.Items.Add('Quit TokenMeter'); $quit.Add_Click({ Stop-App })
    $t.ContextMenuStrip = $menu
    $t.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main } })
    $t.Add_BalloonTipClicked({ Show-Main })
    $t.Icon = New-TrayIconImage '--' 'none'
    $t.Text = 'TokenMeter'
    $t.Visible = $true
    return $t
}

function Send-Alerts {
    <# Balloon tips, one at a time: Windows replaces a showing balloon with the next. #>
    if (-not $script:Settings.alertsEnabled -or -not $script:Board) { return }
    $r = Invoke-TMAlerts -Board $script:Board -State $script:AlertState -Now (Get-TMNow)
    foreach ($n in $r.Notifications) { $script:BalloonQueue.Enqueue($n) }
    $before = if ($script:AlertState) { ConvertTo-TMJson $script:AlertState } else { '' }
    $script:AlertState = $r.State
    $after = ConvertTo-TMJson $r.State
    if ($after -ne $before) { Invoke-Safely 'save alert state' { Write-TMFileAtomic -Path $script:P.AlertsPath -Text $after } }
}

function Show-NextBalloon {
    if ($script:BalloonQueue.Count -eq 0 -or ([DateTime]::UtcNow - $script:LastBalloon).TotalSeconds -lt 7) { return }
    $n = $script:BalloonQueue.Dequeue()
    $script:Tray.ShowBalloonTip(8000, $n.Title, $n.Body, [System.Windows.Forms.ToolTipIcon]::Info)
    $script:LastBalloon = [DateTime]::UtcNow
}

# ---------------------------------------------------------------- background work
#
# Network reads and the log scan run on a runspace pool with the Core module
# loaded. A DispatcherTimer collects finished jobs on the UI thread, so all
# state changes happen there and nothing needs a lock.

function Start-Pool {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $iss.ImportPSModule(@((Join-Path $PSScriptRoot 'TokenMeter.Core.psm1')))
    $script:Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 3, $iss, $Host)
    $script:Pool.Open()
    $script:Jobs = @{}
}

function Start-Job2([string]$Name, [string]$Script, [hashtable]$Params, [scriptblock]$OnDone) {
    <# One job per name at a time; returns $false when that job is already running. #>
    if ($script:Jobs.ContainsKey($Name)) { return $false }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Script)
    if ($Params) { [void]$ps.AddParameters($Params) }
    $script:Jobs[$Name] = @{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone }
    return $true
}

function Receive-Jobs {
    foreach ($name in @($script:Jobs.Keys)) {
        $j = $script:Jobs[$name]
        if (-not $j.Handle.IsCompleted) { continue }
        $script:Jobs.Remove($name)
        $result = $null
        try {
            $out = $j.PS.EndInvoke($j.Handle)
            if ($out.Count -gt 0) { $result = $out[$out.Count - 1]; if ($result -is [psobject]) { $result = $result.PSObject.BaseObject } }
            foreach ($err in $j.PS.Streams.Error) { Write-Log ('{0}: {1}' -f $name, $err.Exception.Message) }
        } catch {
            Write-Log ('{0} failed: {1}' -f $name, $_.Exception.Message)
        } finally { $j.PS.Dispose() }
        Invoke-Safely "$name result" { & $j.OnDone $result }
    }
}

function Request-Live([double]$Now) {
    <# At most every three minutes; half an hour after a 429; an hour while the token is expired. #>
    if ($Now -lt $script:LiveNext) { return }
    $script:LiveNext = $Now + 180
    [void](Start-Job2 'claude-live' 'param($Path) Invoke-TMClaudeLive -CredentialsPath $Path' @{ Path = $script:P.ClaudeCredentials } {
        param($r)
        if (-not $r) { return }
        if ($r.Ok) {
            $script:Live = @{ Meters = $r.Meters; Extra = $r.Extra; FetchedAt = $r.FetchedAt }
            $script:LiveProblem = $null
        } else {
            $script:LiveProblem = Get-TMLiveProblemText $r.Failure $r.Status
            if ($r.Failure -eq 'rateLimited') { $script:LiveNext = (Get-TMNow) + 1800 }
            # Expired: Claude Code renews it on its next run; check hourly.
            if ($r.Failure -eq 'expired') { $script:LiveNext = (Get-TMNow) + 3600 }
            Write-Log ('claude live: {0} {1}' -f $r.Failure, $r.Status)
        }
        Update-Data
    })
}

function Request-Copilot([double]$Now) {
    <# Every five minutes through gh; hourly while gh is missing. #>
    if ($Now -lt $script:CopilotNext) { return }
    $script:CopilotNext = $Now + 300
    [void](Start-Job2 'copilot' 'Invoke-TMCopilotQuota' $null {
        param($r)
        if (-not $r) { return }
        if ($r.Ok) {
            $script:CopilotAccountSeen = [string]$script:Settings.copilotAccountName
            $script:Copilot = ConvertFrom-TMCopilotQuota -Response $r.Response -FetchedAt $r.FetchedAt -AccountOverride $script:Settings.copilotAccountName
            $script:CopilotProblem = $null
        } else {
            $script:CopilotProblem = switch ($r.Failure) {
                'noGh'    { $script:CopilotNext = (Get-TMNow) + 3600; 'Install the GitHub CLI (gh) and run gh auth login to read Copilot limits.' }
                'timeout' { 'gh did not answer; retrying in a few minutes.' }
                default   { if ($r.Detail) { 'gh api: ' + $r.Detail } else { 'gh api failed; retrying in a few minutes.' } }
            }
            Write-Log ('copilot: {0}' -f $r.Failure)
        }
        Update-Data
    })
}

function Request-Scan([double]$Now) {
    <# Every five minutes. The first pass over a month of logs takes a while; after that only appended lines are read. #>
    if (($Now - $script:LastScan) -lt 300) { return }
    $s = $script:Settings
    $params = @{
        ClaudeProjectsDir = $script:P.ClaudeProjects
        CodexSessionsDir  = $script:P.CodexSessions
        VSCodeUserDirs    = @($script:P.VSCodeUserDirs)
        CachePath         = $script:P.CachePath
        IncludeClaude     = [bool]$s.providers.claude
        IncludeCodex      = [bool]$s.providers.codex
        IncludeCopilot    = [bool]$s.providers.copilot
    }
    if (Start-Job2 'scan' 'param($A) Invoke-TMActivityScan @A' @{ A = $params } {
        param($r)
        if ($r) { $script:Activity = $r }
        Update-Data
    }) { $script:LastScan = $Now }
}

function Request-Refresh {
    <# The refresh button: re-read everything now, unless Claude has told us to back off. #>
    if ($script:LiveProblem -ne (Get-TMLiveProblemText 'rateLimited')) { $script:LiveNext = 0 }
    $script:CopilotNext = 0
    $script:LastScan = 0
    Update-Data
}

# ---------------------------------------------------------------- collect

function Update-Data {
    <#
    Rebuilds the board from local files and the latest background results,
    writes it when it changed, raises alerts and redraws. Cheap enough for
    every 20 seconds: the only file reads here are the tail of the newest
    Codex rollout and two small JSON files, re-parsed only when they change.
    #>
    if ($script:Quitting) { return }
    $now = Get-TMNow
    $s = $script:Settings
    Request-Scan $now

    $providers = @()
    if ($s.providers.claude) {
        $acct = Get-TMClaudeAccount -ClaudeJsonPath $script:P.ClaudeJson -AccountOverride $s.claudeAccountName
        if ($s.liveClaude) { Request-Live $now }
        $live = if ($s.liveClaude) { $script:Live } else { $null }
        $providers += Get-TMClaudeProvider -Account $acct -Live $live
    }
    if ($s.providers.codex) {
        $providers += Get-TMCodexProvider -CodexDir $script:P.CodexDir -AccountOverride $s.codexAccountName -Now $now
    }
    if ($s.providers.copilot) {
        Request-Copilot $now
        if ($script:Copilot) { $providers += $script:Copilot }
    }
    $activity = $script:Activity
    $board = New-TMBoard -Providers $providers -Activity $activity -Now $now
    $script:Board = $board

    # Compare without the timestamp so an unchanged board is not rewritten.
    $fp = Get-TMBoardFingerprint $board
    if ($fp -ne $script:Fingerprint) {
        $script:Fingerprint = $fp
        Invoke-Safely 'write board' { Write-TMBoard -Board $board -Path $script:P.BoardPath }
    }
    Send-Alerts
    Update-Tray
    Update-MainView
    Update-WidgetView
}

function Initialize-FromBoard {
    <#
    Starts from the last board on disk, so the window and widget show the
    previous figures (dimmed if old) instead of an empty state while the first
    reads run.
    #>
    $b = Read-TMBoard -Path $script:P.BoardPath
    if (-not $b) { return }
    foreach ($p in @($b.providers)) {
        if ($p.vendor -eq 'claude' -and $null -ne (Get-TMNumber $p.updatedAt)) {
            $script:Live = @{ Meters = @($p.meters); Extra = $p.extra; FetchedAt = [double]$p.updatedAt }
        }
        if ($p.vendor -eq 'copilot') { $script:Copilot = $p }
    }
    if (Test-TMObject $b.activity) { $script:Activity = $b.activity }
}

# ---------------------------------------------------------------- lifecycle

function Stop-App {
    if ($script:Quitting) { return }
    $script:Quitting = $true
    foreach ($t in @($script:PollTimer, $script:FastTimer, $script:TickTimer)) { if ($t) { $t.Stop() } }
    Save-WidgetPosition
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    foreach ($j in @($script:Jobs.Values)) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } }
    try { $script:Pool.Close() } catch { }
    foreach ($w in @($script:SettingsWindow, $script:Widget, $script:Main)) { if ($w) { try { $w.Close() } catch { } } }
    $script:App.Shutdown()
}

$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:App.Resources.MergedDictionaries.Add((Import-Xaml $script:SharedStyles))
$script:App.Add_DispatcherUnhandledException({ param($s, $e) Write-Log ('unhandled: ' + $e.Exception.Message); $e.Handled = $true })
[System.Windows.Forms.Application]::EnableVisualStyles()
[void](Set-TMTheme)

Start-Pool
Initialize-FromBoard
$script:Main = New-MainWindow
$script:Widget = New-WidgetWindow
$script:Tray = New-Tray

# Poll: limits every 20 s (the Claude and Copilot reads throttle themselves).
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromSeconds(20)
$script:PollTimer.Add_Tick({ Invoke-Safely 'poll' { Update-Data } })

# Fast: finished background jobs, queued balloons, and open/quit requests
# from a second launch or from uninstall.ps1.
$script:FastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FastTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:FastTimer.Add_Tick({
    Invoke-Safely 'jobs' { Receive-Jobs }
    Invoke-Safely 'balloon' { Show-NextBalloon }
    if ($script:OpenEvent.WaitOne(0)) { Invoke-Safely 'open' { Show-Main } }
    if ($script:QuitEvent.WaitOne(0)) { Stop-App }
})

# Tick: countdowns move and "Live" turns into "3m ago" without new data;
# also picks up a change of Windows theme.
$script:TickTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TickTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:TickTimer.Add_Tick({ Invoke-Safely 'tick' {
    [void](Set-TMTheme)
    Update-Tray; Update-MainView; Update-WidgetView
} })

if ($script:Settings.widgetOnStart) { Set-WidgetVisible $true }
if (-not $Background -or $script:FirstRun) { Show-Main }
Update-Data
if ($script:FirstRun) { Save-TMSettings -Settings $script:Settings -Path $script:P.SettingsPath }
foreach ($t in @($script:PollTimer, $script:FastTimer, $script:TickTimer)) { $t.Start() }

try {
    [void]$script:App.Run()
} finally {
    try { $script:Mutex.ReleaseMutex() } catch { }
    $script:Mutex.Dispose(); $script:OpenEvent.Dispose(); $script:QuitEvent.Dispose()
}
