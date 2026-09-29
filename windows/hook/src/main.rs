//! coucou-hook — the relay Claude Code runs on every hook event.
//!
//! Reads the hook JSON on stdin, adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<user>`.
//!
//! Hard rule (docs/CLAUDE.md): **never block Claude Code.**
//! * Connecting is given 300 ms. If Coucou is closed, slow or crashed we exit 0
//!   with nothing on stdout and the session carries on untouched.
//! * Only `PermissionRequest` then waits for an answer, because that is the whole
//!   point of approving from the island. If no answer arrives in time we still
//!   exit 0 with an empty stdout, so Claude Code falls back to asking in the
//!   terminal instead of us silently denying anything.
//!
//! Usage: `coucou-hook <EventName>` (the name is also read from the JSON).

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Budget for getting a pipe connection. Beyond this Claude Code wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_TIMEOUT: Duration = Duration::from_secs(110);

fn pipe_path() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
    format!(r"\\.\pipe\coucou-{user}")
}

/// Opens the pipe, retrying while the server is busy, within CONNECT_TIMEOUT.
fn connect() -> Option<std::fs::File> {
    let path = pipe_path();
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match std::fs::OpenOptions::new().read(true).write(true).open(&path) {
            Ok(file) => return Some(file),
            Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(15)),
            Err(_) => return None,
        }
    }
}

fn main() {
    // Any unexpected problem must still be a clean exit.
    let _ = std::panic::catch_unwind(run);
    std::process::exit(0);
}

fn run() {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() || raw.is_empty() {
        return;
    }
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }

    let Ok(mut payload) = serde_json::from_slice::<serde_json::Value>(&raw) else { return };
    let Some(map) = payload.as_object_mut() else { return };

    // The event name is passed as argv[1] by the hook command; the JSON usually
    // carries it too. Trust argv when the JSON is missing it.
    let arg_event = std::env::args().nth(1).unwrap_or_default();
    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| arg_event.clone());
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    let cwd_missing = map
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(str::is_empty)
        .unwrap_or(true);
    if cwd_missing {
        if let Ok(cwd) = std::env::current_dir() {
            map.insert(
                "cwd".into(),
                serde_json::Value::String(cwd.to_string_lossy().to_string()),
            );
        }
    }

    // Which terminal the session runs in. Unlike macOS, Coucou on Windows accepts
    // events from every terminal, so this is context only — never a filter.
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
    ] {
        if !map.contains_key(key) {
            let value = std::env::var(var).unwrap_or_default();
            map.insert(key.into(), serde_json::Value::String(value));
        }
    }

    let Some(mut pipe) = connect() else { return };

    let mut line = payload.to_string();
    line.push('\n');
    if pipe.write_all(line.as_bytes()).is_err() {
        return;
    }
    let _ = pipe.flush();

    if event != "PermissionRequest" {
        return; // fire and forget
    }

    // Wait for the island's decision on a helper thread so the timeout is real.
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    if buf.contains(&b'\n') {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(String::from_utf8_lossy(&buf).trim().to_string());
    });

    if let Ok(response) = rx.recv_timeout(DECISION_TIMEOUT) {
        if response.contains("permissionDecision") {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{response}");
            let _ = out.flush();
        }
    }
    // No answer: stdout stays empty and Claude Code asks in the terminal.
}
