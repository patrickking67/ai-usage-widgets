#Requires -Version 5.1
<#
TokenMeter.Core.psm1 - everything TokenMeter knows, and nothing it shows.

The Windows app (TokenMeter.ps1) is a thin WPF shell over this module. All
data logic lives here, with no UI types, so it runs under pwsh on any platform
and tests/Core.Tests.ps1 can check it on a Mac against spec/fixtures.

What it produces is the board (spec/board.md), the one JSON document every
TokenMeter client agrees on. Behaviour mirrors the macOS app, which is the
reference: apps/macos/App/Collector.swift, ClaudeLive.swift,
ActivityScanner.swift, Alerts.swift and Shared/Usage.swift.

Credentials: TokenMeter reads Claude Code's OAuth access token and sends it to
the one endpoint that needs it. It never writes, refreshes or stores it, and
never logs it. Refreshing from a second process rotates the grant and signs
every Claude Code session out, so an expired token is simply skipped until
Claude Code renews it itself. Codex's id_token is only decoded locally for its
plan claim. Copilot goes through the gh CLI, which keeps its own token.

Compatibility: Windows PowerShell 5.1 and PowerShell 7+. Source is ASCII only,
because 5.1 reads a BOM-less script as ANSI; the few non-ASCII characters the
UI needs are built from code points.
#>

Set-StrictMode -Off
Add-Type -AssemblyName System.Net.Http

# ---------------------------------------------------------------- constants

$script:Dot     = [string][char]0x00B7   # the middle dot in "Weekly (dot) Opus"
$script:EmDash  = [string][char]0x2014
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:VendorNames = @{ claude = 'Claude Code'; codex = 'Codex'; copilot = 'GitHub Copilot' }
# Vendors this client can draw. The board may carry others (cursor, grok, or
# ones not invented yet); readers skip them rather than fail.
$script:DrawableVendors = @('claude', 'codex', 'copilot')

$script:UsageUrl  = 'https://api.anthropic.com/api/oauth/usage'
# Without a claude-code User-Agent the usage endpoint answers 429, which looks
# like a real rate limit and is not.
$script:UserAgent = 'claude-code/2.1.59'

$script:StaleSeconds = 6 * 3600

# ---------------------------------------------------------------- JSON
#
# Two editions, two parsers. Windows PowerShell 5.1's ConvertFrom-Json is slow
# and caps input at 2 MB; its JavaScriptSerializer with the cap lifted is fast
# and returns dictionaries. PowerShell 7's ConvertFrom-Json -AsHashtable
# returns dictionaries too, so the rest of the module sees one shape either way.

$script:IsDesktop = $PSVersionTable.PSEdition -ne 'Core'
if ($script:IsDesktop) {
    Add-Type -AssemblyName System.Web.Extensions
    $script:Jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $script:Jss.MaxJsonLength = [int]::MaxValue
    $script:Jss.RecursionLimit = 256
    # .NET Framework may still default to TLS 1.0 for HttpClient.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} else {
    $script:FromJsonArgs = @{ AsHashtable = $true; Depth = 256; ErrorAction = 'Stop' }
    # 7.5+ can leave ISO dates as strings. Older 7.x turns them into DateTime,
    # which ConvertTo-TMUnix also accepts.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:FromJsonArgs.DateKind = 'String' }
}

function ConvertFrom-TMJson {
    <# Parses JSON text into hashtables/dictionaries and arrays. Throws on bad input. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($script:IsDesktop) { return $script:Jss.DeserializeObject($Text) }
    return ConvertFrom-Json -InputObject $Text @script:FromJsonArgs
}

function ConvertTo-TMJson {
    <# Compact JSON from dictionaries, lists and primitives. #>
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($script:IsDesktop) { return ConvertTo-TMJsonText $Value }
    return ConvertTo-Json -InputObject $Value -Depth 32 -Compress
}

$script:JsonControlChars = New-Object regex '[\x00-\x1f]'

function ConvertTo-TMJsonText {
    <#
    A small JSON writer for Windows PowerShell 5.1, whose ConvertTo-Json is
    slow and whose JavaScriptSerializer would serialise PowerShell's object
    wrappers instead of the values inside them. Also exported so the tests can
    check it against ConvertTo-Json on PowerShell 7.
    #>
    param([AllowNull()]$Value)
    $sb = New-Object System.Text.StringBuilder
    Write-TMJsonValue $sb $Value
    return $sb.ToString()
}

function Write-TMJsonValue {
    param([System.Text.StringBuilder]$Sb, $Value)
    if ($Value -is [System.Management.Automation.PSObject]) { $Value = $Value.PSObject.BaseObject }
    if ($null -eq $Value) { [void]$Sb.Append('null'); return }
    if ($Value -is [bool]) { [void]$Sb.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string] -or $Value -is [char]) {
        # Native replaces, not a per-character loop: every Windows path is full of backslashes.
        $t = ([string]$Value).Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
        if ($script:JsonControlChars.IsMatch($t)) {
            $t = $script:JsonControlChars.Replace($t, { param($m) '\u{0:x4}' -f [int][char]$m.Value })
        }
        [void]$Sb.Append('"').Append($t).Append('"'); return
    }
    if ($Value -is [double] -or $Value -is [single]) {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { [void]$Sb.Append('null') }
        else { [void]$Sb.Append($d.ToString('R', $script:Invariant)) }
        return
    }
    if ($Value -is [ValueType] -and $Value -isnot [DateTime] -and $Value -isnot [enum]) {
        [void]$Sb.Append(([IFormattable]$Value).ToString($null, $script:Invariant)); return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        [void]$Sb.Append('{'); $first = $true
        foreach ($k in $Value.Keys) {
            if (-not $first) { [void]$Sb.Append(',') }; $first = $false
            Write-TMJsonValue $Sb ([string]$k); [void]$Sb.Append(':'); Write-TMJsonValue $Sb $Value[$k]
        }
        [void]$Sb.Append('}'); return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        [void]$Sb.Append('['); $first = $true
        foreach ($v in $Value) {
            if (-not $first) { [void]$Sb.Append(',') }; $first = $false
            Write-TMJsonValue $Sb $v
        }
        [void]$Sb.Append(']'); return
    }
    Write-TMJsonValue $Sb ([string]$Value)
}

function Read-TMJsonFile {
    <# The parsed file, or $null when it is missing or not JSON. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ConvertFrom-TMJson ([IO.File]::ReadAllText($Path)) } catch { return $null }
}

# ~/.claude.json is rewritten constantly and can run to megabytes of project
# history; re-parsing it every 20 seconds would be most of the app's CPU. Keep
# the parse until the file's timestamp or size moves.
$script:JsonFileCache = @{}
function Read-TMJsonFileCached {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { $fi = New-Object IO.FileInfo($Path) } catch { return $null }
    if (-not $fi.Exists) { return $null }
    $stamp = '{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
    $hit = $script:JsonFileCache[$Path]
    if ($hit -and $hit.Stamp -eq $stamp) { return $hit.Value }
    $value = Read-TMJsonFile $Path
    $script:JsonFileCache[$Path] = @{ Stamp = $stamp; Value = $value }
    return $value
}

function Write-TMFileAtomic {
    <#
    Writes a sibling file and renames it over the target, so a reader (the
    widget, the Claude Code plugin) never sees half a document.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = '{0}.{1}.tmp' -f $Path, [Diagnostics.Process]::GetCurrentProcess().Id
    [IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    if ([IO.File]::Exists($Path)) {
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

# ---------------------------------------------------------------- small helpers

function Test-TMObject { param($Value) return ($Value -is [System.Collections.IDictionary]) }

function Get-TMNow { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }

function Get-TMNumber {
    <# A JSON number (or numeric string) as [double]; $null for anything else. #>
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    if ($Value -is [string]) {
        $d = 0.0
        if ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, $script:Invariant, [ref]$d)) { return $d }
        return $null
    }
    if ($Value -is [ValueType]) { try { return [double]$Value } catch { return $null } }
    return $null
}

function ConvertTo-TMUnix {
    <#
    Unix seconds from an ISO-8601 string, a DateTime, a DateTimeOffset or a
    number. Strings without an offset are taken as UTC, like the vendors mean.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUnixTimeMilliseconds() / 1000.0 }
    if ($Value -is [DateTime]) {
        $dt = if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
        return ([DateTimeOffset]$dt).ToUnixTimeMilliseconds() / 1000.0
    }
    if ($Value -is [string]) {
        $dto = [DateTimeOffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AllowWhiteSpaces
        if ([DateTimeOffset]::TryParse($Value, $script:Invariant, $styles, [ref]$dto)) { return $dto.ToUnixTimeMilliseconds() / 1000.0 }
        return $null
    }
    return Get-TMNumber $Value
}

function Get-TMHourKey {
    <# "1790564400": the start of the UTC hour, which is also a local hour boundary in whole-hour zones. #>
    param([double]$Unix)
    return ([long][Math]::Floor($Unix / 3600) * 3600).ToString($script:Invariant)
}

function ConvertTo-TMLocalMidnight {
    <# Unix seconds of local midnight on the day containing $Unix. #>
    param([double]$Unix)
    $local = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($Unix * 1000)).ToLocalTime()
    return [double]([DateTimeOffset]::new($local.Date)).ToUnixTimeSeconds()
}

function Find-TMKey {
    <# Depth-first search for a key; Codex nests rate_limits at different depths across versions. #>
    param($Object, [string]$Key)
    if (Test-TMObject $Object) {
        if ($null -ne $Object[$Key]) { return $Object[$Key] }
        foreach ($v in $Object.Values) { $hit = Find-TMKey $v $Key; if ($null -ne $hit) { return $hit } }
    } elseif ($Object -is [System.Collections.IList]) {
        foreach ($v in $Object) { $hit = Find-TMKey $v $Key; if ($null -ne $hit) { return $hit } }
    }
    return $null
}

