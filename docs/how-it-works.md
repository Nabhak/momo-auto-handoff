# How it works

## Data flow

```
Claude Code ──statusLine JSON (stdin)──> statusline-usage.sh
                                            └─ writes ~/.claude/state/usage/<session_id>.json
                                               {five_hour_pct, five_hour_resets_at, seven_day_pct,
                                                seven_day_resets_at, context_pct, ts}

UserPromptSubmit / PostToolUse ──> limit-guard.sh
      reads the usage file (pure bash, a few ms); if over threshold and fresh and not yet warned,
      prints {"hookSpecificOutput":{"additionalContext": "..."}}  and creates
      ~/.claude/state/flags/<session_id>-<window>-<resets_at>   (so it warns once per window + reset)

StopFailure ──> session-snapshot.py ──> ~/.claude/state/snapshots/<slug>/<session_id>.md (+ latest.md)
Stop / SessionEnd ──> same script (Stop is throttled to once per 60 s per session)

launchd every 20 min ──> idle-handoff.py
      for each ~/.claude/projects/<slug>/<session_id>.jsonl idle 2 h .. 48 h without a marker:
        reuse the snapshot if it is newer than the transcript, else rebuild it from the transcript
        (git info is copied from an older snapshot, git is never run)
        write one block "## AUTO-IDLE SAVE <last activity> session <id>" into
        ~/.claude/state/handoffs/<slug>.md   (newest first, at most 5 blocks)
        create marker ~/.claude/state/idle-done/<session_id>-<mtime>
      prune state/{usage,flags,idle-done} files older than 14 days

SessionStart ──> handoff-inject.py
      if state/handoffs/<slug-of-cwd>.md exists and is newer than <cwd>/docs/handoff.md,
      add one line of context with the path (not the content). Skipped for source=compact.
```

`<slug>` is the working directory with every character outside `[A-Za-z0-9-]` replaced by `-`, which is how Claude Code names directories under `~/.claude/projects/`.

## Safety properties

- Every hook command ends in `|| true` and has a timeout; the scripts always exit 0.
- Nothing is written into a project directory. All output goes under `$CLAUDE_CONFIG_DIR/state/`.
- No network access anywhere. No LLM calls.
- State files and directories are created `0600` / `0700`.
- Transcript sessions whose entrypoint is not `cli` (SDK, headless) are skipped.
- Sub-agent transcripts (`agent-*.jsonl`) are skipped by the idle job.

## What the model sees

At the threshold, one line like:

> 5-hour usage limit near (91%, resets at 14:30 local). Finish the current step, then commit your own files only (git commit -- <paths>, no push), update docs/handoff.md (...), and tell the user in two short lines that the limit is near and the work is saved.

Edit the sentence at the bottom of `limit-guard.sh` if you want different behaviour (for example, no commit).

## Hooks added to settings.json

See `templates/settings-hooks.json`. The installer adds an entry only if that event does not already reference the same `tools/<script>`.
