#!/bin/bash
# momo-auto-handoff: limit guard (hook: UserPromptSubmit + PostToolUse).
# Pure bash on the fast path: no forks until a threshold is hit.
# Reads <config>/state/usage/<session_id>.json (written by statusline-usage.sh).
# If the 5-hour window is >= FIVE % or the 7-day window is >= SEVEN %, and the usage file is fresh,
# and this window+reset was not warned yet, print hook additionalContext ONCE. Always exit 0, silent otherwise.
#
# Tunables (env, e.g. via the "env" block of settings.json):
#   AUTO_HANDOFF_FIVE   default 85   5-hour threshold, percent
#   AUTO_HANDOFF_SEVEN  default 90   7-day threshold, percent
#   AUTO_HANDOFF_MAXAGE default 600  ignore usage files older than this many seconds

FIVE=${AUTO_HANDOFF_FIVE:-85}
SEVEN=${AUTO_HANDOFF_SEVEN:-90}
MAXAGE=${AUTO_HANDOFF_MAXAGE:-600}
[[ $FIVE =~ ^[0-9]+$ ]] || FIVE=85
[[ $SEVEN =~ ^[0-9]+$ ]] || SEVEN=90
[[ $MAXAGE =~ ^[0-9]+$ ]] || MAXAGE=600
ST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state"

IN=""
read -r -t 1 -d '' IN || true
[[ $IN =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{1,100})\" ]] || exit 0
SID="${BASH_REMATCH[1]}"
EV=UserPromptSubmit
[[ $IN =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]{1,40})\" ]] && EV="${BASH_REMATCH[1]}"

F="$ST/usage/$SID.json"
[ -r "$F" ] || exit 0
U=$(<"$F")

num() { # key -> R (integer part of a number, or empty)
  if [[ $U =~ \"$1\":([0-9.]+) ]]; then R="${BASH_REMATCH[1]%%.*}"; else R=""; fi
}
num five_hour_pct;       P5="$R"
num five_hour_resets_at; T5="$R"
num seven_day_pct;       P7="$R"
num seven_day_resets_at; T7="$R"
num ts;                  TS="$R"

HIT5=0; HIT7=0
[ -n "$P5" ] && [ "$P5" -ge "$FIVE" ] && HIT5=1
[ -n "$P7" ] && [ "$P7" -ge "$SEVEN" ] && HIT7=1
[ "$HIT5$HIT7" = "00" ] && exit 0

# only now fork: freshness + flags
NOW=$(date +%s)
[ -n "$TS" ] && [ $((NOW - TS)) -le "$MAXAGE" ] || exit 0
mkdir -p "$ST/flags" 2>/dev/null

hhmm() { # epoch -> local HH:MM (BSD and GNU date)
  if [ "$(uname)" = Darwin ]; then date -r "$1" +%H:%M 2>/dev/null; else date -d "@$1" +%H:%M 2>/dev/null; fi
}

MSG=""
claim() { # window pct resets_at label
  local fl="$ST/flags/$SID-$1-${3:-none}" hm=""
  [ -e "$fl" ] && return
  : > "$fl" 2>/dev/null || return
  [ -n "$3" ] && hm=$(hhmm "$3")
  MSG="$MSG $4 usage limit near ($2%, resets at ${hm:-unknown} local)."
}
[ "$HIT5" = 1 ] && claim five_hour "$P5" "$T5" "5-hour"
[ "$HIT7" = 1 ] && claim seven_day "$P7" "$T7" "7-day"
[ -z "$MSG" ] && exit 0

MSG="$MSG Finish the current step, then commit your own files only (git commit -- <paths>, no push), update docs/handoff.md (run commands, current state, open items, rules), and tell the user in two short lines that the limit is near and the work is saved."
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$EV" "${MSG# }"
exit 0