function Read-TMFileTail {
    <# The last $Bytes of a file as text, opened shared so a writer is never blocked. #>
    param([string]$Path, [int]$Bytes = 786432)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    } catch { return $null }
    try {
        $start = [Math]::Max([long]0, $fs.Length - $Bytes)
        [void]$fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ([int]($fs.Length - $start))
        $read = 0
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return $script:Utf8NoBom.GetString($buf, 0, $read)
    } finally { $fs.Dispose() }
}

function Get-TMJwtClaims {
    <# Decodes a JWT's payload locally. The token itself is not kept or logged. #>
    param([string]$Jwt)
    if (-not $Jwt) { return $null }
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
    while ($b64.Length % 4 -ne 0) { $b64 += '=' }
    try { return ConvertFrom-TMJson ($script:Utf8NoBom.GetString([Convert]::FromBase64String($b64))) } catch { return $null }
}

function ConvertTo-TMTitleCase {
    param([string]$Text)
    return $script:Invariant.TextInfo.ToTitleCase($Text.ToLowerInvariant())
}

# ---------------------------------------------------------------- paths

function Get-TMPaths {
    <#
    Where everything lives. Every location a vendor lets you move is followed:
    CLAUDE_CONFIG_DIR, CODEX_HOME, TOKENMETER_BOARD.
    #>
    [CmdletBinding()] param()
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $userHome '.claude' }
    # With CLAUDE_CONFIG_DIR set, Claude Code keeps .claude.json inside it.
    $claudeJson = Join-Path $userHome '.claude.json'
    if ($env:CLAUDE_CONFIG_DIR -and (Test-Path -LiteralPath (Join-Path $claudeDir '.claude.json'))) {
        $claudeJson = Join-Path $claudeDir '.claude.json'
    }
    $codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userHome '.codex' }

    $dataDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'TokenMeter' }
               else { Join-Path (Join-Path (Join-Path $userHome '.local') 'share') 'TokenMeter' }

    # VS Code (and Insiders) keep Copilot Chat sessions under their user dir.
    $vscode = @()
    if ($env:APPDATA) {
        $vscode = @((Join-Path $env:APPDATA 'Code\User'), (Join-Path $env:APPDATA 'Code - Insiders\User'))
    } elseif (Test-Path -LiteralPath (Join-Path $userHome 'Library')) {
        $as = Join-Path (Join-Path $userHome 'Library') 'Application Support'
        $vscode = @((Join-Path $as 'Code/User'), (Join-Path $as 'Code - Insiders/User'))
    } else {
        $vscode = @((Join-Path $userHome '.config/Code/User'), (Join-Path $userHome '.config/Code - Insiders/User'))
    }

    return @{
        Home              = $userHome
        ClaudeDir         = $claudeDir
        ClaudeJson        = $claudeJson
        ClaudeCredentials = Join-Path $claudeDir '.credentials.json'
        ClaudeProjects    = Join-Path $claudeDir 'projects'
        CodexDir          = $codexDir
        CodexSessions     = Join-Path $codexDir 'sessions'
        VSCodeUserDirs    = $vscode
        DataDir           = $dataDir
        BoardPath         = if ($env:TOKENMETER_BOARD) { $env:TOKENMETER_BOARD } else { Join-Path $dataDir 'board.json' }
        CachePath         = Join-Path $dataDir 'activity-cache.json'
        SettingsPath      = Join-Path $dataDir 'settings.json'
        AlertsPath        = Join-Path $dataDir 'alerts.json'
        LogPath           = Join-Path $dataDir 'tokenmeter.log'
    }
}

# ---------------------------------------------------------------- meters and pace

function New-TMMeter {
    <# One rate-limit window. resetsAt is omitted, not null, when unknown (spec). #>
    param([string]$Label, [double]$Used, $ResetsAt, [double]$WindowSeconds)
    $m = [ordered]@{ label = $Label; used = $Used }
    if ($null -ne $ResetsAt) { $m.resetsAt = [double]$ResetsAt }
    $m.windowSeconds = $WindowSeconds
    return $m
}

function Get-TMMeterFraction {
    <# 0..1. A window whose reset has passed is a fresh window, not a stuck one. #>
    param($Meter, [double]$Now = (Get-TMNow))
    $r = Get-TMNumber $Meter.resetsAt
    if ($null -ne $r -and $Now -ge $r) { return 0.0 }
    return [Math]::Min([Math]::Max((Get-TMNumber $Meter.used) / 100.0, 0.0), 1.0)
}

function Get-TMElapsedFraction {
    <# How far through the window we are, 0..1: where even use would put the bar. #>
    param($Meter, [double]$Now = (Get-TMNow))
    $r = Get-TMNumber $Meter.resetsAt
    $w = Get-TMNumber $Meter.windowSeconds
    if ($null -eq $r -or $r -le $Now -or -not ($w -gt 0)) { return $null }
    $elapsed = $w - ($r - $Now)
    if ($elapsed -le 0) { return $null }
    return [Math]::Min($elapsed / $w, 1.0)
}

function Get-TMProjectedAtReset {
    <#
    The percentage at reset if the rate so far holds. Nil in the first 8% of a
    window, where one burst would project nonsense.
    #>
    param($Meter, [double]$Now = (Get-TMNow))
    $e = Get-TMElapsedFraction $Meter $Now
    $used = Get-TMNumber $Meter.used
    if ($null -eq $e -or $e -lt 0.08 -or $used -lt 1) { return $null }
    return $used / $e
}

function Get-TMLimitDate {
    <# Unix seconds when this rate reaches 100%, if that lands before the reset. #>
    param($Meter, [double]$Now = (Get-TMNow))
    $r = Get-TMNumber $Meter.resetsAt
    $e = Get-TMElapsedFraction $Meter $Now
    $used = Get-TMNumber $Meter.used
    if ($null -eq $r -or $null -eq $e -or $e -lt 0.08 -or $used -lt 1 -or $used -ge 100) { return $null }
    $perSecond = $used / ($e * (Get-TMNumber $Meter.windowSeconds))
    $hit = $Now + (100 - $used) / $perSecond
    if ($hit -lt $r) { return $hit }
    return $null
}

function Get-TMMeterTint {
    <#
    'red', 'amber' or 'accent'. Colour by projection, not by the raw number:
    60% used with ten minutes left is fine; 60% used ten minutes into a
    five-hour window is not. Mirrors pace_colour() in the status line.
    #>
    param($Meter, [double]$Now = (Get-TMNow))
    $r = Get-TMNumber $Meter.resetsAt
    if ($null -eq $r) { return 'accent' }
    $used = (Get-TMMeterFraction $Meter $Now) * 100
    $w = Get-TMNumber $Meter.windowSeconds
    $left = [Math]::Max($r - $Now, 0)
    $elapsed = [Math]::Max($w - $left, 60)
    $projected = $used * $w / $elapsed
    if ($used -ge 90 -or $projected -ge 130) { return 'red' }
    if ($used -ge 70 -or $projected -ge 100) { return 'amber' }
    return 'accent'
}

function Format-TMCountdown {
    <# "2h 13m" / "41m" / "3d 4h" / "now" #>
    param([double]$Seconds)
    $s = [long][Math]::Max($Seconds, 0)
    if ($s -lt 60) { return 'now' }
    $h = [long][Math]::Floor($s / 3600); $m = [long][Math]::Floor(($s % 3600) / 60)
    if ($h -ge 24) { return '{0}d {1}h' -f [long][Math]::Floor($h / 24), ($h % 24) }
    if ($h -gt 0) { return '{0}h {1:00}m' -f $h, $m }
    return '{0}m' -f $m
}

function Format-TMAgo {
    <# "Live" under two minutes, then "5m ago", "3h ago", "4d ago". #>
    param([double]$Seconds)
    $s = [long]$Seconds
    if ($s -lt 120) { return 'Live' }
    if ($s -lt 3600) { return '{0}m ago' -f [long][Math]::Floor($s / 60) }
    if ($s -lt 86400) { return '{0}h ago' -f [long][Math]::Floor($s / 3600) }
    return '{0}d ago' -f [long][Math]::Floor($s / 86400)
}

function Get-TMResetText {
    <# "Resets in 4h 13m", "Resets Wednesday", "Resets Oct 1" or "Fresh window". #>
    param($Meter, [double]$Now = (Get-TMNow))
    $r = Get-TMNumber $Meter.resetsAt
    if ($null -eq $r -or $r -le $Now) { return 'Fresh window' }
    $w = Get-TMNumber $Meter.windowSeconds
    if ($w -le 18000 -or ($r - $Now) -lt 86400) { return 'Resets in ' + (Format-TMCountdown ($r - $Now)) }
    $local = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($r * 1000)).ToLocalTime()
    if (($r - $Now) -lt 7 * 86400) { return 'Resets ' + $local.ToString('dddd', $script:Invariant) }
    return 'Resets ' + $local.ToString('MMM d', $script:Invariant)
}

function Get-TMPaceNote {
    <#
    "Limit in 1h 40m" (hot) when the rate so far would exhaust the window
    before it resets, else "On pace for 64%", else $null.
    #>
    param($Meter, [double]$Now = (Get-TMNow))
    $hit = Get-TMLimitDate $Meter $Now
    if ($null -ne $hit) { return @{ Text = 'Limit in ' + (Format-TMCountdown ($hit - $Now)); Hot = $true } }
    $p = Get-TMProjectedAtReset $Meter $Now
    if ($null -ne $p) { return @{ Text = 'On pace for {0}%' -f [long][Math]::Round($p, [MidpointRounding]::AwayFromZero); Hot = $false } }
    return $null
}

