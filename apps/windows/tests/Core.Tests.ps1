#Requires -Version 5.1
<#
Core.Tests.ps1 - checks TokenMeter.Core.psm1 against spec/fixtures.

Plain PowerShell, no Pester needed:
    pwsh -NoProfile -File tests/Core.Tests.ps1
Runs on any platform; everything it writes goes to a temp directory, and it
never touches the network or real credentials. Exit code is the number of
failures (0 = all passed).
#>

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Split-Path -Parent $here
$fixtures = Join-Path (Split-Path -Parent (Split-Path -Parent $appDir)) 'spec/fixtures'
Import-Module (Join-Path $appDir 'TokenMeter.Core.psm1') -Force

$script:Passed = 0
$script:Failed = 0
$script:Dot = [string][char]0x00B7

function Section([string]$Name) { Write-Host ''; Write-Host "== $Name" -ForegroundColor Cyan }
function Pass([string]$Name) { $script:Passed++; Write-Host "  ok   $Name" -ForegroundColor Green }
function Fail([string]$Name, [string]$Detail) { $script:Failed++; Write-Host "  FAIL $Name  $Detail" -ForegroundColor Red }
function Assert-True($Condition, [string]$Name) { if ($Condition) { Pass $Name } else { Fail $Name '' } }
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -eq $Expected) { Pass $Name } else { Fail $Name ("expected <{0}> got <{1}>" -f $Expected, $Actual) }
}
function Assert-Near([double]$Actual, [double]$Expected, [double]$Tolerance, [string]$Name) {
    if ([Math]::Abs($Actual - $Expected) -le $Tolerance) { Pass $Name } else { Fail $Name ("expected {0} +/- {1}, got {2}" -f $Expected, $Tolerance, $Actual) }
}
function Fixture([string]$Name) { Join-Path $fixtures $Name }
function Unix([string]$Iso) { [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tokenmeter-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Text([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Write-Lines([string]$Path, [object[]]$Objects) {
    Write-Text $Path ((@($Objects | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 20 -Compress }) -join "`n") + "`n")
}
function Iso([double]$Unix) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]($Unix * 1000)).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture) }

