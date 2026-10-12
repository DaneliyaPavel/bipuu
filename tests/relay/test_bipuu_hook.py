"""Characterization tests for the hook relay (Bipuu/Resources/hook/bipuu-hook.py).

They pin the contract between an agent, the relay and the app socket:

* the relay never blocks and never fails the agent (always exit 0);
* when the app is absent or silent, nothing allows anything (fail-open to the agent's own prompt);
* every permission decision is translated to the output format of each agent;
* events are normalised and tagged the same way for every agent.

A fake app (a Unix socket in a throwaway HOME) stands in for Bipuu.
Run: python3 -m unittest discover -s tests/relay -v
"""
import hashlib
import hmac
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RELAY = os.path.join(ROOT, "Bipuu", "Resources", "hook", "bipuu-hook.py")
WRAPPER = os.path.join(ROOT, "Bipuu", "Resources", "hook", "bipuu-hook")


KEY = bytes.fromhex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
OTHER_KEY = bytes.fromhex("ff" * 32)


def mac(key, tag, nonce, body):
    return hmac.new(key, tag + b"|" + nonce.encode() + b"|" + body, hashlib.sha256).hexdigest()


class FakeApp:
    """A stand-in for Bipuu speaking protocol BIPUU1 over a Unix socket in a throwaway HOME.

    reply        decision JSON to send back (None: send nothing)
    server_key   key used to sign replies (default: the real channel key; a squatter uses another)
    signing      "ok" | "none" (plain, unsigned) | "other-nonce" (replay) | "tamper" (body changed after signing)
    """

    def __init__(self, home, reply=None, server_key=KEY, signing="ok", write_key=True):
        self.dir = os.path.join(home, "Library", "Application Support", "Bipuu")
        os.makedirs(self.dir, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.key_path = os.path.join(self.dir, "channel.key")
        if write_key:
            with open(self.key_path, "w") as f:
                f.write(KEY.hex() + "\n")
            os.chmod(self.key_path, 0o600)
        self.path = os.path.join(self.dir, "bipuu.sock")
        self.reply = reply
        self.server_key = server_key
        self.signing = signing
        self.received = []        # only requests whose signature verified
        self.rejected = 0
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self.path)
        os.chmod(self.path, 0o600)
        self._srv.listen(8)
        self._srv.settimeout(0.2)
        self._stop = False
        self._t = threading.Thread(target=self._loop, daemon=True)
        self._t.start()

    def _read_two_lines(self, c):
        buf = b""
        while buf.count(b"\n") < 2:
            chunk = c.recv(65536)
            if not chunk:
                break
            buf += chunk
        parts = buf.split(b"\n")
        return (parts[0], parts[1]) if len(parts) >= 2 else (b"", b"")

    def _loop(self):
        while not self._stop:
            try:
                c, _ = self._srv.accept()
            except (socket.timeout, OSError):
                continue
            c.settimeout(2)
            try:
                header, body = self._read_two_lines(c)
                h = header.decode("ascii", "replace").split(" ")
                nonce = h[1] if len(h) == 3 else ""
                if len(h) == 3 and h[0] == "BIPUU1" and hmac.compare_digest(mac(KEY, b"bipuu1", nonce, body), h[2]):
                    self.received.append(json.loads(body.decode()))
                    if self.reply is not None:
                        self._send_reply(c, nonce)
                else:
                    self.rejected += 1
            except Exception:
                pass
            finally:
                c.close()

    def _send_reply(self, c, nonce):
        body = self.reply.encode()
        if self.signing == "none":
            c.sendall(body + b"\n")
            return
        signed_nonce = "f" * 32 if self.signing == "other-nonce" else nonce
        header = "BIPUU1R %s" % mac(self.server_key, b"bipuu1r", signed_nonce, body)
        if self.signing == "tamper":
            body = body.replace(b"deny", b"allow").replace(b"ask", b"allow")
        c.sendall(header.encode() + b"\n" + body + b"\n")

    def close(self):
        self._stop = True
        self._t.join(timeout=2)
        self._srv.close()