function Test-TMProviderStale {
    <# Codex only reports during a session, so a figure can be days old. Past six hours it is stale. #>
    param($Provider, [double]$Now = (Get-TMNow))
    $u = Get-TMNumber $Provider.updatedAt
    if ($null -eq $u) { return $true }
    return ($Now - $u) -gt $script:StaleSeconds
}

function Get-TMHottestMeter {
    <# The meter closest to its limit: what the tray and the widget show. #>
    param($Provider, [double]$Now = (Get-TMNow))
    $best = $null; $bestF = -1.0
    foreach ($m in @($Provider.meters)) {
        if ($null -eq $m) { continue }
        $f = Get-TMMeterFraction $m $Now
        if ($f -gt $bestF) { $best = $m; $bestF = $f }
    }
    return $best
}

function Get-TMVendorName {
    param([string]$Vendor)
    if ($script:VendorNames.ContainsKey($Vendor)) { return $script:VendorNames[$Vendor] }
    return (ConvertTo-TMTitleCase $Vendor)
}

function Get-TMAccountLine {
    <# "Acme (dot) Business", or just the plan when there is no name. #>
    param($Provider)
    $parts = @($Provider.account, $Provider.plan) | Where-Object { $_ }
    return ($parts -join " $script:Dot ")
}

function Format-TMMoney {
    param([double]$Value)
    if ([Math]::Round($Value) -eq $Value) { return '$' + ([long]$Value).ToString($script:Invariant) }
    return '$' + $Value.ToString('0.00', $script:Invariant)
}

function Get-TMExtraText {
    <# "$42 of $200", or "$42" with no cap. #>
    param($Extra)
    $used = Format-TMMoney (Get-TMNumber $Extra.used)
    $limit = Get-TMNumber $Extra.limit
    if ($null -ne $limit) { return '{0} of {1}' -f $used, (Format-TMMoney $limit) }
    return $used
}

function Get-TMExtraFraction {
    param($Extra)
    $limit = Get-TMNumber $Extra.limit
    if ($null -eq $limit -or $limit -le 0) { return $null }
    return [Math]::Min((Get-TMNumber $Extra.used) / $limit, 1.0)
}

# ---------------------------------------------------------------- Claude Code: limits

function ConvertFrom-TMClaudeUsage {
    <#
    Decodes a /api/oauth/usage response. Any top-level object with a
    `utilization` is a window, so a window Anthropic adds later still shows up
    rather than silently vanishing.
    #>
    param([Parameter(Mandatory)]$Response, [double]$Now = (Get-TMNow))
    $known = @{
        five_hour        = @('Current', 18000, 0)
        seven_day        = @('Weekly', 604800, 1)
        seven_day_opus   = @("Weekly $script:Dot Opus", 604800, 2)
        seven_day_sonnet = @("Weekly $script:Dot Sonnet", 604800, 3)
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $extra = $null
    if (Test-TMObject $Response) {
        foreach ($key in @($Response.Keys)) {
            $obj = $Response[$key]
            if (-not (Test-TMObject $obj)) { continue }
            if ($key -eq 'extra_usage') {
                $used = Get-TMNumber $obj['used_credits']
                if ($obj['is_enabled'] -eq $true -and $null -ne $used) {
                    $extra = [ordered]@{ used = $used }
                    $limit = Get-TMNumber $obj['monthly_limit']
                    if ($null -ne $limit) { $extra.limit = $limit }
                }
                continue
            }
            $used = Get-TMNumber $obj['utilization']
            if ($null -eq $used) { continue }
            if ($known.ContainsKey($key)) {
                $k = $known[$key]
            } else {
                $span = if ($key.StartsWith('five')) { 18000 } else { 604800 }
                $k = @((ConvertTo-TMTitleCase ($key -replace '_', ' ')), $span, 9)
            }
            $meter = New-TMMeter -Label $k[0] -Used $used -ResetsAt (ConvertTo-TMUnix $obj['resets_at']) -WindowSeconds $k[1]
            $rows.Add(@{ Order = $k[2]; Key = $key; Meter = $meter })
        }
    }
    $sorted = @($rows | Sort-Object -Property @{ Expression = { $_.Order } }, @{ Expression = { $_.Key } })
    return @{ meters = @($sorted | ForEach-Object { $_.Meter }); extra = $extra; fetchedAt = $Now }
}

function Read-TMClaudeToken {
    <#
    Claude Code's access token from .credentials.json, read only. Returns
    @{ Status = 'ok'|'noToken'|'expired'; Token }. An expired token is not
    refreshed: that is Claude Code's job, and doing it here would sign every
    Claude Code session out.
    #>
    param([string]$CredentialsPath, [double]$Now = (Get-TMNow))
    $json = Read-TMJsonFile $CredentialsPath
    $oauth = if (Test-TMObject $json) { $json['claudeAiOauth'] } else { $null }
    $token = if (Test-TMObject $oauth) { [string]$oauth['accessToken'] } else { '' }
    if (-not $token) { return @{ Status = 'noToken'; Token = $null } }
    $exp = Get-TMNumber $oauth['expiresAt']      # milliseconds
    if ($null -ne $exp -and ($exp / 1000.0) -lt $Now) { return @{ Status = 'expired'; Token = $null } }
    return @{ Status = 'ok'; Token = $token }
}

function Get-TMLiveProblemText {
    <# What to say under the Claude card when the live read is not working; $null to stay quiet. #>
    param([string]$Failure, $Status)
    switch ($Failure) {
        'noToken'      { return 'Sign in to Claude Code to read limits directly.' }
        'expired'      { return 'Waiting for Claude Code to renew its sign-in.' }
        'unauthorized' { return "Claude rejected the token $script:EmDash open Claude Code to sign in again." }
        'rateLimited'  { return 'Claude usage endpoint is rate limiting; retrying later.' }
        'badResponse'  { return "Claude usage endpoint returned $Status." }
        default        { return $null }   # offline: stay quiet, try again next round
    }
}

function Invoke-TMClaudeLive {
    <#
    One read of Claude plan limits straight from Anthropic. Never throws;
    returns @{ Ok; Failure; Status; Meters; Extra; FetchedAt }. The token goes
    into the Authorization header and nowhere else.
    #>
    param([string]$CredentialsPath, [double]$Now = (Get-TMNow), [int]$TimeoutSeconds = 20)
    $t = Read-TMClaudeToken -CredentialsPath $CredentialsPath -Now $Now
    if ($t.Status -ne 'ok') { return @{ Ok = $false; Failure = $t.Status } }

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $status = -1; $body = $null
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $script:UsageUrl)
        [void]$req.Headers.TryAddWithoutValidation('Authorization', 'Bearer ' + $t.Token)
        [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $script:UserAgent)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } catch {
        return @{ Ok = $false; Failure = 'offline' }
    } finally {
        $t.Token = $null
        $client.Dispose()
    }
    switch ($status) {
        200 { }
        401 { return @{ Ok = $false; Failure = 'unauthorized'; Status = $status } }
        403 { return @{ Ok = $false; Failure = 'unauthorized'; Status = $status } }
        429 { return @{ Ok = $false; Failure = 'rateLimited'; Status = $status } }
        default { return @{ Ok = $false; Failure = 'badResponse'; Status = $status } }
    }
    try { $root = ConvertFrom-TMJson $body } catch { return @{ Ok = $false; Failure = 'badResponse'; Status = $status } }
    $snap = ConvertFrom-TMClaudeUsage -Response $root -Now (Get-TMNow)
    return @{ Ok = $true; Meters = $snap.meters; Extra = $snap.extra; FetchedAt = $snap.fetchedAt }
}

# ---------------------------------------------------------------- Claude Code: account

function Get-TMClaudeAccount {
    <#
    Account and plan from `oauthAccount` in ~/.claude.json: profile metadata,
    no secrets. Returns @{ Account; Plan } or $null.
    #>
    param([string]$ClaudeJsonPath, [string]$AccountOverride)
    $json = Read-TMJsonFileCached $ClaudeJsonPath
    $acct = if (Test-TMObject $json) { $json['oauthAccount'] } else { $null }
    if (-not (Test-TMObject $acct)) { return $null }

    $orgType = [string]$acct['organizationType']
    $isOrg = $orgType.Contains('team') -or $orgType.Contains('enterprise')
    $account = if ($AccountOverride -and $AccountOverride.Trim()) { $AccountOverride.Trim() }
               elseif ($isOrg) { if ($acct['organizationName']) { [string]$acct['organizationName'] } else { 'Organization' } }
               else { 'Personal' }

    # Individual plans carry their tier on the org (`default_claude_max_20x`)
    # with `userRateLimitTier` null, so read both before falling back to
    # `organizationType` (`claude_max`, `claude_pro`).
    $tier = (@($acct['userRateLimitTier'], $acct['organizationRateLimitTier']) | Where-Object { $_ -is [string] }) -join ' '
    $plan = if ($orgType.Contains('enterprise')) { 'Enterprise' }
            elseif ($orgType.Contains('team')) { 'Team' }
            elseif ($tier.Contains('max_20x')) { 'Max 20x' }
            elseif ($tier.Contains('max_5x')) { 'Max 5x' }
            elseif ($tier.Contains('max') -or $orgType.Contains('max')) { 'Max' }
            elseif ($tier.Contains('pro') -or $orgType.Contains('pro')) { 'Pro' }
            else { 'Free' }
    return @{ Account = $account; Plan = $plan }
}