try {
    # ------------------------------------------------------------ Claude decode
    Section 'Claude usage endpoint: decode (fixtures/typical.json)'
    $snap = ConvertFrom-TMClaudeUsage -Response (Read-TMJsonFile (Fixture 'typical.json')) -Now 1000
    $m = @($snap.meters)
    Assert-Equal $m.Count 3 'three windows'
    Assert-Equal (($m | ForEach-Object { $_.label }) -join ',') "Current,Weekly,Weekly $script:Dot Opus" 'ordered Current, Weekly, Weekly (dot) Opus'
    Assert-Equal $m[0].used 42.5 'five_hour utilization'
    Assert-Equal $m[0].windowSeconds 18000 'five_hour window is 18000 s'
    Assert-Equal $m[0].resetsAt (Unix '2026-09-04T21:00:00Z') 'five_hour resets_at as unix seconds'
    Assert-Equal $m[1].used 61 'seven_day utilization'
    Assert-Equal $m[1].windowSeconds 604800 'seven_day window is 604800 s'
    Assert-Equal $m[2].used 18.25 'seven_day_opus utilization'
    Assert-Equal $snap.extra.used 42 'extra used $42'
    Assert-Equal $snap.extra.limit 200 'extra limit $200'
    Assert-Equal (Get-TMExtraText $snap.extra) '$42 of $200' 'extra text'
    Assert-Equal $snap.fetchedAt 1000 'fetchedAt is now'

    $at = ConvertFrom-TMClaudeUsage -Response (Read-TMJsonFile (Fixture 'at-limit.json'))
    Assert-True ($null -eq $at.extra) 'extra_usage disabled -> no extra'
    Assert-Equal ((@($at.meters) | ForEach-Object { $_.used }) -join ',') '100,104.2' 'at-limit keeps >100%'

    $unk = ConvertFrom-TMClaudeUsage -Response (Read-TMJsonFile (Fixture 'unknown-window.json'))
    Assert-Equal (@($unk.meters)[1].label) 'Thirty Day Experimental' 'unknown window gets a prettified label'
    Assert-Equal (@($unk.meters)[1].windowSeconds) 604800 'unknown window defaults to weekly span'
    Assert-Equal (@((ConvertFrom-TMClaudeUsage -Response (Read-TMJsonFile (Fixture 'no-weekly.json'))).meters).Count) 1 'no-weekly has one window'

    # ------------------------------------------------------------ pace
    Section 'Pace math'
    $now = 1790000000.0
    $hot = @{ label = 'Current'; used = 60; resetsAt = $now + 3 * 3600; windowSeconds = 18000 }
    Assert-Near (Get-TMElapsedFraction $hot $now) 0.4 1e-9 '2h into 5h -> elapsed 0.4'
    Assert-Near (Get-TMProjectedAtReset $hot $now) 150 1e-6 '60% at 2h of 5h -> projected 150%'
    Assert-Near ((Get-TMLimitDate $hot $now) - $now) 4800 0.5 'limit in 80 minutes'
    Assert-Equal (Get-TMPaceNote $hot $now).Text 'Limit in 1h 20m' 'pace note says Limit in 1h 20m'
    Assert-Equal (Get-TMMeterTint $hot $now) 'red' 'projected >= 130% is red'
    $early = @{ label = 'Current'; used = 5; resetsAt = $now + 17900; windowSeconds = 18000 }
    Assert-True ($null -eq (Get-TMProjectedAtReset $early $now)) 'no projection in first 8% of window'
    $calm = @{ label = 'Weekly'; used = 20; resetsAt = $now + 3 * 86400; windowSeconds = 604800 }
    Assert-Equal (Get-TMMeterTint $calm $now) 'accent' 'on-pace weekly is accent'
    Assert-Equal (Get-TMPaceNote $calm $now).Text 'On pace for 35%' 'on pace note'
    Assert-Equal (Get-TMResetText $calm $now) ('Resets ' + [DateTimeOffset]::FromUnixTimeSeconds([long]($now + 3 * 86400)).ToLocalTime().ToString('dddd', [Globalization.CultureInfo]::InvariantCulture)) 'weekly resets on a weekday'
    $late = @{ label = 'Current'; used = 75; resetsAt = $now + 600; windowSeconds = 18000 }
    Assert-Equal (Get-TMMeterTint $late $now) 'amber' '75% near the end is amber'
    Assert-Equal (Get-TMResetText $late $now) 'Resets in 10m' 'reset countdown'
    $past = @{ label = 'Current'; used = 88; resetsAt = $now - 60; windowSeconds = 18000 }
    Assert-Equal (Get-TMMeterFraction $past $now) 0 'a passed reset shows 0%'
    Assert-Equal (Get-TMResetText $past $now) 'Fresh window' 'a passed reset says Fresh window'
    Assert-Equal (Format-TMCountdown (3 * 86400 + 4 * 3600)) '3d 4h' 'countdown days'
    Assert-Equal (Format-TMAgo 30) 'Live' 'ago: Live'
    Assert-Equal (Format-TMAgo (4 * 86400 + 5)) '4d ago' 'ago: 4d ago'

    # ------------------------------------------------------------ Codex
    Section 'Codex rollouts'
    $lim = Read-TMCodexRateLimits -Path (Fixture 'codex-rollout.jsonl')
    $cm = @(ConvertFrom-TMCodexLimits -Limits $lim -Mtime 1788450000)
    Assert-Equal (($cm | ForEach-Object { $_.label }) -join ',') 'Current,Weekly' 'newest line: Current then Weekly'
    Assert-Equal $cm[0].used 91 'primary 91%'
    Assert-Equal $cm[0].windowSeconds 18000 '300-minute window'
    Assert-Equal $cm[0].resetsAt 1788455880 'resets_at kept'
    Assert-Equal $cm[1].used 34 'secondary 34%'
    $two = @(ConvertFrom-TMCodexLimits -Limits (Read-TMCodexRateLimits -Path (Fixture 'codex-two-limit-ids.jsonl')) -Mtime 0)
    Assert-Equal $two.Count 1 'premium line with null primary is skipped'
    Assert-Equal "$($two[0].label) $($two[0].used)" 'Weekly 94' 'falls back to the last real codex limits'
    Assert-True ($null -eq (Read-TMCodexRateLimits -Path (Fixture 'codex-no-limits.jsonl'))) 'rate_limits null -> nothing'

    # A CODEX_HOME with a dated session dir and an id_token.
    $codexHome = Join-Path $tmp 'codex'
    $nowReal = Get-TMNow
    $d = [DateTime]::Now
    $dayDir = Join-Path $codexHome ('sessions/{0:0000}/{1:00}/{2:00}' -f $d.Year, $d.Month, $d.Day)
    New-Item -ItemType Directory -Path $dayDir -Force | Out-Null
    Copy-Item (Fixture 'codex-rollout.jsonl') (Join-Path $dayDir 'rollout-test.jsonl')
    (Get-Item (Join-Path $dayDir 'rollout-test.jsonl')).LastWriteTimeUtc = [DateTime]::UtcNow   # a session running now
    function New-FakeJwt($claims) {
        $b = [Convert]::ToBase64String($utf8.GetBytes((ConvertTo-Json $claims -Depth 5 -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "eyJhbGciOiJub25lIn0.$b.sig"
    }
    $claims = @{ 'https://api.openai.com/auth' = @{ chatgpt_plan_type = 'business' }; organizations = @(@{ title = 'API Org Should Not Show' }) }
    Write-Text (Join-Path $codexHome 'auth.json') (ConvertTo-Json @{ tokens = @{ id_token = (New-FakeJwt $claims) } } -Compress)
    $cp = Get-TMCodexProvider -CodexDir $codexHome -Now $nowReal
    Assert-Equal $cp.plan 'Business' 'plan from chatgpt_plan_type'
    Assert-Equal $cp.account '' 'workspace plan: no name (never the API org title)'
    Assert-Equal @($cp.meters).Count 2 'provider carries both windows'
    Assert-True ([Math]::Abs($cp.updatedAt - $nowReal) -lt 120) 'updatedAt is the rollout mtime'
    Assert-Equal (Get-TMCodexProvider -CodexDir $codexHome -AccountOverride 'Acme' -Now $nowReal).account 'Acme' 'codexAccountName overrides'
    $claims.'https://api.openai.com/auth'.chatgpt_plan_type = 'plus'
    Write-Text (Join-Path $codexHome 'auth.json') (ConvertTo-Json @{ tokens = @{ id_token = (New-FakeJwt $claims) } } -Compress)
    $cp2 = Get-TMCodexProvider -CodexDir $codexHome -Now $nowReal
    Assert-Equal "$($cp2.account)/$($cp2.plan)" 'Personal/Plus' 'personal plan'
    Assert-True ($null -eq (Get-TMCodexProvider -CodexDir (Join-Path $tmp 'nope'))) 'no ~/.codex -> no provider'

    # ------------------------------------------------------------ Claude account + token
    Section 'Claude account and token (read only)'
    $cj = Join-Path $tmp 'claude.json'
    Write-Text $cj '{"oauthAccount":{"organizationType":"claude_max","userRateLimitTier":null,"organizationRateLimitTier":"default_claude_max_20x","organizationName":"someone@example.com Org"}}'
    $acct = Get-TMClaudeAccount -ClaudeJsonPath $cj
    Assert-Equal "$($acct.Account)/$($acct.Plan)" 'Personal/Max 20x' 'Max 20x read from organizationRateLimitTier'
    Write-Text $cj '{"oauthAccount":{"organizationType":"claude_team","organizationName":"Acme"}, "projects":{}}'
    $acct = Get-TMClaudeAccount -ClaudeJsonPath $cj
    Assert-Equal "$($acct.Account)/$($acct.Plan)" 'Acme/Team' 'team org uses organizationName'
    $prov = Get-TMClaudeProvider -Account $acct -Live @{ Meters = $snap.meters; Extra = $snap.extra; FetchedAt = 1234 }
    Assert-Equal "$($prov.vendor)|$(@($prov.meters).Count)|$($prov.updatedAt)|$($prov.extra.limit)" 'claude|3|1234|200' 'provider merges account and live snapshot'

    $cred = Join-Path $tmp 'credentials.json'
    Write-Text $cred ('{"claudeAiOauth":{"accessToken":"sk-test-not-real","expiresAt":' + [long](($nowReal + 3600) * 1000) + '}}')
    $tok = Read-TMClaudeToken -CredentialsPath $cred -Now $nowReal
    Assert-Equal $tok.Status 'ok' 'valid token read'
    Write-Text $cred ('{"claudeAiOauth":{"accessToken":"sk-test-not-real","expiresAt":' + [long](($nowReal - 60) * 1000) + '}}')
    $tok = Read-TMClaudeToken -CredentialsPath $cred -Now $nowReal
    Assert-True ($tok.Status -eq 'expired' -and $null -eq $tok.Token) 'expired token is skipped, not refreshed'
    Assert-Equal (Read-TMClaudeToken -CredentialsPath (Join-Path $tmp 'missing.json')).Status 'noToken' 'missing credentials -> noToken'
    $live = Invoke-TMClaudeLive -CredentialsPath $cred -Now $nowReal
    Assert-True (-not $live.Ok -and $live.Failure -eq 'expired') 'live read with expired token makes no request'
    Assert-True ([IO.File]::ReadAllText($cred).Contains('sk-test-not-real')) 'credentials file untouched'

    # ------------------------------------------------------------ Copilot
    Section 'GitHub Copilot quota'
    $capped = ConvertFrom-TMJson '{"copilot_plan":"individual","quota_reset_date":"2026-10-01","quota_snapshots":{"premium_interactions":{"unlimited":false,"percent_remaining":37.5,"credits_used":187}}}'
    $gp = ConvertFrom-TMCopilotQuota -Response $capped -FetchedAt 1000
    Assert-Equal "$($gp.vendor)|$($gp.account)|$($gp.plan)" 'copilot|Personal|Individual' 'capped individual plan'
    Assert-Equal (@($gp.meters)[0].label) 'Monthly' 'Monthly meter'
    Assert-Equal (@($gp.meters)[0].used) 62.5 'used = 100 - percent_remaining'
    Assert-Equal (@($gp.meters)[0].resetsAt) ([double]([DateTimeOffset]::new([DateTime]::new(2026, 10, 1))).ToUnixTimeSeconds()) 'resets at local midnight'
    Assert-Equal (@($gp.meters)[0].windowSeconds) 2592000 '30-day window'
    $unl = ConvertFrom-TMJson '{"copilot_plan":"business","quota_reset_date":"2026-10-01","quota_snapshots":{"premium_interactions":{"unlimited":true,"percent_remaining":100.0,"credits_used":1894}}}'
    $gu = ConvertFrom-TMCopilotQuota -Response $unl -FetchedAt 1000
    Assert-Equal @($gu.meters).Count 0 'unlimited: no meter'
    Assert-Equal $gu.note "1,894 credits this month $script:Dot no cap" 'unlimited: credits note'
    Assert-Equal "$($gu.account)/$($gu.plan)" '/Business' 'business plan: no account name'

    Section 'GitHub Copilot sessions (VS Code mutation log)'
    $t0 = [long](($nowReal - 7200) * 1000)
    $vsUser = Join-Path $tmp 'vscode/User'
    $sess = Join-Path $vsUser 'workspaceStorage/abc123/chatSessions/s1.jsonl'
    Write-Lines $sess @(
        @{ kind = 0; v = @{ sessionId = 's1'; requests = @(@{ requestId = 'r1'; timestamp = $t0; modelId = 'copilot/auto' }) } },
        @{ kind = 2; k = @('requests'); v = @(@{ requestId = 'r2'; timestamp = $t0 + 1000; modelId = 'copilot/gpt-6-astra'; promptTokens = 100; completionTokens = 20; copilotCredits = 1.0 }) },
        @{ kind = 1; k = @('requests', 0, 'promptTokens'); v = 1000 },
        @{ kind = 1; k = @('requests', 0, 'completionTokens'); v = 50 },
        @{ kind = 1; k = @('requests', 0, 'result'); v = @{ metadata = @{ promptTokens = 1000; outputTokens = 50 } } },
        @{ kind = 2; k = @('requests'); i = 1; v = @(@{ requestId = 'r2'; timestamp = $t0 + 1000; modelId = 'copilot/gpt-6-astra'; promptTokens = 100; completionTokens = 20 }) },
        @{ kind = 2; k = @('requests', 1, 'response'); v = @(@{ value = 'text' }) }
    )
    $byId = Read-TMCopilotSession -Path $sess
    Assert-Equal $byId.Count 2 'two requests after dedupe by requestId'
    Assert-Equal "$($byId['r1'].prompt)/$($byId['r1'].completion)" '1000/50' 'kind-1 patches set r1 tokens'
    Assert-Equal "$($byId['r2'].prompt)/$($byId['r2'].completion)" '100/20' 'spliced re-push of r2 counted once'
    $old = Join-Path $vsUser 'globalStorage/emptyWindowChatSessions/old.json'
    Write-Text $old (ConvertTo-Json -Depth 10 -Compress @{ requests = @(@{ requestId = 'r9'; timestamp = $t0; modelId = 'copilot/auto'; result = @{ metadata = @{ promptTokens = 7; outputTokens = 3 } } }) })
    Assert-Equal (Read-TMCopilotSession -Path $old)['r9'].prompt 7 'old .json format: result.metadata fallback'

    # ------------------------------------------------------------ activity scan
    Section 'Activity scan (synthetic Claude Code + Codex + Copilot logs)'
    $claudeProjects = Join-Path $tmp 'claude/projects'
    $codexSessions = Join-Path $tmp 'codexlogs/sessions'
    $cachePath = Join-Path $tmp 'data/activity-cache.json'
    $ts = Iso ($nowReal - 7200)
    function Asst($id, $model, $usage, $content, [bool]$side = $false) {
        @{ type = 'assistant'; isSidechain = $side; timestamp = $ts; message = @{ id = $id; model = $model; role = 'assistant'; content = $content; usage = $usage } }
    }
    $u1 = @{ input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 1000; cache_creation_input_tokens = 100 }
    $mainLog = Join-Path $claudeProjects 'proj/s1.jsonl'
    Write-Lines $mainLog @(
        @{ type = 'user'; timestamp = $ts; message = @{ role = 'user'; content = 'hello "type":"assistant"' } },
        (Asst 'm1' 'claude-opus-5-5' $u1 @(@{ type = 'text'; text = 'thinking' })),
        (Asst 'm1' 'claude-opus-5-5' $u1 @(@{ type = 'tool_use'; id = 'toolu_1'; name = 'mcp__Desktop_Commander__read_file'; input = @{ path = 'x' } })),
        (Asst 'm2' 'claude-opus-5-5' @{ input_tokens = 1; output_tokens = 10; cache_read_input_tokens = 160000; cache_creation_input_tokens = 0 } @(
            @{ type = 'tool_use'; id = 'toolu_2'; name = 'Skill'; input = @{ skill = 'superpowers:brainstorming' } },
            @{ type = 'tool_use'; id = 'toolu_3'; name = 'Task'; input = @{ subagent_type = 'Explore' } },
            @{ type = 'tool_use'; id = 'toolu_4'; name = 'Bash'; input = @{ command = 'ls' } })),
        (Asst 'm3' '<synthetic>' @{ input_tokens = 999; output_tokens = 999 } @())
    )
    Write-Lines (Join-Path $claudeProjects 'proj/s1/subagents/agent-a.jsonl') @(
        (Asst 'm4' 'claude-sonnet-5' @{ input_tokens = 50; output_tokens = 50 } @() $true)
    )
    # An old transcript outside the retention window must be ignored.
    $oldLog = Join-Path $claudeProjects 'proj/ancient.jsonl'
    Write-Lines $oldLog @((Asst 'm0' 'claude-opus-4-8' @{ input_tokens = 5000000; output_tokens = 1 } @()))
    (Get-Item $oldLog).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)

    $codexLog = Join-Path $codexSessions '2026/09/20/rollout-a.jsonl'
    function Tc($total, $in, $cached, $out) {
        @{ timestamp = $ts; type = 'event_msg'; payload = @{ type = 'token_count'; info = @{ total_token_usage = @{ total_tokens = $total }; last_token_usage = @{ input_tokens = $in; cached_input_tokens = $cached; output_tokens = $out } } } }
    }
    Write-Lines $codexLog @(
        @{ timestamp = $ts; type = 'turn_context'; payload = @{ model = 'gpt-6-astra' } },
        (Tc 100 80 30 20),
        (Tc 100 80 30 20),      # re-emitted: total did not grow
        (Tc 250 120 100 30)
    )

    $scanArgs = @{ ClaudeProjectsDir = $claudeProjects; CodexSessionsDir = $codexSessions; VSCodeUserDirs = @($vsUser); CachePath = $cachePath; Now = $nowReal }
    $a = Invoke-TMActivityScan @scanArgs
    $c24 = $a.claude24h
    Assert-Equal "$($c24.input)/$($c24.output)/$($c24.cacheRead)/$($c24.cacheWrite)" '61/65/161000/100' 'claude 24h breakdown (m1 once, m2, subagent m4)'
    Assert-Equal $c24.requests 3 'claude requests: repeated message.id counted once, <synthetic> skipped'
    $x24 = $a.codex24h
    Assert-Equal "$($x24.input)/$($x24.cacheRead)/$($x24.output)/$($x24.requests)" '70/130/50/2' 'codex: repeated token_count skipped (monotonic total)'
    Assert-Equal @($a.days).Count 30 '30 days in activity.days'
    $sumC = 0.0; $sumX = 0.0; $sumG = 0.0
    foreach ($day in $a.days) { $sumC += $day.claude; $sumX += $day.codex; $sumG += $day.copilot }
    Assert-Equal $sumC 161226 'claude day totals = input+output+cache read+cache write'
    Assert-Equal $sumX 250 'codex day totals'
    Assert-Equal $sumG 1180 'copilot day totals = prompt + completion (jsonl 1170 + old .json 10)'
    Assert-True ($a.days[29].day -gt $a.days[0].day) 'days oldest first'
    Assert-Near $a.subagentShare (100 / 161226) 1e-12 'subagent share from subagents/ files'
    Assert-Near $a.longContextShare (160011 / 161226) 1e-12 'long-context share (>150k prompt)'
    $names = @($a.drivers | ForEach-Object { '{0}|{1}' -f $_.kind, $_.name }) | Sort-Object
    Assert-Equal ($names -join ',') 'MCP|Desktop Commander,Skill|superpowers:brainstorming,Subagent|Explore' 'drivers exclude built-in tools'
    Assert-Near (@($a.drivers)[0].share) (161126 / 161226) 1e-12 'driver share is token-weighted by session-hour'
    Assert-Equal (@($a.models)[0].model) 'claude-opus-5-5' 'largest model first'
    Assert-True (@($a.models | Where-Object { $_.model -eq 'claude-opus-4-8' }).Count -eq 0) 'file past retention ignored'
    Assert-True (@($a.models | Where-Object { $_.vendor -eq 'copilot' -and $_.model -eq 'gpt-6-astra' }).Count -eq 1) 'copilot model from modelId'
    Assert-Equal (Get-TMModelDisplayName 'claude-opus-5-5') 'Opus 5.5' 'model display name'
    Assert-Equal (Get-TMModelDisplayName 'gpt-6-astra') 'GPT-6 Astra' 'gpt display name'
    Assert-Equal (Get-TMModelDisplayName 'claude-sonnet-4-20250514') 'Sonnet 4' 'dated model display name'
    Assert-True ((Get-TMActivityTip $a) -like '*above 150k context*') 'tip picks the strongest signal'

    # Incremental: a second pass reads nothing new; an appended line is read once.
    $a2 = Invoke-TMActivityScan @scanArgs
    Assert-Equal $a2.claude24h.requests 3 'rescan without changes adds nothing (offset cache)'
    Add-Content -LiteralPath $mainLog -Value (ConvertTo-Json -Depth 10 -Compress (Asst 'm5' 'claude-opus-5-5' @{ input_tokens = 1; output_tokens = 1 } @())) -Encoding UTF8
    $a3 = Invoke-TMActivityScan @scanArgs
    Assert-Equal $a3.claude24h.requests 4 'appended line counted once'
    # A half-written last line waits for the next pass.
    [IO.File]::AppendAllText($mainLog, '{"type":"assistant","timestamp":"' + $ts + '","message":{"id":"m6"', $utf8)
    $a4 = Invoke-TMActivityScan @scanArgs
    Assert-Equal $a4.claude24h.requests 4 'partial line not consumed'
    [IO.File]::AppendAllText($mainLog, ',"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":2}}}' + "`n", $utf8)
    $a5 = Invoke-TMActivityScan @scanArgs
    Assert-Equal $a5.claude24h.requests 5 'completed line read on the next pass'
    # A rewritten (shorter) file starts over.
    Write-Lines $mainLog @((Asst 'm7' 'claude-opus-5-5' @{ input_tokens = 3; output_tokens = 3 } @()))
    $a6 = Invoke-TMActivityScan @scanArgs
    Assert-Equal $a6.claude24h.requests 2 'truncated file is re-read from the start (m7 + subagent m4)'
    Assert-True (Test-Path -LiteralPath $cachePath) 'offset cache written'

    # ------------------------------------------------------------ board
    Section 'Board write/read round trip'
    $claudeP = Get-TMClaudeProvider -Account @{ Account = 'Personal'; Plan = 'Max 20x' } -Live @{ Meters = $snap.meters; Extra = $snap.extra; FetchedAt = $nowReal }
    $board = New-TMBoard -Providers @($claudeP, $cp, $gu) -Activity $a -Now $nowReal
    $boardPath = Join-Path $tmp 'out/board.json'
    Write-TMBoard -Board $board -Path $boardPath
    Assert-True (-not (Get-ChildItem (Split-Path $boardPath) -Filter '*.tmp').Count) 'atomic write leaves no temp file'
    $back = Read-TMBoard -Path $boardPath
    Assert-Equal ((@($back.providers) | ForEach-Object { $_.vendor }) -join ',') 'claude,codex,copilot' 'providers in order'
    Assert-Equal @(@($back.providers)[0].meters).Count 3 'claude meters survive'
    Assert-Equal (@($back.providers)[0].extra.limit) 200 'extra survives'
    Assert-Equal (@($back.providers)[2].note) "1,894 credits this month $script:Dot no cap" 'note survives'
    Assert-Equal @($back.activity.days).Count 30 'activity.days survives'

    # Every key we write must be a key the contract defines.
    $spec = Read-TMJsonFile (Fixture 'board.json')
    function Get-Keys($v, $set) {
        if (Test-TMObject $v) { foreach ($k in $v.Keys) { [void]$set.Add([string]$k); Get-Keys $v[$k] $set } }
        elseif ($v -is [System.Collections.IList]) { foreach ($x in $v) { Get-Keys $x $set } }
    }
    $specKeys = [System.Collections.Generic.HashSet[string]]::new(); Get-Keys $spec $specKeys
    foreach ($k in 'note', 'copilot', 'experimental', 'cursor', 'grok', 'extra', 'limit') { [void]$specKeys.Add($k) }   # in the spec tables, not in the fixture
    $ourKeys = [System.Collections.Generic.HashSet[string]]::new(); Get-Keys $back $ourKeys
    $extraKeys = @($ourKeys | Where-Object { -not $specKeys.Contains($_) })
    Assert-Equal ($extraKeys -join ',') '' 'no keys outside the contract'
    foreach ($k in 'generatedAt', 'providers', 'activity') { Assert-True ($back.Keys -contains $k) "top-level key $k" }
    foreach ($k in 'vendor', 'account', 'plan', 'meters', 'updatedAt', 'extra') { Assert-True (@($back.providers)[0].Keys -contains $k) "provider key $k" }
    foreach ($k in 'label', 'used', 'resetsAt', 'windowSeconds') { Assert-True (@(@($back.providers)[0].meters)[0].Keys -contains $k) "meter key $k" }
    foreach ($k in 'days', 'models', 'claude24h', 'codex24h', 'drivers', 'subagentShare', 'longContextShare') { Assert-True ($back.activity.Keys -contains $k) "activity key $k" }
    Assert-True (-not (@($back.providers)[2].Keys -contains 'extra')) 'absent optionals are omitted, not null'

    $specBack = Read-TMBoard -Path (Fixture 'board.json')
    Assert-Equal @($specBack.providers).Count 2 'reads the spec fixture board'
    Write-Text (Join-Path $tmp 'unknown.json') '{"generatedAt":1,"providers":[{"vendor":"zzz","account":"","meters":[]},{"vendor":"codex","account":"","meters":[{"label":"Weekly","used":5,"windowSeconds":604800}],"futureKey":1}],"futureTop":true}'
    $ub = Read-TMBoard -Path (Join-Path $tmp 'unknown.json')
    Assert-Equal ((@($ub.providers) | ForEach-Object { $_.vendor }) -join ',') 'codex' 'unknown vendors and keys are skipped'
    Assert-True ($null -eq (Read-TMBoard -Path (Join-Path $tmp 'missing-board.json'))) 'missing board -> $null'

    # The hand-written JSON writer used on Windows PowerShell 5.1 must agree with ConvertTo-Json.
    # ConvertTo-Json writes 42.0 where the writer writes 42; the same JSON number.
    $reference = [regex]::Replace((ConvertTo-Json -InputObject $board -Depth 32 -Compress), '(?<=\d)\.0(?=[,}\]])', '')
    Assert-Equal (ConvertTo-TMJsonText $board) $reference '5.1 JSON writer matches ConvertTo-Json'

    # ------------------------------------------------------------ alerts
    Section 'Alerts'
    $mk = { param($used) New-TMBoard -Providers @([ordered]@{ vendor = 'claude'; account = ''; meters = @(@{ label = 'Current'; used = $used; resetsAt = $now + 3600; windowSeconds = 18000 }); updatedAt = $now }) -Now $now }
    $r1 = Invoke-TMAlerts -Board (& $mk 85) -State $null -Now $now
    Assert-Equal @($r1.Notifications).Count 1 '80% alert fires'
    Assert-Equal $r1.Notifications[0].Title 'Claude Code current at 85%' 'alert title'
    $r2 = Invoke-TMAlerts -Board (& $mk 86) -State $r1.State -Now ($now + 20)
    Assert-Equal @($r2.Notifications).Count 0 'fires once per window'
    $r3 = Invoke-TMAlerts -Board (& $mk 96) -State $r2.State -Now ($now + 40)
    Assert-Equal $r3.Notifications[0].Title 'Claude Code current at 96%' '95% alert fires'
    $r4 = Invoke-TMAlerts -Board (& $mk 96) -State $r3.State -Now ($now + 3700)
    Assert-Equal $r4.Notifications[0].Title 'Claude Code current limit reset' 'reset all-clear after a hot window'
    $j = ConvertFrom-TMJson (ConvertTo-TMJson $r3.State)
    Assert-Equal @((Invoke-TMAlerts -Board (& $mk 97) -State $j -Now ($now + 60)).Notifications).Count 0 'state survives a JSON round trip (relaunch)'

    # ------------------------------------------------------------ settings
    Section 'Settings'
    $sp = Join-Path $tmp 'data/settings.json'
    $s = Get-TMSettings -Path $sp
    Assert-True ($s.alertsEnabled -and $s.liveClaude -and $s.providers.copilot) 'defaults when missing'
    $s.codexAccountName = 'Acme'; $s.providers.codex = $false
    Save-TMSettings -Settings $s -Path $sp
    $s2 = Get-TMSettings -Path $sp
    Assert-Equal "$($s2.codexAccountName)|$($s2.providers.codex)|$($s2.providers.claude)" 'Acme|False|True' 'settings round trip'

    Section 'Formatting'
    Assert-Equal (Format-TMTokens 28015593) '28.0M' '28.0M'
    Assert-Equal (Format-TMTokens 11500) '11.5k' '11.5k'
    Assert-Equal (Format-TMTokens 144) '144' '144'
    Assert-Equal (Format-TMTokens 8270898277) '8.3B' '8.3B'
    Assert-Equal (Get-TMAccountLine @{ account = 'Acme'; plan = 'Business' }) "Acme $script:Dot Business" 'account line'
    Assert-Equal (Get-TMAccountLine @{ account = ''; plan = 'Business' }) 'Business' 'account line without a name'
}
catch {
    Fail 'unexpected error' ($_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
exit $script:Failed
