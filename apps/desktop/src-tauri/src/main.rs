#![windows_subsystem = "windows"]

use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use std::{
    env,
    ffi::OsStr,
    fs::{self, OpenOptions},
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs},
    path::{Path, PathBuf},
    process::Command,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, OnceLock,
    },
    thread::sleep,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{
    AppHandle, Manager, PhysicalPosition, PhysicalSize, Position, Runtime, Size, Url, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, Window, WindowEvent,
};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

static LOG_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static BACKEND_ACTION_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static CLOSE_CONFIRM_ACTIVE: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
struct PrerequisiteStatus {
    docker_installed: bool,
    docker_detail: String,
    lmstudio_detected: bool,
    lmstudio_detail: String,
}

#[derive(Serialize)]
struct BackendStatus {
    ok: bool,
    detail: String,
    app_url: String,
    lan_enabled: bool,
    services_ok: bool,
    http_ok: bool,
    search_ready: bool,
}

#[derive(Serialize)]
struct ExportSettings {
    export_dir: String,
}

#[derive(Deserialize)]
struct ExportSessionPayload {
    filename: String,
    xml: String,
}

#[derive(Serialize, Deserialize)]
struct PersistedWindowState {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    maximized: bool,
}

const MIN_MAIN_WINDOW_WIDTH: u32 = 1100;
const MIN_MAIN_WINDOW_HEIGHT: u32 = 720;

fn hidden_command(program: impl AsRef<OsStr>) -> Command {
    let mut command = Command::new(program);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

fn repo_root() -> Result<PathBuf, String> {
    if let Ok(path) = env::var("HYPERSEARCH_RUNTIME_ROOT") {
        if !path.trim().is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| "Unable to resolve repository root".to_string())
}

fn hypersearch_data_root() -> Result<PathBuf, String> {
    let local_app_data =
        env::var("LOCALAPPDATA").map_err(|_| "LOCALAPPDATA is not available".to_string())?;
    Ok(PathBuf::from(local_app_data).join("HyperSearch"))
}

fn window_state_path() -> Result<PathBuf, String> {
    Ok(hypersearch_data_root()?.join("window-state.json"))
}

fn save_main_window_state<R: Runtime>(window: &Window<R>) {
    let Ok(position) = window.outer_position() else {
        return;
    };
    let Ok(size) = window.outer_size() else {
        return;
    };
    let maximized = window.is_maximized().unwrap_or(false);
    let state = PersistedWindowState {
        x: position.x,
        y: position.y,
        width: size.width.max(MIN_MAIN_WINDOW_WIDTH),
        height: size.height.max(MIN_MAIN_WINDOW_HEIGHT),
        maximized,
    };
    let Ok(path) = window_state_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    match serde_json::to_string_pretty(&state) {
        Ok(contents) => {
            if let Err(error) = fs::write(&path, contents) {
                log_desktop_event("window.state.save_error", error.to_string());
            } else {
                log_desktop_event(
                    "window.state.saved",
                    format!(
                        "x={} y={} width={} height={} maximized={}",
                        state.x, state.y, state.width, state.height, state.maximized
                    ),
                );
            }
        }
        Err(error) => log_desktop_event("window.state.serialize_error", error.to_string()),
    }
}

fn restore_main_window_state<R: Runtime>(window: &WebviewWindow<R>) {
    let Ok(path) = window_state_path() else {
        return;
    };
    let Ok(contents) = fs::read_to_string(&path) else {
        return;
    };
    let Ok(state) = serde_json::from_str::<PersistedWindowState>(&contents) else {
        log_desktop_event(
            "window.state.restore_error",
            format!("unable to parse {}", path.display()),
        );
        return;
    };
    let width = state.width.max(MIN_MAIN_WINDOW_WIDTH);
    let height = state.height.max(MIN_MAIN_WINDOW_HEIGHT);
    if let Err(error) = window.set_size(Size::Physical(PhysicalSize { width, height })) {
        log_desktop_event("window.state.restore_size_error", error.to_string());
    }
    if let Err(error) = window.set_position(Position::Physical(PhysicalPosition {
        x: state.x,
        y: state.y,
    })) {
        log_desktop_event("window.state.restore_position_error", error.to_string());
    }
    if state.maximized {
        if let Err(error) = window.maximize() {
            log_desktop_event("window.state.restore_maximize_error", error.to_string());
        }
    }
    log_desktop_event(
        "window.state.restored",
        format!(
            "x={} y={} width={} height={} maximized={}",
            state.x, state.y, width, height, state.maximized
        ),
    );
}

fn truncate_log(value: &str, limit: usize) -> String {
    let normalized = value.replace('\r', "");
    if normalized.len() <= limit {
        return normalized;
    }
    let mut clipped = String::new();
    for character in normalized.chars() {
        if clipped.len() + character.len_utf8() > limit {
            break;
        }
        clipped.push(character);
    }
    format!(
        "{}...<truncated {} bytes>",
        clipped,
        normalized.len().saturating_sub(clipped.len())
    )
}

fn utc_date_parts(days_since_epoch: i64) -> (i64, i64, i64) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m, d)
}

fn utc_timestamp_parts() -> (String, u64) {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = duration.as_secs() as i64;
    let millis = duration.as_millis() as u64;
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = utc_date_parts(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    (
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z"),
        millis,
    )
}

fn safe_log_slug(value: &str) -> String {
    let mut slug = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
        } else if matches!(ch, '-' | '_' | '.') {
            slug.push(ch);
        } else if ch.is_whitespace() && !slug.ends_with('-') {
            slug.push('-');
        }
        if slug.len() >= 80 {
            break;
        }
    }
    let trimmed = slug.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "command".to_string()
    } else {
        trimmed
    }
}

fn log_desktop_event(event: &str, detail: impl AsRef<str>) {
    let Ok(root) = hypersearch_data_root() else {
        return;
    };
    let dir = root.join("logs");
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    let (iso_timestamp, unix_millis) = utc_timestamp_parts();
    let redacted_detail = redact_sensitive_text(detail.as_ref());
    let _guard = LOG_LOCK.get_or_init(|| Mutex::new(())).lock().ok();
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("desktop.log"))
    {
        let _ = writeln!(
            file,
            "[{}] [{}] [{}] {}",
            iso_timestamp,
            unix_millis,
            event,
            redacted_detail
        );
    }
}

fn copy_file_preserving_settings(source: &Path, target: &Path) -> Result<(), String> {
    let file_name = source
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    if target.exists() && matches!(file_name.as_str(), ".env" | "hypersearch.db") {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::copy(source, target).map_err(|error| error.to_string())?;
    Ok(())
}

fn copy_dir_preserving_settings(source: &Path, target: &Path) -> Result<(), String> {
    if !source.exists() {
        return Err(format!("Runtime resource is missing: {}", source.display()));
    }
    fs::create_dir_all(target).map_err(|error| error.to_string())?;
    for entry in fs::read_dir(source).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let source_path = entry.path();
        let file_name = entry.file_name();
        let file_name_text = file_name.to_string_lossy().to_ascii_lowercase();
        if matches!(
            file_name_text.as_str(),
            "node_modules" | "target" | "dist" | "__pycache__" | ".pytest_cache" | ".docker"
        ) {
            continue;
        }
        let target_path = target.join(&file_name);
        if source_path.is_dir() {
            if file_name_text == "data" {
                fs::create_dir_all(&target_path).map_err(|error| error.to_string())?;
                continue;
            }
            copy_dir_preserving_settings(&source_path, &target_path)?;
        } else {
            copy_file_preserving_settings(&source_path, &target_path)?;
        }
    }
    Ok(())
}