function Get-TMClaudeProvider {
    <#
    The Claude provider from its account metadata and the last live snapshot
    (either may be missing). $null when there is neither.
    #>
    param($Account, $Live)
    if ($null -eq $Account -and $null -eq $Live) { return $null }
    $p = [ordered]@{ vendor = 'claude'; account = '' }
    if ($Account) { $p.account = $Account.Account; $p.plan = $Account.Plan }
    $p.meters = @()
    if ($Live) {
        $p.meters = @($Live.Meters)
        $p.updatedAt = [double]$Live.FetchedAt
        if ($Live.Extra) { $p.extra = $Live.Extra }
    }
    return $p
}

# ---------------------------------------------------------------- Codex

function Read-TMCodexRateLimits {
    <#
    The last `rate_limits` in a rollout that carries a real `primary` window.
    Later events can report another limit id with nulls (see
    fixtures/codex-two-limit-ids.jsonl); those are skipped, not shown as 0%.
    #>
    param([string]$Path, [int]$TailBytes = 786432)
    $tail = Read-TMFileTail -Path $Path -Bytes $TailBytes
    if (-not $tail) { return $null }
    $lines = $tail.Split([char]10)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line.Contains('"rate_limits"')) { continue }
        try { $obj = ConvertFrom-TMJson $line } catch { continue }
        $limits = Find-TMKey $obj 'rate_limits'
        if ((Test-TMObject $limits) -and (Test-TMObject $limits['primary'])) { return $limits }
    }
    return $null
}

function ConvertFrom-TMCodexLimits {
    <# Meters from a rate_limits object, shortest window first. #>
    param([Parameter(Mandatory)]$Limits, [double]$Mtime)
    $meters = [System.Collections.Generic.List[object]]::new()
    foreach ($key in 'primary', 'secondary') {
        $w = $Limits[$key]
        if (-not (Test-TMObject $w)) { continue }
        $used = Get-TMNumber $w['used_percent']
        if ($null -eq $used) { continue }
        $minutes = Get-TMNumber $w['window_minutes']; if ($null -eq $minutes) { $minutes = 0 }
        $resets = Get-TMNumber $w['resets_at']
        if ($null -eq $resets) {
            $inSec = Get-TMNumber $w['resets_in_seconds']
            if ($null -ne $inSec) { $resets = $Mtime + $inSec }
        }
        $label = if ($minutes -ge 10000) { 'Weekly' } elseif ($minutes -le 300) { 'Current' } else { '{0}h' -f [long]($minutes / 60) }
        $meters.Add((New-TMMeter -Label $label -Used $used -ResetsAt $resets -WindowSeconds ($minutes * 60)))
    }
    return @($meters | Sort-Object -Property @{ Expression = { $_.windowSeconds } })
}

function Get-TMCodexLimits {
    <#
    Newest rollout from the last week of day-directories
    (sessions/YYYY/MM/DD), then the last line in it with real limits.
    Returns @{ Limits; Mtime } or $null.
    #>
    param([string]$SessionsDir, [double]$Now = (Get-TMNow))
    $today = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($Now * 1000)).ToLocalTime().Date
    $candidates = [System.Collections.Generic.List[object]]::new()
    for ($back = 0; $back -lt 8; $back++) {
        $d = $today.AddDays(-$back)
        $dir = Join-Path $SessionsDir ('{0:0000}' -f $d.Year)
        $dir = Join-Path (Join-Path $dir ('{0:00}' -f $d.Month)) ('{0:00}' -f $d.Day)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) { $candidates.Add($f) }
    }
    foreach ($f in @($candidates | Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 5)) {
        $limits = Read-TMCodexRateLimits -Path $f.FullName
        if ($limits) {
            return @{ Limits = $limits; Mtime = ([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds() / 1000.0 }
        }
    }
    return $null
}

function Get-TMCodexPlanName {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    foreach ($pair in @(@('enterprise', 'Enterprise'), @('business', 'Business'), @('team', 'Team'), @('edu', 'Edu'),
                        @('pro', 'Pro'), @('plus', 'Plus'), @('free', 'Free'))) {
        if ($Raw.Contains($pair[0])) { return $pair[1] }
    }
    return (ConvertTo-TMTitleCase $Raw)
}

function Get-TMCodexProvider {
    <#
    Limits from the newest rollout; plan from the id_token's
    chatgpt_plan_type claim, decoded locally.

    The token's `organizations` are OpenAI *API platform* orgs, not the
    ChatGPT workspace, so their titles would be wrong here, and the workspace
    name is not in the token at all. A workspace plan shows the
    codexAccountName setting if there is one, else no name, just the plan.
    #>
    param([string]$CodexDir, [string]$AccountOverride, [double]$Now = (Get-TMNow))
    if (-not $CodexDir -or -not (Test-Path -LiteralPath $CodexDir -PathType Container)) { return $null }

    $isWorkspace = $false; $plan = $null
    $auth = Read-TMJsonFileCached (Join-Path $CodexDir 'auth.json')
    if ((Test-TMObject $auth) -and (Test-TMObject $auth['tokens'])) {
        $claims = Get-TMJwtClaims ([string]$auth['tokens']['id_token'])
        $openai = if (Test-TMObject $claims) { $claims['https://api.openai.com/auth'] } else { $null }
        if (Test-TMObject $openai) {
            $raw = [string]$openai['chatgpt_plan_type']
            $plan = Get-TMCodexPlanName $raw
            foreach ($w in 'business', 'team', 'enterprise', 'edu') { if ($raw.Contains($w)) { $isWorkspace = $true } }
        }
    }
    $account = if ($AccountOverride -and $AccountOverride.Trim()) { $AccountOverride.Trim() } elseif ($isWorkspace) { '' } else { 'Personal' }

    $p = [ordered]@{ vendor = 'codex'; account = $account }
    if ($plan) { $p.plan = $plan }
    $p.meters = @()
    $latest = Get-TMCodexLimits -SessionsDir (Join-Path $CodexDir 'sessions') -Now $Now
    if ($latest) {
        $p.meters = @(ConvertFrom-TMCodexLimits -Limits $latest.Limits -Mtime $latest.Mtime)
        $p.updatedAt = $latest.Mtime
    }
    return $p
}

# ---------------------------------------------------------------- GitHub Copilot

function Invoke-TMCopilotQuota {
    <#
    `gh api /copilot_internal/user`, through the gh CLI so TokenMeter never
    touches the GitHub token. Never throws; returns @{ Ok; Failure; Detail;
    Response; FetchedAt }.
    #>
    param([int]$TimeoutSeconds = 20)
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gh) { return @{ Ok = $false; Failure = 'noGh' } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $gh.Source
    $psi.Arguments = 'api /copilot_internal/user'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return @{ Ok = $false; Failure = 'timeout' }
        }
        $out = $outTask.GetAwaiter().GetResult()
        $err = $errTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) {
            # gh's own message ("HTTP 404", "not logged in"); scrubbed of anything token-shaped anyway.
            $first = (($err -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            $first = [regex]::Replace([string]$first, '(gh[opsu]_|github_pat_)[A-Za-z0-9_]+', '$1****')
            return @{ Ok = $false; Failure = 'ghFailed'; Detail = $first }
        }
        return @{ Ok = $true; Response = (ConvertFrom-TMJson $out); FetchedAt = (Get-TMNow) }
    } catch {
        return @{ Ok = $false; Failure = 'ghFailed' }
    }
}

function ConvertFrom-TMCopilotQuota {
    <#
    The Copilot provider from a /copilot_internal/user response.
    Premium requests are the lane that runs out: a "Monthly" meter when
    capped; when unlimited there is no percentage to show, so a note carries
    the month's credit count instead.
    #>
    param([Parameter(Mandatory)]$Response, [double]$FetchedAt = (Get-TMNow), [string]$AccountOverride)
    $rawPlan = [string]$Response['copilot_plan']
    $plan = if ($rawPlan) { ConvertTo-TMTitleCase ($rawPlan -replace '_', ' ') } else { $null }
    $isOrg = $rawPlan -match 'business|enterprise'
    $account = if ($AccountOverride -and $AccountOverride.Trim()) { $AccountOverride.Trim() } elseif ($isOrg) { '' } else { 'Personal' }

    $p = [ordered]@{ vendor = 'copilot'; account = $account }
    if ($plan) { $p.plan = $plan }
    $p.meters = @()
    $p.updatedAt = $FetchedAt

    $snap = if (Test-TMObject $Response['quota_snapshots']) { $Response['quota_snapshots']['premium_interactions'] } else { $null }
    if (Test-TMObject $snap) {
        if ($snap['unlimited'] -eq $false) {
            $remaining = Get-TMNumber $snap['percent_remaining']
            if ($null -ne $remaining) {
                # The quota resets at local midnight on quota_reset_date.
                $resets = $null
                $d = [DateTime]::MinValue
                if ([DateTime]::TryParseExact([string]$Response['quota_reset_date'], 'yyyy-MM-dd', $script:Invariant,
                        [Globalization.DateTimeStyles]::None, [ref]$d)) {
                    $resets = [double]([DateTimeOffset]::new($d)).ToUnixTimeSeconds()
                } else {
                    $resets = ConvertTo-TMUnix $Response['quota_reset_date_utc']
                }
                $p.meters = @(New-TMMeter -Label 'Monthly' -Used ([Math]::Max(100 - $remaining, 0)) -ResetsAt $resets -WindowSeconds (30 * 86400))
            }
        } elseif ($snap['unlimited'] -eq $true) {
            $credits = Get-TMNumber $snap['credits_used']
            if ($null -ne $credits) {
                $p.note = '{0} credits this month {1} no cap' -f ([long]$credits).ToString('N0', $script:Invariant), $script:Dot
            }
        }
    }
    return $p
}

