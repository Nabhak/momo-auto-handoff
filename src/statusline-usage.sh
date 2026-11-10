#!/bin/bash
# momo-auto-handoff: statusline usage writer.
# Claude Code pipes a JSON blob to the statusLine command on stdin. This script reads it and, when it
# carries rate_limits (subscription plans only), writes <config>/state/usage/<session_id>.json for limit-guard.sh.
# Written on change, or as a 60 s heartbeat so the file never looks stale. Best effort: never fails the statusline.
#
# Usage:
#   statusline-usage.sh                 print a minimal line ("5h 42% | 7d 10%"), or nothing without rate_limits
#   statusline-usage.sh --quiet         print nothing (use inside your own statusline script)
#   statusline-usage.sh --wrap 'CMD'    write the file, then run CMD (your existing statusline) with the same stdin
# Needs python3 (stdlib only). No network.

QUIET=0
WRAP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --wrap) WRAP="${2:-}"; shift ;;
  esac
  shift 2>/dev/null || true
done

PY=$(cat <<'EOF'
import json, os, re, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
try:
    sid = str(d.get("session_id") or "")
    rl = d.get("rate_limits")
    if not (re.fullmatch(r"[A-Za-z0-9_\-]{1,100}", sid) and isinstance(rl, dict) and rl):
        sys.exit(0)

    def g(o, k):
        w = rl.get(o)
        v = w.get(k) if isinstance(w, dict) else None
        return v if isinstance(v, (int, float, str)) and not isinstance(v, bool) else None

    cw = d.get("context_window")
    cp = cw.get("used_percentage") if isinstance(cw, dict) else None
    vals = {
        "five_hour_pct": g("five_hour", "used_percentage"),
        "five_hour_resets_at": g("five_hour", "resets_at"),
        "seven_day_pct": g("seven_day", "used_percentage"),
        "seven_day_resets_at": g("seven_day", "resets_at"),
        "context_pct": cp if isinstance(cp, (int, float)) else None,
    }
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    ud = os.path.join(cfg, "state", "usage")
    f = os.path.join(ud, sid + ".json")
    try:
        with open(f) as fh:
            old = json.load(fh)
        age = time.time() - os.stat(f).st_mtime
    except Exception:
        old, age = None, 1e9
    if old is None or age > 60 or any(old.get(k) != v for k, v in vals.items()):
        vals["ts"] = int(time.time())
        os.makedirs(ud, mode=0o700, exist_ok=True)
        t = "%s.tmp.%d" % (f, os.getpid())
        fd = os.open(t, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(vals, fh, separators=(",", ":"))
        os.chmod(t, 0o600)
        os.replace(t, f)
    parts = []
    for label, k in (("5h", "five_hour_pct"), ("7d", "seven_day_pct")):
        v = vals[k]
        if isinstance(v, (int, float)):
            parts.append("%s %d%%" % (label, int(v)))
    if parts:
        print(" | ".join(parts))
except Exception:
    pass
EOF
)

INPUT=$(cat)
LINE=$(printf '%s' "$INPUT" | python3 -I -c "$PY" 2>/dev/null)

if [ -n "$WRAP" ]; then
  printf '%s' "$INPUT" | bash -c "$WRAP"
elif [ "$QUIET" != 1 ] && [ -n "$LINE" ]; then
  printf '%s\n' "$LINE"
fi
exit 0