class RelayTestCase(unittest.TestCase):
    def setUp(self):
        # Short path: AF_UNIX paths are limited to ~104 bytes.
        self.home = tempfile.mkdtemp(prefix="bp-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.app = None

    def start_app(self, reply=None, **kw):
        self.app = FakeApp(self.home, reply, **kw)
        self.addCleanup(self.app.close)
        return self.app

    def run_relay(self, payload, *args, env=None, stdin=None, script=RELAY, timeout=20):
        e = {"PATH": os.environ.get("PATH", ""), "HOME": self.home}
        e.update(env or {})
        data = stdin if stdin is not None else (json.dumps(payload).encode() if payload is not None else b"")
        cmd = [sys.executable, script, *args] if script.endswith(".py") else [script, *args]
        return subprocess.run(cmd, input=data, capture_output=True, env=e, timeout=timeout)

    def out_json(self, proc):
        text = proc.stdout.decode().strip()
        return json.loads(text) if text else None


PERM = {"hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/work/app",
        "tool_name": "Bash", "tool_input": {"command": "rm -rf build"},
        "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "rm -rf build"}]}]}


class FireAndForget(RelayTestCase):
    def test_forwards_tagged_event_and_prints_nothing_for_claude(self):
        app = self.start_app()
        p = self.run_relay({"hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/w",
                            "tool_name": "Bash", "tool_input": {"command": "ls"}},
                           "--agent", "my-tool", env={"TERM_PROGRAM": "iTerm.app"})
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b"")
        self.assertEqual(len(app.received), 1)
        got = app.received[0]
        self.assertEqual(got["bipuu_agent"], "my-tool")
        self.assertEqual(got["hook_event_name"], "PreToolUse")
        self.assertEqual(got["tool_input"], {"command": "ls"})
        self.assertEqual(got["term_program"], "iTerm.app")

    def test_cwd_falls_back_to_workspace_paths_then_process_cwd(self):
        app = self.start_app()
        self.run_relay({"hook_event_name": "Stop", "session_id": "s", "workspacePaths": ["/ws/a"]}, "--agent", "x")
        self.run_relay({"hook_event_name": "Stop", "session_id": "s"}, "--agent", "x")
        self.assertEqual(app.received[0]["cwd"], "/ws/a")
        self.assertTrue(os.path.isabs(app.received[1]["cwd"]))

    def test_gemini_event_and_tool_fields_are_normalised(self):
        app = self.start_app()
        p = self.run_relay({"hook_event_name": "BeforeTool", "toolCall": {"name": "run_shell", "args": {"CommandLine": "ls"}},
                            "conversationId": "c-1"}, "--agent", "gemini")
        self.assertEqual(self.out_json(p), {})                 # gemini needs a JSON object
        got = app.received[0]
        self.assertEqual(got["hook_event_name"], "PreToolUse")
        self.assertEqual(got["tool_name"], "run_shell")
        self.assertEqual(got["tool_input"]["command"], "ls")
        self.assertEqual(got["session_id"], "c-1")

    def test_event_name_can_come_from_argv(self):
        app = self.start_app()
        self.run_relay({"session_id": "s", "toolName": "bash", "toolArgs": {"command": "x"}, "workdir": "/wd"},
                       "--agent", "copilot", "preToolUse")
        got = app.received[0]
        self.assertEqual(got["hook_event_name"], "PreToolUse")
        self.assertEqual(got["tool_name"], "bash")
        self.assertEqual(got["cwd"], "/wd")

    def test_claude_desktop_entrypoint_is_tagged_and_explicit_agent_wins(self):
        app = self.start_app()
        base = {"hook_event_name": "SessionStart", "session_id": "s", "cwd": "/w"}
        self.run_relay(dict(base), env={"CLAUDE_CODE_ENTRYPOINT": "claude-desktop"})
        self.run_relay(dict(base), "--agent", "codex", env={"CLAUDE_CODE_ENTRYPOINT": "claude-desktop"})
        self.assertEqual(app.received[0]["bipuu_agent"], "claude-desktop")
        self.assertEqual(app.received[1]["bipuu_agent"], "codex")

    def test_antigravity_pretooluse_asks_and_other_events_get_empty_object(self):
        self.start_app()
        p = self.run_relay({"hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/w"}, "--agent", "antigravity")
        self.assertEqual(self.out_json(p), {"decision": "ask"})
        p = self.run_relay({"hook_event_name": "Stop", "session_id": "s", "cwd": "/w"}, "--agent", "antigravity")
        self.assertEqual(self.out_json(p), {})

    def test_garbage_or_empty_stdin_exits_cleanly_without_output(self):
        app = self.start_app()
        for stdin in (b"", b"not json", b"[1,2"):
            p = self.run_relay(None, "--agent", "x", stdin=stdin)
            self.assertEqual(p.returncode, 0)
            self.assertEqual(p.stdout, b"")
        self.assertEqual(app.received, [])


class AppAbsent(RelayTestCase):
    """No Bipuu: the agent must carry on and ask in its own UI."""

    def test_events_are_dropped_silently(self):
        p = self.run_relay({"hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/w"}, "--agent", "claude-x")
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_permission_request_prints_nothing_for_unknown_agents(self):
        for agent in (None, "codex", "muse", "hermes"):
            args = ("--agent", agent) if agent else ()
            p = self.run_relay(PERM, *args)
            self.assertEqual((agent, p.returncode, p.stdout), (agent, 0, b""))

    def test_copilot_is_fail_closed_to_ask(self):
        p = self.run_relay(PERM, "--agent", "copilot")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.out_json(p), {"permissionDecision": "ask"})

    def test_stale_socket_file_is_treated_as_absent(self):
        d = os.path.join(self.home, "Library", "Application Support", "Bipuu")
        os.makedirs(d, mode=0o700)
        with open(os.path.join(d, "channel.key"), "w") as f:
            f.write(KEY.hex() + "\n")
        os.chmod(os.path.join(d, "channel.key"), 0o600)
        open(os.path.join(d, "bipuu.sock"), "w").close()   # a regular file, nobody listening
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))


