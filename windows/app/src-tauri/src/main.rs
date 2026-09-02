// Model Compare Studio — Tauri backend.
//
// Spawns the Python engine (engine/model_compare.py), streams its JSONL
// progress events to the frontend, persists settings to a JSON file, and
// stores API keys in the OS credential vault (Windows Credential Manager /
// macOS Keychain).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use tauri::{AppHandle, Emitter, Manager};

const KEYRING_SERVICE: &str = "local.model-compare-studio.vault";
const KEY_NAMES: [&str; 4] = ["meta", "deepseek", "zai", "tavily"];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunRequest {
    prompt: String,
    providers: Vec<String>,
    web_search: bool,
    allow_tools: bool,
    context_file: Option<String>,
    attachments: Vec<String>,
    models: HashMap<String, String>,
    efforts: HashMap<String, String>,
    summary_model: Option<String>,
    summary_model_id: Option<String>,
    summary_effort: Option<String>,
    results_dir: Option<String>,
}

#[derive(Debug, Serialize)]
struct RunStarted {
    pid: u32,
}

enum EngineCmd {
    /// Pre-built executable (PyInstaller bundle) — no Python required.
    Exe(PathBuf),
    /// Python source — needs python3 / py -3 on the system.
    Script(PathBuf),
}

fn resolve_engine_path(app: &AppHandle) -> Result<EngineCmd, String> {
    if let Ok(override_path) = std::env::var("MODEL_COMPARE_ENGINE") {
        let p = PathBuf::from(&override_path);
        if p.exists() {
            return Ok(if p.extension().is_some_and(|e| e == "exe") {
                EngineCmd::Exe(p)
            } else {
                EngineCmd::Script(p)
            });
        }
    }
    // Production: bundled as resources.
    if let Ok(resource_dir) = app.path().resource_dir() {
        let exe = resource_dir.join("engine").join("model_compare.exe");
        if exe.exists() {
            return Ok(EngineCmd::Exe(exe));
        }
        for candidate in [
            resource_dir.join("engine").join("model_compare.py"),
            resource_dir.join("model_compare.py"),
        ] {
            if candidate.exists() {
                return Ok(EngineCmd::Script(candidate));
            }
        }
    }
    // Development: src-tauri/../../engine/model_compare.py.
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("engine")
        .join("model_compare.py");
    if dev.exists() {
        return Ok(EngineCmd::Script(dev));
    }
    Err("engine not found (model_compare.py / model_compare.exe)".to_string())
}

fn python_command() -> Command {
    if cfg!(windows) {
        // The `py` launcher is the most reliable entry point on Windows.
        match Command::new("py").arg("-3").arg("--version").output() {
            Ok(out) if out.status.success() => {
                let mut cmd = Command::new("py");
                cmd.arg("-3");
                return cmd;
            }
            _ => {}
        }
    }
    Command::new("python3")
}

fn load_vault_keys() -> HashMap<String, String> {
    let mut map = HashMap::new();
    for name in KEY_NAMES {
        if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, name) {
            if let Ok(secret) = entry.get_password() {
                map.insert(name.to_string(), secret);
            }
        }
    }
    map
}

