#!/usr/bin/env bash
# momo-auto-handoff test suite. Everything runs in a temporary HOME; your real ~/.claude is never touched.
# Usage: tests/run.sh      (exit code 0 = all passed)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/momo-test.XXXXXX")"
REAL_HOME="$HOME"
trap 'rm -rf "$T"' EXIT
unset CLAUDE_CONFIG_DIR
export AUTO_HANDOFF_SKIP_LAUNCHCTL=1
export PYTHONDONTWRITEBYTECODE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
section() { echo; echo "== $*"; }

newhome() { # -> sets H and CF (fake home + fake config dir)
  H="$T/home$1"; CF="$H/.claude"; rm -rf "$H"; mkdir -p "$CF"; export HOME="$H"
}
tree_sum() { (cd "$1" && { find . | sort; find . -type f -exec shasum {} \; | sort; }); }
norm() { jq -S . "$1"; }
install_() { HOME="$H" "$REPO/install.sh" "$@"; }
uninstall_() { HOME="$H" "$REPO/uninstall.sh" "$@"; }
nbackups() { find "$CF/state/backups" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ------------------------------------------------------------------------------------------------
section "static checks"
for f in "$REPO"/install.sh "$REPO"/uninstall.sh "$REPO"/tests/run.sh "$REPO"/src/*.sh; do
  check "bash -n $(basename "$f")" bash -n "$f"
done
for f in "$REPO"/src/*.py; do
  check "python syntax $(basename "$f")" python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f"
done
check "templates/settings-hooks.json is valid JSON" jq -e . "$REPO/templates/settings-hooks.json"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck (errors+warnings)" shellcheck -S warning "$REPO"/install.sh "$REPO"/uninstall.sh "$REPO"/src/*.sh "$REPO"/tests/run.sh
else
  echo "  SKIP  shellcheck not installed"
fi

# ------------------------------------------------------------------------------------------------
section "install: (a) empty settings, dry-run first"
newhome a
before=$(tree_sum "$H")
out=$(install_ --dry-run 2>&1); rc=$?
eq "dry-run exits 0" "$rc" 0
eq "dry-run changes nothing" "$(tree_sum "$H")" "$before"
check "dry-run mentions a plan" grep -q "Dry run only" <<<"$out"
check "dry-run lists hooks" grep -q "UserPromptSubmit" <<<"$out"

section "install: (a) empty settings, real run"
out=$(install_ 2>&1); rc=$?
eq "install exits 0" "$rc" 0
check "settings.json valid" jq -e . "$CF/settings.json"
eq "6 hook entries added" "$(jq '[.hooks[] | length] | add' "$CF/settings.json")" 6
for ev in UserPromptSubmit PostToolUse Stop SessionEnd StopFailure SessionStart; do
  eq "event $ev present once" "$(jq --arg e "$ev" '.hooks[$e] | length' "$CF/settings.json")" 1
done
eq "statusLine set (none existed)" "$(jq -r '.statusLine.command' "$CF/settings.json")" 'bash "$HOME/.claude/tools/statusline-usage.sh"'
for f in limit-guard.sh handoff-inject.py session-snapshot.py idle-handoff.py statusline-usage.sh; do
  check "tools/$f installed and executable" test -x "$CF/tools/$f"
  check "tools/$f identical to src" cmp -s "$REPO/src/$f" "$CF/tools/$f"
done
P="$H/Library/LaunchAgents/com.momo.auto-handoff.plist"
check "plist rendered" test -f "$P"
if command -v plutil >/dev/null 2>&1; then check "plutil -lint plist" plutil -lint "$P"; else echo "  SKIP  plutil missing"; fi
check "plist points to temp HOME script" grep -q "$CF/tools/idle-handoff.py" "$P"
check "plist has no unrendered placeholder" bash -c '! grep -q "@[A-Z_]*@" "$1"' _ "$P"
check "manifest written" jq -e '.hooks | length == 6' "$CF/state/momo-auto-handoff-install.json"
check "install output prints uninstall line" grep -q "uninstall.sh" <<<"$out"

section "install: idempotence"
cp "$CF/settings.json" "$T/settings.after1"
nb=$(nbackups)
tree1=$(tree_sum "$H")
out=$(install_ 2>&1); rc=$?
eq "second run exits 0" "$rc" 0
check "second run: settings.json byte-identical" cmp -s "$T/settings.after1" "$CF/settings.json"
eq "second run: no new backups" "$(nbackups)" "$nb"
eq "second run: whole tree identical" "$(tree_sum "$H")" "$tree1"
check "second run says nothing to change" grep -q "Nothing to change" <<<"$out"

section "uninstall: (a) restores empty settings"
out=$(uninstall_ --dry-run 2>&1)
eq "uninstall --dry-run changes nothing" "$(tree_sum "$H")" "$tree1"
mkdir -p "$CF/state/usage" "$CF/state/handoffs"; echo '{}' > "$CF/state/usage/keep.json"; echo hi > "$CF/state/handoffs/x.md"
out=$(uninstall_ 2>&1); rc=$?
eq "uninstall exits 0" "$rc" 0
eq "settings equal to original {}" "$(norm "$CF/settings.json")" "$(echo '{}' | jq -S .)"
check "scripts removed" bash -c '! ls "$1"/tools/*.sh "$1"/tools/*.py >/dev/null 2>&1' _ "$CF"
check "plist removed" test ! -e "$P"
check "user data kept without --purge" test -f "$CF/state/usage/keep.json"
check "manifest removed" test ! -e "$CF/state/momo-auto-handoff-install.json"
install_ >/dev/null 2>&1
out=$(uninstall_ --purge 2>&1)
check "--purge removes usage + handoffs" bash -c '[ ! -e "$1/state/usage" ] && [ ! -e "$1/state/handoffs" ]' _ "$CF"
check "backups kept after --purge" test -d "$CF/state/backups"
out=$(uninstall_ 2>&1)
check "second uninstall = nothing to remove" grep -q "Nothing to remove" <<<"$out"

# ------------------------------------------------------------------------------------------------
section "install: (b) existing hooks + existing statusLine"
newhome b
cat > "$T/orig-b.json" <<'EOF'
{
  "model": "opus",
  "env": { "X": "1" },
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo pre" } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "echo ups" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "python3 \"$HOME/.claude/tools/session-snapshot.py\" || true" } ] } ]
  },
  "statusLine": { "type": "command", "command": "echo \"it's my line\"" }
}
EOF
cp "$T/orig-b.json" "$CF/settings.json"
before=$(tree_sum "$H")
install_ --dry-run >/dev/null 2>&1
eq "dry-run changes nothing (b)" "$(tree_sum "$H")" "$before"
out=$(install_ 2>&1); rc=$?
eq "install exits 0 (b)" "$rc" 0
S="$CF/settings.json"
eq "PreToolUse untouched" "$(jq -cS '.hooks.PreToolUse' "$S")" "$(jq -cS '.hooks.PreToolUse' "$T/orig-b.json")"
eq "UserPromptSubmit: original first, ours appended (len 2)" "$(jq '.hooks.UserPromptSubmit | length' "$S")" 2
eq "UserPromptSubmit[0] is the user's hook" "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$S")" "echo ups"
eq "Stop: existing snapshot hook not duplicated" "$(jq '.hooks.Stop | length' "$S")" 1
eq "model + env preserved" "$(jq -c '[.model,.env]' "$S")" '["opus",{"X":"1"}]'
eq "existing statusLine untouched" "$(jq -cS '.statusLine' "$S")" "$(jq -cS '.statusLine' "$T/orig-b.json")"
check "instructions printed for the statusLine" grep -q "statusline-usage.sh" <<<"$out"
check "settings backup exists with original content" bash -c 'cmp -s "$1" "$(ls "$2"/state/backups/*/settings.json | head -1)"' _ "$T/orig-b.json" "$CF"
cp "$S" "$T/b.after1"; nb=$(nbackups); t1=$(tree_sum "$H")
install_ >/dev/null 2>&1
check "idempotent: settings byte-identical" cmp -s "$T/b.after1" "$S"
eq "idempotent: tree identical" "$(tree_sum "$H")" "$t1"
eq "idempotent: no new backups" "$(nbackups)" "$nb"
uninstall_ >/dev/null 2>&1
eq "uninstall restores equivalent settings (b)" "$(norm "$S")" "$(norm "$T/orig-b.json")"

