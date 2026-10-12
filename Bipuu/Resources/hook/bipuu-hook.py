#!/usr/bin/env python3
# bipuu-hook.py — Bipuu hook relay for Claude Code and third-party agents.
# Reads JSON from stdin, forwards it to Bipuu over a private Unix socket, translates the reply.
#
# Fail-open by construction: whatever goes wrong (no app, wrong peer, bad signature, timeout),
# the relay prints nothing that allows anything and exits 0, so the agent asks in its own UI.
#
# Channel authentication (protocol BIPUU1, see docs/SECURITY_BASELINE.md):
#   request  "BIPUU1 <nonce> <mac>\n<json>\n"   mac = HMAC-SHA256(key, "bipuu1|"  + nonce + "|" + json)
#   reply    "BIPUU1R <mac>\n<json>\n"          mac = HMAC-SHA256(key, "bipuu1r|" + nonce + "|" + json)
# `key` is channel.key, created by the app (mode 0600). A decision whose signature does not verify
# for THIS request is ignored, so a process that merely squats the socket cannot approve anything.
import sys, json, os, socket, stat, struct, hmac, hashlib, secrets

SUPPORT_DIR = os.path.expanduser('~/Library/Application Support/Bipuu')
SOCKET_PATH = os.path.join(SUPPORT_DIR, 'bipuu.sock')
KEY_PATH = os.path.join(SUPPORT_DIR, 'channel.key')
MAX_REPLY = 1048576


def load_key():
    """The channel key, or None when it is missing, malformed, or readable by anyone else."""
    try:
        st = os.lstat(KEY_PATH)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            return None
        key = bytes.fromhex(open(KEY_PATH).read().strip())
        return key if len(key) == 32 else None
    except Exception:
        return None


def endpoint_is_private():
    """The directory and the socket must belong to this user and be closed to everyone else."""
    try:
        d = os.lstat(SUPPORT_DIR)
        s = os.lstat(SOCKET_PATH)
        uid = os.getuid()
        return (stat.S_ISDIR(d.st_mode) and d.st_uid == uid and not d.st_mode & 0o077
                and stat.S_ISSOCK(s.st_mode) and s.st_uid == uid and not s.st_mode & 0o077)
    except Exception:
        return False


def connect(timeout):
    """A connected socket to the app, or None unless the endpoint is private and its server runs as us."""
    if not endpoint_is_private():
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(SOCKET_PATH)
        cred = s.getsockopt(0, 1, 76)          # SOL_LOCAL, LOCAL_PEERCRED: struct xucred {version, uid, ...}
        if struct.unpack_from('=II', cred)[1] != os.getuid():
            s.close()
            return None
        return s
    except Exception:
        try:
            s.close()
        except Exception:
            pass
        return None


def send_signed(s, key, body):
    """Sends header + body and returns the nonce the reply must be bound to."""
    nonce = secrets.token_hex(16)
    mac = hmac.new(key, b'bipuu1|' + nonce.encode() + b'|' + body, hashlib.sha256).hexdigest()
    s.sendall(('BIPUU1 %s %s\n' % (nonce, mac)).encode() + body + b'\n')
    return nonce


def read_reply(s, key, nonce):
    """The parsed reply if, and only if, its signature verifies for this request; otherwise None."""
    buf = b''
    while buf.count(b'\n') < 2:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > MAX_REPLY:
            return None
    lines = buf.split(b'\n')
    if len(lines) < 2:
        return None
    parts = lines[0].decode('ascii', 'replace').split(' ')
    if len(parts) != 2 or parts[0] != 'BIPUU1R':
        return None
    expect = hmac.new(key, b'bipuu1r|' + nonce.encode() + b'|' + lines[1], hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expect, parts[1]):
        return None
    try:
        obj = json.loads(lines[1])
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def ask_app(payload, timeout, wait_for_reply):
    """Delivers a payload to the app; returns its verified reply (dict) when wait_for_reply, else None."""
    key = load_key()
    if key is None:
        return None
    s = connect(timeout)
    if s is None:
        return None
    try:
        nonce = send_signed(s, key, json.dumps(payload).encode())
        if not wait_for_reply:
            return None
        return read_reply(s, key, nonce)
    except Exception:
        return None
    finally:
        try:
            s.close()
        except Exception:
            pass

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    # --statusline mode: relay rate_limits to Bipuu, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'bipuu_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        ask_app(relay, 0.3, False)
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['bipuu_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        resp_obj = ask_app(payload, 125, True)
        if resp_obj and resp_obj.get('permissionDecision', '') == 'answer':
            answers = resp_obj.get('answers', {})
            questions = payload.get('tool_input', {}).get('questions', [])
            out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
            sys.stdout.write(json.dumps(out) + '\n')
            sys.stdout.flush()
            sys.exit(0)
        # 'ask', unknown, unsigned or no reply: no output → Claude Code asks in the terminal
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with bipuu_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('bipuu_agent', agent)
    # Claude Code sessions from the Claude desktop app (Code tab) report this entrypoint;
    # route them to the Claude Desktop pill instead of dropping them (no VS Code terminal).
    if not payload.get('bipuu_agent') and os.environ.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-desktop':
        payload['bipuu_agent'] = 'claude-desktop'

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    # Copilot sends the working directory as `workdir`; it must win over the process cwd.
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')

    if event == 'PermissionRequest':
        # Block and wait for Bipuu's decision (Claude Code allows up to 120s)
        resp_obj = ask_app(payload, 118, True) or {}   # verified reply only; {} otherwise
        decision = resp_obj.get('permissionDecision', '')
        if agent == 'hermes':
            hermes_choice = 'once' if decision == 'allow' else decision
            if hermes_choice in ('once', 'always', 'deny'):
                sys.stdout.write(json.dumps({'choice': hermes_choice}) + '\n')
                sys.stdout.flush()
            sys.exit(0)
        if decision in ('allow', 'always'):
            # Copilot/Muse use {"permissionDecision":"allow"} directly
            if agent in ('copilot', 'muse'):
                out = {'permissionDecision': 'allow'}
            elif decision == 'always' and agent != 'codex':
                # Let Claude Code persist the rule via updatedPermissions
                suggestions = payload.get('permission_suggestions', [])
                out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
            else:
                # Claude Code / Codex plain allow
                out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
            sys.stdout.write(json.dumps(out) + '\n')
            sys.stdout.flush()
            sys.exit(0)
        elif decision == 'deny':
            if agent in ('copilot', 'muse'):
                out = {'permissionDecision': 'deny'}
            else:
                out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Bipuu'}}}
            sys.stdout.write(json.dumps(out) + '\n')
            sys.stdout.flush()
            sys.exit(0)
        elif decision == 'answer':
            # AskUserQuestion answered from the notch
            answers = resp_obj.get('answers', {})
            questions = payload.get('tool_input', {}).get('questions', [])
            out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
            sys.stdout.write(json.dumps(out) + '\n')
            sys.stdout.flush()
            sys.exit(0)
        # 'ask', unknown, unsigned or no reply: fall through → no output → agent re-asks
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        # Hermes: no output → json.loads raises in plugin → transport_fallback: builtin activates
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\n')
            sys.stdout.flush()
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    ask_app(payload, 0.3, False)   # never blocks, never raises

    # Antigravity needs a decision on PreToolUse ({} reads as a denial). "ask" keeps its own
    # permission prompt (and the user's Always Allow); Bipuu never allows a tool by itself.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)