fn ensure_runtime_env_files(root: &Path) -> Result<(), String> {
    let root_env = root.join(".env");
    if !root_env.exists() {
        let template = root.join(".env.example");
        if template.exists() {
            fs::copy(&template, &root_env).map_err(|error| error.to_string())?;
            log_desktop_event(
                "runtime.env.create",
                format!("created .env from {}", template.display()),
            );
        } else {
            fs::write(
                &root_env,
                "HYPERSEARCH_ENV=production\nHYPERSEARCH_LAN_ENABLED=false\nHYPERSEARCH_LLM_ENABLED=true\nHYPERSEARCH_PROVIDER_DEFAULT=lmstudio\nHYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234\nHYPERSEARCH_LMSTUDIO_MODEL=qwen2.5-7b-instruct\nCOMPOSE_PROJECT_NAME=hypersearch\nHYPERSEARCH_API_IMAGE=ghcr.io/nacsez/hypersearch-api:1.0.0\nHYPERSEARCH_UI_IMAGE=ghcr.io/nacsez/hypersearch-ui:1.0.0\nHYPERSEARCH_IMAGE_SOURCE=online\n",
            )
            .map_err(|error| error.to_string())?;
            log_desktop_event("runtime.env.create", "created .env from built-in defaults");
        }
    } else {
        log_desktop_event(
            "runtime.env.preserve",
            format!("preserved {}", root_env.display()),
        );
    }

    let compose_env = root.join("infra").join("docker").join(".env");
    if !compose_env.exists() {
        if let Some(parent) = compose_env.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::write(
            &compose_env,
            "COMPOSE_PROJECT_NAME=hypersearch\nHYPERSEARCH_BIND_HOST=127.0.0.1\nHYPERSEARCH_HTTP_PORT=8090\nHYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234\nHYPERSEARCH_API_IMAGE=ghcr.io/nacsez/hypersearch-api:1.0.0\nHYPERSEARCH_UI_IMAGE=ghcr.io/nacsez/hypersearch-ui:1.0.0\nHYPERSEARCH_CADDY_IMAGE=caddy:2.11.2-alpine\nHYPERSEARCH_VALKEY_IMAGE=valkey/valkey:8.1.6-alpine\nHYPERSEARCH_SEARXNG_IMAGE=searxng/searxng:2026.4.13-ee66b070a\n",
        )
        .map_err(|error| error.to_string())?;
        log_desktop_event(
            "runtime.compose_env.create",
            format!("created {}", compose_env.display()),
        );
    } else {
        log_desktop_event(
            "runtime.compose_env.preserve",
            format!("preserved {}", compose_env.display()),
        );
    }
    set_env_value(&root_env, "HYPERSEARCH_ENV", "production")?;
    set_env_minimum_int(&root_env, "HYPERSEARCH_PROVIDER_TIMEOUT_MS", 180000)?;
    set_env_minimum_int(&root_env, "HYPERSEARCH_MAX_TIMEOUT_MS", 600000)?;
    set_env_value(&root_env, "COMPOSE_PROJECT_NAME", "hypersearch")?;
    set_env_default(
        &root_env,
        "HYPERSEARCH_API_IMAGE",
        "ghcr.io/nacsez/hypersearch-api:1.0.0",
    )?;
    set_env_default(
        &root_env,
        "HYPERSEARCH_UI_IMAGE",
        "ghcr.io/nacsez/hypersearch-ui:1.0.0",
    )?;
    set_env_value(&compose_env, "COMPOSE_PROJECT_NAME", "hypersearch")?;
    set_env_default(
        &compose_env,
        "HYPERSEARCH_API_IMAGE",
        "ghcr.io/nacsez/hypersearch-api:1.0.0",
    )?;
    set_env_default(
        &compose_env,
        "HYPERSEARCH_UI_IMAGE",
        "ghcr.io/nacsez/hypersearch-ui:1.0.0",
    )?;
    set_env_value(&compose_env, "HYPERSEARCH_CADDY_IMAGE", "caddy:2.11.2-alpine")?;
    set_env_value(
        &compose_env,
        "HYPERSEARCH_VALKEY_IMAGE",
        "valkey/valkey:8.1.6-alpine",
    )?;
    set_env_value(
        &compose_env,
        "HYPERSEARCH_SEARXNG_IMAGE",
        "searxng/searxng:2026.4.13-ee66b070a",
    )?;
    fs::create_dir_all(root.join("data").join("exports")).map_err(|error| error.to_string())?;
    Ok(())
}

fn apply_install_profile(root: &Path) -> Result<(), String> {
    let profile_path = hypersearch_data_root()?.join("install-profile.env");
    if !profile_path.exists() {
        log_desktop_event(
            "install_profile.skip",
            "install-profile.env was not present",
        );
        return Ok(());
    }
    log_desktop_event(
        "install_profile.apply.start",
        format!("path={}", profile_path.display()),
    );
    let contents = fs::read_to_string(&profile_path).map_err(|error| error.to_string())?;
    for line in contents.lines() {
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        let name = name.trim();
        let value = value.trim();
        if name.is_empty() {
            continue;
        }
        match name {
            "HYPERSEARCH_LMSTUDIO_MODEL"
            | "HYPERSEARCH_LMSTUDIO_BASE_URL"
            | "HYPERSEARCH_PROVIDER_DEFAULT" => {
                set_env_value(&root.join(".env"), name, value)?;
            }
            "HYPERSEARCH_COMPOSE_LMSTUDIO_BASE_URL" => {
                set_env_value(
                    &root.join("infra").join("docker").join(".env"),
                    "HYPERSEARCH_LMSTUDIO_BASE_URL",
                    value,
                )?;
            }
            _ => {}
        }
    }
    log_desktop_event("install_profile.apply.complete", "provider profile applied");
    Ok(())
}

