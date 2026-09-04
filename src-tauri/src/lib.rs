use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::Emitter;

const WINDOWS_START_SCRIPT: &str = include_str!("../../start-distributed-model-windows-nvidia.sh");
const WINDOWS_WORKER_SCRIPT: &str = include_str!("../../share-gpu-worker-windows-nvidia.sh");
const MAC_START_SCRIPT: &str = include_str!("../../start-distributed-model-macos-apple-silicon.sh");
const MAC_WORKER_SCRIPT: &str = include_str!("../../share-gpu-worker-macos-apple-silicon.sh");
const LINUX_START_SCRIPT: &str = include_str!("../../start-distributed-model-linux-nvidia.sh");
const LINUX_WORKER_SCRIPT: &str = include_str!("../../share-gpu-worker-linux-nvidia.sh");

#[derive(Default, Clone)]
struct SessionRegistry {
    pids: Arc<Mutex<HashMap<String, u32>>>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct LaunchOptions {
    role: String,
    stack: String,
    target_os: String,
    shell_path: String,
    llama_dir: String,
    model_path: String,
    context: String,
    server_host: String,
    server_port: String,
    rpc_port: String,
    discovery_port: String,
    discovery_seconds: String,
    mode: String,
    use_all_workers: bool,
    use_cache: bool,
    manual_rpc_servers: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EnvVar {
    key: String,
    value: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchPreview {
    shell: String,
    command: String,
    environment: Vec<EnvVar>,
    requirements: Vec<String>,
    notes: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HostInfo {
    os: String,
    arch: String,
    default_stack: String,
    default_target_os: String,
    network_host: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LogEvent {
    session_id: String,
    stream: String,
    line: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionEvent {
    session_id: String,
    status: String,
    code: Option<i32>,
}

#[tauri::command]
fn detect_host() -> HostInfo {
    let os = std::env::consts::OS.to_string();
    let arch = std::env::consts::ARCH.to_string();
    let default_stack = if os == "macos" && arch == "aarch64" {
        "apple".to_string()
    } else {
        "nvidia".to_string()
    };
    let default_target_os = match os.as_str() {
        "macos" => "macos",
        "windows" => "windows",
        "linux" => "linux",
        _ => "linux",
    }
    .to_string();

    HostInfo {
        os,
        arch,
        default_stack,
        default_target_os,
        network_host: local_server_host(),
    }
}

fn local_server_host() -> String {
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = Command::new("scutil").args(["--get", "LocalHostName"]).output() {
            let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !name.is_empty() {
                return format!("{name}.local");
            }
        }
    }

    #[cfg(target_os = "windows")]
    {
        if let Ok(name) = std::env::var("COMPUTERNAME") {
            if !name.trim().is_empty() {
                return name;
            }
        }
    }

    if let Ok(output) = Command::new("hostname").output() {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !name.is_empty() {
            return name;
        }
    }

    "localhost".to_string()
}

#[tauri::command]
fn build_preview(options: LaunchOptions) -> Result<LaunchPreview, String> {
    let (_script_name, _) = script_for(&options)?;
    let shell = shell_for(&options);
    let environment = env_for(&options);
    let env_text = environment
        .iter()
        .map(|item| format!("{}={} ", item.key, shell_quote(&item.value)))
        .collect::<String>();
    let command = format!("{}{} <generated launcher>", env_text, shell);

    Ok(LaunchPreview {
        shell,
        command,
        environment,
        requirements: requirements_for(&options),
        notes: notes_for(&options),
    })
}

#[tauri::command]
fn start_session(
    app: tauri::AppHandle,
    state: tauri::State<'_, SessionRegistry>,
    options: LaunchOptions,
) -> Result<String, String> {
    if options.role == "host" && options.model_path.trim().is_empty() {
        return Err("Choose the GGUF model path before starting the model.".to_string());
    }

    let (script_name, script) = script_for(&options)?;
    let shell = shell_for(&options);
    let session_id = new_session_id();
    let script_path = write_script(&session_id, script_name, script)?;

    let mut command = Command::new(&shell);
    command
        .arg(&script_path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    for env_var in env_for(&options) {
        command.env(env_var.key, env_var.value);
    }

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::last_os_error())
                }
            });
        }
    }

    let mut child = command
        .spawn()
        .map_err(|err| format!("Failed to start the selected preset with {shell}: {err}"))?;
    let pid = child.id();

    state
        .pids
        .lock()
        .map_err(|_| "Session registry is unavailable.".to_string())?
        .insert(session_id.clone(), pid);

    let _ = app.emit(
        "session-log",
        LogEvent {
            session_id: session_id.clone(),
            stream: "system".to_string(),
            line: format!("Started session as process {pid}."),
        },
    );

