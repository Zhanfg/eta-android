use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const DEFAULT_BASE: &str = "/data/adb/opencode";
const DEFAULT_ADDR: &str = "127.0.0.1:17665";
const LOG_RETENTION_SECS: u64 = 72 * 3600;
const LOG_GC_INTERVAL_SECS: u64 = 24 * 3600;
const LOG_CAP_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "UPPERCASE")]
enum Level { Trace, Debug, Info, Warn, Error }

#[derive(Clone)]
struct Paths {
    base: PathBuf,
    state: PathBuf,
    logs: PathBuf,
    workspaces: PathBuf,
    goals: PathBuf,
    token: PathBuf,
}

impl Paths {
    fn new(base: PathBuf) -> Self {
        let state = base.join("state");
        Self {
            logs: base.join("logs"),
            workspaces: state.join("workspaces"),
            goals: state.join("goals"),
            token: state.join("bridge.token"),
            base,
            state,
        }
    }

    fn ensure(&self) -> std::io::Result<()> {
        for p in [&self.base, &self.state, &self.logs, &self.workspaces, &self.goals] {
            fs::create_dir_all(p)?;
        }
        Ok(())
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

fn log(paths: &Paths, level: Level, component: &str, event: &str, message: &str, fields: Value) {
    let row = json!({
        "ts": now_secs(), "level": level, "component": component,
        "event": event, "message": message, "fields": fields
    });
    let file = paths.logs.join(format!("ocd-{}.jsonl", now_secs() / 86400));
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(file) {
        let _ = writeln!(f, "{row}");
    }
}

fn log_gc(paths: &Paths) {
    let now = SystemTime::now();
    let cutoff = now.checked_sub(Duration::from_secs(LOG_RETENTION_SECS)).unwrap_or(UNIX_EPOCH);
    let mut files = Vec::new();
    let mut total = 0u64;
    if let Ok(entries) = fs::read_dir(&paths.logs) {
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if !meta.is_file() { continue; }
            let modified = meta.modified().unwrap_or(UNIX_EPOCH);
            if modified < cutoff {
                let _ = fs::remove_file(entry.path());
                continue;
            }
            total = total.saturating_add(meta.len());
            files.push((modified, meta.len(), entry.path()));
        }
    }
    if total > LOG_CAP_BYTES {
        files.sort_by_key(|x| x.0);
        for (_, size, path) in files {
            if total <= LOG_CAP_BYTES { break; }
            if fs::remove_file(path).is_ok() { total = total.saturating_sub(size); }
        }
    }
}

fn random_token() -> std::io::Result<String> {
    let mut bytes = [0u8; 32];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

fn ensure_token(paths: &Paths) -> std::io::Result<String> {
    if let Ok(token) = fs::read_to_string(&paths.token) {
        let token = token.trim().to_owned();
        if token.len() >= 32 { return Ok(token); }
    }
    let token = random_token()?;
    fs::write(&paths.token, format!("{token}\n"))?;
    Ok(token)
}

fn make_id(prefix: &str) -> String {
    format!("{prefix}_{}_{}", now_secs(), std::process::id())
}

fn atomic_json<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let mut file = File::create(&tmp)?;
    serde_json::to_writer_pretty(&mut file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(tmp, path)
}

fn load_dir<T: for<'de> Deserialize<'de>>(dir: &Path) -> Vec<T> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.path().extension().and_then(|v| v.to_str()) != Some("json") { continue; }
            if let Ok(data) = fs::read(entry.path()) {
                if let Ok(item) = serde_json::from_slice(&data) { out.push(item); }
            }
        }
    }
    out
}

