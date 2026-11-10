#!/usr/bin/env bash
# momo-auto-handoff uninstaller. Reverses install.sh. No sudo, no prompts, no network.
#
#   ./uninstall.sh [--dry-run] [--purge]
#
#   --dry-run  print the plan, change nothing
#   --purge    also delete saved data: state/{usage,flags,idle-done,handoffs,snapshots}, idle-handoff.log, manifest
#              (settings backups in state/backups/ are always kept)
#
# Removes only the hooks install.sh added (recorded in the manifest), our scripts (restoring any file install.sh
# backed up), the launchd job, and our statusLine (restoring your original if it was wrapped).
set -euo pipefail

LABEL="com.momo.auto-handoff"
SCRIPTS="limit-guard.sh handoff-inject.py session-snapshot.py idle-handoff.py statusline-usage.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0; PURGE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }
command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq)"

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CFG="${CFG%/}"
case "$CFG" in /*) ;; *) die "CLAUDE_CONFIG_DIR must be an absolute path (got: $CFG)" ;; esac

SETTINGS="$CFG/settings.json"
TOOLS="$CFG/tools"
MANIFEST="$CFG/state/momo-auto-handoff-install.json"
BACKUP_DIR="$CFG/state/backups/$(date +%Y-%m-%d)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ACT=""
act() { ACT="$ACT$*"$'\n'; }

backup_file() {
  local src=$1 base n=0 dest
  base=$(basename "$src")
  (umask 077; mkdir -p "$BACKUP_DIR")
  dest="$BACKUP_DIR/$base"
  while [ -e "$dest" ]; do n=$((n + 1)); dest="$BACKUP_DIR/$base.$n"; done
  cp -p "$src" "$dest"; chmod 600 "$dest"
  printf '%s' "$dest"
}

say "momo-auto-handoff uninstaller  (config dir: $CFG)"
[ "$DRY" = 1 ] && say "DRY RUN: nothing will be changed."
say ""

MAN='{}'
if [ -f "$MANIFEST" ]; then
  MAN=$(cat "$MANIFEST"); jq -e . >/dev/null 2>&1 <<<"$MAN" || { say "warning: manifest unreadable, using defaults"; MAN='{}'; }
else
  say "note: no install manifest found; falling back to removing the guard/inject hooks only"
fi

# ---- settings.json -----------------------------------------------------------------------------
SETTINGS_CHANGED=0; NEW=""; SETTINGS_BACKUP=""
if [ -f "$SETTINGS" ]; then
  CUR=$(cat "$SETTINGS")
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$CUR" || die "$SETTINGS is not a valid JSON object; nothing was changed"
  if jq -e '(.hooks // []) | length > 0' >/dev/null 2>&1 <<<"$MAN"; then
    PAIRS=$(jq -c '.hooks' <<<"$MAN")
  else
    PAIRS='[{"event":"UserPromptSubmit","key":"tools/limit-guard.sh"},{"event":"PostToolUse","key":"tools/limit-guard.sh"},{"event":"SessionStart","key":"tools/handoff-inject.py"},{"event":"StopFailure","key":"tools/session-snapshot.py"}]'
  fi
  NEW=$(jq --argjson p "$PAIRS" '
    reduce $p[] as $x (.;
      if (.hooks[$x.event] // null) == null then .
      else .hooks[$x.event] |= (map(.hooks |= map(select(((.command // "") | contains($x.key)) | not))) | map(select((.hooks | length) > 0)))
      end)
    | if (.hooks // null) != null then
        .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end' <<<"$CUR")

  # statusLine
  SL_CMD=$(jq -r '.statusLine.command // ""' <<<"$NEW")
  MODE=$(jq -r '.statusline.mode // "none"' <<<"$MAN")
  if [[ "$SL_CMD" == *tools/statusline-usage.sh* ]]; then
    case "$MODE" in
      set) NEW=$(jq 'del(.statusLine)' <<<"$NEW"); act "statusLine removed (it was set by the installer)" ;;
      wrapped) NEW=$(jq --argjson o "$(jq -c '.statusline.original' <<<"$MAN")" '.statusLine = $o' <<<"$NEW"); act "statusLine restored to your original" ;;
      *) say "note: statusLine still points at statusline-usage.sh and was not set by the installer; left as is. Edit it by hand if you want it gone." ;;
    esac
  fi
  if [ "$(jq -cS . <<<"$CUR")" != "$(jq -cS . <<<"$NEW")" ]; then
    SETTINGS_CHANGED=1
    act "hooks removed from settings.json: $(jq -r '[.[] | "\(.event)->\(.key)"] | join(", ")' <<<"$PAIRS")"
  fi
fi

# ---- scripts -----------------------------------------------------------------------------------
FILE_ACTIONS=""   # name|remove|restore-path
for f in $SCRIPTS; do
  d="$TOOLS/$f"
  [ -e "$d" ] || continue
  if cmp -s "$HERE/src/$f" "$d" || grep -q "momo-auto-handoff" "$d" 2>/dev/null; then
    bk=$(jq -r --arg k "tools/$f" '.files[$k].backup // ""' <<<"$MAN")
    if [ -n "$bk" ] && [ ! -f "$bk" ]; then say "warning: recorded backup for tools/$f is missing: $bk"; bk=""; fi
    FILE_ACTIONS="$FILE_ACTIONS$f|$bk"$'\n'
    if [ -n "$bk" ]; then act "script restored from backup: tools/$f"; else act "script removed: tools/$f"; fi
  else
    say "warning: tools/$f is not a momo-auto-handoff file (modified or replaced); left in place"
  fi
done

# ---- launchd -----------------------------------------------------------------------------------
HAVE_PLIST=0; [ -e "$PLIST" ] && HAVE_PLIST=1
LOADED=0
if [ "$(uname -s)" = Darwin ] && [ -z "${AUTO_HANDOFF_SKIP_LAUNCHCTL:-}" ] && command -v launchctl >/dev/null 2>&1; then
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && LOADED=1
fi
[ "$LOADED" = 1 ] && act "launchd job stopped ($LABEL)"
[ "$HAVE_PLIST" = 1 ] && act "launchd plist removed: $PLIST"

# ---- purge -------------------------------------------------------------------------------------
PURGE_LIST=""
if [ "$PURGE" = 1 ]; then
  for p in state/usage state/flags state/idle-done state/handoffs state/snapshots state/idle-handoff.log; do
    [ -e "$CFG/$p" ] && PURGE_LIST="$PURGE_LIST$CFG/$p"$'\n'
  done
  [ -n "$PURGE_LIST" ] && act "purged saved data: $(printf '%s' "$PURGE_LIST" | sed "s|^$CFG/||" | tr '\n' ' ')"
fi
[ -f "$MANIFEST" ] && act "install manifest removed"

if [ "$DRY" = 1 ]; then
  say "Plan:"
  if [ -z "$ACT" ]; then say "  nothing to remove"; else printf '%s' "$ACT" | sed 's/^/  - /'; fi
  say ""; say "Dry run only. Nothing was changed."
  exit 0
fi

# ---- apply -------------------------------------------------------------------------------------
if [ "$SETTINGS_CHANGED" = 1 ]; then
  SETTINGS_BACKUP=$(backup_file "$SETTINGS")
  TMPF=$(mktemp "${TMPDIR:-/tmp}/momo-settings.XXXXXX")
  jq . <<<"$NEW" > "$TMPF"
  jq -e . "$TMPF" >/dev/null || { rm -f "$TMPF"; die "internal error: result is not valid JSON; settings untouched"; }
  cat "$TMPF" > "$SETTINGS"; rm -f "$TMPF"
fi

while IFS='|' read -r f bk; do
  [ -z "$f" ] && continue
  if [ -n "$bk" ]; then cp -p "$bk" "$TOOLS/$f"; else rm -f "$TOOLS/$f"; fi
done <<<"$FILE_ACTIONS"

if [ "$LOADED" = 1 ]; then launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true; fi
[ "$HAVE_PLIST" = 1 ] && rm -f "$PLIST"

if [ -n "$PURGE_LIST" ]; then
  while IFS= read -r p; do [ -n "$p" ] && rm -rf "$p"; done <<<"$PURGE_LIST"
fi
rm -f "$MANIFEST"

if [ -z "$ACT" ]; then say "Nothing to remove."; else say "Removed:"; printf '%s' "$ACT" | sed 's/^/  - /'; fi
[ -n "$SETTINGS_BACKUP" ] && say "  settings backup: $SETTINGS_BACKUP"
say ""
say "Running Claude Code sessions keep their old hooks until restarted."
[ "$PURGE" = 0 ] && say "Saved data kept (state/usage, snapshots, handoffs...). Re-run with --purge to delete it."
exit 0