section "install: --wrap-statusline"
install_ --wrap-statusline >/dev/null 2>&1
cmd=$(jq -r '.statusLine.command' "$S")
check "statusLine wraps our script" grep -q "statusline-usage.sh\" --wrap" <<<"$cmd"
line=$(printf '%s' '{"session_id":"wrap1","rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":2000000000},"seven_day":{"used_percentage":10,"resets_at":2000500000}}}' | HOME="$H" bash -c "$cmd")
eq "wrapped command still prints the user's own line" "$line" "it's my line"
check "usage file written by wrapper" test -f "$CF/state/usage/wrap1.json"
uninstall_ >/dev/null 2>&1
eq "uninstall restores original statusLine" "$(jq -cS '.statusLine' "$S")" "$(jq -cS '.statusLine' "$T/orig-b.json")"
eq "settings equal to original after wrap+uninstall" "$(norm "$S")" "$(norm "$T/orig-b.json")"

section "install: same-name tool file is backed up and restored"
newhome c
mkdir -p "$CF/tools"; echo "my own limit guard" > "$CF/tools/limit-guard.sh"
install_ >/dev/null 2>&1
check "ours installed over it" cmp -s "$REPO/src/limit-guard.sh" "$CF/tools/limit-guard.sh"
check "original kept in backups" grep -rq "my own limit guard" "$CF/state/backups"
uninstall_ >/dev/null 2>&1
eq "uninstall restores the user's file" "$(cat "$CF/tools/limit-guard.sh")" "my own limit guard"