    if let Some(stdout) = child.stdout.take() {
        stream_output(app.clone(), session_id.clone(), "stdout", stdout);
    }
    if let Some(stderr) = child.stderr.take() {
        stream_output(app.clone(), session_id.clone(), "stderr", stderr);
    }

    let sessions = state.pids.clone();
    let wait_app = app.clone();
    let wait_session_id = session_id.clone();
    thread::spawn(move || {
        let status = child.wait();
        if let Ok(mut pids) = sessions.lock() {
            pids.remove(&wait_session_id);
        }

        let (label, code) = match status {
            Ok(exit_status) => (
                if exit_status.success() { "finished" } else { "exited" }.to_string(),
                exit_status.code(),
            ),
            Err(err) => (format!("wait failed: {err}"), None),
        };

        let _ = wait_app.emit(
            "session-ended",
            SessionEvent {
                session_id: wait_session_id,
                status: label,
                code,
            },
        );
    });

    Ok(session_id)
}

#[tauri::command]
fn stop_session(
    state: tauri::State<'_, SessionRegistry>,
    session_id: String,
) -> Result<(), String> {
    let pid = state
        .pids
        .lock()
        .map_err(|_| "Session registry is unavailable.".to_string())?
        .get(&session_id)
        .copied()
        .ok_or_else(|| "No running process was found for that session.".to_string())?;

    stop_pid(pid)
}

fn script_for(options: &LaunchOptions) -> Result<(&'static str, &'static str), String> {
    match (
        options.stack.as_str(),
        options.target_os.as_str(),
        options.role.as_str(),
    ) {
        ("apple", "macos", "host") => Ok((
            "start-distributed-model-macos-apple-silicon.sh",
            MAC_START_SCRIPT,
        )),
        ("apple", "macos", "worker") => Ok((
            "share-gpu-worker-macos-apple-silicon.sh",
            MAC_WORKER_SCRIPT,
        )),
        ("nvidia", "windows", "host") => Ok((
            "start-distributed-model-windows-nvidia.sh",
            WINDOWS_START_SCRIPT,
        )),
        ("nvidia", "windows", "worker") => Ok((
            "share-gpu-worker-windows-nvidia.sh",
            WINDOWS_WORKER_SCRIPT,
        )),
        ("nvidia", "linux", "host") => Ok((
            "start-distributed-model-linux-nvidia.sh",
            LINUX_START_SCRIPT,
        )),
        ("nvidia", "linux", "worker") => Ok((
            "share-gpu-worker-linux-nvidia.sh",
            LINUX_WORKER_SCRIPT,
        )),
        ("apple", _, _) => Err("Apple Silicon mode is currently macOS only.".to_string()),
        _ => Err("Choose a supported stack and operating system.".to_string()),
    }
}

fn env_for(options: &LaunchOptions) -> Vec<EnvVar> {
    let mut env = Vec::new();
    push_env(&mut env, "PATH", &launch_path_for(options));
    push_env(&mut env, "LLAMA_DIR", &options.llama_dir);
    push_env(&mut env, "MODEL", &options.model_path);
    push_env(&mut env, "CONTEXT", &options.context);
    push_env(&mut env, "SERVER_HOST", &options.server_host);
    push_env(&mut env, "SERVER_BIND", &options.server_host);
    push_env(&mut env, "SERVER_PORT", &options.server_port);
    push_env(&mut env, "RPC_PORT", &options.rpc_port);
    push_env(&mut env, "DISCOVERY_PORT", &options.discovery_port);
    push_env(&mut env, "DISCOVERY_SECONDS", &options.discovery_seconds);
    push_env(&mut env, "MODE", &options.mode);
    push_env(
        &mut env,
        "USE_ALL_WORKERS",
        if options.use_all_workers { "1" } else { "0" },
    );
    push_env(
        &mut env,
        "USE_CACHE",
        if options.use_cache { "1" } else { "0" },
    );
    push_env(&mut env, "RPC_SERVERS", &options.manual_rpc_servers);
    env
}

