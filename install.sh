#!/usr/bin/env bash
# momo-auto-handoff installer (bash 3.2+, macOS / Linux). No sudo, no prompts, no network.
#
#   ./install.sh [--dry-run] [--no-launchd] [--wrap-statusline]
#
#   --dry-run          print the plan, change nothing
#   --no-launchd       skip the idle-save background job (macOS only anyway)
#   --wrap-statusline  if you already have a statusLine, wrap it so the usage file is written too
#                      (default: print the exact instructions and leave your statusLine alone)
#
# Env: CLAUDE_CONFIG_DIR (default ~/.claude), AUTO_HANDOFF_SKIP_LAUNCHCTL=1 (render plist, do not call launchctl)
set -euo pipefail

LABEL="com.momo.auto-handoff"
SCRIPTS="limit-guard.sh handoff-inject.py session-snapshot.py idle-handoff.py statusline-usage.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0; NO_LAUNCHD=0; WRAP=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-launchd) NO_LAUNCHD=1 ;;
    --wrap-statusline) WRAP=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }

# ---- requirements -----------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq; Debian/Ubuntu: apt install jq)"
jq -n '"a"|gsub("a";"b")' >/dev/null 2>&1 || die "jq 1.6 or newer is required"
command -v python3 >/dev/null 2>&1 || die "python3 (3.7+) is required"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null || die "python3 3.7 or newer is required"

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CFG="${CFG%/}"
case "$CFG" in /*) ;; *) die "CLAUDE_CONFIG_DIR must be an absolute path (got: $CFG)" ;; esac
case "$CFG" in *\"*|*\$*|*\`*|*\\*|*\'*) die "config dir path contains an unsupported character: $CFG" ;; esac
if [ "$CFG" = "$HOME/.claude" ]; then CFG_REF='$HOME/.claude'; else CFG_REF="$CFG"; fi

SETTINGS="$CFG/settings.json"
TOOLS="$CFG/tools"
MANIFEST="$CFG/state/momo-auto-handoff-install.json"
BACKUP_DIR="$CFG/state/backups/$(date +%Y-%m-%d)"
OS="$(uname -s)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CHANGES=""
note() { CHANGES="$CHANGES$*"$'\n'; }
PREFIX=""; [ "$DRY" = 1 ] && PREFIX="[dry-run] would: "

[ -f "$HERE/templates/settings-hooks.json" ] || die "run this from the repository (templates/ not found next to install.sh)"
for f in $SCRIPTS; do [ -f "$HERE/src/$f" ] || die "missing src/$f"; done
SKILL_REL="skills/recall/SKILL.md"; SKILL_SRC="$HERE/src/$SKILL_REL"; SKILL_DEST="$CFG/$SKILL_REL"
[ -f "$SKILL_SRC" ] || die "missing src/$SKILL_REL"

backup_file() { # src -> prints backup path
  local src=$1 base n=0 dest
  base=$(basename "$src")
  (umask 077; mkdir -p "$BACKUP_DIR")
  dest="$BACKUP_DIR/$base"
  while [ -e "$dest" ]; do n=$((n + 1)); dest="$BACKUP_DIR/$base.$n"; done
  cp -p "$src" "$dest"; chmod 600 "$dest"
  printf '%s' "$dest"
}

say "momo-auto-handoff installer  (config dir: $CFG)"
[ "$DRY" = 1 ] && say "DRY RUN: nothing will be changed."
say ""

# ---- 1. settings.json: hooks + statusLine ------------------------------------------------------
CUR='{}'
if [ -e "$SETTINGS" ]; then
  CUR=$(cat "$SETTINGS")
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$CUR" || die "$SETTINGS is not a valid JSON object; fix it first (nothing was changed)"
  jq -e '(.hooks // {}) | type == "object" and ([.[] | type] | all(. == "array"))' >/dev/null <<<"$CUR" \
    || die "$SETTINGS: \"hooks\" has an unexpected shape (every event must be an array); nothing was changed"
fi

TPL=$(jq --arg cfg "$CFG_REF" 'walk(if type == "string" then gsub("@CFG@"; $cfg) else . end)' "$HERE/templates/settings-hooks.json")

# hooks to add = template entries whose script (tools/<name>) is not already referenced in that event
JQ_ADDED='
  [ $t.hooks | to_entries[] | .key as $ev | .value[]
    | (.hooks[0].command | capture("(?<k>tools/[A-Za-z0-9_.-]+)").k) as $k
    | select(([ ($cur.hooks[$ev] // [])[] | .hooks[]? | (.command // "") | contains($k) ] | any) | not)
    | {event: $ev, key: $k, group: .} ]'
ADDED=$(jq -c --argjson t "$TPL" --argjson cur "$CUR" -n "$JQ_ADDED")

NEW=$(jq --argjson a "$ADDED" 'if ($a | length) > 0 then .hooks //= {} | reduce $a[] as $x (.; .hooks[$x.event] = ((.hooks[$x.event] // []) + [$x.group])) else . end' <<<"$CUR")

NHOOKS=$(jq 'length' <<<"$ADDED")
if [ "$NHOOKS" -gt 0 ]; then
  while IFS= read -r l; do note "hook added: $l"; done < <(jq -r '.[] | "\(.event)  ->  \(.key)"' <<<"$ADDED")
fi

# statusLine
SL_MODE="none"; SL_ORIG='null'; SL_INSTRUCTIONS=""
OURS_CMD="bash \"$CFG_REF/tools/statusline-usage.sh\""
HAS_SL=$(jq -r 'if .statusLine == null then "no" else "yes" end' <<<"$CUR")
SL_CMD=$(jq -r '.statusLine.command // ""' <<<"$CUR")
if [ "$HAS_SL" = "no" ]; then
  NEW=$(jq --arg c "$OURS_CMD" '.statusLine = {type: "command", command: $c}' <<<"$NEW")
  SL_MODE="set"
  note "statusLine set: statusline-usage.sh (you had none)"
elif [[ "$SL_CMD" == *tools/statusline-usage.sh* ]]; then
  :  # already ours or already wrapped
else
  WRAPPED="bash \"$CFG_REF/tools/statusline-usage.sh\" --wrap $(jq -rn --arg c "$SL_CMD" --arg q "'" '$q + ($c | gsub($q; $q + "\\" + $q + $q)) + $q')"
  CAN_WRAP=$(jq -r '(.statusLine.type == "command") and ((.statusLine.command // "") != "")' <<<"$CUR")
  if [ "$WRAP" = 1 ] && [ "$CAN_WRAP" = "true" ]; then
    SL_ORIG=$(jq -c '.statusLine' <<<"$CUR")
    NEW=$(jq --arg c "$WRAPPED" '.statusLine.command = $c' <<<"$NEW")
    SL_MODE="wrapped"
    note "statusLine wrapped (original saved in the install manifest and the settings backup)"
  else
    SL_INSTRUCTIONS="Your existing statusLine was left untouched. The guard needs the usage file, so do ONE of:
  A) re-run with --wrap-statusline (wraps your command; reversible with uninstall.sh), or
  B) set this as \"statusLine\" in $SETTINGS by hand:
       \"statusLine\": { \"type\": \"command\", \"command\": $(jq -n --arg c "$WRAPPED" '$c') }
  C) if your statusLine is your own script, add this line near the top (after you read stdin into \$INPUT):
       printf '%s' \"\$INPUT\" | \"$CFG_REF/tools/statusline-usage.sh\" --quiet &"
  fi
fi

SETTINGS_CHANGED=0
if [ "$(jq -cS . <<<"$CUR")" != "$(jq -cS . <<<"$NEW")" ]; then SETTINGS_CHANGED=1; fi

# ---- 2a. the /recall skill ---------------------------------------------------------------------
if [ ! -e "$SKILL_DEST" ]; then SKILL_STATE=new
elif cmp -s "$SKILL_SRC" "$SKILL_DEST"; then SKILL_STATE=same
else SKILL_STATE=replace; fi
case "$SKILL_STATE" in
  new) note "skill installed: $SKILL_REL (/recall)" ;;
  replace) note "skill updated: $SKILL_REL (previous copy backed up)" ;;
esac

# ---- 2. scripts --------------------------------------------------------------------------------
FILE_PLAN=""   # lines: name|state   state = new | same | replace
for f in $SCRIPTS; do
  d="$TOOLS/$f"
  if [ ! -e "$d" ]; then st=new
  elif cmp -s "$HERE/src/$f" "$d"; then st=same
  else st=replace; fi
  FILE_PLAN="$FILE_PLAN$f|$st"$'\n'
  case "$st" in
    new) note "script installed: tools/$f" ;;
    replace) note "script updated: tools/$f (previous copy backed up)" ;;
  esac
done

# ---- 3. launchd (macOS only) -------------------------------------------------------------------
LAUNCHD="skip"; PLIST_NEW=""; PLIST_STATE=""
if [ "$NO_LAUNCHD" = 1 ]; then
  LAUNCHD_MSG="idle-save job: skipped (--no-launchd)"
elif [ "$OS" != "Darwin" ]; then
  LAUNCHD_MSG="idle-save job: skipped (launchd is macOS only; hooks still work. See docs/troubleshooting.md for a cron line)"
else
  LAUNCHD="yes"
  PY_BIN=""
  if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null; then
    PY_BIN=/usr/bin/python3
  else
    PY_BIN=$(command -v python3)
  fi
  PLIST_NEW=$(python3 -I -c '
import html, sys
t = open(sys.argv[1], encoding="utf-8").read()
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    t = t.replace("@%s@" % k, html.escape(v, quote=False))
sys.stdout.write(t)
' "$HERE/templates/com.momo.auto-handoff.plist.in" "LABEL=$LABEL" "PYTHON=$PY_BIN" "SCRIPT=$TOOLS/idle-handoff.py" \
    "CONFIG_DIR=$CFG" "LOG=$CFG/state/idle-handoff.log")
  if [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$PLIST_NEW" ]; then PLIST_STATE=same; else PLIST_STATE=new; note "launchd job: $PLIST (every 20 min)"; fi
  LAUNCHD_MSG="idle-save job: $LABEL"
fi

# ---- plan / apply ------------------------------------------------------------------------------
if [ "$DRY" = 1 ]; then
  say "Plan:"
  if [ -z "$CHANGES" ]; then say "  nothing to change (already installed)"; else printf '%s' "$CHANGES" | sed 's/^/  + /'; fi
  [ -n "${LAUNCHD_MSG:-}" ] && say "  $LAUNCHD_MSG"
  [ -n "$SL_INSTRUCTIONS" ] && { say ""; say "$SL_INSTRUCTIONS"; }
  say ""; say "Dry run only. Nothing was changed."
  exit 0
fi

SETTINGS_BACKUP=""
if [ "$SETTINGS_CHANGED" = 1 ]; then
  if [ -e "$SETTINGS" ]; then SETTINGS_BACKUP=$(backup_file "$SETTINGS"); fi
  mkdir -p "$CFG"
  TMPF=$(mktemp "${TMPDIR:-/tmp}/momo-settings.XXXXXX")
  jq . <<<"$NEW" > "$TMPF"
  jq -e . "$TMPF" >/dev/null || { rm -f "$TMPF"; die "internal error: merged settings are not valid JSON; nothing written"; }
  cat "$TMPF" > "$SETTINGS"   # cat keeps symlinks and file mode intact
  rm -f "$TMPF"
fi

mkdir -p "$TOOLS"
FILES_JSON='{}'
while IFS='|' read -r f st; do
  [ -z "$f" ] && continue
  d="$TOOLS/$f"; bk=""
  if [ "$st" = replace ]; then bk=$(backup_file "$d"); fi
  if [ "$st" != same ]; then cp "$HERE/src/$f" "$d"; fi
  chmod 755 "$d"
  FILES_JSON=$(jq -c --arg f "tools/$f" --arg b "$bk" '.[$f] = {backup: (if $b == "" then null else $b end)}' <<<"$FILES_JSON")
done <<<"$FILE_PLAN"

if [ "$SKILL_STATE" != same ]; then
  mkdir -p "$(dirname "$SKILL_DEST")"
  skbk=""; [ "$SKILL_STATE" = replace ] && skbk=$(backup_file "$SKILL_DEST")
  cp "$SKILL_SRC" "$SKILL_DEST"
  FILES_JSON=$(jq -c --arg f "$SKILL_REL" --arg b "$skbk" '.[$f] = {backup: (if $b == "" then null else $b end)}' <<<"$FILES_JSON")
fi

if [ "$LAUNCHD" = "yes" ]; then
  mkdir -p "$(dirname "$PLIST")" "$CFG/state"
  if [ "$PLIST_STATE" = new ]; then
    TMPP=$(mktemp "${TMPDIR:-/tmp}/momo-plist.XXXXXX")
    printf '%s\n' "$PLIST_NEW" > "$TMPP"
    if command -v plutil >/dev/null 2>&1; then plutil -lint "$TMPP" >/dev/null || { rm -f "$TMPP"; die "rendered launchd plist failed plutil -lint; nothing installed for launchd"; }; fi
    [ -e "$PLIST" ] && backup_file "$PLIST" >/dev/null
    cat "$TMPP" > "$PLIST"; chmod 644 "$PLIST"; rm -f "$TMPP"
  fi
  if [ -n "${AUTO_HANDOFF_SKIP_LAUNCHCTL:-}" ]; then
    say "launchctl skipped (AUTO_HANDOFF_SKIP_LAUNCHCTL set)"
  else
    DOM="gui/$(id -u)"
    LOADED=0; launchctl print "$DOM/$LABEL" >/dev/null 2>&1 && LOADED=1
    if [ "$LOADED" = 1 ] && [ "$PLIST_STATE" = same ]; then
      :
    else
      [ "$LOADED" = 1 ] && launchctl bootout "$DOM/$LABEL" >/dev/null 2>&1 || true
      if launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null; then note "launchd job loaded ($DOM/$LABEL)"
      else say "warning: launchctl bootstrap failed. Run manually: launchctl bootstrap $DOM \"$PLIST\""; fi
    fi
  fi
fi

# manifest (merge with an older one so a second run never forgets what the first run did)
mkdir -p "$CFG/state"
OLD='{}'; [ -f "$MANIFEST" ] && OLD=$(cat "$MANIFEST")
jq -n --argjson old "$OLD" --argjson added "$ADDED" --argjson files "$FILES_JSON" \
      --arg slmode "$SL_MODE" --argjson slorig "$SL_ORIG" --arg cfg "$CFG" --arg plist "$PLIST" --arg lc "$LAUNCHD" '
  {
    cfg: $cfg,
    hooks: ((($old.hooks // []) + ($added | map({event, key}))) | unique),
    files: ($files + ($old.files // {})),
    statusline: (if ($old.statusline.mode // "none") != "none" then $old.statusline
                 else {mode: $slmode, original: $slorig} end),
    launchd: (if $lc == "yes" then $plist else ($old.launchd // null) end)
  }' > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
chmod 600 "$MANIFEST"

# ---- report ------------------------------------------------------------------------------------
if [ -z "$CHANGES" ]; then
  say "Nothing to change: already installed and up to date."
else
  say "Changed:"; printf '%s' "$CHANGES" | sed 's/^/  + /'
  [ -n "$SETTINGS_BACKUP" ] && say "  settings backup: $SETTINGS_BACKUP"
fi
[ -n "${LAUNCHD_MSG:-}" ] && say "  $LAUNCHD_MSG"
[ -n "$SL_INSTRUCTIONS" ] && { say ""; say "$SL_INSTRUCTIONS"; }
say ""
say "Hooks load in NEW Claude Code sessions (restart running ones)."
say "Uninstall: $HERE/uninstall.sh   (add --purge to also delete saved usage/snapshot/handoff data)"
