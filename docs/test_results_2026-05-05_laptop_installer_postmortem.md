# HyperSearch Laptop Installer Test Postmortem - 2026-05-05

## Purpose

This document preserves the May 2026 laptop installation test results, diagnosis, and follow-up recommendations for the HyperSearch 1.0 Windows installer effort.

The test goal was to validate whether the generated single Windows installer could guide a fresh Windows 11 laptop through prerequisite setup, runtime deployment, Docker stack startup, LM Studio setup, and first usable HyperSearch launch.

## Evidence Reviewed

Logs collected from the laptop test system:

- `desktop.log`
- `installer-20260504-210134.log`
- `installer-20260504-213047.log`
- `installer-20260505-200521.log`
- `installer-20260505-205156.log`
- `installer-transcript-20260504-210134.log`
- `installer-transcript-20260504-213047.log`
- `installer-transcript-20260505-200521.log`
- `installer-transcript-20260505-205156.log`
- `setup-summary-20260504-210134.json`
- `setup-summary-20260504-213047.json`
- `setup-summary-20260505-200521.json`
- `setup-summary-20260505-205156.json`

## Test System Snapshot

From the setup summaries:

- OS: Windows 11 Pro, build `26100`
- User: `WORKSHOPER\Workshoper`
- RAM: `15.7GB`
- GPU detected: `NVIDIA Quadro P1000`
- Docker later detected: `Docker version 29.4.1, build 055a478`
- LM Studio later detected: `C:\Program Files\LM Studio\LM Studio.exe`
- Installed HyperSearch runtime path: `C:\Users\Workshoper\AppData\Local\HyperSearch\runtime`
- Selected initial model profile: `openai/gpt-oss-20b`
- LM Studio base URL profile: `http://host.docker.internal:1234`

## Install Attempt Timeline

### 2026-05-04 21:01

The installer copied the runtime payload successfully, with `robocopy` exit code `1`. Docker Desktop and LM Studio installation were skipped by the user.

Result:

- HyperSearch files were installed.
- Runtime `.env` and Docker Compose `.env` were created.
- App could not run the backend because Docker was not installed.
- Research mode could not run because LM Studio was not installed.

### 2026-05-04 21:30

Docker Desktop installation was accepted and completed:

- Docker installer download size: `647543728` bytes.
- Docker installer exit code: `0`.
- Docker Desktop launch was requested.

LM Studio installation through `winget` failed:

- Winget exit code: `-1978335138` (`0x8A15005E`).
- LM Studio was not detected after the install step.
- The setup helper attempted to offer model download, but `lms.exe` was not available.

Warnings captured:

- Docker command was not callable immediately after install, likely because PATH/session state had not updated.
- LM Studio executable was not found after winget.
- `lms.exe` was not available.

Result:

- Docker installed, but not immediately usable from the setup PowerShell session.
- LM Studio install was not completed by the automated path.
- HyperSearch still configured the default model as `openai/gpt-oss-20b`.

### 2026-05-04 21:45-21:57

The desktop launcher began seeing Docker and LM Studio. Early Docker calls failed with Docker engine/API instability:

- `program not found`
- `request returned 500 Internal Server Error for API route and version ...`
- `Docker Desktop is unable to start`
- `failed to connect to the docker API at npipe:////./pipe/docker_engine`

Eventually Docker became usable. One later `docker compose up -d --build` attempt built/pulled enough images for the stack to start. The log shows all services running:

- `docker-api-1`
- `docker-caddy-1`
- `docker-searxng-1`
- `docker-ui-1`
- `docker-valkey-1`

The exposed UI port was:

- `127.0.0.1:8090->80/tcp`

Result:

- HyperSearch did start once.
- The path to getting there was fragile and not novice-friendly.
- Overlapping start/stop attempts created transient conflicts before the successful run.

### 2026-05-05 20:05 and 20:51

By these later installer runs, Docker Desktop and LM Studio were both detected cleanly:

- Docker: installed
- LM Studio: installed
- Runtime copy: successful, `robocopy` exit code `2`
- Setup warnings: none

However, every backend startup attempt failed at Docker image metadata resolution:

```text
lookup registry-1.docker.io: no such host
```

Affected images included:

- `python:3.11-slim`
- `node:20-alpine`
- `nginx:1.27-alpine`
- `caddy:2-alpine`
- `searxng/searxng:latest`
- `valkey/valkey:8-alpine`

Docker reported:

```text
dialing registry-1.docker.io:443 container via direct connection because Docker Desktop has no HTTPS proxy
```

