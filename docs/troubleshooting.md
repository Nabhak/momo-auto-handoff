# Troubleshooting

## The guard never warns
1. Is the usage file being written? `ls -l ~/.claude/state/usage/` should show a recent `<session_id>.json` while a session is open. If not:
   - your `statusLine` does not run `statusline-usage.sh` (see the install output, or re-run `./install.sh --wrap-statusline`);
   - your plan reports no `rate_limits` (API key, Bedrock, Vertex): the guard is silent by design. Check with: `echo '{"session_id":"t","rate_limits":null}' | ~/.claude/tools/statusline-usage.sh`.
2. Test the guard by hand:
   ```sh
   cat ~/.claude/state/usage/<session_id>.json
   echo '{"session_id":"<session_id>","hook_event_name":"UserPromptSubmit"}' | AUTO_HANDOFF_FIVE=1 ~/.claude/tools/limit-guard.sh
   ```
   If it prints nothing, a flag file may already exist: `ls ~/.claude/state/flags/`.
3. Usage file older than 10 minutes is ignored (`AUTO_HANDOFF_MAXAGE`). The statusline only runs while the session is active.
4. Hooks load at session start. Restart the session after installing.

## No idle handoff files appear
- macOS only. Check the job: `launchctl print gui/$(id -u)/com.momo.auto-handoff`.
- Run it now: `launchctl kickstart gui/$(id -u)/com.momo.auto-handoff`, then read `~/.claude/state/idle-handoff.log`.
- Dry run: `python3 ~/.claude/tools/idle-handoff.py --dry-run`.
- A session is picked only if its transcript was last written 2 h to 48 h ago, was a `cli` session, and has user messages or edited files. Each session is saved once per last-activity time.
- If the job cannot read your folders, macOS privacy settings may block background reads of Documents, Desktop or Downloads. The job only reads `~/.claude`, so this should not apply.

## Linux
The hooks and statusline script work as plain bash/python. launchd does not exist, so run the idle job from cron (untested):

```
*/20 * * * * python3 "$HOME/.claude/tools/idle-handoff.py" >> "$HOME/.claude/state/idle-handoff.log" 2>&1
```

## Settings merge refused
`install.sh` stops without changing anything if `settings.json` is not a JSON object or `hooks` has an unexpected shape. Fix the file (comments are not allowed in JSON) and re-run. Backups of every change are in `~/.claude/state/backups/<date>/`.

## Mute without uninstalling
- Guard only: `chmod -x ~/.claude/tools/limit-guard.sh` (the hook command ends in `|| true`).
- Idle job only: `launchctl bootout gui/$(id -u)/com.momo.auto-handoff`.

## A Claude Code update changed the hooks
Re-check the payload of `StopFailure` and the statusLine `rate_limits` field after major updates. This was tested on Claude Code 2.1.292.
