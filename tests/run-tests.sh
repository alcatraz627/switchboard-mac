#!/usr/bin/env bash
# Switchboard's test suite: bash + python3 + swiftc only, no framework.
# Nothing here clicks a switch on the real machine except the timer probe,
# which is opt-in (SWITCHBOARD_PROBE_TIMERS=1) because it flips Keep Awake.
#
#   tests/run-tests.sh          exit 0 when every check passes
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[2mskip %s\033[0m\n' "$*"; }
section() { printf '\n\033[2m── %s ──\033[0m\n' "$*"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n ($*)"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

WORK="$(mktemp -d)"
export SWITCHBOARD_STATE="$WORK/state"

section "syntax"
for f in scripts/*.sh tests/*.sh tests/fixtures/*.sh; do check "$f parses" bash -n "$f"; done
for f in Resources/lib/*.py; do check "$f compiles" python3 -m py_compile "$f"; done

section "swift"
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find Sources -name '*.swift' | sort)
BIN="$WORK/Switchboard"
if /usr/bin/swiftc -O "${SRCS[@]}" -o "$BIN" > "$WORK/compile.log" 2>&1; then
  ok "every file in Sources/ compiles as one module"
  export SWITCHBOARD_LIB="$ROOT/Resources/lib"
  out="$("$BIN" --dump 2>&1)"
  if [[ "$out" == "SWITCHBOARD DUMP"* ]]; then ok "headless --dump prints the Machine tab"; else bad "--dump output: ${out:0:120}"; fi
  [[ "$out" == *"SESSION"* && "$out" == *"Keep Awake"* ]] && ok "Session group always present" || bad "Session group missing"
  [[ "$out" == *"lib=$ROOT/Resources/lib"* ]] && ok "SWITCHBOARD_LIB points the helpers at the source tree" || bad "lib override ignored"
  check "headless snapshot renders" "$BIN" --snapshot "$WORK/home.png" --tab home
  if [[ "${SWITCHBOARD_PROBE_TIMERS:-}" == 1 ]]; then
    check "timed flips on Keep Awake (real power assertion)" "$BIN" --probe-timers
  else
    skip "timer probe (set SWITCHBOARD_PROBE_TIMERS=1; it flips Keep Awake and restores it)"
  fi
else
  bad "Sources/ failed to compile"; rg "error:" "$WORK/compile.log" | head -5
fi

section "machine state (Switchboard.swift)"
check "guards, approvals, settings, warden, shell caps" bash tests/fixtures/switchboard-probe.sh

section "agent policy (optional: needs ~/.claude/scripts/pol/pol.sh)"
if [[ -f "$HOME/.claude/scripts/pol/pol.sh" ]]; then
  check "pol.sh store (resolution, scopes, snoozes, owner-only writes)" bash "$HOME/.claude/scripts/pol/pol.test.sh"
  check "policy hooks (every key and route, old stores still win)" bash "$HOME/.claude/scripts/hooks/guard-policy.test.sh"
  check "panel store probe (every write the panel makes)" bash tests/fixtures/policy-probe.sh
else
  skip "policy store not installed"
fi

section "home (wiz.py, offline: never reaches a bulb)"
check "scene table is served" python3 Resources/lib/wiz.py scenes
eq "out-of-range brightness refused" 2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 dimming=500)"
eq "unknown key refused"             2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 color=red)"
eq "bad state refused"               2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 state=maybe)"
eq "no answer is an error, not a hang" 1 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 state=on)"
eq "a malformed colour is refused"   2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 rgb=zz0000)"
eq "a short colour is refused"       2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 rgb=fff)"
eq "a well-formed colour gets to the bulb" 1 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 rgb=ff8800)"
eq "scene speed out of range is refused"   2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 speed=500)"
echo '{"aa0000000001": "127.0.0.1"}' > "$SWITCHBOARD_STATE/wiz-known.json"
kept="$(python3 Resources/lib/wiz.py discover --timeout 1)"
[[ "$kept" == *'"mac": "aa0000000001"'*'"reachable": false'* ]] \
  && ok "a known bulb that misses a scan stays listed as not answering" \
  || bad "known bulb dropped from the scan: ${kept:0:160}"
check "the Home tab renders with colour strips open" "$BIN" --snapshot "$WORK/home-expanded.png" --tab home --expand

section "machine helpers (jobs.py, wol.py)"
check "jobs.py list emits a JSON array" python3 -c "import json,subprocess;assert isinstance(json.loads(subprocess.run(['python3','Resources/lib/jobs.py','list'],capture_output=True,text=True).stdout),list)"
eq "jobs.py run of an unknown label fails"  1 "$(rc python3 Resources/lib/jobs.py run com.example.no-such-job)"
eq "jobs.py start of an unknown label fails" 1 "$(rc python3 Resources/lib/jobs.py start com.example.no-such-job)"
eq "jobs.py stop of an unknown label fails"  1 "$(rc python3 Resources/lib/jobs.py stop com.example.no-such-job)"
check "jobs.py gives every job a distinct name" python3 -c "import json,subprocess;n=[j['name'] for j in json.loads(subprocess.run(['python3','Resources/lib/jobs.py','list'],capture_output=True,text=True).stdout)];assert len(n)==len(set(n)),n"
check "devservers.py list emits servers" python3 -c "import json,subprocess;d=json.loads(subprocess.run(['python3','Resources/lib/devservers.py','list'],capture_output=True,text=True,timeout=60).stdout);assert isinstance(d['servers'],list)"
eq "devservers.py start of a name pm2 lacks fails" 1 "$(rc python3 Resources/lib/devservers.py start no-such-server-xyz)"
eq "wol.py refuses a malformed MAC"         2 "$(rc python3 Resources/lib/wol.py wake not-a-mac)"
eq "wol.py sends to a well-formed MAC"      0 "$(rc python3 Resources/lib/wol.py wake 02:00:00:00:00:01)"
python3 Resources/lib/wol.py add "Test box" 02:00:00:00:00:02 >/dev/null
eq "a saved device lands in the state folder" "Test box" \
   "$(python3 -c "import json;print(json.load(open('$SWITCHBOARD_STATE/wol-targets.json'))[0]['name'])")"

section "state folder adoption (state.py)"
FAKE="$WORK/fakehome"
mkdir -p "$FAKE/.claude/widgets"
echo '[{"name":"Old","mac":"02:00:00:00:00:03","broadcast":"255.255.255.255"}]' > "$FAKE/.claude/widgets/.wol-targets.json"
got="$(env -u SWITCHBOARD_STATE HOME="$FAKE" python3 Resources/lib/wol.py list)"
[[ "$got" == *'"Old"'* ]] && ok "a pre-extraction device list is adopted" || bad "legacy list not adopted: $got"
[[ -f "$FAKE/Library/Application Support/Switchboard/wol-targets.json" ]] && ok "and copied into Application Support" || bad "not copied"
[[ -f "$FAKE/.claude/widgets/.wol-targets.json" ]] && ok "the old file is left in place" || bad "old file moved"

rm -rf "$WORK"
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