fn launch_path_for(options: &LaunchOptions) -> String {
    let current_path = std::env::var("PATH").unwrap_or_default();
    let mut paths: Vec<PathBuf> = match options.target_os.as_str() {
        "macos" => [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/Library/Apple/usr/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        .into_iter()
        .map(PathBuf::from)
        .collect(),
        "linux" => [
            "/usr/local/cuda/bin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        .into_iter()
        .map(PathBuf::from)
        .collect(),
        _ => Vec::new(),
    };

    if !current_path.trim().is_empty() {
        paths.extend(std::env::split_paths(&current_path));
    }

    let mut deduped = Vec::new();
    for path in paths {
        if !deduped.contains(&path) {
            deduped.push(path);
        }
    }
    std::env::join_paths(deduped)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or(current_path)
}

fn push_env(env: &mut Vec<EnvVar>, key: &str, value: &str) {
    let trimmed = value.trim();
    if !trimmed.is_empty() {
        env.push(EnvVar {
            key: key.to_string(),
            value: trimmed.to_string(),
        });
    }
}

fn requirements_for(options: &LaunchOptions) -> Vec<String> {
    match (options.stack.as_str(), options.target_os.as_str()) {
        ("apple", "macos") => vec![
            "Apple Silicon Mac".to_string(),
            "Xcode Command Line Tools".to_string(),
            "git, cmake, and dns-sd".to_string(),
            "Trusted LAN with Bonjour/mDNS enabled".to_string(),
        ],
        ("nvidia", "windows") => vec![
            "NVIDIA driver and CUDA Toolkit".to_string(),
            "Git for Windows with bash available in PATH".to_string(),
            "CMake".to_string(),
            "Visual Studio 2022 Build Tools with Desktop C++".to_string(),
            "PowerShell permission to add LocalSubnet firewall rules".to_string(),
        ],
        ("nvidia", "linux") => vec![
            "NVIDIA driver and CUDA Toolkit".to_string(),
            "git, cmake, python3, and nvidia-smi".to_string(),
            "LAN allows UDP discovery and TCP RPC between machines".to_string(),
        ],
        _ => vec!["Unsupported platform selection".to_string()],
    }
}

fn notes_for(options: &LaunchOptions) -> Vec<String> {
    let mut notes = Vec::new();
    if options.role == "worker" {
        notes.push("This machine contributes GPU memory and must stay running while a model uses it.".to_string());
    } else {
        notes.push("This machine starts llama-server or llama-cli and joins discovered workers.".to_string());
    }
    if options.stack == "apple" {
        notes.push("Apple workers are discovered with Bonjour/mDNS.".to_string());
    }
    if options.stack == "nvidia" {
        notes.push("NVIDIA workers are discovered with UDP broadcast, with manual RPC endpoints available as a fallback.".to_string());
    }
    notes.push("Use this only on a trusted local network; llama.cpp RPC should not be exposed to the Internet.".to_string());
    notes
}

fn shell_for(options: &LaunchOptions) -> String {
    let trimmed = options.shell_path.trim();
    if !trimmed.is_empty() {
        return trimmed.to_string();
    }
    if options.target_os == "windows" {
        "bash.exe".to_string()
    } else {
        "bash".to_string()
    }
}

fn write_script(session_id: &str, script_name: &str, script: &str) -> Result<PathBuf, String> {
    let dir = std::env::temp_dir().join("sharrd").join(session_id);
    fs::create_dir_all(&dir).map_err(|err| format!("Failed to create launch directory: {err}"))?;
    let path = dir.join(script_name);
    fs::write(&path, script).map_err(|err| format!("Failed to write launch script: {err}"))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&path)
            .map_err(|err| format!("Failed to read launch script permissions: {err}"))?
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions)
            .map_err(|err| format!("Failed to make launch script executable: {err}"))?;
    }

    Ok(path)
}

fn stream_output<R>(app: tauri::AppHandle, session_id: String, stream: &str, reader: R)
where
    R: std::io::Read + Send + 'static,
{
    let stream_name = stream.to_string();
    thread::spawn(move || {
        let reader = BufReader::new(reader);
        for line in reader.lines() {
            match line {
                Ok(line) => {
                    let _ = app.emit(
                        "session-log",
                        LogEvent {
                            session_id: session_id.clone(),
                            stream: stream_name.clone(),
                            line,
                        },
                    );
                }
                Err(err) => {
                    let _ = app.emit(
                        "session-log",
                        LogEvent {
                            session_id: session_id.clone(),
                            stream: "system".to_string(),
                            line: format!("Failed to read {stream_name}: {err}"),
                        },
                    );
                    break;
                }
            }
        }
    });
}

fn stop_pid(pid: u32) -> Result<(), String> {
    #[cfg(windows)]
    let status = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .status();

    #[cfg(not(windows))]
    let status = Command::new("kill")
        .args(["-TERM", &format!("-{pid}")])
        .status();

    match status {
        Ok(exit_status) if exit_status.success() => Ok(()),
        Ok(exit_status) => Err(format!("Stop command exited with status {exit_status}.")),
        Err(err) => Err(format!("Failed to stop process {pid}: {err}")),
    }
}

fn new_session_id() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    format!("session-{millis}")
}

fn shell_quote(value: &str) -> String {
    if value.chars().all(|ch| ch.is_ascii_alphanumeric() || "._/:=-".contains(ch)) {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
}

pub fn run() {
    tauri::Builder::default()
        .manage(SessionRegistry::default())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            detect_host,
            build_preview,
            start_session,
            stop_session
        ])
        .setup(|app| {
            let _ = app.handle().emit(
                "session-log",
                LogEvent {
                    session_id: "app".to_string(),
                    stream: "system".to_string(),
                    line: "Sharrd is ready.".to_string(),
                },
            );
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Sharrd");
}
