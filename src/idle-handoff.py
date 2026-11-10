#!/usr/bin/env python3
"""momo-auto-handoff: idle handoff (run by launchd every 20 min). Stdlib only, no LLM, no git, no network.
Picks <config>/projects/<slug>/<sid>.jsonl idle 2h..48h with no marker state/idle-done/<sid>-<mtime>,
builds a snapshot (reuses session-snapshot.py build_snapshot; saved git info only) and writes it as one block
into <config>/state/handoffs/<slug>.md (one block per session, newest first, cap MAX_BLOCKS).
Never writes into project directories. Also prunes state/{usage,flags,idle-done} files older than 14 days.
<config> is $CLAUDE_CONFIG_DIR or ~/.claude. Dry run: --dry-run (prints, writes nothing).
Env: AUTO_HANDOFF_MIN_IDLE_HOURS (default 2), AUTO_HANDOFF_MAX_IDLE_HOURS (default 48)."""
import importlib.util
import os
import re
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
CL = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
PROJECTS = os.path.join(CL, "projects")
ST = os.path.join(CL, "state")
SNAPS = os.path.join(ST, "snapshots")
HANDOFFS = os.path.join(ST, "handoffs")
DONE = os.path.join(ST, "idle-done")


def _hours(name, default):
    try:
        v = float(os.environ.get(name, ""))
        return v if v >= 0 else default
    except ValueError:
        return default


MIN_IDLE = _hours("AUTO_HANDOFF_MIN_IDLE_HOURS", 2) * 3600
MAX_IDLE = _hours("AUTO_HANDOFF_MAX_IDLE_HOURS", 48) * 3600
LOG = os.path.join(ST, "idle-handoff.log")
LOG_MAX = 200_000
MAX_BLOCKS = 5
GIT_LINES = 25
PRUNE_SECS = 14 * 86400
SID_RE = re.compile(r"[A-Za-z0-9_\-]{1,100}")
HEAD_RE = re.compile(r"^## AUTO-IDLE SAVE (.+?) session (\S+)\s*$")