class PermissionDecisions(RelayTestCase):
    """decision from the app -> output for each agent."""

    def decide(self, decision, *args, **kw):
        reply = json.dumps({"permissionDecision": decision, **kw})
        self.start_app(reply)
        return self.run_relay(PERM, *args)

    def test_claude_allow_deny(self):
        self.assertEqual(self.out_json(self.decide("allow")),
                         {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})

    def test_claude_deny_has_message(self):
        out = self.out_json(self.decide("deny"))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "deny")
        self.assertTrue(out["hookSpecificOutput"]["decision"]["message"])

    def test_claude_always_returns_the_agents_own_suggestions(self):
        out = self.out_json(self.decide("always"))
        d = out["hookSpecificOutput"]["decision"]
        self.assertEqual(d["behavior"], "allow")
        self.assertEqual(d["updatedPermissions"], PERM["permission_suggestions"])

    def test_codex_always_is_a_plain_allow(self):
        out = self.out_json(self.decide("always", "--agent", "codex"))
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})

    def test_copilot_and_muse_use_flat_decisions(self):
        for agent in ("copilot", "muse"):
            self.setUp()
            self.assertEqual(self.out_json(self.decide("allow", "--agent", agent)), {"permissionDecision": "allow"})
            self.setUp()
            self.assertEqual(self.out_json(self.decide("deny", "--agent", agent)), {"permissionDecision": "deny"})

    def test_hermes_choices(self):
        for decision, choice in (("allow", "once"), ("always", "always"), ("deny", "deny")):
            self.setUp()
            self.assertEqual(self.out_json(self.decide(decision, "--agent", "hermes")), {"choice": choice})

    def test_ask_and_unknown_decisions_allow_nothing(self):
        for decision in ("ask", "bogus", ""):
            self.setUp()
            p = self.decide(decision)
            self.assertEqual((decision, p.returncode, p.stdout), (decision, 0, b""))

    def test_copilot_ask_prints_ask(self):
        self.assertEqual(self.out_json(self.decide("ask", "--agent", "copilot")), {"permissionDecision": "ask"})

    def test_garbage_reply_allows_nothing(self):
        self.start_app("this is not json")
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_request_reaches_the_app_intact(self):
        self.decide("ask")
        got = self.app.received[0]
        self.assertEqual(got["tool_input"], {"command": "rm -rf build"})
        self.assertEqual(got["hook_event_name"], "PermissionRequest")

    def test_answer_decision_wraps_answers(self):
        self.start_app(json.dumps({"permissionDecision": "answer", "answers": {"Q?": "A"}}))
        payload = dict(PERM, tool_input={"questions": [{"question": "Q?"}]})
        out = self.out_json(self.run_relay(payload))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["updatedInput"]["answers"], {"Q?": "A"})