fn prepare_runtime_stack(app: &AppHandle) -> Result<PathBuf, String> {
    log_desktop_event(
        "runtime.prepare.start",
        "preparing HyperSearch runtime stack",
    );
    let data_root = hypersearch_data_root()?;
    let runtime_root = data_root.join("runtime");
    if let Ok(resource_dir) = app.path().resource_dir() {
        let stack_resource = resource_dir.join("hypersearch-stack");
        if stack_resource.exists() {
            log_desktop_event(
                "runtime.copy.resource.start",
                format!(
                    "source={} destination={}",
                    stack_resource.display(),
                    runtime_root.display()
                ),
            );
            copy_dir_preserving_settings(&stack_resource, &runtime_root)?;
            log_desktop_event("runtime.copy.resource.complete", "runtime resource copied");
        }
    }
    if !runtime_root.exists() {
        let development_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .map(Path::to_path_buf)
            .ok_or_else(|| "Unable to resolve development runtime root".to_string())?;
        log_desktop_event(
            "runtime.copy.development.start",
            format!(
                "source={} destination={}",
                development_root.display(),
                runtime_root.display()
            ),
        );
        copy_dir_preserving_settings(&development_root, &runtime_root)?;
        log_desktop_event(
            "runtime.copy.development.complete",
            "development runtime copied",
        );
    }
    ensure_runtime_env_files(&runtime_root)?;
    apply_install_profile(&runtime_root)?;
    env::set_var("HYPERSEARCH_RUNTIME_ROOT", &runtime_root);
    log_desktop_event(
        "runtime.prepare.complete",
        format!("runtime_root={}", runtime_root.display()),
    );
    Ok(runtime_root)
}

fn docker_config_dir(root: &Path) -> Result<PathBuf, String> {
    let path = root.join(".docker");
    fs::create_dir_all(&path).map_err(|error| error.to_string())?;
    Ok(path)
}

fn command_logs_dir() -> Result<PathBuf, String> {
    let dir = hypersearch_data_root()?.join("logs").join("commands");
    fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    Ok(dir)
}

fn write_command_log(
    command_debug: &str,
    status: &str,
    stdout: &str,
    stderr: &str,
    duration: Duration,
) -> Option<PathBuf> {
    let dir = command_logs_dir().ok()?;
    let (timestamp, millis) = utc_timestamp_parts();
    let command_debug = redact_sensitive_text(command_debug);
    let stdout = redact_sensitive_text(stdout);
    let stderr = redact_sensitive_text(stderr);
    let filename = format!(
        "desktop-command-{}-{}-{}.log",
        timestamp.replace(':', "").replace('-', ""),
        millis,
        safe_log_slug(&command_debug)
    );
    let path = dir.join(filename);
    let content = format!(
        "timestamp={timestamp}\nstatus={status}\nduration_ms={}\ncommand={command_debug}\n\n--- stdout ---\n{stdout}\n\n--- stderr ---\n{stderr}\n",
        duration.as_millis()
    );
    fs::write(&path, content).ok()?;
    Some(path)
}

fn run_command(mut command: Command) -> Result<String, String> {
    let command_debug = format!("{:?}", command);
    log_desktop_event("command.start", &command_debug);
    let started = Instant::now();
    let output = command.output().map_err(|error| {
        log_desktop_event(
            "command.spawn_error",
            format!("command={} error={}", command_debug, error),
        );
        error.to_string()
    })?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let duration = started.elapsed();
    let status = output.status.to_string();
    let command_log = write_command_log(&command_debug, &status, &stdout, &stderr, duration)
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_else(|| "<command log unavailable>".to_string());
    if !output.status.success() {
        let redacted_stdout = redact_sensitive_text(&stdout);
        let redacted_stderr = redact_sensitive_text(&stderr);
        log_desktop_event(
            "command.failure",
            format!(
                "command={} status={} duration_ms={} command_log={} stdout={} stderr={}",
                command_debug,
                output.status,
                duration.as_millis(),
                command_log,
                truncate_log(&redacted_stdout, 1600),
                truncate_log(&redacted_stderr, 1600)
            ),
        );
        return Err(format!("{}\n{}", redacted_stdout, redacted_stderr).trim().to_string());
    }
    let redacted_stdout = redact_sensitive_text(&stdout);
    let redacted_stderr = redact_sensitive_text(&stderr);
    log_desktop_event(
        "command.success",
        format!(
            "command={} status={} duration_ms={} command_log={} stdout={} stderr={}",
            command_debug,
            output.status,
            duration.as_millis(),
            command_log,
            truncate_log(&redacted_stdout, 1200),
            truncate_log(&redacted_stderr, 1200)
        ),
    );
    Ok(format!("{}\n{}", redacted_stdout, redacted_stderr).trim().to_string())
}

fn run_docker(root: &Path, args: &[&str]) -> Result<String, String> {
    let mut command = hidden_command("docker");
    command
        .args(args)
        .env("DOCKER_CONFIG", docker_config_dir(root)?);
    run_command(command)
}

fn run_compose(args: &[&str]) -> Result<String, String> {
    let root = repo_root()?;
    let compose_dir = root.join("infra").join("docker");
    let mut command = hidden_command("docker");
    command
        .args([
            "compose",
            "--ansi",
            "never",
            "--project-name",
            "hypersearch",
        ])
        .args(args)
        .current_dir(compose_dir)
        .env("COMPOSE_PROJECT_NAME", "hypersearch")
        .env("DOCKER_CONFIG", docker_config_dir(&root)?);
    run_command(command)
}

fn run_compose_dev(args: &[&str]) -> Result<String, String> {
    let root = repo_root()?;
    let compose_dir = root.join("infra").join("docker");
    let mut command = hidden_command("docker");
    command
        .args([
            "compose",
            "--ansi",
            "never",
            "--project-name",
            "hypersearch",
            "-f",
            "docker-compose.yml",
            "-f",
            "docker-compose.dev.yml",
        ])
        .args(args)
        .current_dir(compose_dir)
        .env("COMPOSE_PROJECT_NAME", "hypersearch")
        .env("DOCKER_CONFIG", docker_config_dir(&root)?);
    run_command(command)
}

