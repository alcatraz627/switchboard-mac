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
export SWITCHBOARD_LOG_DIR="$WORK/logs"

section "syntax"
for f in scripts/*.sh tests/*.sh tests/fixtures/*.sh; do check "$f parses" bash -n "$f"; done
for f in Resources/lib/*.py hooks/*.py; do check "$f compiles" python3 -m py_compile "$f"; done

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
  check "Approve writes the file the push gate reads (scratch folder)" "$BIN" --probe-approve
  check "a clean, failed, hung and missing command are told apart" "$BIN" --probe-shell
  check "a panel open costs one snapshot; a wait gets a fresh one" "$BIN" --probe-snapshot
  check "list tabs: parsing, a failing source, preview and search" "$BIN" --probe-catalog
  check "the Library tab renders" "$BIN" --snapshot "$WORK/library.png" --tab library
  check "the Hooks tab renders" "$BIN" --snapshot "$WORK/rules.png" --tab rules
  check "the Ledger tab renders" "$BIN" --snapshot "$WORK/ledger.png" --tab ledger
  check "the Runtime tab renders" "$BIN" --snapshot "$WORK/runtime.png" --tab runtime
  check "the Claude MCP tab renders" "$BIN" --snapshot "$WORK/plugins.png" --tab plugins
  check "a transcript window says when the hub is down" "$BIN" --probe-transcript
  check "a section hidden in Settings is neither drawn nor read" "$BIN" --probe-visibility
  check "the Settings tab renders" "$BIN" --snapshot "$WORK/settings.png" --tab settings
  check "notes save, read back, expire, reorder and delete (scratch folder)" env SWITCHBOARD_STATE="$WORK/notes-state" "$BIN" --probe-notes
  check "scrolling turns one quick page per push, wraps, and ignores inertia" "$BIN" --probe-quick
  for p in home limits approvals bulbs notes timers controls models; do
    check "the $p quick page renders" env SWITCHBOARD_STATE="$WORK/notes-state" "$BIN" --snapshot-quick "$WORK/quick-$p.png" --page "$p"
  done
  check "sessions: grouping, order, hero, a gone session drops out, a recorded scan carries every used field" \
    "$BIN" --probe-sessions --scan-file tests/fixtures/scan-sample.json
  for z in md lg; do
    check "the sessions quick page and Settings render at size $z" bash -c "\"$BIN\" --snapshot-quick \"$WORK/quick-sessions-$z.png\" --page sessions --scan-file tests/fixtures/scan-sample.json --size $z && \"$BIN\" --snapshot \"$WORK/settings-$z.png\" --tab settings --size $z"
  done
  check "the sessions quick page renders from a recorded scan" \
    "$BIN" --snapshot-quick "$WORK/quick-sessions.png" --page sessions --scan-file tests/fixtures/scan-sample.json
  bash hub/lib/scan.sh --quick > "$WORK/live-scan.json" 2>/dev/null
  check "the hub's scanner still emits every field the Sessions card reads" \
    "$BIN" --probe-sessions --scan-file "$WORK/live-scan.json"
  check "timers run, go off, extend and clear" "$BIN" --probe-timers-tab
  check "the Queue tab renders" "$BIN" --snapshot "$WORK/queue.png" --tab queue
  check "the time picker renders" "$BIN" --snapshot-when "$WORK/when.png"
  check "the Notes tab renders with an editor open" env SWITCHBOARD_STATE="$WORK/notes-state" "$BIN" --snapshot "$WORK/notes.png" --tab notes --expand
  check "every eject helper answer is JSON with ok" python3 -c "import json,subprocess;r=subprocess.run(['python3','Resources/lib/drives.py','eject','disk99'],capture_output=True,text=True);assert json.loads(r.stdout)['ok'] is False"
  # A helper that fails shows its group with the reason instead of dropping it.
  BADLIB="$WORK/badlib"; cp -Rf "$ROOT/Resources/lib" "$BADLIB"
  printf 'import sys\nsys.stderr.write("diskutil is not answering\\n")\nsys.exit(2)\n' > "$BADLIB/drives.py"
  bad_out="$(SWITCHBOARD_LIB="$BADLIB" "$BIN" --dump 2>&1)"
  [[ "$bad_out" == *"status: failed: Drives: diskutil is not answering"* ]] \
    && ok "a failing helper's group says why, by its group name, instead of vanishing" || bad "failing helper not surfaced: ${bad_out:0:200}"
  # A helper that caught its own crash answers {ok: false}; that is a failed read too, not a fresh empty list.
  printf 'import json,sys\nprint(json.dumps({"ok": False, "error": "ValueError: bad saved address"}))\nsys.exit(1)\n' > "$BADLIB/jobs.py"
  bad_out="$(SWITCHBOARD_LIB="$BADLIB" "$BIN" --dump 2>&1)"
  [[ "$bad_out" == *"status: failed: Schedules: bad saved address"* ]] \
    && ok "a helper's own {ok: false} answer fails its group with a plain sentence" || bad "ok:false answer not surfaced: ${bad_out:0:200}"
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
python3 Resources/lib/wiz.py name aa0000000009 "Desk lamp" >/dev/null
eq "a bulb name is saved in the state folder" "Desk lamp" \
   "$(python3 -c "import json;print(json.load(open('$SWITCHBOARD_STATE/wiz-names.json'))['aa0000000009'])")"
python3 Resources/lib/wiz.py name aa0000000009 "" >/dev/null
eq "an empty name removes it" "absent" \
   "$(python3 -c "import json;print(json.load(open('$SWITCHBOARD_STATE/wiz-names.json')).get('aa0000000009','absent'))")"
eq "scene speed out of range is refused"   2 "$(rc python3 Resources/lib/wiz.py set 127.0.0.1 speed=500)"
echo '{"aa0000000001": "127.0.0.1"}' > "$SWITCHBOARD_STATE/wiz-known.json"
kept="$(python3 Resources/lib/wiz.py discover --timeout 1)"
[[ "$kept" == *'"mac": "aa0000000001"'*'"reachable": false'* ]] \
  && ok "a known bulb that misses a scan stays listed as not answering" \
  || bad "known bulb dropped from the scan: ${kept:0:160}"
eq "discovery survives noise on the port; a confirmed change reads as done" "discover:found set:on" \
   "$(env SWITCHBOARD_STATE="$WORK/wiz-probe" python3 tests/fixtures/wiz-probe.py)"
check "the Home tab renders with colour strips open" "$BIN" --snapshot "$WORK/home-expanded.png" --tab home --expand

section "machine helpers (jobs.py, wol.py)"
check "jobs.py list emits a JSON array" python3 -c "import json,subprocess;assert isinstance(json.loads(subprocess.run(['python3','Resources/lib/jobs.py','list'],capture_output=True,text=True).stdout),list)"
eq "jobs.py run of an unknown label fails"  1 "$(rc python3 Resources/lib/jobs.py run com.example.no-such-job)"
eq "jobs.py start of an unknown label fails" 1 "$(rc python3 Resources/lib/jobs.py start com.example.no-such-job)"
eq "jobs.py stop of an unknown label fails"  1 "$(rc python3 Resources/lib/jobs.py stop com.example.no-such-job)"
check "jobs.py gives every job a distinct name" python3 -c "import json,subprocess;n=[j['name'] for j in json.loads(subprocess.run(['python3','Resources/lib/jobs.py','list'],capture_output=True,text=True).stdout)];assert len(n)==len(set(n)),n"
check "devservers.py list emits servers" python3 -c "import json,subprocess;d=json.loads(subprocess.run(['python3','Resources/lib/devservers.py','list'],capture_output=True,text=True,timeout=60).stdout);assert isinstance(d['servers'],list)"
# A tool that cannot answer must fail the list with its reason, never read as "nothing loaded".
FAKEBIN="$(mktemp -d)"
printf '#!/bin/sh\necho "Could not connect to launchd" >&2\nexit 5\n' > "$FAKEBIN/launchctl"
printf '#!/bin/sh\necho "lsof: cannot read" >&2\nexit 1\n' > "$FAKEBIN/lsof"
chmod +x "$FAKEBIN/launchctl" "$FAKEBIN/lsof"
check "jobs.py list fails with the reason when launchctl cannot answer" python3 -c "import subprocess;r=subprocess.run(['python3','Resources/lib/jobs.py','list'],capture_output=True,text=True,env={'PATH':'$FAKEBIN:/usr/bin:/bin'});assert r.returncode==2 and 'Could not connect' in r.stderr, r"
check "devservers.py list fails with the reason when lsof cannot answer" python3 -c "import subprocess;r=subprocess.run(['python3','Resources/lib/devservers.py','list'],capture_output=True,text=True,timeout=60,env={'PATH':'$FAKEBIN:/usr/bin:/bin','HOME':'$HOME'});assert r.returncode==2 and 'lsof could not' in r.stderr, r"
# A helper that crashes or cannot ask answers in its own JSON, never a traceback.
check "jobs.py start answers {ok: false} with a sentence when launchctl cannot answer" python3 -c "import json,subprocess;r=subprocess.run(['python3','Resources/lib/jobs.py','start','com.example.x'],capture_output=True,text=True,env={'PATH':'$FAKEBIN:/usr/bin:/bin'});d=json.loads(r.stdout);assert r.returncode==1 and d['ok'] is False and 'Traceback' not in r.stderr and 'Could not connect' in d['error'], r"
printf '#!/bin/sh\nif [ "$1" = list ]; then echo "PID\tStatus\tLabel"; exit 0; fi\necho "print-disabled refused" >&2\nexit 5\n' > "$FAKEBIN/launchctl-half"
mkdir -p "$FAKEBIN/half"; cp -f "$FAKEBIN/launchctl-half" "$FAKEBIN/half/launchctl"; chmod +x "$FAKEBIN/half/launchctl"
check "jobs.py list fails when launchctl print-disabled cannot answer, not showing every job as enabled" python3 -c "import subprocess;r=subprocess.run(['python3','Resources/lib/jobs.py','list'],capture_output=True,text=True,env={'PATH':'$FAKEBIN/half:/usr/bin:/bin'});assert r.returncode==2 and 'print-disabled' in r.stderr, r"
PHOME="$WORK/phome"; mkdir -p "$PHOME/.claude/scripts/dev-servers"
printf '#!/bin/sh\necho "ledger locked" >&2\nexit 3\n' > "$PHOME/.claude/scripts/dev-servers/ports.sh"
check "devservers.py list fails with the reason when the port ledger cannot be read" python3 -c "import subprocess;r=subprocess.run(['python3','Resources/lib/devservers.py','list'],capture_output=True,text=True,timeout=60,env={'PATH':'/usr/bin:/bin:/usr/sbin','HOME':'$PHOME'});assert r.returncode==2 and 'ledger locked' in r.stderr, r"
RHOME="$WORK/rhome"; mkdir -p "$RHOME" "$FAKEBIN/csync"
printf '#!/bin/sh\ncase "$2" in status) echo "{\\"checks\\": []}";; ls) echo "relay unreachable" >&2; exit 3;; esac\n' > "$FAKEBIN/csync/csync"; chmod +x "$FAKEBIN/csync/csync"
check "remote.py list shows a failed csync ls as a failing check, not an empty host list" python3 -c "import json,subprocess;r=subprocess.run(['python3','Resources/lib/remote.py','list'],capture_output=True,text=True,timeout=60,env={'PATH':'$FAKEBIN/csync:/usr/bin:/bin','HOME':'$RHOME'});d=json.loads(r.stdout);c=[x for x in d['checks'] if x['check']=='csync ls'];assert c and c[0]['ok'] is False and 'relay unreachable' in c[0]['detail'], r.stdout"
WBAD="$WORK/wiz-bad"; mkdir -p "$WBAD"; echo '{"aa0000000002": 5}' > "$WBAD/wiz-known.json"
check "wiz.py answers {error} instead of a traceback when its saved addresses are damaged" python3 -c "import json,subprocess;r=subprocess.run(['python3','Resources/lib/wiz.py','discover','--timeout','1'],capture_output=True,text=True,env={'PATH':'/usr/bin:/bin','HOME':'$HOME','SWITCHBOARD_STATE':'$WBAD'});assert r.returncode==1 and 'Traceback' not in r.stderr and json.loads(r.stdout)['error'], r"
eq "devservers.py start of a name pm2 lacks fails" 1 "$(rc python3 Resources/lib/devservers.py start no-such-server-xyz)"
check "dbservices.py list emits services" python3 -c "import json,subprocess;d=json.loads(subprocess.run(['python3','Resources/lib/dbservices.py','list'],capture_output=True,text=True,timeout=30).stdout);assert isinstance(d['services'],list)"
eq "dbservices.py refuses a label outside homebrew.mxcl" 1 "$(rc python3 Resources/lib/dbservices.py stop com.example.not-a-db)"
eq "dbservices.py stop of an unknown homebrew label fails" 1 "$(rc python3 Resources/lib/dbservices.py stop homebrew.mxcl.no-such-db)"
check "models.py list reports pressure and mem-guard" python3 -c "import json,subprocess;d=json.loads(subprocess.run(['python3','Resources/lib/models.py','list'],capture_output=True,text=True,timeout=30).stdout);assert d['pressure'] and 'guard' in d"
eq "models.py refuses an unknown verb"      64 "$(rc python3 Resources/lib/models.py warm sideways)"
check "models.py says the warm tool is missing instead of a traceback" python3 -c "import json,subprocess,os;r=subprocess.run(['python3','Resources/lib/models.py','warm','on'],capture_output=True,text=True,env=dict(os.environ,HOME='$WORK'));assert r.returncode==1 and 'warm tool is missing' in json.loads(r.stdout)['error'], r"
check "gitscan.py fails the list with the reason when git is missing" python3 -c "import subprocess,sys;r=subprocess.run([sys.executable,'Resources/lib/gitscan.py','list','--fresh'],capture_output=True,text=True,timeout=120,env={'PATH':'/bin','HOME':'$HOME'});assert r.returncode==2 and 'git is not installed' in r.stderr, r"
check "remote.py list reports hosts and checks" python3 -c "import json,subprocess;d=json.loads(subprocess.run(['python3','Resources/lib/remote.py','list'],capture_output=True,text=True,timeout=90).stdout);assert isinstance(d['hosts'],list) and isinstance(d['checks'],list)"
eq "remote.py refuses an unknown host"     1 "$(rc python3 Resources/lib/remote.py shot no-such-host-xyz)"
check "gitscan.py list reports repos and a clean count" python3 -c "import json,subprocess;d=json.loads(subprocess.run(['python3','Resources/lib/gitscan.py','list'],capture_output=True,text=True,timeout=120).stdout);assert isinstance(d['repos'],list) and d['clean']>=0"
eq "gitscan.py refuses a path outside ~/Code" 1 "$(rc python3 Resources/lib/gitscan.py prune /tmp)"
check "drives.py list emits a JSON array" python3 -c "import json,subprocess;assert isinstance(json.loads(subprocess.run(['python3','Resources/lib/drives.py','list'],capture_output=True,text=True,timeout=60).stdout),list)"
eq "drives.py refuses to eject the boot disk" 1 "$(rc python3 Resources/lib/drives.py eject disk0)"
eq "jobs.py disable of an unknown label fails" 1 "$(rc python3 Resources/lib/jobs.py disable com.example.no-such-job)"
eq "devservers.py kill of a quiet port fails" 1 "$(rc python3 Resources/lib/devservers.py kill 6499)"
check "remote.py chat command is one ssh line" python3 -c "import json,subprocess;c=json.loads(subprocess.run(['python3','Resources/lib/remote.py','chatcmd','somehost'],capture_output=True,text=True).stdout)['command'];assert c.startswith('ssh -t -F ') and 'csync-somehost' in c and 'read -p' not in c,c"
eq "wol.py refuses a malformed MAC"         2 "$(rc python3 Resources/lib/wol.py wake not-a-mac)"
eq "wol.py sends to a well-formed MAC"      0 "$(rc python3 Resources/lib/wol.py wake 02:00:00:00:00:01)"
python3 Resources/lib/wol.py add "Test box" 02:00:00:00:00:02 >/dev/null
eq "a saved device lands in the state folder" "Test box" \
   "$(python3 -c "import json;print(json.load(open('$SWITCHBOARD_STATE/wol-targets.json'))[0]['name'])")"
printf '[{"name": "Kept box", "mac": "02:00' > "$SWITCHBOARD_STATE/wol-targets.json"
eq "an add refuses to overwrite an unreadable device file" 1 "$(rc python3 Resources/lib/wol.py add "New box" 02:00:00:00:00:03)"
eq "and the unreadable file is left as it was" '[{"name": "Kept box", "mac": "02:00' "$(cat "$SWITCHBOARD_STATE/wol-targets.json")"
check "a device list read says the file is unreadable instead of showing no saved devices" python3 -c "import json,subprocess;r=subprocess.run(['python3','Resources/lib/wol.py','list'],capture_output=True,text=True);d=json.loads(r.stdout);assert r.returncode==1 and d['ok'] is False and 'could not be read' in d['error'], r"
rm -f "$SWITCHBOARD_STATE/wol-targets.json"
mkdir -p "$WORK/ro-state"; chmod 555 "$WORK/ro-state"
check "wol.py add answers {ok: false} with a sentence when the state folder cannot be written" python3 -c "import json,subprocess;r=subprocess.run(['python3','Resources/lib/wol.py','add','Box','02:00:00:00:00:09'],capture_output=True,text=True,env={'PATH':'/usr/bin:/bin','HOME':'$HOME','SWITCHBOARD_STATE':'$WORK/ro-state'});d=json.loads(r.stdout);assert r.returncode==1 and d['ok'] is False and 'Traceback' not in r.stderr, r"
chmod 755 "$WORK/ro-state"

check "permission-ask hook: off by default, Approve and Deny answer, silence leaves it to the terminal (scratch folder)" python3 tests/fixtures/permission-ask-probe.py
check "pm2login.py: start-at-login reads pm2's saved list and changes only its own entry (scratch pm2 folder)" python3 tests/fixtures/pm2login-probe.py

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
