# momo-auto-handoff

Small, local automation for [Claude Code](https://claude.com/claude-code) so that a usage limit or a long idle gap does not cost you your place in the work.

No LLM calls, no network, no daemon of its own. Stdlib Python and bash, merged into your existing `settings.json` without replacing anything.

## What it does

1. **Near-limit guard.** A statusline snippet records your rate-limit usage per session. A hook (`UserPromptSubmit` and `PostToolUse`) reads it, and once usage reaches **85 % of the 5-hour window** or **90 % of the 7-day window** it tells the model, once per window: finish the current step, commit its own files, update `docs/handoff.md`, and tell you the limit is near.
2. **Snapshot on a real limit hit.** A `StopFailure` hook saves a short markdown snapshot of the session tail (last messages, files edited, last git status) with secrets redacted. `Stop` and `SessionEnd` hooks keep a fresh snapshot too.
3. **Idle auto-save (macOS launchd).** Every 20 minutes a job looks for sessions idle between 2 h and 48 h and writes a mechanical (no LLM) summary to `~/.claude/state/handoffs/<project-slug>.md`. It never writes into your project directories and never runs `git`.
4. **Next-session pointer.** A `SessionStart` hook tells the new session that such a file exists, if it is newer than the project's `docs/handoff.md`.
5. **`/recall` skill.** A small Claude Code skill. In any project, `/recall` (or `/recall <project-name>`) reads the saved snapshots and the idle handoff, and tells you what you were doing, what is unfinished, which files are uncommitted and what to do next. Cheaper than resuming a huge session.

## Install

```sh
git clone <this repo> momo-auto-handoff && cd momo-auto-handoff
./install.sh --dry-run     # shows the plan, changes nothing
./install.sh
```

Needs `bash`, `jq` (1.6+) and `python3` (3.7+). No sudo, no prompts.

What `install.sh` does:

- backs up `settings.json` to `~/.claude/state/backups/<date>/` before changing it;
- merges six hook entries with `jq` (never replaces your arrays; running it twice adds nothing; a hook is skipped if that event already runs the same script);
- copies the scripts to `~/.claude/tools/` (a same-named file is backed up first);
- copies the `/recall` skill to `~/.claude/skills/recall/SKILL.md` (a skill of your own with that name is backed up first and restored on uninstall);
- sets `statusLine` **only if you have none**. If you already have one it is never touched silently: you get exact instructions, or pass `--wrap-statusline` to wrap your command (reversible);
- on macOS, renders a launchd plist with your `$HOME` and loads it with `launchctl bootstrap gui/$(id -u)`. Skip with `--no-launchd`;
- prints what changed and the uninstall command.

Hooks load in new Claude Code sessions. Restart running ones.

## Uninstall

```sh
./uninstall.sh --dry-run
./uninstall.sh            # removes only what install.sh added, restores backed-up files
./uninstall.sh --purge    # also deletes saved usage/snapshot/handoff data
```

`CLAUDE_CONFIG_DIR` is honoured by every script (default `~/.claude`).

## Limits, stated plainly

- **The idle job is macOS-only** (launchd). On Linux the hooks work but the idle job is not installed; see `docs/troubleshooting.md` for a cron line (untested).
- **It cannot trigger `/compact` or any Claude Code command from outside.** It only injects a message into the session via hooks and writes files.
- **The guard needs `rate_limits` in the statusLine JSON.** That is present on Claude.ai subscription plans and `null` on API-key, Bedrock and Vertex. There the guard stays silent (it finds no usage file) and everything else still works.
- The guard is advisory: the model may or may not follow the instruction. A near-limit warning appears at most once per window and reset time.
- The idle summary is mechanical (last messages, edited files, saved git info), not an LLM-written handoff. Verify state before acting on it.
- The snapshot hooks run read-only `git rev-parse` / `git status` in the session's directory.
- Tested on **Claude Code 2.1.292**, macOS. Hook payloads (`StopFailure`, statusLine `rate_limits`) may change in other versions.

## Layout

```
install.sh  uninstall.sh
src/        limit-guard.sh  statusline-usage.sh  session-snapshot.py  idle-handoff.py  handoff-inject.py
templates/  settings-hooks.json  com.momo.auto-handoff.plist.in
docs/       how-it-works.md  thresholds.md  troubleshooting.md
tests/      run.sh            (runs in a temporary HOME, never your real config)
```

## Tests

```sh
tests/run.sh
```

## Privacy

Everything stays on your machine. Snapshots and handoffs are stored `0600` under `~/.claude/state/` and pass through secret redaction (API-key shapes, bearer tokens, `password=` style assignments, long base64-like blobs). Redaction is best effort: do not treat these files as safe to share.

## License

MIT