fn is_registry_access_error(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "error from registry: denied",
        "pull access denied",
        "repository does not exist",
        "may require 'docker login'",
        "requested access to the resource is denied",
        "unauthorized",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

fn compose_up_with_local_build_fallback() -> Result<String, String> {
    match run_compose(&["up", "-d"]) {
        Ok(output) => Ok(output),
        Err(error) if is_registry_access_error(&error) => {
            log_desktop_event(
                "backend.action.local_build_fallback",
                truncate_log(&error, 1200),
            );
            let fallback = run_compose_dev(&["up", "-d", "--build"])?;
            let root = repo_root()?;
            let root_env = root.join(".env");
            let compose_env = root.join("infra").join("docker").join(".env");
            set_env_value(
                &root_env,
                "HYPERSEARCH_IMAGE_SOURCE",
                "local-build-fallback",
            )?;
            set_env_value(&root_env, "HYPERSEARCH_API_IMAGE", "hypersearch-api:dev")?;
            set_env_value(&root_env, "HYPERSEARCH_UI_IMAGE", "hypersearch-ui:dev")?;
            set_env_value(&compose_env, "HYPERSEARCH_API_IMAGE", "hypersearch-api:dev")?;
            set_env_value(&compose_env, "HYPERSEARCH_UI_IMAGE", "hypersearch-ui:dev")?;
            Ok(format!(
                "Prebuilt image pull failed, so HyperSearch built local runtime images from the bundled source.\n\nPull failure:\n{error}\n\nLocal build fallback:\n{fallback}"
            ))
        }
        Err(error) => Err(error),
    }
}

fn shutdown_stack() -> Result<String, String> {
    log_desktop_event("backend.shutdown.start", "docker compose down requested");
    let result = run_compose(&["down", "--remove-orphans"]);
    match &result {
        Ok(output) => log_desktop_event("backend.shutdown.complete", truncate_log(output, 1200)),
        Err(error) => log_desktop_event("backend.shutdown.error", truncate_log(error, 1200)),
    }
    result
}

fn docker_desktop_exe() -> Option<PathBuf> {
    let candidates = [
        r"C:\Program Files\Docker\Docker\Docker Desktop.exe",
        r"C:\Program Files\Docker\Docker\Docker Desktop Installer.exe",
    ];
    candidates
        .iter()
        .map(PathBuf::from)
        .find(|path| path.exists())
}

fn has_fatal_docker_stderr(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "docker desktop is unable to start",
        "failed to connect to the docker api",
        "request returned 500 internal server error",
        "check if the daemon is running",
        "is the docker daemon running",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

fn is_docker_version_string(value: &str) -> bool {
    let mut parts = value.trim().split('.');
    let Some(major) = parts.next() else {
        return false;
    };
    let Some(minor) = parts.next() else {
        return false;
    };
    major.chars().all(|ch| ch.is_ascii_digit()) && minor.chars().all(|ch| ch.is_ascii_digit())
}

fn docker_info_version(root: &Path) -> Result<String, String> {
    let mut command = hidden_command("docker");
    command
        .args(["info", "--format", "{{.ServerVersion}}"])
        .env("DOCKER_CONFIG", docker_config_dir(root)?);
    let command_debug = format!("{:?}", command);
    log_desktop_event("docker.ready_check.command.start", &command_debug);
    let started = Instant::now();
    let output = command.output().map_err(|error| {
        log_desktop_event(
            "docker.ready_check.command.spawn_error",
            format!("command={} error={}", command_debug, error),
        );
        error.to_string()
    })?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let duration = started.elapsed();
    let status = output.status.to_string();
    let command_log = write_command_log(&command_debug, &status, &stdout, &stderr, duration)
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_else(|| "<command log unavailable>".to_string());
    if !output.status.success()
        || has_fatal_docker_stderr(&stderr)
        || !is_docker_version_string(&stdout)
    {
        let detail = format!(
            "status={} stdout={} stderr={} command_log={}",
            output.status, stdout, stderr, command_log
        );
        log_desktop_event(
            "docker.ready_check.command.not_ready",
            truncate_log(&detail, 1600),
        );
        return Err(detail);
    }
    log_desktop_event(
        "docker.ready_check.command.ready",
        format!(
            "version={} duration_ms={} command_log={}",
            stdout,
            duration.as_millis(),
            command_log
        ),
    );
    Ok(stdout)
}

fn doctor_command(program: &str, args: &[&str], docker_config: Option<&Path>) -> String {
    let mut command = hidden_command(program);
    command.args(args);
    if let Some(config) = docker_config {
        command.env("DOCKER_CONFIG", config);
    }
    match run_command(command) {
        Ok(output) if output.trim().is_empty() => "ok".to_string(),
        Ok(output) => truncate_log(&output, 1000),
        Err(error) => format!("error: {}", truncate_log(&error, 1000)),
    }
}

fn docker_doctor_report(root: &Path, last_error: &str) -> String {
    let mut lines = Vec::new();
    lines.push("Docker doctor findings:".to_string());
    let local_config = match docker_config_dir(root) {
        Ok(path) => {
            let write_test = path.join("hypersearch-write-test.tmp");
            match fs::write(&write_test, "ok").and_then(|_| fs::remove_file(&write_test)) {
                Ok(_) => lines.push(format!(
                    "local DOCKER_CONFIG: writable ({})",
                    path.display()
                )),
                Err(error) => lines.push(format!(
                    "local DOCKER_CONFIG: not writable ({}) - {}. Remediation: give your user write access to this folder or reinstall HyperSearch outside a protected directory.",
                    path.display(),
                    error
                )),
            }
            path
        }
        Err(error) => {
            lines.push(format!(
                "local DOCKER_CONFIG: unavailable - {error}. Remediation: run HyperSearch from a user-writable directory."
            ));
            root.join(".docker")
        }
    };
    if let Ok(profile) = env::var("USERPROFILE") {
        let user_config = PathBuf::from(profile).join(".docker").join("config.json");
        match fs::metadata(&user_config) {
            Ok(_) => match fs::read_to_string(&user_config) {
                Ok(_) => lines.push(format!(
                    "user Docker config: readable ({})",
                    user_config.display()
                )),
                Err(error) => lines.push(format!(
                    "user Docker config: unreadable ({}) - {}. Remediation: repair that file's ACLs or keep using HyperSearch's isolated local .docker config.",
                    user_config.display(),
                    error
                )),
            },
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => lines.push(format!(
                "user Docker config: access denied ({}) - {}. Remediation: repair that file's ACLs or keep using HyperSearch's isolated local .docker config.",
                user_config.display(),
                error
            )),
            Err(_) => lines.push(format!(
                "user Docker config: not present ({})",
                user_config.display()
            )),
        }
    }
    lines.push(format!(
        "docker context: {}",
        doctor_command("docker", &["context", "show"], Some(&local_config))
    ));
    #[cfg(windows)]
    {
        lines.push(format!(
            "Docker Desktop service: {}",
            doctor_command("sc.exe", &["query", "com.docker.service"], None)
        ));
        lines.push(format!(
            "docker-users membership: {}",
            if doctor_command("whoami", &["/groups"], None)
                .to_ascii_lowercase()
                .contains("docker-users")
            {
                "current user appears to be in docker-users"
            } else {
                "current user was not reported in docker-users. Remediation: add this Windows account to the docker-users group, sign out, then sign back in."
            }
        ));
        match fs::metadata(r"\\.\pipe\docker_engine") {
            Ok(_) => lines.push("Docker named pipe: visible".to_string()),
            Err(error) => lines.push(format!(
                "Docker named pipe: not accessible - {}. Remediation: start Docker Desktop, confirm it finished initialization, and verify this user can access the Docker engine pipe.",
                error
            )),
        }
    }
    if last_error.to_ascii_lowercase().contains("npipe") {
        lines.push("classification: named-pipe or Docker engine permission failure".to_string());
    } else if last_error.to_ascii_lowercase().contains("access is denied") {
        lines.push("classification: Docker config or engine access denied".to_string());
    } else if last_error.to_ascii_lowercase().contains("daemon") {
        lines.push("classification: Docker daemon is not ready".to_string());
    } else {
        lines.push("classification: Docker readiness failure".to_string());
    }
    lines.join("\n")
}

fn ensure_docker_ready() -> Result<String, String> {
    log_desktop_event(
        "docker.ready_check.start",
        "checking Docker engine readiness",
    );
    let root = repo_root()?;
    let mut last_error: String;
    match docker_info_version(&root) {
        Ok(version) => {
            log_desktop_event("docker.ready_check.ready", version.trim());
            return Ok(format!("Docker engine ready: {}", version.trim()));
        }
        Err(error) => {
            last_error = error;
        }
    }

    if let Some(exe) = docker_desktop_exe() {
        log_desktop_event(
            "docker.desktop.launch",
            format!("launching {}", exe.display()),
        );
        let _ = hidden_command(exe).spawn();
    }

    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(90) {
        match docker_info_version(&root) {
            Ok(version) => {
                log_desktop_event("docker.ready_check.ready", version.trim());
                return Ok(format!("Docker engine ready: {}", version.trim()));
            }
            Err(error) => {
                last_error = error;
            }
        }
        sleep(Duration::from_secs(3));
    }
    log_desktop_event(
        "docker.ready_check.timeout",
        truncate_log(&last_error, 1600),
    );
    let doctor = docker_doctor_report(&root, &last_error);
    log_desktop_event("docker.ready_check.doctor", &doctor);
    Err(format!(
        "Docker Desktop did not become ready within 90 seconds. Open Docker Desktop and wait for the engine to finish starting, then press Start again.\n\nLast Docker error:\n{}\n\n{}",
        last_error,
        doctor
    ))
}

fn read_env_value(path: &Path, name: &str, default_value: &str) -> String {
    let Ok(contents) = fs::read_to_string(path) else {
        return default_value.to_string();
    };
    contents
        .lines()
        .find_map(|line| line.strip_prefix(&format!("{name}=")))
        .unwrap_or(default_value)
        .trim()
        .to_string()
}

fn set_env_value(path: &Path, name: &str, value: &str) -> Result<(), String> {
    let contents = fs::read_to_string(path).unwrap_or_default();
    let mut found = false;
    let mut lines = Vec::new();
    for line in contents.lines() {
        if line.starts_with(&format!("{name}=")) {
            lines.push(format!("{name}={value}"));
            found = true;
        } else {
            lines.push(line.to_string());
        }
    }
    if !found {
        lines.push(format!("{name}={value}"));
    }
    fs::write(path, format!("{}\n", lines.join("\n"))).map_err(|error| error.to_string())
}

fn set_env_default(path: &Path, name: &str, value: &str) -> Result<(), String> {
    if read_env_value(path, name, "").is_empty() {
        set_env_value(path, name, value)?;
    }
    Ok(())
}

fn set_env_minimum_int(path: &Path, name: &str, minimum: i64) -> Result<(), String> {
    let current = read_env_value(path, name, "");
    let should_update = current
        .parse::<i64>()
        .map(|value| value < minimum)
        .unwrap_or(true);
    if should_update {
        set_env_value(path, name, &minimum.to_string())?;
    }
    Ok(())
}

fn paired_app_url() -> Result<String, String> {
    let root = repo_root()?;
    let compose_env = root.join("infra").join("docker").join(".env");
    let root_env = root.join(".env");
    let bind_host = read_env_value(&compose_env, "HYPERSEARCH_BIND_HOST", "127.0.0.1");
    let launch_host = match bind_host.as_str() {
        "0.0.0.0" | "::" => "127.0.0.1".to_string(),
        value => value.to_string(),
    };
    let http_port = read_env_value(&compose_env, "HYPERSEARCH_HTTP_PORT", "8090");
    let base_url = format!("http://{}:{}/", launch_host, http_port);
    let lan_enabled = read_env_value(&root_env, "HYPERSEARCH_LAN_ENABLED", "false") == "true";
    let token = read_env_value(&root_env, "HYPERSEARCH_PAIRING_TOKEN", "");
    if lan_enabled && !token.is_empty() {
        Ok(format!("{base_url}#hypersearch_token={token}"))
    } else {
        Ok(base_url)
    }
}

fn default_export_dir() -> Result<PathBuf, String> {
    Ok(repo_root()?.join("data").join("exports"))
}

fn export_dir() -> Result<PathBuf, String> {
    let root = repo_root()?;
    let root_env = root.join(".env");
    let configured = read_env_value(&root_env, "HYPERSEARCH_EXPORT_DIR", "");
    if configured.is_empty() {
        return default_export_dir();
    }
    let path = PathBuf::from(configured);
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(root.join(path))
    }
}

fn sanitize_export_filename(value: &str) -> String {
    let mut output = String::new();
    for ch in value.chars() {
        if matches!(ch, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || ch.is_control() {
            output.push('_');
        } else {
            output.push(ch);
        }
    }
    let trimmed = output.trim().trim_matches('.').to_string();
    if trimmed.is_empty() {
        "hypersearch-session.xml".to_string()
    } else if trimmed.to_ascii_lowercase().ends_with(".xml") {
        trimmed
    } else {
        format!("{trimmed}.xml")
    }
}

fn is_sensitive_key(value: &str) -> bool {
    let normalized = value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .replace('-', "_")
        .to_ascii_uppercase();
    normalized.contains("TOKEN")
        || normalized.contains("SECRET")
        || normalized.contains("PASSWORD")
        || normalized.contains("PASSWD")
        || normalized.contains("API_KEY")
        || normalized.contains("ACCESS_KEY")
        || normalized.contains("PRIVATE_KEY")
        || normalized.contains("AUTH")
        || normalized.contains("CREDENTIAL")
}

fn redact_key_value_line(line: &str) -> Option<String> {
    let separator = line.find('=').or_else(|| line.find(':'))?;
    let (left, right) = line.split_at(separator);
    let key = left
        .rsplit([' ', '{', ',', '['])
        .next()
        .unwrap_or(left)
        .trim();
    if !is_sensitive_key(key) {
        return None;
    }
    let separator_char = right.chars().next().unwrap_or('=');
    let suffix = if line.trim_end().ends_with(',') { "," } else { "" };
    Some(format!("{left}{separator_char}<redacted>{suffix}"))
}

fn redact_parameter_value(line: &str, marker: &str) -> String {
    let mut output = String::with_capacity(line.len());
    let mut remaining = line;
    while let Some(index) = remaining.to_ascii_lowercase().find(marker) {
        let (before, after_before) = remaining.split_at(index);
        output.push_str(before);
        output.push_str(marker);
        output.push_str("<redacted>");
        let after_marker = &after_before[marker.len()..];
        let keep_from = after_marker
            .find(['&', ' ', '\t', '\r', '\n', '"', '\''])
            .unwrap_or(after_marker.len());
        remaining = &after_marker[keep_from..];
    }
    output.push_str(remaining);
    output
}

fn redact_bearer_tokens(line: &str) -> String {
    let lower = line.to_ascii_lowercase();
    let Some(index) = lower.find("bearer ") else {
        return line.to_string();
    };
    let mut output = String::from(&line[..index + 7]);
    output.push_str("<redacted>");
    let rest = &line[index + 7..];
    let keep_from = rest
        .find([' ', '\t', '\r', '\n', '"', '\''])
        .unwrap_or(rest.len());
    output.push_str(&rest[keep_from..]);
    output
}

fn redact_sensitive_line(line: &str) -> String {
    if let Some(redacted) = redact_key_value_line(line) {
        return redacted;
    }
    let mut redacted = line.to_string();
    for marker in [
        "hypersearch_token=",
        "pairing_token=",
        "access_token=",
        "refresh_token=",
        "api_key=",
    ] {
        redacted = redact_parameter_value(&redacted, marker);
    }
    redact_bearer_tokens(&redacted)
}

fn redact_sensitive_text(value: &str) -> String {
    value
        .lines()
        .map(redact_sensitive_line)
        .collect::<Vec<_>>()
        .join("\n")
}

fn redact_env_contents(value: &str) -> String {
    redact_sensitive_text(value)
}

fn copy_diagnostics_tree(source: &Path, target: &Path) -> Result<(), String> {
    if !source.exists() {
        return Ok(());
    }
    fs::create_dir_all(target).map_err(|error| error.to_string())?;
    for entry in fs::read_dir(source).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let source_path = entry.path();
        let target_path = target.join(entry.file_name());
        if source_path.is_dir() {
            copy_diagnostics_tree(&source_path, &target_path)?;
        } else if source_path.is_file() {
            let extension = source_path
                .extension()
                .and_then(OsStr::to_str)
                .unwrap_or_default()
                .to_ascii_lowercase();
            if matches!(extension.as_str(), "log" | "txt" | "json" | "env" | "yaml" | "yml") {
                match fs::read_to_string(&source_path) {
                    Ok(contents) => fs::write(&target_path, redact_sensitive_text(&contents))
                        .map_err(|error| error.to_string())?,
                    Err(_) => {
                        fs::copy(&source_path, &target_path)
                            .map_err(|error| error.to_string())?;
                    }
                }
            } else {
                fs::copy(&source_path, &target_path).map_err(|error| error.to_string())?;
            }
        }
    }
    Ok(())
}

fn write_diagnostics_command(target: &Path, filename: &str, output: Result<String, String>) {
    let body = match output {
        Ok(text) => format!("status=success\n\n{text}\n"),
        Err(error) => format!("status=error\n\n{error}\n"),
    };
    let _ = fs::write(target.join(filename), redact_sensitive_text(&body));
}

fn export_diagnostics_sync() -> Result<String, String> {
    log_desktop_event("diagnostics.export.start", "collecting diagnostics bundle");
    let data_root = hypersearch_data_root()?;
    let (timestamp, _) = utc_timestamp_parts();
    let target = data_root.join("diagnostics").join(format!(
        "hypersearch-diagnostics-{}",
        timestamp.replace(':', "").replace('-', "")
    ));
    fs::create_dir_all(&target).map_err(|error| error.to_string())?;

    let root = repo_root()?;
    let env_path = root.join(".env");
    if let Ok(contents) = fs::read_to_string(&env_path) {
        fs::write(
            target.join("env.redacted.txt"),
            redact_env_contents(&contents),
        )
        .map_err(|error| error.to_string())?;
    }
    let compose_env = root.join("infra").join("docker").join(".env");
    if let Ok(contents) = fs::read_to_string(&compose_env) {
        fs::write(
            target.join("compose-env.redacted.txt"),
            redact_env_contents(&contents),
        )
        .map_err(|error| error.to_string())?;
    }

    write_diagnostics_command(
        &target,
        "docker-version.txt",
        run_docker(&root, &["--version"]),
    );
    write_diagnostics_command(&target, "docker-info.txt", run_docker(&root, &["info"]));
    write_diagnostics_command(&target, "docker-images.txt", run_docker(&root, &["images"]));
    write_diagnostics_command(&target, "compose-config.txt", run_compose(&["config"]));
    write_diagnostics_command(&target, "compose-ps.txt", run_compose(&["ps"]));
    write_diagnostics_command(
        &target,
        "compose-logs.txt",
        run_compose(&["logs", "--tail", "260"]),
    );
    let logs_dir = data_root.join("logs");
    copy_diagnostics_tree(&logs_dir, &target.join("logs"))?;
    fs::write(
        target.join("README.txt"),
        "HyperSearch diagnostics bundle. Token, key, password, auth, and credential values are redacted from env files, compose output, copied command logs, and desktop logs.\n",
    )
    .map_err(|error| error.to_string())?;
    log_desktop_event(
        "diagnostics.export.complete",
        format!("path={}", target.display()),
    );
    Ok(target.to_string_lossy().to_string())
}

fn confirm_shutdown() -> bool {
    let script = r#"
Add-Type -AssemblyName System.Windows.Forms
$result = [System.Windows.Forms.MessageBox]::Show(
  'Closing HyperSearch will stop the local Docker stack and close all HyperSearch sessions. Continue?',
  'Close HyperSearch',
  [System.Windows.Forms.MessageBoxButtons]::YesNo,
  [System.Windows.Forms.MessageBoxIcon]::Warning
)
Write-Output $result
"#;
    let mut command = hidden_command("powershell");
    command.args([
        "-NoProfile",
        "-Sta",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
    ]);
    run_command(command)
        .map(|output| output.contains("Yes"))
        .unwrap_or(false)
}

fn check_prerequisites_sync() -> PrerequisiteStatus {
    log_desktop_event("prereq.check.start", "checking Docker and LM Studio");
    let docker = hidden_command("docker").arg("--version").output();
    let (docker_installed, docker_detail) = match docker {
        Ok(output) if output.status.success() => (
            true,
            String::from_utf8_lossy(&output.stdout).trim().to_string(),
        ),
        Ok(output) => (
            false,
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ),
        Err(error) => (false, error.to_string()),
    };
    let lmstudio_paths = [
        r"C:\Program Files\LM Studio\LM Studio.exe",
        r"C:\Users\%USERNAME%\AppData\Local\Programs\LM Studio\LM Studio.exe",
    ];
    let expanded_paths: Vec<String> = lmstudio_paths
        .iter()
        .map(|path| path.replace("%USERNAME%", &std::env::var("USERNAME").unwrap_or_default()))
        .collect();
    let lmstudio_path = expanded_paths.iter().find(|path| Path::new(path).exists());
    let status = PrerequisiteStatus {
        docker_installed,
        docker_detail,
        lmstudio_detected: lmstudio_path.is_some(),
        lmstudio_detail: lmstudio_path.cloned().unwrap_or_else(|| {
            "Install LM Studio and enable its local server for research synthesis.".to_string()
        }),
    };
    log_desktop_event(
        "prereq.check.complete",
        format!(
            "docker_installed={} docker_detail={} lmstudio_detected={} lmstudio_detail={}",
            status.docker_installed,
            truncate_log(&status.docker_detail, 500),
            status.lmstudio_detected,
            truncate_log(&status.lmstudio_detail, 500)
        ),
    );
    status
}

fn backend_action_sync(action: String) -> Result<String, String> {
    let _action_guard = BACKEND_ACTION_LOCK
        .get_or_init(|| Mutex::new(()))
        .try_lock()
        .map_err(|_| "Another HyperSearch backend action is already running. Wait for it to finish, then retry.".to_string())?;
    log_desktop_event("backend.action.start", format!("action={}", action));
    match action.as_str() {
        "up" => {
            let docker = ensure_docker_ready()?;
            let output = compose_up_with_local_build_fallback()?;
            let result = format!("{docker}\n{output}");
            log_desktop_event("backend.action.complete", truncate_log(&result, 1200));
            Ok(result)
        }
        "down" => {
            let result = shutdown_stack();
            match &result {
                Ok(output) => {
                    log_desktop_event("backend.action.complete", truncate_log(output, 1200))
                }
                Err(error) => log_desktop_event("backend.action.error", truncate_log(error, 1200)),
            }
            result
        }
        "restart" => {
            let docker = ensure_docker_ready()?;
            let down = run_compose(&["down", "--remove-orphans"]).unwrap_or_default();
            let up = compose_up_with_local_build_fallback()?;
            let result = format!("{docker}\n{down}\n{up}");
            log_desktop_event("backend.action.complete", truncate_log(&result, 1200));
            Ok(result)
        }
        _ => {
            log_desktop_event("backend.action.error", "Unsupported backend action");
            Err("Unsupported backend action".to_string())
        }
    }
}

fn backend_logs_sync() -> Result<String, String> {
    log_desktop_event("backend.logs.start", "docker compose logs requested");
    let result = run_compose(&["logs", "--tail", "160"]);
    match &result {
        Ok(output) => log_desktop_event("backend.logs.complete", truncate_log(output, 1200)),
        Err(error) => log_desktop_event("backend.logs.error", truncate_log(error, 1200)),
    }
    result
}

#[derive(Debug)]
struct ComposeServiceState {
    service: String,
    state: String,
    health: String,
}

fn json_field(value: &serde_json::Value, keys: &[&str]) -> String {
    for key in keys {
        if let Some(text) = value.get(*key).and_then(serde_json::Value::as_str) {
            return text.to_string();
        }
    }
    String::new()
}

fn parse_compose_ps_json(output: &str) -> Result<Vec<ComposeServiceState>, String> {
    let trimmed = output.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let values = if trimmed.starts_with('[') {
        match serde_json::from_str::<serde_json::Value>(trimmed)
            .map_err(|error| format!("Unable to parse docker compose ps JSON: {error}"))?
        {
            serde_json::Value::Array(items) => items,
            value => vec![value],
        }
    } else {
        let mut items = Vec::new();
        for line in trimmed.lines().filter(|line| !line.trim().is_empty()) {
            items.push(
                serde_json::from_str::<serde_json::Value>(line)
                    .map_err(|error| format!("Unable to parse docker compose ps JSON line: {error}; line={line}"))?,
            );
        }
        items
    };
    Ok(values
        .iter()
        .map(|value| ComposeServiceState {
            service: json_field(value, &["Service", "service", "Name", "name"]),
            state: json_field(value, &["State", "state"]),
            health: json_field(value, &["Health", "health"]),
        })
        .collect())
}

fn compose_services_report(services: &[ComposeServiceState]) -> (bool, String) {
    let required = ["api", "ui", "caddy", "searxng", "valkey"];
    let mut ok = true;
    let mut lines = Vec::new();
    for service_name in required {
        let Some(service) = services.iter().find(|item| item.service == service_name || item.service.ends_with(&format!("-{service_name}-1"))) else {
            ok = false;
            lines.push(format!("{service_name}: missing"));
            continue;
        };
        let state_ok = service.state.to_ascii_lowercase().contains("running");
        let health_ok = service.health.trim().is_empty()
            || service.health.eq_ignore_ascii_case("healthy")
            || service.health.eq_ignore_ascii_case("none");
        if !state_ok || !health_ok {
            ok = false;
        }
        lines.push(format!(
            "{}: state={} health={}",
            service_name,
            if service.state.is_empty() { "unknown" } else { &service.state },
            if service.health.is_empty() { "not-declared" } else { &service.health }
        ));
    }
    (ok, lines.join("\n"))
}

fn http_probe(base_url: &str, path: &str) -> Result<String, String> {
    let parsed = Url::parse(base_url).map_err(|error| error.to_string())?;
    let host = parsed
        .host_str()
        .ok_or_else(|| "App URL has no host".to_string())?;
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| "App URL has no port".to_string())?;
    let address = (host, port)
        .to_socket_addrs()
        .map_err(|error| error.to_string())?
        .next()
        .ok_or_else(|| "App URL host did not resolve".to_string())?;
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))
        .map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(4)))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| error.to_string())?;
    let host_header = if parsed.port().is_some() {
        format!("{host}:{port}")
    } else {
        host.to_string()
    };
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host_header}\r\nConnection: close\r\nUser-Agent: HyperSearchDesktop/1.0\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|error| error.to_string())?;
    let status_line = response.lines().next().unwrap_or_default().to_string();
    if status_line.contains(" 200 ") {
        Ok(status_line)
    } else {
        Err(if status_line.is_empty() {
            "No HTTP response".to_string()
        } else {
            status_line
        })
    }
}