section "install: custom CLAUDE_CONFIG_DIR (path with & for plist escaping)"
newhome d
CUSTOM="$H/a&b/cfg"; mkdir -p "$CUSTOM"
CLAUDE_CONFIG_DIR="$CUSTOM" HOME="$H" "$REPO/install.sh" >/dev/null 2>&1; rc=$?
eq "install with custom config dir exits 0" "$rc" 0
check "hook command uses the absolute custom path" grep -q "$CUSTOM/tools/limit-guard.sh" "$CUSTOM/settings.json"
check "nothing written to default ~/.claude" test ! -e "$H/.claude/settings.json"
P="$H/Library/LaunchAgents/com.momo.auto-handoff.plist"
if command -v plutil >/dev/null 2>&1; then check "plutil -lint plist with & in path" plutil -lint "$P"; fi
check "plist carries CLAUDE_CONFIG_DIR" grep -q "a&amp;b/cfg" "$P"
CLAUDE_CONFIG_DIR="$CUSTOM" HOME="$H" "$REPO/uninstall.sh" >/dev/null 2>&1

section "install: refuses broken settings.json, changes nothing"
newhome e
echo '{ "hooks": ' > "$CF/settings.json"
before=$(tree_sum "$H")
out=$(install_ 2>&1); rc=$?
eq "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes)" yes
eq "tree unchanged" "$(tree_sum "$H")" "$before"

# ------------------------------------------------------------------------------------------------
section "limit-guard"
newhome g
G="$REPO/src/limit-guard.sh"
now=$(date +%s)
usage() { # sid p5 reset5 p7 reset7 ts
  mkdir -p "$CF/state/usage"
  printf '{"five_hour_pct":%s,"five_hour_resets_at":%s,"seven_day_pct":%s,"seven_day_resets_at":%s,"context_pct":10,"ts":%s}' \
    "$2" "$3" "$4" "$5" "$6" > "$CF/state/usage/$1.json"
}
run_g() { printf '{"session_id":"%s","hook_event_name":"%s"}' "$1" "${2:-UserPromptSubmit}" | HOME="$H" bash "$G"; }
usage s50 50 $((now + 3600)) 20 $((now + 86400)) "$now"
eq "50%: silent" "$(run_g s50)" ""
usage s90 90.4 $((now + 3600)) 20 $((now + 86400)) "$now"
out=$(run_g s90 PostToolUse)
check "90% 5h: warns" grep -q "5-hour usage limit near (90%" <<<"$out"
eq "output is valid hook JSON with the right event" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" PostToolUse
check "message mentions docs/handoff.md" grep -q "docs/handoff.md" <<<"$out"
eq "second call, same window: silent (once only)" "$(run_g s90)" ""
usage s7 10 $((now + 3600)) 95 $((now + 86400)) "$now"
check "95% 7d: warns" grep -q "7-day usage limit near (95%" <<<"$(run_g s7)"
usage sold 99 $((now + 3600)) 99 $((now + 86400)) $((now - 1000))
eq "stale usage file (1000 s old): silent" "$(run_g sold)" ""
eq "no usage file: silent" "$(run_g nosuchsession)" ""
eq "garbage stdin: silent, exit 0" "$(echo 'not json' | HOME="$H" bash "$G"; echo "rc=$?")" "rc=0"
usage s85 85 $((now + 3600)) 0 $((now + 86400)) "$now"
check "exactly 85% 5h: warns" grep -q "5-hour" <<<"$(run_g s85)"
usage s84 84 $((now + 3600)) 89 $((now + 86400)) "$now"
eq "84% / 89%: silent" "$(run_g s84)" ""
usage sov 60 $((now + 3600)) 0 $((now + 86400)) "$now"
check "AUTO_HANDOFF_FIVE=50 override warns at 60%" grep -q "5-hour" <<<"$(printf '{"session_id":"sov"}' | AUTO_HANDOFF_FIVE=50 HOME="$H" bash "$G")"
usage sevil 99 null 0 null "$now"
check "null resets_at: still warns (unknown reset time)" grep -q "resets at unknown" <<<"$(run_g sevil)"