def load_snapshot_mod():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "session-snapshot.py")
    if not os.path.isfile(path):
        path = os.path.join(CL, "tools", "session-snapshot.py")
    spec = importlib.util.spec_from_file_location("session_snapshot", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def saved_git(snap_path):
    """[(label, value)] parsed from an older snapshot, so no git is run."""
    try:
        txt = open(snap_path, encoding="utf-8").read()
    except Exception:
        return []
    out = []
    m = re.search(r"^- git branch: (.*)$", txt, re.M)
    if m:
        out.append(("branch", m.group(1).strip()))
    m = re.search(r"^## git status --porcelain\n(.*?)(?=\n## |\Z)", txt, re.S | re.M)
    if m:
        v = m.group(1).strip()
        out.append(("status", "" if v == "(clean)" else v))
    return out


def snapshot_text(sm, slug, sid, jpath, jmtime):
    """Existing snapshot if at least as new as the transcript, else rebuilt from the jsonl."""
    snap = os.path.join(SNAPS, slug, sid + ".md")
    try:
        if os.stat(snap).st_mtime >= jmtime:
            return open(snap, encoding="utf-8").read()
    except FileNotFoundError:
        pass
    hook = {"session_id": sid, "transcript_path": jpath, "hook_event_name": "IdleHandoff"}
    return sm.build_snapshot(hook, jpath, sid, "IdleHandoff", git=saved_git(snap))


def make_block(text, sid, jmtime, now):
    # drop title + volatile header lines, demote headings so only block headers start with "## "
    lines = []
    in_git = 0  # lines seen in the git status section (capped)
    for ln in text.splitlines():
        if ln.startswith("# Session snapshot") or ln.startswith("- time:") or ln.startswith("- event:"):
            continue
        if ln.startswith("## "):
            in_git = 1 if ln.startswith("## git status") else 0
        elif in_git:
            in_git += 1
            if in_git > GIT_LINES + 1:
                if in_git == GIT_LINES + 2:
                    lines.append("... (more files, truncated)\n")
                continue
        lines.append("###" + ln[2:] if ln.startswith("## ") else ln)
    when = datetime.fromtimestamp(jmtime).astimezone().strftime("%Y-%m-%d %H:%M")
    saved = datetime.fromtimestamp(now).astimezone().strftime("%Y-%m-%d %H:%M")
    head = "## AUTO-IDLE SAVE %s session %s" % (when, sid)
    return head + "\n- idle-saved: %s (time above = last activity)\n" % saved + "\n".join(lines).strip() + "\n"


def parse_blocks(path):
    blocks = []  # [sid, text]
    try:
        txt = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return blocks
    cur = None
    for ln in txt.splitlines():
        m = HEAD_RE.match(ln)
        if m:
            cur = [m.group(2), ln + "\n"]
            blocks.append(cur)
        elif cur is not None:
            cur[1] += ln + "\n"
    return blocks


def write_handoff(slug, new):
    """new: [(sid, jmtime, block_text)]. Replace same-sid blocks, newest first, cap."""
    path = os.path.join(HANDOFFS, slug + ".md")
    keep = {}
    for sid, text in parse_blocks(path):
        keep[sid] = (_block_time(text), text)
    for sid, jm, text in new:
        keep[sid] = (_block_time(text), text)
    ordered = sorted(keep.values(), key=lambda x: x[0], reverse=True)[:MAX_BLOCKS]
    body = "\n".join(t.rstrip("\n") + "\n" for _, t in ordered)
    os.makedirs(HANDOFFS, mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(body)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _block_time(text):
    m = HEAD_RE.match(text.split("\n", 1)[0])
    return m.group(1) if m else ""


def prune():
    cutoff = time.time() - PRUNE_SECS
    for sub in ("usage", "flags", "idle-done"):
        d = os.path.join(ST, sub)
        try:
            names = os.listdir(d)
        except FileNotFoundError:
            continue
        for n in names:
            p = os.path.join(d, n)
            try:
                if os.path.isfile(p) and os.stat(p).st_mtime < cutoff:
                    os.remove(p)
            except OSError:
                pass


def candidates(now):
    try:
        slugs = sorted(os.listdir(PROJECTS))
    except FileNotFoundError:
        return
    for slug in slugs:
        sd = os.path.join(PROJECTS, slug)
        if slug.startswith(".") or not os.path.isdir(sd):
            continue
        try:
            names = os.listdir(sd)
        except OSError:
            continue
        for n in names:
            if not n.endswith(".jsonl"):
                continue
            sid = n[:-6]
            if not SID_RE.fullmatch(sid) or sid.startswith("agent-"):
                continue
            p = os.path.join(sd, n)
            try:
                if not os.path.isfile(p) or os.path.islink(p):
                    continue
                mt = os.stat(p).st_mtime
            except OSError:
                continue
            age = now - mt
            if age < MIN_IDLE or age > MAX_IDLE:
                continue
            if os.path.exists(os.path.join(DONE, "%s-%d" % (sid, int(mt)))):
                continue
            yield slug, sid, p, mt


def trim_log():
    """launchd appends stdout/stderr to LOG forever; keep the tail only."""
    try:
        size = os.path.getsize(LOG)
        if size > LOG_MAX:
            with open(LOG, "rb") as f:
                f.seek(size - LOG_MAX // 2)
                f.readline()
                tail = f.read()
            with open(LOG, "r+b") as f:
                f.write(tail)
                f.truncate()
    except OSError:
        pass


def main():
    dry = "--dry-run" in sys.argv
    if not dry:
        trim_log()
    now = time.time()
    os.makedirs(DONE, mode=0o700, exist_ok=True)
    sm = load_snapshot_mod()
    per_slug = {}
    marks = []
    for slug, sid, p, mt in candidates(now):
        try:
            text = snapshot_text(sm, slug, sid, p, mt)
        except Exception as e:
            print("skip %s/%s: %s" % (slug, sid, e))
            continue
        marks.append((sid, mt))
        # nothing worth saving: no user msgs and no edited files
        if not text or ("(none in tail window)" in text and "## Files edited (tail window)\n(none)" in text):
            print("empty/non-cli %s/%s" % (slug, sid))
            continue
        print("pick %s/%s idle=%.1fh" % (slug, sid, (now - mt) / 3600))
        per_slug.setdefault(slug, []).append((sid, mt, make_block(text, sid, mt, now)))
    if dry:
        for slug, items in per_slug.items():
            print("[dry] would write %s.md with %d block(s)" % (slug, len(items)))
        return
    for slug, items in per_slug.items():
        write_handoff(slug, items)
    for sid, mt in marks:
        fd = os.open(os.path.join(DONE, "%s-%d" % (sid, int(mt))), os.O_WRONLY | os.O_CREAT, 0o600)
        os.close(fd)
    prune()
    if marks:
        print("%s done: %d session(s), %d handoff file(s)" % (datetime.now().isoformat(timespec="seconds"), len(marks), len(per_slug)))


if __name__ == "__main__":
    try:
        main()
    except BaseException as e:  # never crash-loop launchd
        print("error: %r" % (e,))
    sys.exit(0)
