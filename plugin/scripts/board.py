#!/usr/bin/env python3
"""TokenMeter board reader for the Claude Code plugin.

Reads the board.json that the TokenMeter app writes (see spec/board.md) and
prints plan limits, activity and headroom. Standard library only; never needs
credentials and never writes anything.

Usage:
  board.py limits                 providers/meters with %, reset, pace, staleness
  board.py activity [--days N]    token activity (default last 7 days)
  board.py budget [--vendor V]    machine-readable headroom + verdict (JSON)
  board.py json                   the raw board
  board.py path                   which board file would be read
  board.py hook                   SessionStart hook output (silent unless tight)
  board.py statusline             compact status-line segment

Board lookup order: $TOKENMETER_BOARD, then the platform path
(macOS/Linux ~/.cache/tokenmeter/board.json, Windows
%LOCALAPPDATA%\\TokenMeter\\board.json), then the legacy
~/.cache/claude-usage/board.json.

Exit codes: 0 ok, 2 no usable board (a human-readable explanation is printed).
Set TOKENMETER_NOW=<unix seconds> to evaluate the board at a fixed time.
"""

import json
import os
import sys
import time

REPO_URL = "https://github.com/patrickking67/ai-usage-widgets"
KNOWN_VENDORS = ("claude", "codex", "copilot", "cursor", "grok")
VENDOR_NAMES = {"claude": "Claude", "codex": "Codex", "copilot": "GitHub Copilot",
                "cursor": "Cursor", "grok": "Grok"}
STALE_SECONDS = 6 * 3600          # spec: provider older than 6 h is stale
BOARD_DEAD_SECONDS = 24 * 3600    # hook stays quiet if the whole board is older
PACE_MIN_ELAPSED = 0.08           # spec: skip pace when e < 0.08
PACE_MIN_USED = 1.0               # spec: skip pace when used < 1
LONG_CONTEXT_LABEL = "> 150k context"

VERDICT_RANK = {"plenty": 0, "ok": 1, "tight": 2, "critical": 3}
EXIT_NO_BOARD = 2


# --------------------------------------------------------------------------- io

def _setup_stdout():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass


def now():
    override = os.environ.get("TOKENMETER_NOW")
    if override:
        try:
            return float(override)
        except ValueError:
            pass
    return time.time()


def candidate_paths():
    """Return (paths, explicit). explicit=True when $TOKENMETER_BOARD is set."""
    override = os.environ.get("TOKENMETER_BOARD")
    if override:
        return [os.path.expanduser(override)], True
    home = os.path.expanduser("~")
    paths = []
    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
        paths.append(os.path.join(local, "TokenMeter", "board.json"))
    paths.append(os.path.join(home, ".cache", "tokenmeter", "board.json"))
    paths.append(os.path.join(home, ".cache", "claude-usage", "board.json"))  # legacy
    seen, out = set(), []
    for p in paths:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out, False


class BoardError(Exception):
    pass


def load_board():
    paths, explicit = candidate_paths()
    for p in paths:
        if os.path.isfile(p):
            try:
                with open(p, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
            except (OSError, ValueError) as exc:
                raise BoardError("The TokenMeter board at %s could not be read (%s). "
                                 "It may be mid-write; try again in a few seconds." % (p, exc))
            if not isinstance(data, dict):
                raise BoardError("The TokenMeter board at %s is not a JSON object." % p)
            return p, data
    if explicit:
        raise BoardError("$TOKENMETER_BOARD points to %s, which does not exist." % paths[0])
    raise BoardError(no_board_message(paths))


def no_board_message(paths):
    lines = [
        "No TokenMeter board found. Looked in:",
    ]
    lines += ["  - %s" % p for p in paths]
    lines += [
        "",
        "TokenMeter is a small menu-bar (macOS) / tray (Windows) app that tracks",
        "Claude Code and Codex plan limits and writes this board file. Install it from",
        "  %s" % REPO_URL,
        "launch it once, and the board appears within a minute. It reads the limits",
        "your tools already expose locally; this plugin never needs credentials.",
        "To point at a board elsewhere, set TOKENMETER_BOARD=/path/to/board.json.",
    ]
    return "\n".join(lines)


# ------------------------------------------------------------------- formatting

def fmt_pct(x):
    if x is None:
        return "-"
    if 99.95 <= x < 100:
        return ">99.9%"
    if abs(x - round(x)) < 0.05:
        return "%d%%" % round(x)
    return "%.1f%%" % x


def fmt_duration(seconds):
    if seconds is None:
        return "-"
    s = max(0, int(seconds))
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return "%dd %dh" % (d, h)
    if h:
        return "%dh %02dm" % (h, m)
    return "%dm" % m


def fmt_short_duration(seconds):
    s = max(0, int(seconds))
    if s >= 48 * 3600:
        return "%dd" % round(s / 86400.0)
    if s >= 3600:
        return "%dh" % round(s / 3600.0)
    return "%dm" % max(1, s // 60)


def fmt_clock(ts, ref=None):
    """'Wed 9:00' in local time; 'today 9:00' / 'tomorrow 9:00' when close."""
    lt = time.localtime(ts)
    clock = "%d:%02d" % (lt.tm_hour, lt.tm_min)
    day = time.strftime("%a", lt)
    if ref is not None:
        rt = time.localtime(ref)
        delta_days = _local_day_index(lt) - _local_day_index(rt)
        if delta_days == 0:
            return "today %s" % clock
        if delta_days == 1:
            return "tomorrow %s" % clock
    return "%s %s" % (day, clock)


def fmt_weekday_clock(ts):
    lt = time.localtime(ts)
    return "%s %d:%02d" % (time.strftime("%a", lt), lt.tm_hour, lt.tm_min)


def _local_day_index(lt):
    return int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 12, 0, 0, 0, 0, -1)) // 86400)