# ------------------------------------------------------------------------------------------------
section "statusline-usage.sh"
newhome s
SU="$REPO/src/statusline-usage.sh"
J='{"session_id":"abc-1","workspace":{"current_dir":"/x"},"context_window":{"used_percentage":33},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":2000000000},"seven_day":{"used_percentage":10,"resets_at":2000500000}}}'
out=$(printf '%s' "$J" | HOME="$H" bash "$SU")
eq "default mode prints a minimal line" "$out" "5h 42% | 7d 10%"
eq "usage file: five_hour_pct" "$(jq -r .five_hour_pct "$CF/state/usage/abc-1.json")" 42.5
eq "usage file: seven_day_resets_at" "$(jq -r .seven_day_resets_at "$CF/state/usage/abc-1.json")" 2000500000
eq "usage file: context_pct" "$(jq -r .context_pct "$CF/state/usage/abc-1.json")" 33
eq "usage file mode 600" "$(stat -f %Lp "$CF/state/usage/abc-1.json" 2>/dev/null || stat -c %a "$CF/state/usage/abc-1.json")" 600
eq "--quiet prints nothing" "$(printf '%s' "$J" | HOME="$H" bash "$SU" --quiet)" ""
eq "rate_limits null (API-key plan): no output" "$(printf '%s' '{"session_id":"api1","rate_limits":null}' | HOME="$H" bash "$SU")" ""
check "rate_limits null: no usage file" test ! -e "$CF/state/usage/api1.json"
printf '%s' '{"session_id":"../evil","rate_limits":{"five_hour":{"used_percentage":1}}}' | HOME="$H" bash "$SU" >/dev/null
check "unsafe session_id rejected" bash -c '! find "$1" -name "*evil*" | grep -q .' _ "$H"
eq "garbage stdin: exit 0, silent" "$(echo 'zzz' | HOME="$H" bash "$SU"; echo "rc=$?")" "rc=0"
eq "--wrap passes stdin through" "$(printf 'hello' | HOME="$H" bash "$SU" --wrap 'cat')" "hello"