class AskUserQuestion(RelayTestCase):
    def test_answered_question_becomes_an_allow_with_updated_input(self):
        self.start_app(json.dumps({"permissionDecision": "answer", "answers": {"Pick": "B"}}))
        payload = {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "session_id": "s",
                   "tool_input": {"questions": [{"question": "Pick"}]}}
        out = self.out_json(self.run_relay(payload, "--ask"))
        h = out["hookSpecificOutput"]
        self.assertEqual((h["hookEventName"], h["permissionDecision"]), ("PreToolUse", "allow"))
        self.assertEqual(h["updatedInput"]["answers"], {"Pick": "B"})
        self.assertEqual(self.app.received[0]["bipuu_kind"], "ask_user_question")

    def test_other_tools_are_ignored(self):
        app = self.start_app("{}")
        p = self.run_relay({"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s"}, "--ask")
        self.assertEqual((p.returncode, p.stdout, app.received), (0, b"", []))

    def test_unanswered_question_prints_nothing(self):
        self.start_app(json.dumps({"permissionDecision": "ask"}))
        p = self.run_relay({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "session_id": "s",
                            "tool_input": {"questions": []}}, "--ask")
        self.assertEqual((p.returncode, p.stdout), (0, b""))


class Statusline(RelayTestCase):
    def test_rate_limits_are_relayed_and_previous_command_still_runs(self):
        app = self.start_app()
        hook_dir = os.path.join(self.home, "hook")
        os.makedirs(hook_dir)
        shutil.copy(RELAY, hook_dir)
        with open(os.path.join(hook_dir, "statusline-previous.json"), "w") as f:
            json.dump({"command": "printf 'PREV'"}, f)
        p = self.run_relay({"session_id": "s", "rate_limits": {"five_hour": {"used_percentage": 12}}},
                           "--statusline", script=os.path.join(hook_dir, "bipuu-hook.py"))
        self.assertEqual((p.returncode, p.stdout), (0, b"PREV"))
        self.assertEqual(app.received[0]["bipuu_kind"], "statusline")
        self.assertEqual(app.received[0]["rate_limits"]["five_hour"]["used_percentage"], 12)

    def test_without_previous_command_prints_nothing(self):
        self.start_app()
        p = self.run_relay({"session_id": "s", "rate_limits": {}}, "--statusline")
        self.assertEqual((p.returncode, p.stdout), (0, b""))


