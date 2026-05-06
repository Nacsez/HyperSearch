# HyperSearch Desktop Launcher

HyperSearch Desktop is the preferred local entry point for 1.0 testing on Windows.

## Launch

Run `Launch-HyperSearch.vbs` from the repository root for the quiet launcher path. It starts the compiled Tauri desktop app without opening a command prompt.

The launcher uses the debug executable at `apps/desktop/src-tauri/target/debug/hypersearch-desktop.exe`. If the executable is missing, `Launch-HyperSearch.ps1` rebuilds the desktop frontend and native shell.

## Local Sessions

The default mode is local-only:

- Caddy binds to `127.0.0.1:8090`.
- Local browser and embedded desktop sessions do not require a pairing token.
- The desktop app starts and stops the managed Docker Compose stack.

The launcher has two main views:

- **Deploy** starts/stops the Docker stack, checks prerequisites, shows service health, and exposes backend logs.
- **Sessions** hosts embedded HyperSearch sessions as full-panel tabs.

Use **New Session** to open HyperSearch as a managed tab inside the launcher. Multiple sessions can be opened in parallel for separate searches or research runs. Hidden sessions stay mounted so in-flight research requests can continue while you work in another session. Use **Browser** as a fallback if you want to inspect the same local page in your default browser.

Each HyperSearch session keeps a local saved snapshot in browser storage. Open **Session Library** inside a session to rename, load, delete, or export saved sessions.

The in-session **Help** button opens the browser help page in normal browser mode. In the desktop launcher it opens a managed session titled **Help**, keeping support material inside the app shell.

## Local Model Selection

Open **Operations** in HyperSearch, edit the LM Studio provider endpoint, and save the profile. For Docker-managed HyperSearch, LM Studio on the host machine should usually be `http://host.docker.internal:1234`; a non-Docker local development API may use `http://127.0.0.1:1234`.

After saving the endpoint, choose **Discover models**. HyperSearch queries the provider's OpenAI-compatible `/v1/models` endpoint, populates the preferred-model dropdown, and saves the selected model when you choose **Save profile**.

## XML Exports

Set the export folder on the desktop **Deploy** view. Embedded sessions send XML exports to the desktop shell, which writes files into that folder. Browser-only sessions download the XML through the browser.

Export filenames use the first 48 characters of the active query, sanitized for Windows filenames, followed by a timestamp such as `20260426_153015.xml`.

Inside a HyperSearch session, open **Search Settings** and expand **XML export contents** to choose which fields are written: session metadata, question, search results, fetched full text, summaries, research answer, research sources, activity log, and provider trace.

## Headless Use

The desktop app manages the backend, but the same running service is available to command-line and API clients on `http://127.0.0.1:8090`.

```powershell
.\scripts\Invoke-HyperSearch.cmd -Action ready
.\scripts\Invoke-HyperSearch.cmd -Action search -Query "history of cincinnati ohio" -Results 10
.\scripts\Invoke-HyperSearch.cmd -Action research -Query "origin of ronald mcdonald" -Results 25 -ResearchSources 5
```

For LAN mode, pass the pairing token with `-PairingToken`.

## LAN Mode

LAN mode is opt-in from the desktop app. When enabled:

- Caddy binds to `0.0.0.0`.
- The API requires `X-HyperSearch-Token` for private-network access.
- Desktop-launched embedded sessions and browser sessions receive the token in the URL once, store it locally, and remove it from the address bar.
- Browsers on another computer still need the displayed pairing token.

Disabling LAN mode restores local-only binding and clears the saved pairing token in `.env`.

## Shutdown Behavior

Closing the main desktop launcher prompts before shutdown. Confirming the prompt runs `docker compose down` against the managed stack and exits the desktop app, closing embedded HyperSearch sessions with it.

## Diagnostics

The launcher uses a runtime-local Docker config directory at `.docker` to avoid failures caused by unreadable user-level Docker config files. Docker and service output is visible from the **Logs** button in the launcher.

Backend actions are serialized: Start, Stop, Restart, and close-triggered shutdown cannot run over each other. Normal startup uses prebuilt images and does not pass `--build`.

Open **Settings > Export Diagnostics** to collect:

- installer logs
- desktop timeline logs
- full command stdout/stderr logs
- redacted environment files
- Docker version/info/image output
- Compose config, ps, and recent service logs

Diagnostics are written under `%LOCALAPPDATA%\HyperSearch\diagnostics`.

## Release Candidate Installer

The release-candidate installer supports two channels:

- **Online media** pulls prebuilt images during setup.
- **Full media** loads bundled Docker image archives from `payload\images`.

Both channels write setup summaries and command logs under `%LOCALAPPDATA%\HyperSearch\logs`.