def fmt_day(ts):
    lt = time.localtime(ts)
    return "%s %d %s" % (time.strftime("%a", lt), lt.tm_mday, time.strftime("%b", lt))


def fmt_tokens(n):
    if n is None:
        return "-"
    n = float(n)
    for unit, div in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if abs(n) >= div:
            v = n / div
            return ("%.1f%s" % (v, unit)) if v < 100 else ("%d%s" % (round(v), unit))
    return "%d" % n


def vendor_name(v):
    return VENDOR_NAMES.get(v, v)


def table(rows, headers):
    widths = [len(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(str(c)))
    out = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)).rstrip()]
    out.append("  ".join("-" * w for w in widths))
    for r in rows:
        out.append("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(r)).rstrip())
    return "\n".join(out)


# --------------------------------------------------------------------- analysis

def _num(x):
    try:
        if x is None or isinstance(x, bool):
            return None
        return float(x)
    except (TypeError, ValueError):
        return None


def analyze_meter(m, t):
    """Apply the spec's fresh-window and pace rules to one meter."""
    used = _num(m.get("used")) or 0.0
    resets_at = _num(m.get("resetsAt"))
    window = _num(m.get("windowSeconds"))
    r = {
        "label": str(m.get("label", "?")),
        "used": used,
        "reportedUsed": used,
        "resetsAt": resets_at,
        "windowSeconds": window,
        "freshWindow": False,
        "secondsToReset": None,
        "projectedAtReset": None,
        "limitHitAt": None,
        "colour": "neutral",
    }
    if resets_at is not None and resets_at <= t:
        # The stored number belongs to the old window.
        r["used"] = 0.0
        r["freshWindow"] = True
        r["resetsAt"] = None
    elif resets_at is not None:
        r["secondsToReset"] = resets_at - t
        if window and window > 0:
            elapsed = window - (resets_at - t)
            e = elapsed / window
            if e >= PACE_MIN_ELAPSED and used >= PACE_MIN_USED:
                r["projectedAtReset"] = used / e
                rate = used / (e * window)  # percent per second
                if used >= 100:
                    r["limitHitAt"] = t
                elif rate > 0:
                    hit = t + (100.0 - used) / rate
                    if hit < resets_at:
                        r["limitHitAt"] = hit
    u, p = r["used"], r["projectedAtReset"]
    if u >= 90 or (p is not None and p >= 130):
        r["colour"] = "red"
    elif u >= 70 or (p is not None and p >= 100):
        r["colour"] = "amber"
    r["remaining"] = max(0.0, 100.0 - u)
    r["verdict"] = meter_verdict(r)
    return r


def meter_verdict(r):
    """plenty / ok / tight / critical. tight and critical mirror amber and red."""
    u, p = r["used"], r["projectedAtReset"]
    if r["colour"] == "red":
        return "critical"
    if r["colour"] == "amber":
        return "tight"
    if u >= 40 or (p is not None and p >= 70):
        return "ok"
    return "plenty"


def worst(verdicts, default="plenty"):
    verdicts = [v for v in verdicts if v in VERDICT_RANK]
    if not verdicts:
        return default
    return max(verdicts, key=lambda v: VERDICT_RANK[v])


def providers(board, t):
    out = []
    for p in board.get("providers") or []:
        if not isinstance(p, dict) or p.get("vendor") not in KNOWN_VENDORS:
            continue
        updated = _num(p.get("updatedAt"))
        age = max(0.0, t - updated) if updated is not None else None
        meters = [analyze_meter(m, t) for m in (p.get("meters") or []) if isinstance(m, dict)]
        extra = p.get("extra") if isinstance(p.get("extra"), dict) else None
        out.append({
            "vendor": p["vendor"],
            "name": vendor_name(p["vendor"]),
            "account": p.get("account") or "",
            "plan": p.get("plan") or "",
            "note": p.get("note") if isinstance(p.get("note"), str) else "",
            "updatedAt": updated,
            "ageSeconds": age,
            "stale": age is not None and age > STALE_SECONDS,
            "experimental": bool(p.get("experimental")),
            "extra": extra,
            "meters": meters,
            "verdict": worst([m["verdict"] for m in meters]) if meters else "n/a",
        })
    return out


def board_age(board, t):
    g = _num(board.get("generatedAt"))
    return max(0.0, t - g) if g is not None else None


# --------------------------------------------------------------------- commands

def cmd_path(_args):
    paths, explicit = candidate_paths()
    for p in paths:
        if os.path.isfile(p):
            print(p)
            return 0
    print("(none found; looked in: %s)" % ", ".join(paths))
    return EXIT_NO_BOARD


def cmd_json(_args):
    path, board = load_board()
    print(json.dumps(board, indent=2, sort_keys=True))
    return 0


def meter_status(m, t):
    if m["freshWindow"]:
        return "Fresh window (old window reset)"
    bits = []
    if m["limitHitAt"] is not None:
        if m["used"] >= 100:
            bits.append("LIMIT REACHED")
        else:
            bits.append("hits limit %s (in %s)" % (fmt_clock(m["limitHitAt"], t),
                                                   fmt_duration(m["limitHitAt"] - t)))
    elif m["projectedAtReset"] is not None:
        bits.append("on pace")
    elif m["resetsAt"] is not None:
        bits.append("too early for pace" if m["used"] >= PACE_MIN_USED else "idle")
    else:
        bits.append("no reset time reported")
    return "; ".join(bits)


def cmd_limits(_args):
    path, board = load_board()
    t = now()
    provs = providers(board, t)
    out = ["TokenMeter limits (board: %s)" % path]
    age = board_age(board, t)
    if age is not None and age > STALE_SECONDS:
        out.append("WARNING: the board was last written %s ago; the TokenMeter app may "
                   "not be running. Numbers below may be out of date." % fmt_duration(age))
    if not provs:
        out.append("")
        out.append("The board has no providers yet. TokenMeter adds one per tool once it "
                   "has read that tool's limits.")
        print("\n".join(out))
        return 0
    for p in provs:
        out.append("")
        head = p["name"]
        extras = [x for x in (p["plan"], p["account"]) if x]
        if extras:
            head += " (%s)" % " · ".join(extras)
        if p["verdict"] in VERDICT_RANK:
            head += " — overall: %s" % p["verdict"].upper()
        out.append(head)
        if p["note"]:
            out.append("  %s" % p["note"])
        if p["stale"]:
            out.append("  STALE: last reported %s ago; treat these numbers as dimmed." %
                       fmt_duration(p["ageSeconds"]))
        if p["experimental"]:
            out.append("  (experimental data source, not verified on real accounts)")
        if not p["meters"]:
            out.append("  (no %% meters reported%s)" % ("; see note above" if p["note"] else ""))
        else:
            rows = []
            for m in p["meters"]:
                used = fmt_pct(m["used"]) + (" (stale)" if p["stale"] else "")
                resets = "-"
                if m["resetsAt"] is not None:
                    resets = "%s (in %s)" % (fmt_clock(m["resetsAt"], t),
                                             fmt_duration(m["secondsToReset"]))
                elif m["freshWindow"]:
                    resets = "passed"
                rows.append([m["label"], used, fmt_pct(m["remaining"]), resets,
                             fmt_pct(m["projectedAtReset"]), m["colour"], meter_status(m, t)])
            out.append(_indent(table(rows, ["Meter", "Used", "Left", "Resets",
                                             "Proj@reset", "Colour", "Pace"]), "  "))
        if p["extra"]:
            used = _num(p["extra"].get("used"))
            limit = _num(p["extra"].get("limit"))
            s = "  Pay-as-you-go: $%.2f" % (used or 0)
            if limit:
                s += " of $%.2f" % limit
            out.append(s)
    out.append("")
    out.append("Pace: projected-at-reset = used / elapsed fraction of the window "
               "(skipped when <8% elapsed or <1% used).")
    print("\n".join(out))
    return 0


def _indent(text, prefix):
    return "\n".join(prefix + line for line in text.splitlines())


def _vendors_in_days(days):
    vs = []
    for d in days:
        for k in d:
            if k != "day" and k not in vs:
                vs.append(k)
    return [v for v in KNOWN_VENDORS if v in vs]  # unknown vendors are skipped


def _day_total(d, vendors):
    return sum((_num(d.get(v)) or 0) for v in vendors)


def usage_split(u):
    if not isinstance(u, dict):
        return None
    inp = _num(u.get("input")) or 0
    out = _num(u.get("output")) or 0
    cr = _num(u.get("cacheRead")) or 0
    cw = _num(u.get("cacheWrite")) or 0
    req = _num(u.get("requests")) or 0
    total = inp + out + cr + cw
    prompt_side = inp + cr + cw
    return {
        "input": inp, "output": out, "cacheRead": cr, "cacheWrite": cw,
        "requests": req, "total": total,
        "cacheHit": (cr / prompt_side) if prompt_side else None,
        "perRequest": (total / req) if req else None,
    }


def activity_tips(act):
    """Evidence-based one-liners, highest impact first."""
    tips = []
    lc = _num(act.get("longContextShare"))
    sa = _num(act.get("subagentShare"))
    drivers = [d for d in (act.get("drivers") or []) if isinstance(d, dict)]
    c24 = usage_split(act.get("claude24h"))
    if lc is not None and lc >= 0.5:
        tips.append("%s of Claude tokens were sent with %s. Use /compact or /clear between "
                    "unrelated tasks and start fresh sessions for new work; every turn re-sends "
                    "the whole context." % (fmt_pct(lc * 100), LONG_CONTEXT_LABEL))
    if sa is not None and sa >= 0.5:
        tips.append("%s of Claude tokens came from subagents. Fan out fewer parallel subagents, "
                    "give them narrow prompts, and use a smaller model for search/lookup "
                    "subagents." % fmt_pct(sa * 100))
    mcp = [d for d in drivers if d.get("kind") == "MCP"]
    if mcp:
        top = max(mcp, key=lambda d: _num(d.get("share")) or 0)
        share = _num(top.get("share")) or 0
        if share >= 0.5:
            tips.append("MCP server '%s' was active in session-hours holding %s of Claude "
                        "tokens (%d calls). If it is not needed for a task, disable it "
                        "(/mcp) so its tool schemas stop riding along in every request."
                        % (top.get("name"), fmt_pct(share * 100), int(_num(top.get("calls")) or 0)))
    if c24 and c24["cacheHit"] is not None and c24["total"] > 0 and c24["cacheHit"] < 0.7:
        tips.append("Claude cache hit rate over 24 h is only %s. Long idle gaps (>5 min) and "
                    "editing early context invalidate the prompt cache; keep sessions "
                    "continuous or start new ones deliberately." % fmt_pct(c24["cacheHit"] * 100))
    if not tips:
        tips.append("No obvious waste pattern: context size, subagent share and cache hits "
                    "all look healthy.")
    return tips


def cmd_activity(args):
    ndays = 7
    if "--days" in args:
        i = args.index("--days")
        try:
            ndays = max(1, int(args[i + 1]))
        except (IndexError, ValueError):
            print("usage: board.py activity [--days N]", file=sys.stderr)
            return 1
    path, board = load_board()
    t = now()
    act = board.get("activity")
    if not isinstance(act, dict):
        print("TokenMeter has not scanned local logs yet (board has no 'activity'). "
              "Leave the TokenMeter app running for a minute and try again.")
        return 0
    out = ["TokenMeter activity (board: %s; this machine only)" % path]
    age = board_age(board, t)
    if age is not None and age > STALE_SECONDS:
        out.append("WARNING: board last written %s ago." % fmt_duration(age))

    days = [d for d in (act.get("days") or []) if isinstance(d, dict) and _num(d.get("day")) is not None]
    days.sort(key=lambda d: d["day"])
    vendors = _vendors_in_days(days)
    shown = days[-ndays:]
    out.append("")
    if len(days) < ndays:
        out.append("(asked for %d days; the board holds %d)" % (ndays, len(days)))
    if shown:
        out.append("Last %d days — total tokens (input + output + cache read + cache write)"
                   % len(shown))
        rows = []
        for d in shown:
            rows.append([fmt_day(d["day"])] + [fmt_tokens(d.get(v) or 0) for v in vendors]
                        + [fmt_tokens(_day_total(d, vendors))])
        tot = ["TOTAL"] + [fmt_tokens(sum((_num(d.get(v)) or 0) for d in shown)) for v in vendors]
        tot.append(fmt_tokens(sum(_day_total(d, vendors) for d in shown)))
        rows.append(tot)
        out.append(_indent(table(rows, ["Day"] + [vendor_name(v) for v in vendors] + ["All"]), "  "))
        peak = max(shown, key=lambda d: _day_total(d, vendors))
        out.append("  Peak day: %s (%s)" % (fmt_day(peak["day"]), fmt_tokens(_day_total(peak, vendors))))
    else:
        out.append("No daily totals on the board yet.")

    # Week-over-week trend from the longer series (30 days on current boards).
    if len(days) >= 14:
        weeks = []
        i = len(days)
        while i - 7 >= 0 and len(weeks) < 4:
            block = days[i - 7:i]
            weeks.append(block)
            i -= 7
        out.append("")
        out.append("Weekly trend (7-day blocks, newest first)")
        rows = []
        for w in weeks:
            per_v = [fmt_tokens(sum((_num(d.get(v)) or 0) for d in w)) for v in vendors]
            rows.append(["%s – %s" % (fmt_day(w[0]["day"]), fmt_day(w[-1]["day"]))] + per_v
                        + [fmt_tokens(sum(_day_total(d, vendors) for d in w))])
        out.append(_indent(table(rows, ["Week"] + [vendor_name(v) for v in vendors] + ["All"]), "  "))
        this_w = sum(_day_total(d, vendors) for d in weeks[0])
        prev = [sum(_day_total(d, vendors) for d in w) for w in weeks[1:]]
        if prev:
            avg = sum(prev) / len(prev)
            if avg > 0:
                out.append("  This week vs average of previous %d week(s): %s vs %s (%+d%%)"
                           % (len(prev), fmt_tokens(this_w), fmt_tokens(avg),
                              round((this_w / avg - 1) * 100)))

    drivers = [d for d in (act.get("drivers") or []) if isinstance(d, dict)]
    if drivers:
        drivers.sort(key=lambda d: _num(d.get("share")) or 0, reverse=True)
        out.append("")
        out.append("Top drivers (share of Claude tokens in session-hours the driver was active; "
                   "shares overlap)")
        rows = [[d.get("name", "?"), d.get("kind", "?"), int(_num(d.get("calls")) or 0),
                 fmt_pct((_num(d.get("share")) or 0) * 100)] for d in drivers[:8]]
        out.append(_indent(table(rows, ["Driver", "Kind", "Calls", "Share"]), "  "))

    shares = []
    sa = _num(act.get("subagentShare"))
    lc = _num(act.get("longContextShare"))
    if sa is not None:
        shares.append("subagents %s" % fmt_pct(sa * 100))
    if lc is not None:
        shares.append("long context (%s) %s" % (LONG_CONTEXT_LABEL, fmt_pct(lc * 100)))
    if shares:
        out.append("")
        out.append("Share of Claude tokens: " + ", ".join(shares))

    rows = []
    for key, name in (("claude24h", "Claude"), ("codex24h", "Codex")):
        u = usage_split(act.get(key))
        if u:
            rows.append([name, fmt_tokens(u["input"]), fmt_tokens(u["output"]),
                         fmt_tokens(u["cacheRead"]), fmt_tokens(u["cacheWrite"]),
                         int(u["requests"]), fmt_tokens(u["total"]),
                         fmt_pct(u["cacheHit"] * 100) if u["cacheHit"] is not None else "-",
                         fmt_tokens(u["perRequest"])])
    if rows:
        out.append("")
        out.append("Last 24 h")
        out.append(_indent(table(rows, ["Tool", "Input", "Output", "CacheRd", "CacheWr",
                                        "Requests", "Total", "CacheHit", "Tok/req"]), "  "))
        out.append("  CacheHit = cache read / (input + cache read + cache write).")

    models = [m for m in (act.get("models") or []) if isinstance(m, dict)]
    if models:
        models = [m for m in models if m.get("vendor") in KNOWN_VENDORS]
        models.sort(key=lambda m: _num(m.get("tokens")) or 0, reverse=True)
        total = sum((_num(m.get("tokens")) or 0) for m in models) or 1
        out.append("")
        out.append("Models (last 7 days)")
        rows = [[vendor_name(m.get("vendor", "?")), m.get("model", "?"),
                 fmt_tokens(m.get("tokens") or 0),
                 fmt_pct((_num(m.get("tokens")) or 0) / total * 100)] for m in models[:10]]
        out.append(_indent(table(rows, ["Tool", "Model", "Tokens", "Share"]), "  "))

    out.append("")
    tips = activity_tips(act)
    out.append("Tip: " + tips[0])
    for extra in tips[1:]:
        out.append("Also: " + extra)
    print("\n".join(out))
    return 0


def budget_data(board, path, t, vendor=None):
    provs = providers(board, t)
    if vendor:
        provs = [p for p in provs if p["vendor"] == vendor]
    age = board_age(board, t)
    out_provs = []
    headline_meter = None
    for p in provs:
        ms = []
        for m in p["meters"]:
            entry = {
                "label": m["label"],
                "used": round(m["used"], 1),
                "remaining": round(m["remaining"], 1),
                "freshWindow": m["freshWindow"],
                "resetsAt": m["resetsAt"],
                "resetsAtLocal": fmt_weekday_clock(m["resetsAt"]) if m["resetsAt"] else None,
                "hoursToReset": round(m["secondsToReset"] / 3600.0, 2) if m["secondsToReset"] is not None else None,
                "windowHours": round(m["windowSeconds"] / 3600.0, 1) if m["windowSeconds"] else None,
                "projectedAtReset": round(m["projectedAtReset"], 1) if m["projectedAtReset"] is not None else None,
                "limitHitAt": m["limitHitAt"],
                "limitHitAtLocal": fmt_weekday_clock(m["limitHitAt"]) if m["limitHitAt"] else None,
                "hoursToLimit": round((m["limitHitAt"] - t) / 3600.0, 2) if m["limitHitAt"] else None,
                "verdict": m["verdict"],
            }
            ms.append(entry)
            key = (VERDICT_RANK[m["verdict"]], m["used"], m["projectedAtReset"] or 0)
            if headline_meter is None or key > headline_meter[0]:
                headline_meter = (key, p, m)
        out_provs.append({
            "vendor": p["vendor"], "account": p["account"], "plan": p["plan"],
            "note": p["note"] or None,
            "stale": p["stale"],
            "ageHours": round(p["ageSeconds"] / 3600.0, 2) if p["ageSeconds"] is not None else None,
            "experimental": p["experimental"],
            "verdict": p["verdict"], "meters": ms,
        })
    calibrate(board, out_provs, t)
    verdict = worst([p["verdict"] for p in out_provs], default="unknown") if out_provs else "unknown"
    headline = None
    if headline_meter:
        _, p, m = headline_meter
        headline = headline_text(p, m, t)
    return {
        "status": "ok",
        "board": path,
        "now": t,
        "boardAgeHours": round(age / 3600.0, 2) if age is not None else None,
        "boardStale": age is not None and age > STALE_SECONDS,
        "vendorFilter": vendor,
        "verdict": verdict,
        "headline": headline,
        "providers": out_provs,
    }


def calibrate(board, provs, t):
    """Rough tokens-per-1% for multi-day meters, from this machine's daily totals.

    Sums the vendor's daily tokens since the window started and divides by the
    percent used. Approximate: plan meters weight token types differently and
    other machines on the same account are invisible here. Only this user's own
    mix is reflected, which is what makes it useful for estimating a task.
    """
    act = board.get("activity")
    if not isinstance(act, dict):
        return
    days = [d for d in (act.get("days") or []) if isinstance(d, dict) and _num(d.get("day")) is not None]
    for p in provs:
        for m in p["meters"]:
            m["tokensPerPercent"] = None
            win = (m["windowHours"] or 0) * 3600
            if m["resetsAt"] is None or win < 86400 or m["used"] < 1:
                continue
            start = m["resetsAt"] - win
            total = 0.0
            for d in days:
                day = _num(d["day"])
                tokens = _num(d.get(p["vendor"])) or 0
                if day + 86400 <= start or day > t:
                    continue
                frac = 1.0 if day >= start else (day + 86400 - start) / 86400.0
                total += tokens * frac
            if total > 0:
                m["tokensPerPercent"] = int(total / m["used"])
                m["tokensPerPercentHuman"] = fmt_tokens(total / m["used"])


def headline_text(p, m, t):
    label = m["label"]
    lbl = label.lower() if label in ("Current", "Weekly", "Monthly") else label
    if label == "Current":
        lbl = "5-hour"
    s = "%s %s limit at %s" % (p["name"], lbl, fmt_pct(m["used"]))
    if m["freshWindow"]:
        return "%s %s window just reset" % (p["name"], lbl)
    if m["projectedAtReset"] is not None and m["projectedAtReset"] >= 100 and m["used"] < 100:
        s += ", on pace for %d%% by reset" % round(m["projectedAtReset"])
    if m["limitHitAt"] is not None and m["used"] < 100:
        s += " (limit ~%s)" % fmt_weekday_clock(m["limitHitAt"])
    if m["resetsAt"] is not None:
        s += ", resets %s" % fmt_weekday_clock(m["resetsAt"])
    if p["stale"]:
        s += " (data %s old)" % fmt_short_duration(p["ageSeconds"])
    return s


def cmd_budget(args):
    vendor = None
    if "--vendor" in args:
        i = args.index("--vendor")
        try:
            vendor = args[i + 1].lower()
        except IndexError:
            print("usage: board.py budget [--vendor claude|codex|copilot|cursor|grok]", file=sys.stderr)
            return 1
    try:
        path, board = load_board()
    except BoardError as exc:
        print(json.dumps({"status": "no-board", "verdict": "unknown",
                          "message": str(exc), "install": REPO_URL}, indent=2))
        return EXIT_NO_BOARD
    print(json.dumps(budget_data(board, path, now(), vendor), indent=2))
    return 0


def cmd_hook(_args):
    """SessionStart: one line of context when Claude headroom is tight/critical.

    Silent (and exit 0) in every other case, including errors.
    """
    try:
        path, board = load_board()
        t = now()
        age = board_age(board, t)
        if age is not None and age > BOARD_DEAD_SECONDS:
            return 0
        data = budget_data(board, path, t, "claude")
        if data["verdict"] not in ("tight", "critical") or not data["headline"]:
            return 0
        advice = ("prefer lighter strategies" if data["verdict"] == "tight"
                  else "prefer lighter strategies; defer large fan-outs until after reset")
        line = "TokenMeter: %s — %s." % (data["headline"], advice)
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                 "additionalContext": line}}))
    except Exception:
        pass
    return 0