# ------------------------------------------------------------------------------------------------
section "session-snapshot / idle-handoff / handoff-inject (fabricated projects dir)"
newhome i
PROJ="$H/work/demo"; mkdir -p "$PROJ/docs"           # fake project dir (must never be written to)
SLUG=$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9-]/-/g')
PD="$CF/projects/$SLUG"; mkdir -p "$PD"
SECRET="s""k-ABCDEFGH12345678"
mk_jsonl() { # file
  cat > "$1" <<EOF
{"type":"user","cwd":"$PROJ","entrypoint":"cli","message":{"role":"user","content":"Please fix the login bug in auth.py"}}
{"type":"assistant","entrypoint":"cli","message":{"role":"assistant","content":[{"type":"text","text":"Looking at it now."},{"type":"tool_use","name":"Edit","input":{"file_path":"$PROJ/auth.py"}}]}}
{"type":"user","entrypoint":"cli","message":{"role":"user","content":"my key is $SECRET and password=hunter2hunter2 ok?"}}
{"type":"assistant","entrypoint":"cli","message":{"role":"assistant","content":[{"type":"text","text":"Done, tests pass. Remaining: update README."}]}}
EOF
}
age() { python3 -c "import os,sys,time; t=time.time()-float(sys.argv[2])*3600; os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
SID_OLD=11111111-aaaa; SID_FRESH=22222222-bbbb; SID_ANCIENT=33333333-cccc; SID_SDK=44444444-dddd
mk_jsonl "$PD/$SID_OLD.jsonl";     age "$PD/$SID_OLD.jsonl" 5
mk_jsonl "$PD/$SID_FRESH.jsonl";   age "$PD/$SID_FRESH.jsonl" 0.1
mk_jsonl "$PD/$SID_ANCIENT.jsonl"; age "$PD/$SID_ANCIENT.jsonl" 100
sed 's/"entrypoint":"cli"/"entrypoint":"sdk-cli"/' "$PD/$SID_OLD.jsonl" > "$PD/$SID_SDK.jsonl"; age "$PD/$SID_SDK.jsonl" 5
mkdir -p "$T/shim"; printf '#!/bin/sh\ntouch "%s/git-was-called"\nexit 1\n' "$T" > "$T/shim/git"; chmod +x "$T/shim/git"
projsum=$(tree_sum "$PROJ")
IH="$REPO/src/idle-handoff.py"

out=$(PATH="$T/shim:$PATH" HOME="$H" python3 "$IH" --dry-run 2>&1)
check "dry-run picks the 5h-idle session" grep -q "pick $SLUG/$SID_OLD" <<<"$out"
check "dry-run skips fresh session" bash -c '! grep -q "$2" <<<"$1"' _ "$out" "$SID_FRESH"
check "dry-run skips >48h session" bash -c '! grep -q "$2" <<<"$1"' _ "$out" "$SID_ANCIENT"
check "dry-run writes nothing" test ! -e "$CF/state/handoffs"

out=$(PATH="$T/shim:$PATH" HOME="$H" python3 "$IH" 2>&1)
HF="$CF/state/handoffs/$SLUG.md"
check "handoff file written" test -f "$HF"
check "header block present" grep -q "^## AUTO-IDLE SAVE .* session $SID_OLD" "$HF"
check "contains user message" grep -q "fix the login bug" "$HF"
check "contains edited file" grep -q "auth.py" "$HF"
check "secret redacted (key)" bash -c '! grep -q "ABCDEFGH12345678" "$1"' _ "$HF"
check "secret redacted (password=)" bash -c '! grep -q "hunter2hunter2" "$1"' _ "$HF"
check "[REDACTED] marker present" grep -q "REDACTED" "$HF"
check "sdk/non-cli session not saved" bash -c '! grep -q "$2" "$1"' _ "$HF" "$SID_SDK"
check "fresh session not saved" bash -c '! grep -q "$2" "$1"' _ "$HF" "$SID_FRESH"
check "ancient session not saved" bash -c '! grep -q "$2" "$1"' _ "$HF" "$SID_ANCIENT"
eq "handoff file mode 600" "$(stat -f %Lp "$HF" 2>/dev/null || stat -c %a "$HF")" 600
eq "project directory untouched" "$(tree_sum "$PROJ")" "$projsum"
check "git was never executed by idle-handoff" test ! -e "$T/git-was-called"
check "idle marker created" bash -c 'ls "$1"/state/idle-done/'"$SID_OLD"'-* >/dev/null 2>&1' _ "$CF"
cp "$HF" "$T/hf1"
PATH="$T/shim:$PATH" HOME="$H" python3 "$IH" >/dev/null 2>&1
check "second run: handoff unchanged (marker prevents repeat)" cmp -s "$T/hf1" "$HF"
eq "exactly one block for the session" "$(grep -c '^## AUTO-IDLE SAVE' "$HF")" 1

# prune: old usage file removed, fresh kept
mkdir -p "$CF/state/usage"; echo '{}' > "$CF/state/usage/old.json"; echo '{}' > "$CF/state/usage/new.json"; age "$CF/state/usage/old.json" 400
mk_jsonl "$PD/55555555-eeee.jsonl"; age "$PD/55555555-eeee.jsonl" 6
HOME="$H" python3 "$IH" >/dev/null 2>&1
check "prune: >14d usage file removed" test ! -e "$CF/state/usage/old.json"
check "prune: recent usage file kept" test -e "$CF/state/usage/new.json"
eq "two blocks now (newest first, one per session)" "$(grep -c '^## AUTO-IDLE SAVE' "$HF")" 2

# env override: min idle hours
mk_jsonl "$PD/66666666-ffff.jsonl"; age "$PD/66666666-ffff.jsonl" 0.5
HOME="$H" AUTO_HANDOFF_MIN_IDLE_HOURS=0.25 python3 "$IH" >/dev/null 2>&1
check "AUTO_HANDOFF_MIN_IDLE_HOURS override picks 30-min-idle session" grep -q "66666666-ffff" "$HF"

# handoff-inject
HI="$REPO/src/handoff-inject.py"
hi() { printf '{"session_id":"x","cwd":"%s","source":"%s","hook_event_name":"SessionStart"}' "$PROJ" "$1" | HOME="$H" python3 "$HI"; }
out=$(hi startup)
check "inject: points to handoff file" grep -q "$HF" <<<"$out"
eq "inject: valid hook JSON" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" SessionStart
eq "inject: silent on source=compact" "$(hi compact)" ""
echo "# newer, human written" > "$PROJ/docs/handoff.md"
eq "inject: silent when docs/handoff.md is newer" "$(hi startup)" ""
eq "inject: no project cwd -> silent" "$(echo '{}' | HOME="$H" python3 "$HI")" ""

# session-snapshot as a StopFailure hook
SS="$REPO/src/session-snapshot.py"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"StopFailure","error":"rate_limit"}' \
  "$SID_OLD" "$PD/$SID_OLD.jsonl" "$H" | HOME="$H" python3 "$SS"