# ---------------------------------------------------------------- activity: tallies

function New-TMTally { return @{ input = 0.0; output = 0.0; cacheRead = 0.0; cacheWrite = 0.0; requests = 0.0; subagent = 0.0; longContext = 0.0 } }

function Get-TMTallyTotal {
    <# "Total tokens" = input + output + cache read + cache write, as the vendors' dashboards count. #>
    param($T)
    return [double]$T.input + [double]$T.output + [double]$T.cacheRead + [double]$T.cacheWrite
}

function Add-TMTally {
    param($Tallies, [string]$Hour, [string]$Model, [double]$InputTokens, [double]$Output, [double]$CacheRead,
          [double]$CacheWrite, [double]$Requests, [double]$Subagent = 0, [double]$LongContext = 0)
    $byModel = $Tallies[$Hour]
    if ($null -eq $byModel) { $byModel = @{}; $Tallies[$Hour] = $byModel }
    $t = $byModel[$Model]
    if ($null -eq $t) { $t = New-TMTally; $byModel[$Model] = $t }
    $t.input += $InputTokens; $t.output += $Output; $t.cacheRead += $CacheRead; $t.cacheWrite += $CacheWrite
    $t.requests += $Requests; $t.subagent += $Subagent; $t.longContext += $LongContext
}

function New-TMFileState {
    return @{
        offset    = [long]0
        recentIDs = [System.Collections.Generic.List[string]]::new()   # Claude repeats a message across lines
        model     = $null                                                # Codex: from the latest turn_context
        lastTotal = 0.0                                                  # Codex: cumulative, to skip repeated events
        tallies   = @{}                                                  # hour -> model -> tally
        tools     = @{}                                                  # hour -> "kind|name" -> calls
        stamp     = $null                                                # Copilot: size|mtime of the last full read
    }
}

function ConvertTo-TMFileState {
    <# A state loaded from the cache file, with the types the scanner expects. #>
    param($Raw)
    $s = New-TMFileState
    if (-not (Test-TMObject $Raw)) { return $s }
    $s.offset = [long](Get-TMNumber $Raw['offset'])
    foreach ($id in @($Raw['recentIDs'])) { if ($id) { $s.recentIDs.Add([string]$id) } }
    $s.model = $Raw['model']
    $s.lastTotal = [double](Get-TMNumber $Raw['lastTotal'])
    $s.stamp = $Raw['stamp']
    if (Test-TMObject $Raw['tallies']) {
        foreach ($h in @($Raw['tallies'].Keys)) {
            $models = @{}
            foreach ($m in @($Raw['tallies'][$h].Keys)) {
                $src = $Raw['tallies'][$h][$m]; $t = New-TMTally
                foreach ($f in @($t.Keys)) { $v = Get-TMNumber $src[$f]; if ($null -ne $v) { $t[$f] = $v } }
                $models[[string]$m] = $t
            }
            $s.tallies[[string]$h] = $models
        }
    }
    if (Test-TMObject $Raw['tools']) {
        foreach ($h in @($Raw['tools'].Keys)) {
            $calls = @{}
            foreach ($k in @($Raw['tools'][$h].Keys)) { $calls[[string]$k] = [int](Get-TMNumber $Raw['tools'][$h][$k]) }
            $s.tools[[string]$h] = $calls
        }
    }
    return $s
}

function Read-TMActivityCache {
    param([string]$Path)
    $cache = @{ version = 2; files = @{} }
    $raw = Read-TMJsonFile $Path
    if ((Test-TMObject $raw) -and (Get-TMNumber $raw['version']) -eq 2 -and (Test-TMObject $raw['files'])) {
        foreach ($k in @($raw['files'].Keys)) { $cache.files[[string]$k] = ConvertTo-TMFileState $raw['files'][$k] }
    }
    return $cache
}

# ---------------------------------------------------------------- activity: Claude Code

function Get-TMDriver {
    <# "MCP|Desktop Commander", "Skill|superpowers:writing-plans", "Subagent|Explore", "Tool|Bash". #>
    param($Block)
    $name = [string]$Block['name']
    if (-not $name) { return $null }
    $inp = if (Test-TMObject $Block['input']) { $Block['input'] } else { @{} }
    if ($name.StartsWith('mcp__')) {
        $parts = $name -split '__'
        if ($parts.Count -lt 2) { return $null }
        $server = $parts[1]
        if ($server.StartsWith('plugin_')) {                       # plugin_<plugin>_<server>
            $server = @($server.Substring(7).Split('_'))[-1]
        }
        # claude.ai connectors are registered under a UUID; no name to show.
        if ($server -match '^[0-9a-f]{8}-') { $server = 'claude.ai connector' }
        return 'MCP|' + $server.Replace('_', ' ').Replace('-', ' ')
    }
    switch ($name) {
        'Skill' { if ($inp['skill']) { return 'Skill|' + [string]$inp['skill'] }; return $null }
        { $_ -eq 'Agent' -or $_ -eq 'Task' } {
            $type = if ($inp['subagent_type']) { [string]$inp['subagent_type'] } else { 'general-purpose' }
            return 'Subagent|' + $type
        }
        default { return 'Tool|' + $name }
    }
}

function Add-TMClaudeLine {
    <#
    One transcript line. Tools are counted on every line (each carries
    different content blocks); tokens once per message.id, because the same
    message repeats its usage on each of its lines.
    #>
    param([string]$Line, $State, [bool]$SubagentFile)
    try { $o = ConvertFrom-TMJson $Line } catch { return }
    if (-not (Test-TMObject $o)) { return }
    $msg = $o['message']
    if (-not (Test-TMObject $msg)) { return }
    $ts = ConvertTo-TMUnix $o['timestamp']
    if ($null -eq $ts) { return }
    $hour = Get-TMHourKey $ts

    foreach ($block in @($msg['content'])) {
        if ((Test-TMObject $block) -and $block['type'] -eq 'tool_use') {
            $d = Get-TMDriver $block
            if ($d) {
                $calls = $State.tools[$hour]
                if ($null -eq $calls) { $calls = @{}; $State.tools[$hour] = $calls }
                $calls[$d] = [int]$calls[$d] + 1
            }
        }
    }

    $id = [string]$msg['id']
    if (-not $id) { $id = [guid]::NewGuid().ToString() }
    $u = $msg['usage']
    if ($State.recentIDs.Contains($id) -or -not (Test-TMObject $u)) { return }
    $State.recentIDs.Add($id)
    if ($State.recentIDs.Count -gt 64) { $State.recentIDs.RemoveRange(0, $State.recentIDs.Count - 64) }

    $model = if ($msg['model']) { [string]$msg['model'] } else { 'unknown' }
    if ($model -eq '<synthetic>') { return }
    $in = [double](Get-TMNumber $u['input_tokens']); $out = [double](Get-TMNumber $u['output_tokens'])
    $cr = [double](Get-TMNumber $u['cache_read_input_tokens']); $cw = [double](Get-TMNumber $u['cache_creation_input_tokens'])
    $total = $in + $out + $cr + $cw
    $requests = if ($total -eq 0) { 0 } else { 1 }
    $sub = if ($SubagentFile -or $o['isSidechain'] -eq $true) { $total } else { 0 }
    $long = if (($in + $cr + $cw) -gt 150000) { $total } else { 0 }
    Add-TMTally $State.tallies $hour $model $in $out $cr $cw $requests $sub $long
}

# ---------------------------------------------------------------- activity: Codex