def cmd_statusline(_args):
    """Prints e.g. '✳ 22% · ⏳ 3h' for the most-used Claude meter. Silent on error."""
    try:
        path, board = load_board()
        t = now()
        provs = [p for p in providers(board, t) if p["vendor"] == "claude"]
        if not provs or not provs[0]["meters"]:
            return 0
        p = provs[0]
        m = max(p["meters"], key=lambda m: (m["used"], -(m["windowSeconds"] or 0)))
        seg = "✳ %s" % fmt_pct(m["used"])
        if m["secondsToReset"] is not None:
            seg += " · ⏳ %s" % fmt_short_duration(m["secondsToReset"])
        if p["stale"]:
            seg += " (stale)"
        sys.stdout.write(seg + "\n")
    except Exception:
        pass
    return 0


COMMANDS = {
    "limits": cmd_limits,
    "activity": cmd_activity,
    "budget": cmd_budget,
    "json": cmd_json,
    "path": cmd_path,
    "hook": cmd_hook,
    "statusline": cmd_statusline,
}


def main(argv):
    _setup_stdout()
    if len(argv) < 2 or argv[1] in ("-h", "--help", "help") or argv[1] not in COMMANDS:
        print(__doc__.strip())
        return 0 if len(argv) >= 2 and argv[1] in ("-h", "--help", "help") else 1
    try:
        return COMMANDS[argv[1]](argv[2:])
    except BoardError as exc:
        print(str(exc))
        return EXIT_NO_BOARD


if __name__ == "__main__":
    sys.exit(main(sys.argv))