Result:

- The installer completed.
- The desktop launcher copied/prepared runtime correctly.
- Docker engine eventually became reachable.
- The backend stack did not start because Docker Desktop could not resolve Docker Hub from its container/build networking context.

## Primary Findings

### 1. First Launch Still Depends on Docker Hub

The current installer is not truly self-contained for the backend runtime. It installs the application and runtime source files, but the first backend launch runs:

```text
docker compose up -d --build
```

That requires Docker to download base images and service images from Docker Hub. On the laptop, Docker Desktop could be installed, but Docker's Linux/build networking could not resolve `registry-1.docker.io`.

This is the primary failure mode from the final test attempts.

### 2. Docker Desktop Readiness Detection Is Too Permissive

In some attempts, `docker info --format "{{.ServerVersion}}"` returned exit code `0` but wrote a fatal message to stderr:

```text
Error response from daemon: Docker Desktop is unable to start
```

The launcher treated this as ready because the combined command output was non-empty. Readiness should require a clean version string from stdout and should reject known fatal stderr messages.

### 3. Backend Start/Stop Actions Can Overlap

The desktop log shows several overlapping or closely sequenced actions:

- `up`
- `down`
- `restart`
- close-triggered `down`

This led to transient Docker conflicts:

```text
network with name docker_default already exists
container name "/docker-valkey-1" is already in use
```

The UI and Rust command layer need a single-flight backend action guard.

### 4. Compose Project Naming Is Too Generic

The Docker resources are named `docker-*` because the compose directory is `infra/docker`.

Examples:

- `docker-api-1`
- `docker-caddy-1`
- `docker-valkey-1`
- `docker_default`

This is confusing in logs and creates unnecessary collision risk. HyperSearch should use an explicit compose project name.

### 5. LM Studio Install Automation Needs More Diagnostics and Better Fallbacks

The winget install path failed once with code `0x8A15005E`, but the installer did not capture winget stdout/stderr. Later LM Studio was installed manually or through another path and was detected correctly.

The setup flow should capture winget output, explain the failure, and offer a direct download/manual completion route.

### 6. Model Recommendation Is Too Coarse

The installer selected `openai/gpt-oss-20b` because a GPU was detected. The test machine had a Quadro P1000, which should not be treated the same as a modern high-VRAM GPU.

The model recommendation system needs VRAM-aware and memory-aware logic, not a simple GPU/no-GPU decision.

### 7. Logging Worked, But Desktop Logs Need Refinement

The new diagnostics were successful: they exposed the real failure chain.

Remaining logging issues:

- `desktop.log` uses Unix timestamps only.
- Some concurrent log writes interleaved.
- Docker build output is truncated inside the event log.
- Full command outputs should be split into separate command logs while `desktop.log` remains a readable event timeline.

## Current Product Readiness Assessment

The installer is now good enough to diagnose failures, but not yet good enough for a public 1.0 novice install.

Current state:

- Application files install correctly.
- Runtime copy works.
- Docker and LM Studio detection works after prerequisites are installed.
- Logs are sufficient for root-cause analysis.
- Backend startup is too dependent on live Docker Hub access.
- Docker Desktop startup and compose orchestration still require more guardrails.

The highest-risk deployment gap is the first-run Docker build/pull path.

## Recommended P0 Fixes

### Use Prebuilt Runtime Images for the Default Path

The desktop app should not build API/UI images on the user machine during normal startup.

Replace default startup behavior:

```text
docker compose up -d --build
```

with:

```text
docker compose up -d
```

using pinned prebuilt images for:

- HyperSearch API
- HyperSearch UI

This still requires image pulls unless images are bundled, but it removes local Node/Python image build complexity and shortens startup.

### Add an Installer-Time Docker Network Check

Before the installer declares setup complete, it should check whether Docker can actually reach required registries.

Useful checks:

```text
docker info
docker pull hello-world
docker pull caddy:2-alpine
docker pull valkey/valkey:8-alpine
```

If Docker cannot resolve Docker Hub, the installer should show a clear remediation message:

- Docker Desktop is installed, but container networking cannot resolve Docker Hub.
- Check DNS, proxy, VPN, firewall, or Docker Desktop proxy settings.
- HyperSearch cannot start until Docker can pull required images.

### Add an Offline or Full Installer Track

For a true single-EXE experience, consider bundling image tarballs and running:

```text
docker load
```

This would avoid Docker Hub at first launch. It will make the installer much larger, but it aligns better with the "single installer" expectation.