SN="$CF/state/snapshots/$SLUG/$SID_OLD.md"
check "snapshot written" test -f "$SN"
check "latest.md written" test -f "$CF/state/snapshots/$SLUG/latest.md"
check "snapshot lists user message" grep -q "fix the login bug" "$SN"
check "snapshot redacts secrets" bash -c '! grep -q "ABCDEFGH12345678\|hunter2hunter2" "$1"' _ "$SN"
check "snapshot has resume line" grep -q "claude --resume $SID_OLD" "$SN"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop"}' \
  "$SID_SDK" "$PD/$SID_SDK.jsonl" "$H" | HOME="$H" python3 "$SS"
check "non-cli session: no snapshot" test ! -e "$CF/state/snapshots/$SLUG/$SID_SDK.md"
eq "snapshot script exits 0 on garbage" "$(echo garbage | HOME="$H" python3 "$SS"; echo "rc=$?")" "rc=0"

# ------------------------------------------------------------------------------------------------
section "recall skill"
newhome r
install_ >/dev/null 2>&1
check "skills/recall/SKILL.md installed" cmp -s "$REPO/src/skills/recall/SKILL.md" "$CF/skills/recall/SKILL.md"
check "skill has the frontmatter name: recall" grep -q '^name: recall$' "$CF/skills/recall/SKILL.md"
check "manifest records the skill" jq -e '.files["skills/recall/SKILL.md"]' "$CF/state/momo-auto-handoff-install.json"
tr1=$(tree_sum "$H"); install_ >/dev/null 2>&1
eq "second install: tree identical (skill idempotent)" "$(tree_sum "$H")" "$tr1"
uninstall_ >/dev/null 2>&1
check "uninstall removes the skill" test ! -e "$CF/skills/recall/SKILL.md"
check "uninstall removes the empty skills dir" test ! -e "$CF/skills"
newhome s
mkdir -p "$CF/skills/recall"; echo "my own recall skill" > "$CF/skills/recall/SKILL.md"
install_ >/dev/null 2>&1
check "ours installed over the user's recall skill" cmp -s "$REPO/src/skills/recall/SKILL.md" "$CF/skills/recall/SKILL.md"
check "the user's recall skill kept in backups" grep -rq "my own recall skill" "$CF/state/backups"
uninstall_ >/dev/null 2>&1
eq "uninstall restores the user's recall skill" "$(cat "$CF/skills/recall/SKILL.md")" "my own recall skill"
newhome t
mkdir -p "$CF/skills/recall"; install_ >/dev/null 2>&1; echo "edited by the user" > "$CF/skills/recall/SKILL.md"
out=$(uninstall_ 2>&1)
eq "a user-edited skill is left in place" "$(cat "$CF/skills/recall/SKILL.md")" "edited by the user"
check "no owner-specific words in the shipped skill" bash -c '! grep -qiE "owner|thai|nabhak|yhaii" "$1"' _ "$REPO/src/skills/recall/SKILL.md"

section "real ~/.claude untouched"
eq "no state dir created in real HOME by tests" "$([ -e "$REAL_HOME/.claude/state/momo-auto-handoff-install.json" ] && echo changed || echo clean)" clean

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
