# Thresholds and tunables

All optional. Set them in the `env` block of `settings.json` (for the hooks) or in the launchd plist (for the idle job).

| Variable | Default | Used by | Meaning |
|---|---|---|---|
| `AUTO_HANDOFF_FIVE` | 85 | limit-guard.sh | warn when the 5-hour window reaches this percent |
| `AUTO_HANDOFF_SEVEN` | 90 | limit-guard.sh | warn when the 7-day window reaches this percent |
| `AUTO_HANDOFF_MAXAGE` | 600 | limit-guard.sh | ignore a usage file older than this many seconds (stale statusline) |
| `AUTO_HANDOFF_MIN_IDLE_HOURS` | 2 | idle-handoff.py | a session must be idle at least this long |
| `AUTO_HANDOFF_MAX_IDLE_HOURS` | 48 | idle-handoff.py | older sessions are ignored |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | all | config directory |

Example:

```json
{ "env": { "AUTO_HANDOFF_FIVE": "80", "AUTO_HANDOFF_SEVEN": "95" } }
```

Constants in the scripts (edit the file to change): idle job interval 1200 s (plist `StartInterval`), at most 5 blocks per handoff file, git status capped at 25 lines per block, prune after 14 days, snapshot keeps the last 20 per project, Stop-hook throttle 60 s.

## Warn-once rule

The guard creates `state/flags/<session_id>-<window>-<resets_at>` on the first warning. The same window and reset time never warns again for that session; a new reset time (new window) can.