Potential release tracks:

- Web installer: smaller, downloads Docker images during setup.
- Full installer: larger, includes Docker image tarballs.

### Fix Docker Readiness Parsing

Docker readiness should require:

- exit code `0`
- stdout matching a version pattern such as `^\d+\.\d+\.\d+`
- no fatal stderr messages

Known fatal stderr patterns:

- `Docker Desktop is unable to start`
- `failed to connect to the docker API`
- `request returned 500 Internal Server Error`
- `check if the daemon is running`

### Serialize Backend Actions

Add both UI-level and Rust-level guards:

- Disable Start, Stop, Restart, and app-close shutdown while a backend action is in progress.
- Add a Rust-side mutex/single-flight guard around backend actions.
- Suppress duplicate close confirmations while one shutdown is already active.

### Set an Explicit Compose Project Name

Use a fixed project name such as:

```text
COMPOSE_PROJECT_NAME=hypersearch
```

or call compose with:

```text
docker compose --project-name hypersearch ...
```

Also consider using:

```text
docker compose down --remove-orphans
```

before retrying startup after a partial failure.

## Recommended P1 Fixes

### Capture Full Command Logs

Keep `desktop.log` as a readable event timeline, but write full command output to separate files:

```text
%LOCALAPPDATA%\HyperSearch\logs\commands\desktop-command-YYYYMMDD-HHMMSS-<action>.log
```

The event log should link to the command log path.

### Add Human-Readable Desktop Timestamps

Desktop log entries should include local ISO timestamps in addition to Unix seconds.

Example:

```text
[2026-05-05T20:52:16-04:00] [1778028736] [backend.action.start] action=up
```

### Improve LM Studio Install Flow

Capture winget stdout/stderr and classify known failure codes.

Fallback behavior:

- If winget fails, open the direct LM Studio download page.
- Poll for `LM Studio.exe` after install.
- Poll for `%USERPROFILE%\.lmstudio\bin\lms.exe`.
- Do not offer automated model download until `lms.exe` exists.

### Add VRAM-Aware Model Selection

Model recommendation should inspect GPU adapter RAM where available.

Suggested initial policy:

- No usable GPU and less than 12GB RAM: search-only.
- Low-VRAM GPU such as Quadro P1000: recommend small model or search-only.
- 8GB VRAM: recommend small/medium quantized models only.
- 16GB+ VRAM: allow larger model recommendations.
- Never auto-select a 20B model solely because a GPU string exists.

### Add a Diagnostics Export Bundle

The desktop app should offer an "Export Diagnostics" action that packages:

- Installer logs
- Desktop logs
- Setup summaries
- Runtime `.env` with secrets redacted
- Docker version/info output
- Docker compose ps output
- Recent Docker compose logs
- Provider settings/readiness result

## Recommended P2 Fixes

### Public Image Publishing

Publish versioned HyperSearch images:

- `hypersearch/api:1.0.0`
- `hypersearch/ui:1.0.0`

Pin all third-party images by version and optionally digest.

### Installer Result Screen

At the end of setup, show:

- Docker installed/detected
- Docker engine ready/not ready
- Docker registry reachable/not reachable
- LM Studio installed/detected
- Model profile selected
- Runtime path
- Logs path
- Next action

### Better Docker Desktop Integration

Improve Docker Desktop handling:

- Start Docker Desktop during setup if installed.
- Wait longer on first launch.
- Detect WSL/backend errors explicitly.
- Provide a visible "Docker is installed but still starting" state.

## Immediate Next Engineering Plan

1. Change runtime compose behavior to use prebuilt images by default.
2. Add a separate development compose override or command for local `--build`.
3. Add Docker registry/network readiness checks to installer and desktop.
4. Fix Docker readiness parsing.
5. Add backend action single-flight locking.
6. Set `COMPOSE_PROJECT_NAME=hypersearch`.
7. Add `--remove-orphans` cleanup on recovery.
8. Replace GPU/no-GPU model selection with RAM/VRAM-aware recommendations.

## Bottom Line

The laptop test did not show a core HyperSearch application failure. It showed that the installer/runtime strategy still behaves too much like a developer Docker workflow.

For a public 1.0 installer, HyperSearch needs a more production-style runtime path:

- prebuilt images,
- explicit Docker network validation,
- serialized service control,
- better Docker readiness checks,
- and hardware-aware model recommendations.

The improved logs made the failure chain clear and should remain part of the installation and support workflow.
