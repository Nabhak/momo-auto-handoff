#!/usr/bin/env python3
"""momo-auto-handoff: session snapshot hook (Stop / SessionEnd / StopFailure). Stdlib only, no LLM, no network.
Reads hook JSON on stdin, writes a small markdown snapshot of the session tail to
<config>/state/snapshots/<project-slug>/<session_id>.md (+ latest.md), where <config> is
$CLAUDE_CONFIG_DIR or ~/.claude. Secrets are redacted. Runs read-only `git` in the session cwd (branch + status).
Always exits 0 and prints nothing."""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

TAIL_BYTES = 1_500_000
THROTTLE_SECS = 60
KEEP = 20
MAX_USER_MSGS = 8
USER_CHARS = 300
ASSISTANT_CHARS = 600
MAX_FILES = 20
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
NOISE_PREFIXES = (
    "<system-reminder", "<command-", "<local-command", "<task-notification",
    "<user-prompt-submit-hook", "Caveat:", "[Request interrupted", "<bash-",
)

SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)", re.S), "[REDACTED]"),
    (re.compile(r"\bsk-[A-Za-z0-9_\-]{8,}"), "[REDACTED]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}"), "[REDACTED]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "[REDACTED]"),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{12,}"), "[REDACTED]"),
    (re.compile(r"\bxox[a-zA-Z]-[A-Za-z0-9\-]{8,}"), "[REDACTED]"),
    (re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]{8,}"), "Bearer [REDACTED]"),
    (re.compile(r"(?i)\b(password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|auth)\b(\s*[=:]\s*)(\"[^\"]*\"|'[^']*'|\S+)"),
     r"\1\2[REDACTED]"),
    (re.compile(r"[A-Za-z0-9+/_]{40,}={0,2}"), lambda m: "[REDACTED]" if _mixed(m.group(0)) else m.group(0)),
]


def config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def _mixed(t):
    # long base64-ish blob: needs digit + upper + lower (avoids eating plain file paths)
    return any(c.isdigit() for c in t) and any(c.isupper() for c in t) and any(c.islower() for c in t)


def redact(s):
    for pat, rep in SECRET_PATTERNS:
        s = pat.sub(rep, s)
    return s


def trim(s, n):
    s = " ".join(s.split())
    return s if len(s) <= n else s[:n] + "..."


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(b.get("text", ""))
        return "\n".join(parts)
    return ""


def read_tail(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > TAIL_BYTES:
            f.seek(size - TAIL_BYTES)
            f.readline()  # drop partial first line
        data = f.read()
    return data.splitlines()


def git_info(cwd):
    out = []
    if not cwd or not os.path.isdir(cwd):
        return out
    for label, cmd in (("branch", ["git", "rev-parse", "--abbrev-ref", "HEAD"]),
                       ("status", ["git", "status", "--porcelain"])):
        try:
            r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=2,
                               stdin=subprocess.DEVNULL)
            if r.returncode == 0:
                out.append((label, r.stdout.strip()))
        except Exception:
            pass
    return out


def atomic_write(path, content):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def rotate(d):
    try:
        files = []
        for n in os.listdir(d):
            if n.endswith(".md") and n != "latest.md":
                p = os.path.join(d, n)
                try:
                    files.append((os.stat(p).st_mtime, p))
                except FileNotFoundError:
                    pass
        files.sort(reverse=True)
        for _, p in files[KEEP:]:
            try:
                os.remove(p)
            except FileNotFoundError:
                pass
        for n in os.listdir(d):  # stale tmp files
            if ".tmp." in n:
                p = os.path.join(d, n)
                try:
                    if time.time() - os.stat(p).st_mtime > 3600:
                        os.remove(p)
                except FileNotFoundError:
                    pass
    except Exception:
        pass


def build_snapshot(hook, tpath, sid, event, git=None):
    """Snapshot markdown for a session transcript, or None for non-cli sessions.
    git: pre-made [(label, value)] list; None -> run git_info (idle-handoff passes saved values, never runs git)."""
    lines = read_tail(tpath)
    entry = None
    users = []
    last_assistant = ""
    files = []
    cwd = hook.get("cwd") or ""
    for raw in lines:
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        ep = o.get("entrypoint")
        if ep:
            entry = ep
        if o.get("cwd") and not cwd:
            cwd = o["cwd"]
        if o.get("isSidechain"):
            continue
        t = o.get("type")
        msg = o.get("message") if isinstance(o.get("message"), dict) else {}
        if t == "user" and not o.get("isMeta"):
            c = msg.get("content")
            if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                continue
            txt = text_of(c).strip()
            if txt and not txt.startswith(NOISE_PREFIXES):
                users.append(txt)
        elif t == "assistant":
            c = msg.get("content")
            txt = text_of(c).strip()
            if txt:
                last_assistant = txt
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in EDIT_TOOLS:
                        inp = b.get("input") or {}
                        fp = inp.get("file_path") or inp.get("notebook_path")
                        if fp and fp not in files:
                            files.append(fp)
    if entry is not None and entry != "cli":
        return None  # headless / sdk / desktop-agent sessions
    la = hook.get("last_assistant_message")
    if isinstance(la, str) and la.strip():
        last_assistant = la.strip()

    out = []
    out.append("# Session snapshot")
    out.append("- time: %s" % datetime.now().astimezone().isoformat(timespec="seconds"))
    out.append("- event: %s" % (event or "?"))
    out.append("- cwd: %s" % cwd)
    out.append("- session_id: %s" % sid)
    out.append("- resume: `claude --resume %s`" % sid)
    gi = git_info(cwd) if git is None else git
    for label, val in gi:
        if label == "branch":
            out.append("- git branch: %s" % val)
    for label, val in gi:
        if label == "status":
            out.append("\n## git status --porcelain")
            out.append(val if val else "(clean)")
    out.append("\n## Last user messages (oldest to newest)")
    for u in users[-MAX_USER_MSGS:]:
        out.append("- " + trim(u, USER_CHARS))
    if not users:
        out.append("(none in tail window)")
    out.append("\n## Last assistant message")
    out.append(trim(last_assistant, ASSISTANT_CHARS) if last_assistant else "(none)")
    out.append("\n## Files edited (tail window)")
    for fp in files[-MAX_FILES:]:
        out.append("- " + fp)
    if not files:
        out.append("(none)")
    content = redact("\n".join(out) + "\n")
    return content


def main():
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    if not isinstance(hook, dict):
        return
    tpath = hook.get("transcript_path")
    sid = hook.get("session_id")
    if not tpath or not sid or not os.path.isfile(tpath):
        return
    if not re.fullmatch(r"[A-Za-z0-9_\-]{1,100}", str(sid)):
        return
    slug = os.path.basename(os.path.dirname(os.path.abspath(tpath)))
    if not slug or slug in (".", ".."):
        return
    event = hook.get("hook_event_name", "")

    d = os.path.join(config_dir(), "state", "snapshots", slug)
    snap = os.path.join(d, sid + ".md")
    if event == "Stop":
        try:
            if time.time() - os.stat(snap).st_mtime < THROTTLE_SECS:
                return
        except FileNotFoundError:
            pass

    content = build_snapshot(hook, tpath, sid, event)
    if content is None:
        return

    os.makedirs(d, mode=0o700, exist_ok=True)
    for p in (os.path.dirname(d), d):
        try:
            os.chmod(p, 0o700)
        except Exception:
            pass
    atomic_write(snap, content)
    atomic_write(os.path.join(d, "latest.md"), content)
    rotate(d)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