function Add-TMCodexLine {
    <#
    Codex re-emits the same token_count; the running total only moves on new
    work, so an event whose total did not grow is a repeat.
    #>
    param([string]$Line, $State)
    try { $o = ConvertFrom-TMJson $Line } catch { return }
    if (-not (Test-TMObject $o)) { return }
    $p = $o['payload']
    if (-not (Test-TMObject $p)) { return }
    if ($o['type'] -eq 'turn_context') {
        if ($p['model']) { $State.model = [string]$p['model'] }
        return
    }
    if ($p['type'] -ne 'token_count') { return }
    $info = $p['info']
    if (-not (Test-TMObject $info) -or -not (Test-TMObject $info['last_token_usage'])) { return }
    $ts = ConvertTo-TMUnix $o['timestamp']
    if ($null -eq $ts) { return }
    $last = $info['last_token_usage']
    $totalUsage = $info['total_token_usage']
    $total = if (Test-TMObject $totalUsage) { [double](Get-TMNumber $totalUsage['total_tokens']) } else { 0.0 }
    if ($total -le $State.lastTotal) { return }
    $State.lastTotal = $total

    $cached = [double](Get-TMNumber $last['cached_input_tokens'])
    $in = [Math]::Max([double](Get-TMNumber $last['input_tokens']) - $cached, 0)
    $model = if ($State.model) { [string]$State.model } else { 'codex' }
    Add-TMTally $State.tallies (Get-TMHourKey $ts) $model $in ([double](Get-TMNumber $last['output_tokens'])) $cached `
        ([double](Get-TMNumber $last['cache_write_input_tokens'])) 1
}

# ---------------------------------------------------------------- activity: incremental reader

function Update-TMLogState {
    <#
    Reads a JSONL log from its stored offset in 8 MB chunks and hands over
    complete lines only; a half-written last line waits for the next pass.
    Offsets are counted in bytes before decoding, so a multi-byte character
    can never straddle two reads. Memory stays at one chunk whatever the
    file size.
    #>
    param([string]$Path, [long]$Size, $State, [string]$Vendor, [bool]$SubagentFile, [byte[]]$Buffer)
    if ($Size -lt $State.offset) { $State = New-TMFileState }       # rewritten or truncated
    if ($Size -le $State.offset) { return $State }
    try { $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete') } catch { return $State }
    $carry = New-Object IO.MemoryStream
    try {
        [void]$fs.Seek($State.offset, 'Begin')
        while (($n = $fs.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $nl = [Array]::LastIndexOf($Buffer, [byte]10, $n - 1)
            if ($nl -lt 0) { $carry.Write($Buffer, 0, $n); continue }
            if ($carry.Length -gt 0) {
                $carry.Write($Buffer, 0, $nl + 1)
                $bytes = $carry.ToArray()
                $text = $script:Utf8NoBom.GetString($bytes)
                $consumed = $bytes.Length
                $carry.SetLength(0)
            } else {
                $text = $script:Utf8NoBom.GetString($Buffer, 0, $nl + 1)
                $consumed = $nl + 1
            }
            # A cheap substring test keeps JSON parsing to the lines that matter.
            if ($Vendor -eq 'claude') {
                foreach ($line in $text.Split([char]10)) {
                    if ($line.Contains('"type":"assistant"')) { Add-TMClaudeLine $line $State $SubagentFile }
                }
            } else {
                foreach ($line in $text.Split([char]10)) {
                    if ($line.Contains('"token_count"') -or $line.Contains('"turn_context"')) { Add-TMCodexLine $line $State }
                }
            }
            $State.offset += $consumed
            if ($nl + 1 -lt $n) { $carry.Write($Buffer, $nl + 1, $n - $nl - 1) }
        }
    } finally {
        $fs.Dispose(); $carry.Dispose()
    }
    return $State
}

# ---------------------------------------------------------------- activity: Copilot (VS Code chat sessions)

function Get-TMCopilotRequestFields {
    <# The fields TokenMeter needs from one chat request object. #>
    param($Request)
    $r = @{ requestId = [string]$Request['requestId']; timestamp = $Request['timestamp']; modelId = $Request['modelId']
            promptTokens = $Request['promptTokens']; completionTokens = $Request['completionTokens'] }
    $md = if (Test-TMObject $Request['result']) { $Request['result']['metadata'] } else { $null }
    if (Test-TMObject $md) {
        if ($null -eq $r.promptTokens) { $r.promptTokens = $md['promptTokens'] }
        if ($null -eq $r.completionTokens) { $r.completionTokens = $md['outputTokens'] }
    }
    return $r
}

function Find-TMCopilotRequests {
    <# Every object with a requestId, anywhere in a value: the fallback for layouts not replayed below. #>
    param($Value, $Into)
    if (Test-TMObject $Value) {
        if ($null -ne $Value['requestId']) { $Into.Add((Get-TMCopilotRequestFields $Value)) }
        foreach ($v in $Value.Values) { if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { Find-TMCopilotRequests $v $Into } }
    } elseif ($Value -is [System.Collections.IList]) {
        foreach ($v in $Value) { Find-TMCopilotRequests $v $Into }
    }
}

function Read-TMCopilotSession {
    <#
    Requests with token counts from one VS Code chat session file, deduped by
    requestId. A .jsonl session is a mutation log: kind 0 is a snapshot, kind 1
    sets a value at path k, kind 2 pushes onto the array at k (splicing at i
    first when given). Token counts mostly arrive as kind-1 sets on
    ["requests", n, "promptTokens"], so the log is replayed for the requests
    array; every object carrying a requestId is also collected, which covers
    the older whole-file .json format.
    #>
    param([string]$Path)
    $found = [System.Collections.Generic.List[object]]::new()
    $reqs = [System.Collections.Generic.List[object]]::new()
    if ($Path.EndsWith('.jsonl')) {
        try { $reader = New-Object IO.StreamReader($Path, $script:Utf8NoBom) } catch { return @{} }
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if (-not ($line.Contains('"requestId"') -or $line.Contains('Tokens"') -or $line.Contains('"modelId"') -or
                          $line.Contains('"k":["requests"') -or $line.Contains('"kind":0'))) { continue }
                try { $o = ConvertFrom-TMJson $line } catch { continue }
                if (-not (Test-TMObject $o)) { continue }
                $kind = Get-TMNumber $o['kind']; $k = @($o['k']); $v = $o['v']
                if ($kind -eq 0) {
                    $reqs.Clear()
                    if (Test-TMObject $v) { foreach ($r in @($v['requests'])) { if (Test-TMObject $r) { $reqs.Add((Get-TMCopilotRequestFields $r)) } } }
                    Find-TMCopilotRequests $v $found
                } elseif ($kind -eq 1 -and $k.Count -ge 2 -and $k[0] -eq 'requests') {
                    $i = [int](Get-TMNumber $k[1])
                    if ($i -lt 0 -or $i -ge $reqs.Count) { continue }
                    if ($k.Count -eq 2 -and (Test-TMObject $v)) { $reqs[$i] = Get-TMCopilotRequestFields $v }
                    elseif ($k.Count -eq 3) {
                        switch ([string]$k[2]) {
                            'promptTokens'     { $reqs[$i].promptTokens = $v }
                            'completionTokens' { $reqs[$i].completionTokens = $v }
                            'modelId'          { $reqs[$i].modelId = $v }
                            'result' {
                                $md = if (Test-TMObject $v) { $v['metadata'] } else { $null }
                                if (Test-TMObject $md) {
                                    if ($null -eq $reqs[$i].promptTokens) { $reqs[$i].promptTokens = $md['promptTokens'] }
                                    if ($null -eq $reqs[$i].completionTokens) { $reqs[$i].completionTokens = $md['outputTokens'] }
                                }
                            }
                        }
                    }
                } elseif ($kind -eq 2 -and $k.Count -eq 1 -and $k[0] -eq 'requests') {
                    $at = Get-TMNumber $o['i']
                    if ($null -ne $at -and $at -lt $reqs.Count) { $reqs.RemoveRange([int]$at, $reqs.Count - [int]$at) }
                    foreach ($r in @($v)) { if (Test-TMObject $r) { $reqs.Add((Get-TMCopilotRequestFields $r)) } }
                    Find-TMCopilotRequests $v $found
                }
            }
        } finally { $reader.Dispose() }
    } else {
        Find-TMCopilotRequests (Read-TMJsonFile $Path) $found
    }

    # Dedupe by requestId, keeping the largest counts seen for each.
    $byId = @{}
    $all = [System.Collections.Generic.List[object]]::new()
    $all.AddRange($reqs); $all.AddRange($found)
    foreach ($r in $all) {
        if (-not $r.requestId) { continue }
        $prompt = [double](Get-TMNumber $r.promptTokens); $completion = [double](Get-TMNumber $r.completionTokens)
        $prev = $byId[$r.requestId]
        if ($null -eq $prev) {
            $byId[$r.requestId] = @{ timestamp = $r.timestamp; modelId = $r.modelId; prompt = $prompt; completion = $completion }
        } else {
            $prev.prompt = [Math]::Max($prev.prompt, $prompt); $prev.completion = [Math]::Max($prev.completion, $completion)
            if (-not $prev.modelId) { $prev.modelId = $r.modelId }
            if ($null -eq $prev.timestamp) { $prev.timestamp = $r.timestamp }
        }
    }
    return $byId
}

function Update-TMCopilotState {
    <# VS Code rewrites session files, so each changed file is re-read whole; they are small. #>
    param([IO.FileInfo]$File, $State)
    $stamp = '{0}|{1}' -f $File.Length, $File.LastWriteTimeUtc.Ticks
    if ($State.stamp -eq $stamp) { return $State }
    $s = New-TMFileState
    $s.stamp = $stamp
    $byId = Read-TMCopilotSession -Path $File.FullName
    foreach ($id in @($byId.Keys)) {
        $r = $byId[$id]
        if ($r.prompt + $r.completion -le 0) { continue }
        $ms = Get-TMNumber $r.timestamp
        $ts = if ($null -ne $ms) { $ms / 1000.0 } else { ConvertTo-TMUnix $r.timestamp }
        if ($null -eq $ts) { continue }
        $model = [string]$r.modelId
        if ($model.StartsWith('copilot/')) { $model = $model.Substring(8) }
        if (-not $model) { $model = 'copilot' }
        Add-TMTally $s.tallies (Get-TMHourKey $ts) $model $r.prompt $r.completion 0 0 1
    }
    return $s
}

# ---------------------------------------------------------------- activity: scan and summary

function Get-TMRecentFiles {
    <# *.jsonl (and optionally *.json) under a root, modified since $Cutoff; hidden folders skipped. #>
    param([string]$Root, [double]$Cutoff, [string[]]$Extensions = @('.jsonl'))
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $cut = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($Cutoff * 1000)).UtcDateTime
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($Extensions -notcontains $f.Extension) { continue }
        if ($f.LastWriteTimeUtc -lt $cut) { continue }
        $out.Add($f)
    }
    return $out
}

function Invoke-TMActivityScan {
    <#
    Builds the board's `activity` from local logs: Claude Code transcripts,
    Codex rollouts and VS Code Copilot chat sessions.

    There are gigabytes of these, so each file is read once: the cache keeps
    every file's byte offset and hourly tallies, and later scans parse only
    what was appended. A first run over a busy month takes a minute or so;
    after that a pass is quick. Runs on a background runspace in the app.
    #>
    param(
        [string]$ClaudeProjectsDir,
        [string]$CodexSessionsDir,
        [string[]]$VSCodeUserDirs = @(),
        [Parameter(Mandatory)][string]$CachePath,
        [double]$Now = (Get-TMNow),
        [int]$RetentionDays = 31,
        [int]$Days = 30,
        [bool]$IncludeClaude = $true,
        [bool]$IncludeCodex = $true,
        [bool]$IncludeCopilot = $true
    )
    $cache = Read-TMActivityCache $CachePath
    $cutoff = $Now - $RetentionDays * 86400
    $seen = @{}
    $buffer = New-Object byte[] (8MB)

    if ($IncludeClaude) {
        foreach ($f in (Get-TMRecentFiles -Root $ClaudeProjectsDir -Cutoff $cutoff)) {
            $key = 'c:' + $f.FullName; $seen[$key] = $true
            $sub = $f.FullName.Replace('\', '/').Contains('/subagents/')
            $state = if ($cache.files.ContainsKey($key)) { $cache.files[$key] } else { New-TMFileState }
            $cache.files[$key] = Update-TMLogState -Path $f.FullName -Size $f.Length -State $state -Vendor 'claude' -SubagentFile $sub -Buffer $buffer
        }
    }
    if ($IncludeCodex) {
        foreach ($f in (Get-TMRecentFiles -Root $CodexSessionsDir -Cutoff $cutoff)) {
            $key = 'x:' + $f.FullName; $seen[$key] = $true
            $state = if ($cache.files.ContainsKey($key)) { $cache.files[$key] } else { New-TMFileState }
            $cache.files[$key] = Update-TMLogState -Path $f.FullName -Size $f.Length -State $state -Vendor 'codex' -SubagentFile $false -Buffer $buffer
        }
    }
    if ($IncludeCopilot) {
        foreach ($userDir in @($VSCodeUserDirs)) {
            if (-not $userDir) { continue }
            $roots = @()
            $ws = Join-Path $userDir 'workspaceStorage'
            if (Test-Path -LiteralPath $ws) {
                $roots += @(Get-ChildItem -LiteralPath $ws -Directory -ErrorAction SilentlyContinue |
                            ForEach-Object { Join-Path $_.FullName 'chatSessions' })
            }
            $roots += Join-Path (Join-Path $userDir 'globalStorage') 'emptyWindowChatSessions'
            foreach ($root in $roots) {
                foreach ($f in (Get-TMRecentFiles -Root $root -Cutoff $cutoff -Extensions @('.jsonl', '.json'))) {
                    $key = 'g:' + $f.FullName; $seen[$key] = $true
                    $state = if ($cache.files.ContainsKey($key)) { $cache.files[$key] } else { New-TMFileState }
                    $cache.files[$key] = Update-TMCopilotState -File $f -State $state
                }
            }
        }
    }

    # Forget files that aged out or vanished, and hours past the window.
    $cutoffHour = [Math]::Floor($cutoff / 3600) * 3600
    foreach ($k in @($cache.files.Keys)) {
        if (-not $seen.ContainsKey($k)) { $cache.files.Remove($k); continue }
        $s = $cache.files[$k]
        foreach ($h in @($s.tallies.Keys)) { if ([double]$h -lt $cutoffHour) { $s.tallies.Remove($h) } }
        foreach ($h in @($s.tools.Keys)) { if ([double]$h -lt $cutoffHour) { $s.tools.Remove($h) } }
    }
    try { Write-TMFileAtomic -Path $CachePath -Text (ConvertTo-TMJson $cache) } catch { }
    return Get-TMActivitySummary -Cache $cache -Now $Now -Days $Days -IncludeCopilot $IncludeCopilot
}

function Get-TMActivitySummary {
    <# The board's `activity` object from the cached hourly tallies. #>
    param([Parameter(Mandatory)]$Cache, [double]$Now = (Get-TMNow), [int]$Days = 30, [bool]$IncludeCopilot = $true)
    $today = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($Now * 1000)).ToLocalTime().Date
    $dayStarts = @(for ($i = $Days - 1; $i -ge 0; $i--) { [double]([DateTimeOffset]::new($today.AddDays(-$i))).ToUnixTimeSeconds() })
    $rangeStart = $dayStarts[0]
    # "models" stays a 7-day figure whatever the length of `days`.
    $weekStart = [double]([DateTimeOffset]::new($today.AddDays(-6))).ToUnixTimeSeconds()
    $dayAgo = $Now - 86400

    $perDay = @{}; $perModel = @{}; $dayOfHour = @{}
    $claude24 = New-TMTally; $codex24 = New-TMTally
    $calls = @{}; $driverTokens = @{}
    $vendorOf = @{ 'c' = 'claude'; 'x' = 'codex'; 'g' = 'copilot' }

    foreach ($key in @($Cache.files.Keys)) {
        $vendor = $vendorOf[$key.Substring(0, 1)]
        if (-not $vendor) { continue }
        $f = $Cache.files[$key]
        foreach ($h in @($f.tallies.Keys)) {
            $hour = [double]$h
            if ($hour -lt $rangeStart) { continue }
            $day = $dayOfHour[$h]
            if ($null -eq $day) { $day = ConvertTo-TMLocalMidnight $hour; $dayOfHour[$h] = $day }
            foreach ($model in @($f.tallies[$h].Keys)) {
                $t = $f.tallies[$h][$model]
                $total = Get-TMTallyTotal $t
                $dk = '{0}|{1}' -f $day, $vendor
                $perDay[$dk] = [double]$perDay[$dk] + $total
                if ($hour -ge $weekStart) {
                    $mk = '{0}|{1}' -f $vendor, $model
                    $perModel[$mk] = [double]$perModel[$mk] + $total
                }
                if ($hour -lt $dayAgo - 3600) { continue }   # the current partial hour counts
                if ($vendor -eq 'claude') {
                    foreach ($fld in 'input', 'output', 'cacheRead', 'cacheWrite', 'requests', 'subagent', 'longContext') { $claude24[$fld] += $t[$fld] }
                } elseif ($vendor -eq 'codex') {
                    foreach ($fld in 'input', 'output', 'cacheRead', 'cacheWrite', 'requests') { $codex24[$fld] += $t[$fld] }
                }
            }
        }
        # A driver is charged with every token its session spent in each hour
        # it was active. Overlapping and approximate (a session that used two
        # MCP servers counts toward both), but it points at what was running
        # while the limit went down, which call counts do not.
        foreach ($h in @($f.tools.Keys)) {
            if ([double]$h -lt $dayAgo - 3600) { continue }
            $hourTokens = 0.0
            if ($f.tallies.ContainsKey($h)) { foreach ($t in $f.tallies[$h].Values) { $hourTokens += Get-TMTallyTotal $t } }
            foreach ($k in @($f.tools[$h].Keys)) {
                $calls[$k] = [int]$calls[$k] + [int]$f.tools[$h][$k]
                $driverTokens[$k] = [double]$driverTokens[$k] + $hourTokens
            }
        }
    }

    $claudeTotal = Get-TMTallyTotal $claude24
    # Built-in tools (Read, Bash...) run in nearly every session, so they would
    # all read ~100% and crowd out what is actually distinctive.
    $drivers = foreach ($k in @($calls.Keys)) {
        $parts = $k.Split([char[]]'|', 2)
        if ($parts.Count -ne 2 -or $parts[0] -eq 'Tool') { continue }
        $share = if ($claudeTotal -gt 0) { [Math]::Min([double]$driverTokens[$k] / $claudeTotal, 1.0) } else { 0.0 }
        [ordered]@{ name = $parts[1]; kind = $parts[0]; calls = [int]$calls[$k]; share = $share }
    }
    $drivers = @($drivers | Sort-Object -Property @{ Expression = { $_.share }; Descending = $true },
                                                   @{ Expression = { $_.calls }; Descending = $true } | Select-Object -First 12)

    $dayRows = foreach ($d in $dayStarts) {
        $row = [ordered]@{ day = $d; claude = [double]$perDay["$d|claude"]; codex = [double]$perDay["$d|codex"] }
        if ($IncludeCopilot) { $row.copilot = [double]$perDay["$d|copilot"] }
        $row
    }
    $models = foreach ($mk in @($perModel.Keys)) {
        if ($perModel[$mk] -le 0) { continue }
        $parts = $mk.Split([char[]]'|', 2)
        [ordered]@{ vendor = $parts[0]; model = $parts[1]; tokens = [double]$perModel[$mk] }
    }
    $models = @($models | Sort-Object -Property @{ Expression = { $_.tokens }; Descending = $true })

    $a = [ordered]@{
        generatedAt = $Now
        days        = @($dayRows)
        models      = $models
        claude24h   = [ordered]@{ input = $claude24.input; output = $claude24.output; cacheRead = $claude24.cacheRead; cacheWrite = $claude24.cacheWrite; requests = $claude24.requests }
        codex24h    = [ordered]@{ input = $codex24.input; output = $codex24.output; cacheRead = $codex24.cacheRead; cacheWrite = $codex24.cacheWrite; requests = $codex24.requests }
        drivers     = $drivers
    }
    if ($claudeTotal -gt 0) {
        $a.subagentShare = $claude24.subagent / $claudeTotal
        $a.longContextShare = $claude24.longContext / $claudeTotal
    }
    return $a
}

# ---------------------------------------------------------------- activity: presentation

function Format-TMTokens {
    <# 28015593 -> "28.0M", 11500 -> "11.5k", 144 -> "144". #>
    param([double]$Value)
    $a = [Math]::Abs($Value)
    if ($a -ge 1e9) { return ($Value / 1e9).ToString('0.0', $script:Invariant) + 'B' }
    if ($a -ge 1e6) { return ($Value / 1e6).ToString('0.0', $script:Invariant) + 'M' }
    if ($a -ge 1e4) { return ($Value / 1e3).ToString('0.0', $script:Invariant) + 'k' }
    return ([long][Math]::Round($Value, [MidpointRounding]::AwayFromZero)).ToString($script:Invariant)
}

function Get-TMModelDisplayName {
    <# "claude-opus-5-5" -> "Opus 5.5"; "gpt-6-astra" -> "GPT-6 Astra"; "auto" -> "Auto". #>
    param([string]$Model)
    $m = $Model
    if ($m.StartsWith('claude-')) {
        $m = $m.Substring(7) -replace '-\d{8}$', ''
        $parts = @($m.Split('-') | Where-Object { $_ })
        if ($parts.Count -eq 0) { return $Model }
        $family = $parts[0].Substring(0, 1).ToUpperInvariant() + $parts[0].Substring(1)
        if ($parts.Count -eq 1) { return $family }
        return $family + ' ' + ($parts[1..($parts.Count - 1)] -join '.')
    }
    if ($m.StartsWith('gpt-')) {
        $rest = @($m.Substring(4).Split('-') | Where-Object { $_ })
        if ($rest.Count -eq 0) { return $Model }
        $words = @('GPT-' + $rest[0]) + @($rest | Select-Object -Skip 1 | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })
        return ($words -join ' ')
    }
    if ($m -match '^[a-z]+$') { return $m.Substring(0, 1).ToUpperInvariant() + $m.Substring(1) }
    return $Model
}

function Get-TMCacheHit {
    <# Share of prompt tokens served from cache; low means the context keeps being paid for again. #>
    param($Breakdown)
    $prompt = [double]$Breakdown.input + [double]$Breakdown.cacheRead + [double]$Breakdown.cacheWrite
    if ($prompt -le 0) { return $null }
    return [double]$Breakdown.cacheRead / $prompt
}

function Get-TMActivityTip {
    <# One concrete habit worth changing, picked from the strongest signal. #>
    param($Activity)
    $l = Get-TMNumber $Activity.longContextShare
    if ($null -ne $l -and $l -ge 0.5) {
        return "{0}% of Claude tokens ran above 150k context. Long sessions cost more even when cached $script:EmDash /compact mid-task and start fresh when you switch tasks." -f [long][Math]::Round($l * 100)
    }
    $s = Get-TMNumber $Activity.subagentShare
    if ($null -ne $s -and $s -ge 0.5) {
        return 'Subagents drove {0}% of Claude tokens. Each one rebuilds its own context; fewer parallel agents stretch the limit further.' -f [long][Math]::Round($s * 100)
    }
    $h = if ($Activity.claude24h) { Get-TMCacheHit $Activity.claude24h } else { $null }
    if ($null -ne $h -and $h -lt 0.7 -and [double]$Activity.claude24h.requests -gt 20) {
        return 'Only {0}% of prompt tokens came from cache. Long pauses let it expire, so the same context gets paid for again.' -f [long][Math]::Round($h * 100)
    }
    return $null
}

# ---------------------------------------------------------------- the board

function New-TMBoard {
    <# The board (spec/board.md). `activity` is omitted until the first scan. #>
    param([object[]]$Providers = @(), $Activity, [double]$Now = (Get-TMNow))
    $b = [ordered]@{ generatedAt = $Now; providers = @($Providers | Where-Object { $null -ne $_ }) }
    if ($null -ne $Activity) { $b.activity = $Activity }
    return $b
}

function Write-TMBoard {
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$Path)
    Write-TMFileAtomic -Path $Path -Text (ConvertTo-TMJson $Board)
}

function Read-TMBoard {
    <#
    Reads a board, tolerating a missing file, unknown keys and unknown
    vendors: providers this client cannot draw are dropped, not fatal.
    #>
    param([string]$Path)
    $b = Read-TMJsonFile $Path
    if (-not (Test-TMObject $b)) { return $null }
    $b['providers'] = @(@($b['providers']) | Where-Object {
        (Test-TMObject $_) -and ($script:DrawableVendors -contains [string]$_['vendor'])
    } | ForEach-Object {
        $p = $_
        $p['meters'] = @(@($p['meters']) | Where-Object { (Test-TMObject $_) -and $_['label'] -and $null -ne (Get-TMNumber $_['used']) })
        $p
    })
    return $b
}

function Get-TMBoardFingerprint {
    <# The board without its timestamp, to skip rewriting an unchanged file. #>
    param($Board)
    return ConvertTo-TMJson @{ providers = $Board.providers; activity = $Board.activity }
}

# ---------------------------------------------------------------- alerts

function Invoke-TMAlerts {
    <#
    Notifies at 80% and 95% of a window, and again when a window that was
    nearly spent resets: the moment you can go back to work.

    Each alert is keyed to one window instance (vendor, meter, reset time), so
    it fires once per window rather than every poll, and survives a relaunch
    because the caller persists the returned state. Returns
    @{ Notifications = @(@{ Title; Body }); State = @{ fired; watching } }.
    #>
    param([Parameter(Mandatory)]$Board, $State, [double]$Now = (Get-TMNow))
    $fired = [System.Collections.Generic.HashSet[string]]::new()
    $watching = @{}
    if ($State) {
        foreach ($k in @($State.fired)) { if ($k) { [void]$fired.Add([string]$k) } }
        if (Test-TMObject $State.watching) { foreach ($k in @($State.watching.Keys)) { $watching[[string]$k] = [double]$State.watching[$k] } }
    }
    $notes = [System.Collections.Generic.List[object]]::new()

    foreach ($p in @($Board.providers)) {
        $name = Get-TMVendorName ([string]$p.vendor)
        $stale = Test-TMProviderStale $p $Now
        foreach ($m in @($p.meters)) {
            $slot = '{0}|{1}' -f $p.vendor, $m.label
            # A watched hot window whose reset has passed is clear now. Checked
            # even for stale providers: the reset time is known, so Codex at
            # 99% four days ago still gets its all-clear.
            if ($watching.ContainsKey($slot) -and $watching[$slot] -le $Now) {
                $notes.Add(@{ Title = ('{0} {1} limit reset' -f $name, $m.label.ToLowerInvariant()); Body = "You're clear to use $name again." })
                $watching.Remove($slot)
            }
            $r = Get-TMNumber $m.resetsAt
            if ($stale -or $null -eq $r -or $r -le $Now) { continue }
            $used = (Get-TMMeterFraction $m $Now) * 100
            if ($used -ge 90) { $watching[$slot] = $r }
            foreach ($threshold in 95, 80) {
                if ($used -lt $threshold) { continue }
                $key = '{0}|{1}|{2}' -f $slot, [long][Math]::Floor($r), $threshold
                if ($fired.Contains($key)) { break }
                # Crossing 95 marks 80 as fired too, so a jump never double-posts.
                foreach ($t in 80, 95) { if ($t -le $threshold) { [void]$fired.Add(('{0}|{1}|{2}' -f $slot, [long][Math]::Floor($r), $t)) } }
                $reset = Get-TMResetText $m $Now
                $hit = Get-TMLimitDate $m $Now
                $body = if ($null -ne $hit) { "At this pace you'll hit the limit in {0}. {1}." -f (Format-TMCountdown ($hit - $Now)), $reset } else { "$reset." }
                $notes.Add(@{ Title = ('{0} {1} at {2}%' -f $name, $m.label.ToLowerInvariant(), [long][Math]::Round($used)); Body = $body })
                break
            }
        }
    }

    # Keys for windows that reset over a week ago can go.
    $cutoff = $Now - 8 * 86400
    $keep = @($fired | Where-Object {
        $parts = $_.Split('|')
        $parts.Count -ge 2 -and (Get-TMNumber $parts[$parts.Count - 2]) -gt $cutoff
    })
    return @{ Notifications = @($notes); State = @{ fired = $keep; watching = $watching } }
}

# ---------------------------------------------------------------- settings and log

function Get-TMDefaultSettings {
    return [ordered]@{
        alertsEnabled      = $true
        liveClaude         = $true     # read Claude limits directly from Anthropic
        widgetOnStart      = $true
        widgetTopmost      = $true
        widgetLeft         = $null
        widgetTop          = $null
        activityRange      = 7         # days shown by default: 7 or 30
        claudeAccountName  = ''
        codexAccountName   = ''
        copilotAccountName = ''
        providers          = [ordered]@{ claude = $true; codex = $true; copilot = $true }
    }
}

function Get-TMSettings {
    <# Saved settings over the defaults, so a new setting never needs a migration. #>
    param([string]$Path)
    $s = Get-TMDefaultSettings
    $saved = Read-TMJsonFile $Path
    if (Test-TMObject $saved) {
        foreach ($k in @($saved.Keys)) {
            if ($k -eq 'providers' -and (Test-TMObject $saved[$k])) {
                foreach ($v in @($saved[$k].Keys)) { $s.providers[[string]$v] = [bool]$saved[$k][$v] }
            } elseif ($k -ne 'providers') {
                $s[[string]$k] = $saved[$k]
            }
        }
    }
    return $s
}

function Save-TMSettings {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Path)
    Write-TMFileAtomic -Path $Path -Text (ConvertTo-TMJson $Settings)
}

function Write-TMLog {
    <# One line to the app log, kept under 1 MB. Callers pass messages they wrote; never a token. #>
    param([string]$Message, [string]$Path)
    if (-not $Path) { return }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 1MB) {
            Move-Item -LiteralPath $Path -Destination ($Path + '.1') -Force
        }
        $line = '{0} {1}' -f [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss', $script:Invariant), $Message
        [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, $script:Utf8NoBom)
    } catch { }
}

Export-ModuleMember -Function *-TM*
