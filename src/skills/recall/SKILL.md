---
name: recall
description: Recall what a past or closed Claude Code session was doing, from auto-saved snapshots (/recall [project-name]).
---
<!-- installed by momo-auto-handoff -->

# /recall [project-name]

Snapshots: `~/.claude/state/snapshots/<project-slug>/<session_id>.md` + `latest.md`. Slug = cwd with `/` and `.` replaced by `-` (same as the `~/.claude/projects/` directory names). Written by the Stop / SessionEnd / StopFailure hook `~/.claude/tools/session-snapshot.py`. The idle auto-save also writes `~/.claude/state/handoffs/<slug>.md`.

Steps:
1. Pick the directory. No argument: the slug of the current directory. Argument given, or the current directory has no snapshots: fuzzy-match the argument (case-insensitive substring) against `ls ~/.claude/state/snapshots/`. Several matches: pick the newest and list the others.
2. `ls -t <dir>`; read the newest 1-3 snapshots (`latest.md` first). Each has the time, cwd, git branch and status, the last user messages, the last assistant message, the files edited and the session id.
3. If the snapshot is thin (few or no user messages, vague): `tail -n 200 ~/.claude/projects/<slug>/<session_id>.jsonl` with Bash. NEVER read the whole transcript (it can be 80 MB or more).
4. If the current directory has `docs/handoff.md`, read it too. If `~/.claude/state/handoffs/<slug>.md` exists and is newer, read it as well.
5. Write a short summary in the user's language: (a) what we were doing, (b) what is unfinished, (c) uncommitted files (the git status saved in the snapshot; re-run `git status --porcelain` in the cwd for the current state), (d) a suggested next step.
6. Offer `claude --continue` (latest session in the cwd) or `claude --resume <session_id>`. Warn that resuming a huge session costs many tokens, and that a recall is cheaper. Ask what to continue.

No snapshots found: say so, and fall back to the tail of the newest transcript in `~/.claude/projects/<slug>/` (`ls -t`, tail only).