#[derive(Debug, Serialize, Deserialize)]
struct Workspace {
    id: String,
    name: String,
    host_path: String,
    linux_path: String,
    storage_kind: String,
    created_at: u64,
    last_opened: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Goal {
    id: String,
    workspace_id: String,
    prompt: String,
    state: String,
    stage: String,
    progress: u8,
    autonomous: bool,
    reboot_resume: bool,
    created_at: u64,
    updated_at: u64,
}

#[derive(Deserialize)]
struct Rpc {
    id: Option<Value>,
    method: String,
    #[serde(default)] params: Value,
    #[serde(default)] token: String,
}

fn success(id: Value, value: Value) -> Value { json!({"id": id, "result": value}) }
fn failure(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({"id": id, "error": {"code": code, "message": message.into()}})
}

fn handle(req: Rpc, token: &str, paths: &Paths) -> Value {
    let id = req.id.unwrap_or(Value::Null);
    if req.token != token {
        log(paths, Level::Warn, "ipc", "auth_failed", "Rejected IPC client", json!({"method": req.method}));
        return failure(id, 401, "unauthorized");
    }

    match req.method.as_str() {
        "ping" => success(id, json!({"pong": true, "time": now_secs()})),
        "runtime.status" => {
            let goals: Vec<Goal> = load_dir(&paths.goals);
            let active = goals.iter().filter(|g| matches!(g.state.as_str(), "queued" | "running" | "recovering" | "waiting_approval")).count();
            success(id, json!({
                "rootfs_ready": paths.base.join("rootfs/.ocm-ready").exists(),
                "bootstrap": fs::read_to_string(paths.state.join("bootstrap.status")).unwrap_or_else(|_| "unknown".into()).trim(),
                "active_goals": active
            }))
        }
        "workspace.list" => success(id, serde_json::to_value(load_dir::<Workspace>(&paths.workspaces)).unwrap_or_else(|_| json!([]))),
        "workspace.register" => {
            let host = req.params.get("host_path").and_then(Value::as_str).unwrap_or("").trim();
            if !host.starts_with('/') { return failure(id, 400, "host_path must be absolute"); }
            let host_path = PathBuf::from(host);
            if !host_path.is_dir() { return failure(id, 404, format!("directory not found: {host}")); }
            let wid = make_id("ws");
            let now = now_secs();
            let workspace = Workspace {
                id: wid.clone(),
                name: req.params.get("name").and_then(Value::as_str).map(str::to_owned)
                    .or_else(|| host_path.file_name().and_then(|x| x.to_str()).map(str::to_owned))
                    .unwrap_or_else(|| "Workspace".into()),
                host_path: host.into(),
                linux_path: format!("/workspaces/{wid}"),
                storage_kind: if host.starts_with("/storage/emulated/") { "android_shared" } else { "linux_native" }.into(),
                created_at: now,
                last_opened: now,
            };
            if let Err(err) = atomic_json(&paths.workspaces.join(format!("{wid}.json")), &workspace) {
                return failure(id, 500, err.to_string());
            }
            log(paths, Level::Info, "workspace", "registered", "Workspace registered", json!({"id": wid, "host": host}));
            success(id, serde_json::to_value(workspace).unwrap_or_else(|_| json!({})))
        }
        "goal.list" => success(id, serde_json::to_value(load_dir::<Goal>(&paths.goals)).unwrap_or_else(|_| json!([]))),
        "goal.create" => {
            let wid = req.params.get("workspace_id").and_then(Value::as_str).unwrap_or("").trim();
            let prompt = req.params.get("prompt").and_then(Value::as_str).unwrap_or("").trim();
            if wid.is_empty() || prompt.is_empty() { return failure(id, 400, "workspace_id and prompt are required"); }
            if !paths.workspaces.join(format!("{wid}.json")).exists() { return failure(id, 404, "workspace not found"); }
            let gid = make_id("goal");
            let now = now_secs();
            let goal = Goal {
                id: gid.clone(), workspace_id: wid.into(), prompt: prompt.into(),
                state: "queued".into(), stage: "prepare".into(), progress: 0,
                autonomous: req.params.get("autonomous").and_then(Value::as_bool).unwrap_or(true),
                reboot_resume: req.params.get("reboot_resume").and_then(Value::as_bool).unwrap_or(true),
                created_at: now, updated_at: now,
            };
            if let Err(err) = atomic_json(&paths.goals.join(format!("{gid}.json")), &goal) {
                return failure(id, 500, err.to_string());
            }
            log(paths, Level::Info, "goal", "created", "Goal created", json!({"goal": gid, "workspace": wid}));
            success(id, serde_json::to_value(goal).unwrap_or_else(|_| json!({})))
        }
        "notification.snapshot" => {
            let goals: Vec<Goal> = load_dir(&paths.goals);
            if let Some(goal) = goals.into_iter().find(|g| matches!(g.state.as_str(), "queued" | "running" | "recovering" | "waiting_approval")) {
                success(id, json!({"active": true, "goal_id": goal.id, "state": goal.state, "stage": goal.stage, "progress": goal.progress}))
            } else {
                success(id, json!({"active": false}))
            }
        }
        _ => failure(id, 404, format!("unknown method: {}", req.method)),
    }
}

fn serve_client(mut stream: TcpStream, token: String, paths: Paths) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let Ok(clone) = stream.try_clone() else { return };
    let mut reader = BufReader::new(clone);
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() { return; }
    let response = match serde_json::from_str::<Rpc>(line.trim()) {
        Ok(req) => handle(req, &token, &paths),
        Err(err) => failure(Value::Null, 400, err.to_string()),
    };
    let _ = writeln!(stream, "{response}");
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let paths = Paths::new(PathBuf::from(env::var("OCM_BASE").unwrap_or_else(|_| DEFAULT_BASE.into())));
    paths.ensure()?;
    let token = ensure_token(&paths)?;
    log_gc(&paths);
    let gc_paths = paths.clone();
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(LOG_GC_INTERVAL_SECS));
        log_gc(&gc_paths);
    });

    let addr = env::var("OCM_ADDR").unwrap_or_else(|_| DEFAULT_ADDR.into());
    let listener = TcpListener::bind(&addr)?;
    log(&paths, Level::Info, "ocd", "started", "Rust backend started", json!({"addr": addr}));
    log(&paths, Level::Debug, "ocd", "policy", "Five-level logging active", json!({}));
    log(&paths, Level::Trace, "ocd", "trace_ready", "Trace level available", json!({}));
    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                let child_paths = paths.clone();
                let child_token = token.clone();
                thread::spawn(move || serve_client(stream, child_token, child_paths));
            }
            Err(err) => log(&paths, Level::Error, "ipc", "accept_error", "IPC accept failed", json!({"error": err.to_string()})),
        }
    }
    Ok(())
}
