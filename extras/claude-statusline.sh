#!/bin/bash
# Claude Code status line — "dialed" v2, wired to TokenMeter.
#
#   Opus 5.5 · High   ▸ my-app  ⎇ main +2 ~1   ◑ 41% ctx   +120 −30   $4.21 · 1h12m
#   ✳ Acme · Team  5h ━━━╸──── 37% 4h13m  wk ━━╸───── 38% Tue   ◎ Codex wk 30%   ⌬ Copilot 1.9k cr   ↗ Dashboard
#
# Cmd-click (iTerm2) is live on: the folder (Finder), the branch (GitHub), each
# vendor (its usage page) and "Dashboard" (TokenMeter's window). Links are OSC 8,
# which Claude Code passes through in the status line.
#
# Quiet by default: pace warnings appear only when a window is projected past
# 100% by its reset; a context hint only past 80%.
#
# Colours are ANSI palette INDICES, not truecolor, so the line inherits the
# iTerm2 profile's light/dark palette instead of hardcoding one theme.
#
# Side effect: the latest rate-limit snapshot is written atomically to
# ~/.cache/tokenmeter/usage.json, which TokenMeter reads.

input=$(cat)

E=$'\033' BEL=$'\a'
R="${E}[0m"
DIM="${E}[90m"
FG="${E}[39m"
BOLD="${E}[1m"
RED="${E}[31m"  GREEN="${E}[32m"  YELLOW="${E}[33m"
BLUE="${E}[34m" MAUVE="${E}[35m"  CYAN="${E}[36m"
SEP="   "
BOARD="$HOME/.cache/tokenmeter/board.json"