#[tauri::command]
fn run_comparison(app: AppHandle, window: tauri::Window, request: RunRequest) -> Result<RunStarted, String> {
    let engine = resolve_engine_path(&app)?;

    let mut cmd = match &engine {
        EngineCmd::Exe(path) => Command::new(path),
        EngineCmd::Script(path) => {
            let mut c = python_command();
            c.arg(path);
            c
        }
    };
    cmd.arg(&request.prompt)
        .arg(if request.web_search { "--web-search" } else { "--no-web-search" });

    if request.allow_tools {
        cmd.arg("--allow-tools");
    }
    for provider in &request.providers {
        cmd.arg("--provider").arg(provider);
    }
    for (key, model) in &request.models {
        if !model.is_empty() && model != "Default" {
            cmd.arg(format!("--{key}-model")).arg(model);
        }
    }
    for (key, effort) in &request.efforts {
        if !effort.is_empty() && effort != "Default" && effort != "default" {
            cmd.arg(format!("--{key}-effort")).arg(effort);
        }
    }
    if let Some(summary_model) = &request.summary_model {
        if !summary_model.is_empty() {
            cmd.arg("--summary-model").arg(summary_model);
            if let Some(id) = &request.summary_model_id {
                if !id.is_empty() && id != "Default" {
                    cmd.arg("--summary-model-id").arg(id);
                }
            }
            if let Some(effort) = &request.summary_effort {
                if !effort.is_empty() && effort != "Default" {
                    cmd.arg("--summary-effort").arg(effort);
                }
            }
        }
    }
    if let Some(context_file) = &request.context_file {
        if !context_file.is_empty() {
            cmd.arg("--context-file").arg(context_file);
        }
    }
    for attachment in &request.attachments {
        cmd.arg("--attachment").arg(attachment);
    }
    if let Some(results_dir) = &request.results_dir {
        if !results_dir.is_empty() {
            cmd.arg("--results-dir").arg(results_dir);
        }
    }

    // Inject API keys from the OS vault into the child environment only.
    let vault = load_vault_keys();
    if let Some(v) = vault.get("meta") {
        cmd.env("META_API_KEY", v);
    }
    if let Some(v) = vault.get("deepseek") {
        cmd.env("DEEPSEEK_API_KEY", v);
    }
    if let Some(v) = vault.get("zai") {
        cmd.env("ZAI_API_KEY", v);
    }
    if let Some(v) = vault.get("tavily") {
        cmd.env("TAVILY_API_KEY", v);
    }

    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to launch engine: {e}"))?;
    let pid = child.id();

    let stdout = child.stdout.take().ok_or("no stdout on engine process")?;
    let stderr = child.stderr.take().ok_or("no stderr on engine process")?;

    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            match line {
                Ok(text) => {
                    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
                        let _ = window.emit("engine-event", json);
                    } else if !text.trim().is_empty() {
                        let _ = window.emit(
                            "engine-event",
                            serde_json::json!({"event": "log", "message": text}),
                        );
                    }
                }
                Err(_) => break,
            }
        }
        let status = child.wait();
        let ok = matches!(status, Ok(s) if s.success());
        let _ = window.emit(
            "engine-event",
            serde_json::json!({"event": "engine_exit", "success": ok}),
        );
    });

    // Drain stderr in the background so the child never blocks on a full pipe.
    std::thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for line in reader.lines().map_while(Result::ok) {
            eprintln!("[engine stderr] {line}");
        }
    });

    Ok(RunStarted { pid })
}

#[tauri::command]
fn cancel_provider(results_dir: String, provider: String) -> Result<(), String> {
    let marker = PathBuf::from(&results_dir).join(format!(".stop-waiting-{provider}"));
    std::fs::write(&marker, b"").map_err(|e| format!("could not write marker: {e}"))
}

#[tauri::command]
fn read_result_file(results_dir: String, name: String) -> Result<String, String> {
    let path = PathBuf::from(&results_dir).join(&name);
    if name.contains("..") || name.contains('/') || name.contains('\\') {
        return Err("invalid file name".to_string());
    }
    std::fs::read_to_string(&path).map_err(|e| format!("could not read {name}: {e}"))
}

#[tauri::command]
fn load_settings(app: AppHandle) -> Result<String, String> {
    let dir = app
        .path()
        .app_config_dir()
        .map_err(|e| format!("no config dir: {e}"))?;
    let path = dir.join("settings.json");
    match std::fs::read_to_string(&path) {
        Ok(text) => Ok(text),
        Err(_) => Ok("{}".to_string()),
    }
}

#[tauri::command]
fn save_settings(app: AppHandle, settings: String) -> Result<(), String> {
    let dir = app
        .path()
        .app_config_dir()
        .map_err(|e| format!("no config dir: {e}"))?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("could not create config dir: {e}"))?;
    std::fs::write(dir.join("settings.json"), settings)
        .map_err(|e| format!("could not save settings: {e}"))
}

#[tauri::command]
fn set_api_key(name: String, value: String) -> Result<(), String> {
    if !KEY_NAMES.contains(&name.as_str()) {
        return Err(format!("unknown key name: {name}"));
    }
    let entry = keyring::Entry::new(KEYRING_SERVICE, &name)
        .map_err(|e| format!("keyring error: {e}"))?;
    if value.is_empty() {
        let _ = entry.delete_credential();
        Ok(())
    } else {
        entry
            .set_password(&value)
            .map_err(|e| format!("could not store key: {e}"))
    }
}

#[tauri::command]
fn has_api_keys() -> HashMap<String, bool> {
    let vault = load_vault_keys();
    KEY_NAMES
        .iter()
        .map(|name| (name.to_string(), vault.contains_key(*name)))
        .collect()
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            run_comparison,
            cancel_provider,
            read_result_file,
            load_settings,
            save_settings,
            set_api_key,
            has_api_keys,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Model Compare Studio");
}
