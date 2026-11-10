#!/usr/bin/env python3
"""momo-auto-handoff: SessionStart hook. If <config>/state/handoffs/<slug-of-cwd>.md exists and is newer than
<cwd>/docs/handoff.md (or that file is absent), tell the model it exists (path + 1 line, not content).
<config> is $CLAUDE_CONFIG_DIR or ~/.claude. Stdlib only, no network, always exit 0."""
import json
import os
import re
import sys


def main():
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    if not isinstance(hook, dict) or hook.get("source") == "compact":
        return
    cwd = hook.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return
    slug = re.sub(r"[^A-Za-z0-9-]", "-", cwd)  # same as ~/.claude/projects dir names
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    p = os.path.join(cfg, "state", "handoffs", slug + ".md")
    try:
        hm = os.stat(p).st_mtime
    except OSError:
        return
    try:
        if os.stat(os.path.join(cwd, "docs", "handoff.md")).st_mtime >= hm:
            return
    except OSError:
        pass
    msg = "Auto-idle handoff exists at %s (mechanical snapshot, not written by the model): read it, then verify the state before continuing." % p
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}}))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
