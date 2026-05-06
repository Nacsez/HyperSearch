# HyperSearch Windows Installer Test Plan

This document tracks the first Windows 11 fresh-machine installer path for HyperSearch 1.0.

## Installer Responsibilities

- Install the HyperSearch desktop application and register it with Windows uninstall metadata.
- Create Start Menu integration through the Tauri NSIS installer.
- Offer desktop shortcut creation through the normal installer flow.
- Copy the bundled HyperSearch runtime stack into `%LOCALAPPDATA%\HyperSearch\runtime`.
- Preserve existing user data, `.env`, Docker state, cache, exports, and logs on reinstall.
- Check for Docker Desktop and offer to install it when missing.
- Check for LM Studio and offer to install it when missing.
- Configure HyperSearch for LM Studio at `http://host.docker.internal:1234`.
- Load bundled Docker image archives from full media when `payload\images` is present.
- Pull prebuilt images during online setup when no bundled archive is present.
- Avoid building API/UI images on the tester machine during normal release startup. If online media cannot access the private registry during beta testing, setup and desktop startup may fall back to a local API/UI image build and record `imageSetup.mode=local-build-fallback`.
- Choose an initial model profile:
  - 16GB+ adapter RAM: offer/configure `openai/gpt-oss-20b`
  - adequate RAM or midrange GPU: offer/configure `qwen2.5-7b-instruct`
  - low RAM and weak/no GPU: configure search-only mode
- Offer to start an asynchronous model download through LM Studio CLI when available.

## Fresh Windows 11 Test Pass

1. Run the NSIS setup EXE from the generated `Installation Media` folder.
2. Accept HyperSearch installation and choose desktop shortcut preference.
3. If Docker Desktop is missing, accept Docker installation and approve Windows elevation.
4. If LM Studio is missing, accept LM Studio installation.
5. If prompted for model download, accept and verify installer can finish while download continues.
6. Launch HyperSearch from Start Menu or desktop shortcut.
7. Press Start and confirm Docker stack starts from `%LOCALAPPDATA%\HyperSearch\runtime`.
8. Confirm `http://127.0.0.1:8090` opens from the desktop session and browser.
9. Open settings and confirm LM Studio endpoint/model values are populated.
10. If model download is complete and loaded in LM Studio, run research synthesis.
11. Open desktop Settings and run **Export Diagnostics**.

## Logs

Installer setup logs are written to:

`%LOCALAPPDATA%\HyperSearch\logs\installer-*.log`

Full PowerShell setup transcripts are written to:

`%LOCALAPPDATA%\HyperSearch\logs\installer-transcript-*.log`

Machine-readable setup summaries are written to:

`%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json`

Desktop first-launch and service-control diagnostics are written to:

`%LOCALAPPDATA%\HyperSearch\logs\desktop.log`

Full command stdout/stderr logs are written to:

`%LOCALAPPDATA%\HyperSearch\logs\commands`

Diagnostics exports are written to:

`%LOCALAPPDATA%\HyperSearch\diagnostics`

Asynchronous model download logs are written to:

`%LOCALAPPDATA%\HyperSearch\logs\model-download-*.log`

For a deployment issue report, collect all files under `%LOCALAPPDATA%\HyperSearch\logs`, then also capture the current application logs from the Deploy page Logs toggle after pressing Refresh.

## Fresh-Machine QA Notes

- Confirm the installer log records Docker detection, Docker installer download size, installer exit code, and the post-install Docker version when Docker is installed by setup.
- Confirm the installer log records LM Studio detection, winget availability, LM Studio installer exit code, and the final detected LM Studio path.
- Confirm `setup-summary-*.json` includes hardware RAM/GPU detection, selected install profile, runtime copy source/destination, and model-download status.
- Confirm `setup-summary-*.json` records `imageSetup.mode` as `bundled` for full media, `online` for successful online pulls, or `local-build-fallback` when private registry access is denied and local source images are built.
- Confirm `desktop.log` records runtime preparation, Docker readiness checks, `docker compose up -d`, external/internal session launches, XML exports, and app shutdown.
- Confirm command logs contain full Docker/Compose stdout and stderr.
- If the model download continues after setup exits, confirm `model-download-*.log` records the `lms get` and `lms server start` exit codes.