class ChannelAuthentication(RelayTestCase):
    """The relay only believes an app that proves it holds the channel key, and only talks to a private endpoint."""

    def test_requests_carry_a_valid_signature(self):
        app = self.start_app()
        self.run_relay({"hook_event_name": "Stop", "session_id": "s", "cwd": "/w"}, "--agent", "x")
        self.assertEqual(len(app.received), 1)          # FakeApp records only verified requests
        self.assertEqual(app.rejected, 0)

    def test_a_squatter_with_another_key_cannot_approve(self):
        self.start_app(json.dumps({"permissionDecision": "allow"}), server_key=OTHER_KEY)
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_a_squatter_cannot_force_copilot_past_its_own_prompt(self):
        self.start_app(json.dumps({"permissionDecision": "allow"}), server_key=OTHER_KEY)
        p = self.run_relay(PERM, "--agent", "copilot")
        self.assertEqual(self.out_json(p), {"permissionDecision": "ask"})

    def test_unsigned_allow_is_ignored(self):
        self.start_app(json.dumps({"permissionDecision": "allow"}), signing="none")
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_a_reply_recorded_for_another_request_is_ignored(self):
        self.start_app(json.dumps({"permissionDecision": "allow"}), signing="other-nonce")
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_a_reply_changed_after_signing_is_ignored(self):
        self.start_app(json.dumps({"permissionDecision": "deny"}), signing="tamper")
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_answers_to_questions_need_the_signature_too(self):
        self.start_app(json.dumps({"permissionDecision": "answer", "answers": {"Q": "A"}}), signing="none")
        p = self.run_relay({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "session_id": "s",
                            "tool_input": {"questions": [{"question": "Q"}]}}, "--ask")
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_relay_refuses_a_key_other_users_can_read(self):
        app = self.start_app()
        os.chmod(app.key_path, 0o644)
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout), (0, b""))
        self.assertEqual(app.received, [])

    def test_relay_does_nothing_without_a_key(self):
        app = self.start_app(write_key=False)
        p = self.run_relay({"hook_event_name": "Stop", "session_id": "s", "cwd": "/w"}, "--agent", "x")
        self.assertEqual((p.returncode, p.stdout, app.received), (0, b"", []))

    def test_relay_refuses_a_socket_other_users_can_reach(self):
        app = self.start_app()
        os.chmod(app.path, 0o666)
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout, app.received), (0, b"", []))

    def test_relay_refuses_a_directory_other_users_can_enter(self):
        app = self.start_app()
        os.chmod(app.dir, 0o755)
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout, app.received), (0, b"", []))
        os.chmod(app.dir, 0o700)

    def test_relay_refuses_a_symlinked_socket(self):
        app = self.start_app()
        link = os.path.join(self.home, "elsewhere.sock")
        os.rename(app.path, link)
        os.symlink(link, app.path)
        p = self.run_relay(PERM)
        self.assertEqual((p.returncode, p.stdout, app.received), (0, b"", []))


class ShellWrapper(RelayTestCase):
    """The wrapper must exit 0 and keep Copilot valid even when the Python relay is broken."""

    def make_wrapper_dir(self, py_body):
        d = os.path.join(self.home, "w")
        os.makedirs(d)
        shutil.copy(WRAPPER, d)
        with open(os.path.join(d, "bipuu-hook.py"), "w") as f:
            f.write(py_body)
        return os.path.join(d, "bipuu-hook")

    def test_crashing_relay_still_exits_zero(self):
        w = self.make_wrapper_dir("import sys; sys.exit(7)\n")
        p = self.run_relay({"x": 1}, "--agent", "claude-x", script=w)
        self.assertEqual((p.returncode, p.stdout), (0, b""))

    def test_crashing_relay_keeps_copilot_valid(self):
        w = self.make_wrapper_dir("raise SystemExit(1)\n")
        p = self.run_relay({"x": 1}, "--agent", "copilot", "permissionRequest", script=w)
        self.assertEqual(self.out_json(p), {"permissionDecision": "ask"})
        p = self.run_relay({"x": 1}, "--agent", "copilot", "preToolUse", script=w)
        self.assertEqual(self.out_json(p), {})

    def test_wrapper_passes_relay_output_through(self):
        w = self.make_wrapper_dir("print('{\"ok\": 1}')\n")
        p = self.run_relay({"x": 1}, script=w)
        self.assertEqual(self.out_json(p), {"ok": 1})


if __name__ == "__main__":
    unittest.main()