fn backend_status_sync() -> Result<BackendStatus, String> {
    log_desktop_event("backend.status.start", "docker compose ps requested");
    let root = repo_root()?;
    let root_env = root.join(".env");
    let lan_enabled = read_env_value(&root_env, "HYPERSEARCH_LAN_ENABLED", "false") == "true";
    let app_url = paired_app_url()?;
    let status = run_compose(&["ps", "--format", "json"]);
    let (services_ok, service_detail) = match &status {
        Ok(output) => match parse_compose_ps_json(output) {
            Ok(services) => compose_services_report(&services),
            Err(error) => (false, error),
        },
        Err(error) => (false, error.clone()),
    };
    let live_probe = http_probe(&app_url, "/v1/live");
    let ready_probe = http_probe(&app_url, "/v1/ready");
    let http_ok = live_probe.is_ok();
    let search_ready = ready_probe.is_ok();
    let detail = format!(
        "compose_services_ok={services_ok}\n{service_detail}\n\nhttp_live={}\nhttp_ready={}",
        live_probe.unwrap_or_else(|error| format!("error: {error}")),
        ready_probe.unwrap_or_else(|error| format!("error: {error}"))
    );
    let backend_status = BackendStatus {
        ok: services_ok && http_ok && search_ready,
        detail,
        app_url,
        lan_enabled,
        services_ok,
        http_ok,
        search_ready,
    };
    log_desktop_event(
        "backend.status.complete",
        format!(
            "ok={} lan_enabled={} detail={}",
            backend_status.ok,
            backend_status.lan_enabled,
            truncate_log(&backend_status.detail, 1200)
        ),
    );
    Ok(backend_status)
}

