// Named-pipe server for coucou-hook.
//
// `\\.\pipe\coucou-<user>` — one instance per connection. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same pipe, which is how approving from the island works.
//
// Claude Code is never blocked by us: coucou-hook gives the connection 300 ms and
// exits cleanly if Coucou is closed, and we drop the connection after the
// decision timeout so the terminal takes over.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::oneshot;

use crate::island::WINDOW_LABEL;
use crate::log;

/// Slightly under coucou-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
const MAX_PAYLOAD: usize = 1 << 20;

/// Permission requests waiting for a click in the island.
#[derive(Default)]
pub struct Pending(pub Mutex<HashMap<String, oneshot::Sender<String>>>);

static COUNTER: AtomicU64 = AtomicU64::new(1);

pub fn pipe_name() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
    format!(r"\\.\pipe\coucou-{user}")
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let name = pipe_name();
        let mut server = match ServerOptions::new().first_pipe_instance(true).create(&name) {
            Ok(s) => s,
            Err(err) => {
                eprintln!("[coucou] cannot open {name}: {err}");
                return;
            }
        };
        loop {
            if server.connect().await.is_err() {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
            // Hand the connected instance to a task and listen on a fresh one.
            let next = match ServerOptions::new().create(&name) {
                Ok(s) => s,
                Err(err) => {
                    eprintln!("[coucou] cannot reopen {name}: {err}");
                    return;
                }
            };
            let connected = std::mem::replace(&mut server, next);
            let app = app.clone();
            tauri::async_runtime::spawn(async move { handle(app, connected).await });
        }
    });
}

async fn handle(app: AppHandle, mut pipe: NamedPipeServer) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match pipe.read(&mut chunk).await {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') || buf.len() > MAX_PAYLOAD {
                    break;
                }
            }
            Err(_) => return,
        }
    }
    let line = match buf.iter().position(|b| *b == b'\n') {
        Some(i) => &buf[..i],
        None => &buf[..],
    };
    let Ok(mut payload) = serde_json::from_slice::<Value>(line) else { return };
    if !payload.is_object() {
        return;
    }

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    if event != "PermissionRequest" {
        log::line(format!("hook {event}"));
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        let _ = pipe.disconnect();
        return;
    }

    let id = format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, rx) = oneshot::channel::<String>();
    {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        map.insert(id.clone(), tx);
    }
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);

    let decision = match tokio::time::timeout(DECISION_TIMEOUT, rx).await {
        Ok(Ok(d)) => Some(d),
        _ => None,
    };
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    match &decision {
        Some(d) => log::line(format!("hook id={id} answered {d}")),
        None => log::line(format!("hook id={id} timed out — terminal takes over")),
    }

    // No decision: say nothing at all. coucou-hook then writes nothing to stdout
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    let _ = pipe.disconnect();
}

/// Called by the island's Allow / Deny / Always buttons.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let json = match decision {
        "allow" => r#"{"permissionDecision":"allow"}"#,
        "always" => r#"{"permissionDecision":"allow","alwaysAllow":true}"#,
        _ => r#"{"permissionDecision":"deny"}"#,
    };
    let sender = app.state::<Pending>().0.lock().unwrap().remove(request_id);
    match sender {
        Some(tx) => {
            log::line(format!("decision id={request_id} {decision}"));
            let _ = tx.send(json.to_string());
        }
        None => log::line(format!("decision id={request_id} {decision} — no pending request")),
    }
}