# ── parse once ───────────────────────────────────────────────────────
# Numbers are forced to integers here: bash evaluates $(( )) operands as
# expressions, so a non-numeric value must never reach arithmetic.
eval "$(printf '%s' "$input" | jq -r '
  def int: (tonumber? // 0) | floor;
  def ts: if . == null or . == "" then "" else int end;
  @sh "MODEL=\(.model.display_name // "?")",
  @sh "DIR=\(.workspace.current_dir // .cwd // "")",
  @sh "PCT=\(.context_window.used_percentage // 0 | int)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DUR=\(.cost.total_duration_ms // 0 | int)",
  @sh "SID=\(.session_id // "none")",
  @sh "EFFORT=\(.effort.level // "")",
  @sh "FAST=\(.fast_mode // false)",
  @sh "THINK=\(.thinking.enabled // false)",
  @sh "ADDED=\(.cost.total_lines_added // 0 | int)",
  @sh "REMOVED=\(.cost.total_lines_removed // 0 | int)",
  @sh "H5=\(.rate_limits.five_hour.used_percentage // "" )",
  @sh "H5_AT=\(.rate_limits.five_hour.resets_at | ts)",
  @sh "D7=\(.rate_limits.seven_day.used_percentage // "" )",
  @sh "D7_AT=\(.rate_limits.seven_day.resets_at | ts)"
' 2>/dev/null)"
: "${MODEL:=?}" "${PCT:=0}" "${COST:=0}" "${DUR:=0}" "${SID:=none}" "${ADDED:=0}" "${REMOVED:=0}" "${FAST:=false}" "${THINK:=false}"
NOW=$(date +%s)
SID=${SID//[^A-Za-z0-9-]/}; : "${SID:=none}"   # used in temp file names
TMP=${TMPDIR:-/tmp}

# ── helpers ──────────────────────────────────────────────────────────
link() { printf '%s]8;;%s%s%s%s]8;;%s' "$E" "$1" "$BEL" "$2" "$E" "$BEL"; }   # link <url> <text>

dial() {
  local p=$1
  if   [ "$p" -lt 13 ]; then printf '○'
  elif [ "$p" -lt 38 ]; then printf '◔'
  elif [ "$p" -lt 63 ]; then printf '◑'
  elif [ "$p" -lt 88 ]; then printf '◕'
  else                       printf '●'; fi
}

# bar <pct> <width> <colour> [<notch-pct>] — hairline bar, half-cell resolution,
# with an optional pace notch (│) where even consumption would be now.
bar() {
  local p=$1 w=$2 col=$3 notch=${4:--1} halves full half i out="" n=-1
  [ "$p" -gt 100 ] && p=100
  halves=$(( (p * w * 2 + 50) / 100 ))
  full=$(( halves / 2 )); half=$(( halves % 2 ))
  [ "$notch" -ge 0 ] && n=$(( notch * w / 100 )) && [ "$n" -ge "$w" ] && n=$(( w - 1 ))
  out+="$col"
  for ((i = 0; i < w; i++)); do
    if   [ "$i" -lt "$full" ];                         then out+="━"
    elif [ "$i" -eq "$full" ] && [ "$half" -eq 1 ];     then out+="╸${DIM}"
    else
      [ "$i" -eq "$full" ] && out+="${DIM}"
      if [ "$i" -eq "$n" ]; then out+="${FG}│${DIM}"; else out+="─"; fi
    fi
  done
  printf '%s%s' "$out" "$R"
}

until_str() {                  # epoch → "2h13m" / "41m"
  local s=$(( $1 - NOW )) h m
  [ "$s" -lt 0 ] && s=0
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

weekday_or_time() {            # >24h away → "Tue", else "14:00"
  if [ $(( $1 - NOW )) -ge 86400 ]; then date -r "$1" '+%a'; else date -r "$1" '+%H:%M'; fi
}

# pace <used%> <resets_at> <window_s> → sets COL, PROJ, NOTCH (elapsed %)
pace() {
  local used=$1 at=$2 win=$3 left elapsed
  left=$(( at - NOW )); [ "$left" -lt 0 ] && left=0
  elapsed=$(( win - left )); [ "$elapsed" -lt 60 ] && elapsed=60
  PROJ=$(( used * win / elapsed ))
  NOTCH=$(( elapsed * 100 / win ))
  # Too early in the window to project honestly: no colour change, no notch.
  if [ "$NOTCH" -lt 8 ]; then PROJ=$used; NOTCH=-1; fi
  if   [ "$used" -ge 90 ] || [ "$PROJ" -ge 130 ]; then COL="$RED"
  elif [ "$used" -ge 70 ] || [ "$PROJ" -ge 100 ]; then COL="$YELLOW"
  else                                              COL="$CYAN"; fi
}

# ── row 1: model · folder · git · context · diff · cost/time ─────────
MODEL=$(printf '%s' "$MODEL" | awk '{for(i=1;i<=NF;i++){w=$i; p=substr(w,1,1); if(p=="("){$i="(" toupper(substr(w,2,1)) substr(w,3)} else {$i=toupper(p) substr(w,2)}} print}')
MC="$BOLD$FG"
[ "$THINK" = "true" ] && MC="$BOLD$MAUVE"
[ "$FAST" = "true" ] && MC="$BOLD$YELLOW"
L1="${MC}${MODEL}${R}"
[ "$FAST" = "true" ] && L1+=" ${YELLOW}↯${R}"
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    xhigh) e="Extra High" ;;
    *)     e="$(printf '%s' "${EFFORT:0:1}" | tr '[:lower:]' '[:upper:]')${EFFORT:1}" ;;
  esac
  L1+=" ${DIM}·${R} ${e}"
fi

if   [ "$DIR" = "$HOME" ]; then LABEL='~'
elif [ -z "$DIR" ];        then LABEL='—'
else                            LABEL="${DIR##*/}"; fi
if [ -n "$DIR" ]; then L1+="${SEP}${BLUE}▸ $(link "file://${DIR// /%20}" "$LABEL")${R}"
else                   L1+="${SEP}${BLUE}▸ ${LABEL}${R}"; fi

# Git: branch, staged/modified counts and the GitHub URL, cached 5 s per session.
CACHE="$TMP/ccstatus-git2-$SID"
# The open folder may be any repo, so its config gets no chance to run code.
GIT=(git -c core.fsmonitor= -c core.hooksPath=/dev/null --no-optional-locks)
stale=1
if [ -f "$CACHE" ]; then
  mt=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  [ $(( NOW - mt )) -le 5 ] && stale=0
fi
if [ "$stale" -eq 1 ]; then
  if "${GIT[@]}" -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    br=$("${GIT[@]}" -C "$DIR" branch --show-current 2>/dev/null)
    st=$("${GIT[@]}" -C "$DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    md=$("${GIT[@]}" -C "$DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    url=$("${GIT[@]}" -C "$DIR" remote get-url origin 2>/dev/null \
          | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')
    case "$url" in https://github.com/*) ;; *) url="" ;; esac
    printf '%s|%s|%s|%s' "$br" "$st" "$md" "$url" > "$CACHE"
  else
    printf '|||' > "$CACHE"
  fi
fi
IFS='|' read -r BRANCH STAGED MODIFIED REMOTE < "$CACHE"
if [ -n "$BRANCH" ]; then
  if [ -n "$REMOTE" ]; then G="${MAUVE}⎇ $(link "$REMOTE/tree/$BRANCH" "$BRANCH")${R}"
  else                      G="${MAUVE}⎇ ${BRANCH}${R}"; fi
  [ "${STAGED:-0}" -gt 0 ] 2>/dev/null   && G+=" ${GREEN}+${STAGED}${R}"
  [ "${MODIFIED:-0}" -gt 0 ] 2>/dev/null && G+=" ${YELLOW}~${MODIFIED}${R}"
  L1+="  ${G}"
fi

[ "$PCT" -gt 100 ] && PCT=100
if   [ "$PCT" -ge 90 ]; then C="$RED"
elif [ "$PCT" -ge 70 ]; then C="$YELLOW"
else                        C="$CYAN"; fi
L1+="${SEP}${C}$(dial "$PCT")${R} ${PCT}% ${DIM}ctx${R}"
[ "$PCT" -ge 80 ] && L1+=" ${C}· /compact soon${R}"

if [ "${ADDED:-0}" -gt 0 ] 2>/dev/null || [ "${REMOVED:-0}" -gt 0 ] 2>/dev/null; then
  L1+="${SEP}${GREEN}+${ADDED}${R} ${RED}−${REMOVED}${R}"
fi

COST_FMT=$(printf '%.2f' "$COST" 2>/dev/null || echo "0.00")
SEC=$((DUR / 1000)); M=$((SEC / 60)); S=$((SEC % 60))
if [ "$M" -ge 60 ]; then T="$((M / 60))h$((M % 60))m"; else T="${M}m${S}s"; fi
L1+="${SEP}${DIM}\$${COST_FMT} · ${T}${R}"

# ── row 2: TokenMeter lanes ─────────────────────────────────────────
# Claude's windows come from this payload (freshest); the account label and
# the other lanes come from TokenMeter's board.json.
# Board strings come from vendor responses (org and workspace names), so
# control characters are stripped before they reach the terminal.
eval "$(jq -r --argjson now "$NOW" '
  def clean: explode | map(select(. >= 32 and . != 127)) | implode;
  def p(v): .providers[]? | select(.vendor == v);
  def hot: (.meters // []) | max_by(.used) // null;
  @sh "ACCT=\([p("claude") | [.account, .plan] | map(select(. != null and . != "")) | join(" · ") | clean] | first // "")",
  @sh "CX=\([p("codex") | hot | select(. != null) | "\(.label == "Weekly" | if . then "wk" else "5h" end) \(.used | floor)%"] | first // "")",
  @sh "CX_STALE=\([p("codex") | (($now - (.updatedAt // 0)) > 21600)] | first // false)",
  @sh "CP=\([p("copilot") | if (.meters | length) > 0 then "\(hot.used | floor)%" else (.note // "" | capture("^(?<n>[0-9,]+)") .n // "" | gsub(","; "") | tonumber? // 0 | if . >= 1000 then "\(. / 100 | floor / 10)k cr" elif . > 0 then "\(.) cr" else "" end) end] | first // "")",
  @sh "CU=\([p("cursor") | hot | select(. != null) | "\(.used | floor)%"] | first // "")"
' "$BOARD" 2>/dev/null)"

L2=""
CLAUDE_LABEL="✳ ${ACCT:-Claude}"
L2+="${BLUE}$(link "https://claude.ai/settings/usage" "$CLAUDE_LABEL")${R}"
WARN=""
if [ -n "$H5" ] && [ -n "$H5_AT" ]; then
  p=$(printf '%.0f' "$H5"); pace "$p" "$H5_AT" 18000
  L2+="  ${DIM}5h${R} $(bar "$p" 10 "$COL" "$NOTCH") ${p}% ${DIM}$(until_str "$H5_AT")${R}"
  [ "$PROJ" -ge 100 ] && [ "$p" -lt 100 ] && WARN="${COL}🔥 5h on pace for ${PROJ}%${R}"
fi
if [ -n "$D7" ] && [ -n "$D7_AT" ]; then
  p=$(printf '%.0f' "$D7"); pace "$p" "$D7_AT" 604800
  L2+="  ${DIM}wk${R} $(bar "$p" 10 "$COL" "$NOTCH") ${p}% ${DIM}$(weekday_or_time "$D7_AT")${R}"
  [ "$PROJ" -ge 100 ] && [ "$p" -lt 100 ] && WARN="${COL}🔥 week on pace for ${PROJ}%${R}"
fi
if [ -n "$CX" ]; then
  cc="$FG"; [ "$CX_STALE" = "true" ] && cc="$DIM"
  L2+="${SEP}${BLUE}$(link "https://chatgpt.com/codex/settings/usage" "◎ Codex")${R} ${cc}${CX}${R}"
fi
[ -n "$CP" ] && L2+="${SEP}${BLUE}$(link "https://github.com/settings/copilot/features" "⌬ Copilot")${R} ${CP}"
[ -n "$CU" ] && L2+="${SEP}${BLUE}$(link "https://cursor.com/dashboard?tab=usage" "▲ Cursor")${R} ${CU}"
[ -n "$WARN" ] && L2+="${SEP}${WARN}"
[ -x /Applications/TokenMeter.app/Contents/MacOS/TokenMeter ] && L2+="${SEP}${DIM}$(link "tokenmeter://dashboard" "↗ Dashboard")${R}"

# ── snapshot for TokenMeter (only when rate limits are present) ──────
if [ -n "$H5$D7" ]; then
  U="$HOME/.cache/tokenmeter"; mkdir -p "$U"
  NEW=$(printf '%s' "$input" | jq -c --argjson now "$NOW" '{
    updated_at: $now,
    five_hour:  .rate_limits.five_hour,
    seven_day:  .rate_limits.seven_day,
    model:      .model.display_name,
    context_pct:(.context_window.used_percentage // null)
  }')
  OLD_KEY=$(jq -c '[.five_hour, .seven_day]' "$U/usage.json" 2>/dev/null)
  NEW_KEY=$(printf '%s' "$NEW" | jq -c '[.five_hour, .seven_day]')
  AGE=$(( NOW - $(stat -f %m "$U/usage.json" 2>/dev/null || echo 0) ))
  if [ "$OLD_KEY" != "$NEW_KEY" ] || [ "$AGE" -ge 300 ]; then
    printf '%s\n' "$NEW" > "$U/.usage.$$" && mv -f "$U/.usage.$$" "$U/usage.json"
    APP="/Applications/TokenMeter.app/Contents/MacOS/TokenMeter"
    [ -x "$APP" ] && [ "$OLD_KEY" != "$NEW_KEY" ] && { "$APP" --reload >/dev/null 2>&1 & } 2>/dev/null
  fi
fi

# ── iTerm2 status bar: publish \(user.claudeUsage) for this tab ───────
IT2=/Applications/iTerm.app/Contents/Resources/utilities/it2
if [ -n "$ITERM_SESSION_ID" ] && [ -x "$IT2" ] && [ -n "$H5$D7" ]; then
  TXT="✳"
  [ -n "$H5" ] && TXT+=" 5h $(printf '%.0f' "$H5")%"
  [ -n "$D7" ] && TXT+=" · wk $(printf '%.0f' "$D7")%"
  [ -n "$H5_AT" ] && TXT+=" · $(until_str "$H5_AT")"
  [ -n "$CX" ] && TXT+="  ◎ $CX"
  LAST="$TMP/ccstatus-it2-$SID"
  if [ "$(cat "$LAST" 2>/dev/null)" != "$TXT" ]; then
    printf '%s' "$TXT" > "$LAST"
    ( perl -e 'alarm 3; exec @ARGV' "$IT2" session set-var user.claudeUsage \
        "$(jq -Rn --arg t "$TXT" '$t')" --session "${ITERM_SESSION_ID#*:}" >/dev/null 2>&1 & )
  fi
fi

printf '%s\n' "$L1"
printf '%s\n' "$L2"
exit 0