fn set_lan_mode_sync(enabled: bool) -> Result<String, String> {
    log_desktop_event("lan.set.start", format!("enabled={}", enabled));
    let root = repo_root()?;
    let compose_env = root.join("infra").join("docker").join(".env");
    let root_env = root.join(".env");
    let token: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(40)
        .map(char::from)
        .collect();
    set_env_value(
        &compose_env,
        "HYPERSEARCH_BIND_HOST",
        if enabled { "0.0.0.0" } else { "127.0.0.1" },
    )?;
    set_env_value(
        &root_env,
        "HYPERSEARCH_LAN_ENABLED",
        if enabled { "true" } else { "false" },
    )?;
    set_env_value(
        &root_env,
        "HYPERSEARCH_PAIRING_TOKEN",
        if enabled { &token } else { "" },
    )?;
    log_desktop_event("lan.set.complete", format!("enabled={}", enabled));
    Ok(if enabled { token } else { String::new() })
}

fn open_console_sync() -> Result<(), String> {
    log_desktop_event(
        "console.browser.open",
        "opening HyperSearch in external browser",
    );
    hidden_command("cmd")
        .args(["/C", "start", "", &paired_app_url()?])
        .spawn()
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn local_help_path() -> Result<PathBuf, String> {
    let root = repo_root()?;
    let built_help = root
        .join("apps")
        .join("ui")
        .join("dist")
        .join("help")
        .join("index.html");
    if built_help.exists() {
        return Ok(built_help);
    }
    let source_help = root
        .join("apps")
        .join("ui")
        .join("public")
        .join("help")
        .join("index.html");
    if source_help.exists() {
        return Ok(source_help);
    }
    Err("Unable to find the bundled HyperSearch help file.".to_string())
}

fn open_local_help_sync() -> Result<(), String> {
    let path = local_help_path()?;
    log_desktop_event("help.open_local", format!("path={}", path.display()));
    let mut command = hidden_command("cmd");
    command.args(["/C", "start", ""]).arg(path);
    command.spawn().map_err(|error| error.to_string())?;
    Ok(())
}

#[tauri::command]
async fn check_prerequisites() -> PrerequisiteStatus {
    tauri::async_runtime::spawn_blocking(check_prerequisites_sync)
        .await
        .unwrap_or_else(|error| PrerequisiteStatus {
            docker_installed: false,
            docker_detail: error.to_string(),
            lmstudio_detected: false,
            lmstudio_detail: "Unable to inspect prerequisites.".to_string(),
        })
}

#[tauri::command]
async fn backend_action(action: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || backend_action_sync(action))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn backend_logs() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(backend_logs_sync)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn backend_status() -> Result<BackendStatus, String> {
    tauri::async_runtime::spawn_blocking(backend_status_sync)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn set_lan_mode(enabled: bool) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || set_lan_mode_sync(enabled))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn open_console() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(open_console_sync)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn open_local_help() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(open_local_help_sync)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn get_export_settings() -> Result<ExportSettings, String> {
    tauri::async_runtime::spawn_blocking(|| {
        Ok(ExportSettings {
            export_dir: export_dir()?.to_string_lossy().to_string(),
        })
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn set_export_dir(path: String) -> Result<ExportSettings, String> {
    tauri::async_runtime::spawn_blocking(move || {
        log_desktop_event("settings.export_dir.set.start", format!("path={}", path));
        let root = repo_root()?;
        let root_env = root.join(".env");
        let resolved = if path.trim().is_empty() {
            default_export_dir()?
        } else {
            PathBuf::from(path.trim())
        };
        fs::create_dir_all(&resolved).map_err(|error| error.to_string())?;
        set_env_value(
            &root_env,
            "HYPERSEARCH_EXPORT_DIR",
            &resolved.to_string_lossy(),
        )?;
        log_desktop_event(
            "settings.export_dir.set.complete",
            format!("resolved={}", resolved.display()),
        );
        Ok(ExportSettings {
            export_dir: resolved.to_string_lossy().to_string(),
        })
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn export_session_xml(payload: ExportSessionPayload) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        log_desktop_event(
            "session.export_xml.start",
            format!("filename={}", payload.filename),
        );
        let dir = export_dir()?;
        fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
        let filename = sanitize_export_filename(&payload.filename);
        let path = dir.join(filename);
        fs::write(&path, payload.xml).map_err(|error| error.to_string())?;
        log_desktop_event(
            "session.export_xml.complete",
            format!("path={}", path.display()),
        );
        Ok(path.to_string_lossy().to_string())
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn export_diagnostics() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(export_diagnostics_sync)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
fn open_console_window(app: AppHandle) -> Result<String, String> {
    let url = paired_app_url()?;
    let label = format!(
        "hypersearch-session-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|error| error.to_string())?
            .as_millis()
    );
    WebviewWindowBuilder::new(
        &app,
        label.clone(),
        WebviewUrl::External(Url::parse(&url).map_err(|error| error.to_string())?),
    )
    .title("HyperSearch Session")
    .inner_size(1280.0, 860.0)
    .min_inner_size(1100.0, 720.0)
    .build()
    .map_err(|error| error.to_string())?;
    log_desktop_event(
        "console.webview.open",
        format!("label={} paired_url_created=true", label),
    );
    Ok(label)
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            log_desktop_event("app.setup.start", "HyperSearch desktop starting");
            if let Err(error) = prepare_runtime_stack(&app.handle()) {
                log_desktop_event("app.setup.error", &error);
                eprintln!("HyperSearch runtime setup failed: {error}");
            } else {
                log_desktop_event("app.setup.complete", "runtime stack prepared");
            }
            if let Some(window) = app.get_webview_window("main") {
                restore_main_window_state(&window);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            backend_action,
            backend_logs,
            backend_status,
            check_prerequisites,
            export_diagnostics,
            export_session_xml,
            get_export_settings,
            open_console,
            open_console_window,
            open_local_help,
            set_export_dir,
            set_lan_mode
        ])
        .on_window_event(|window, event| {
            if window.label() != "main" {
                return;
            }
            if let WindowEvent::CloseRequested { api, .. } = event {
                save_main_window_state(window);
                api.prevent_close();
                if CLOSE_CONFIRM_ACTIVE.swap(true, Ordering::SeqCst) {
                    log_desktop_event(
                        "app.close.duplicate",
                        "close request ignored because confirmation is already active",
                    );
                    return;
                }
                let app = window.app_handle().clone();
                std::thread::spawn(move || {
                    if confirm_shutdown() {
                        log_desktop_event("app.close.confirmed", "closing HyperSearch desktop");
                        let _guard = BACKEND_ACTION_LOCK
                            .get_or_init(|| Mutex::new(()))
                            .lock()
                            .ok();
                        let _ = shutdown_stack();
                        app.exit(0);
                    } else {
                        log_desktop_event("app.close.cancelled", "close request cancelled");
                        CLOSE_CONFIRM_ACTIVE.store(false, Ordering::SeqCst);
                    }
                });
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running HyperSearch desktop app");
}

#[cfg(test)]
mod tests {
    use super::redact_sensitive_text;

    #[test]
    fn redacts_secret_bearing_lines_and_url_tokens() {
        let input = [
            "HYPERSEARCH_PAIRING_TOKEN=abc123",
            "normal=value",
            "url=http://127.0.0.1:8090/#hypersearch_token=secret-token&x=1",
            "Authorization: Bearer secret-bearer",
            "\"api_key\":\"secret-key\",",
        ]
        .join("\n");

        let redacted = redact_sensitive_text(&input);

        assert!(!redacted.contains("abc123"));
        assert!(!redacted.contains("secret-token"));
        assert!(!redacted.contains("secret-bearer"));
        assert!(!redacted.contains("secret-key"));
        assert!(redacted.contains("normal=value"));
    }
}
