# Testing Launch

For local testing on Windows, use one of the root launchers:

```powershell
.\Launch-HyperSearch.ps1
```

or double-click:

```text
Launch-HyperSearch.cmd
```

The default launcher opens the HyperSearch Desktop debug executable at:

```text
apps\desktop\src-tauri\target\debug\hypersearch-desktop.exe
```

The desktop app can start, stop, restart, inspect logs, open the browser console, and toggle paired LAN mode.
Normal desktop startup uses prebuilt release images. It does not run Docker builds.

If the desktop app is not working yet, use the browser fallback:

```powershell
.\Launch-HyperSearch.ps1 -WebOnly
```

That starts the Docker Compose backend and opens the browser console at the configured local URL.

For local image development, use:

```powershell
.\scripts\Deploy-HyperSearch.cmd -Action up -Build
```

For release-mode startup, use:

```powershell
.\scripts\Deploy-HyperSearch.cmd -Action up
```

## Prerequisites

- Docker Desktop must be installed and running for the backend stack.
- LM Studio is optional for search and source review. It is required only for model synthesis.
- LM Studio must have its local server enabled and a model loaded that matches the saved provider profile.
- Run `.\scripts\Deploy-HyperSearch.cmd -Action doctor` for Docker config, context, named-pipe, service, and group membership diagnostics.

## Release Candidate Media

Use `.\scripts\Build-InstallationMedia.ps1 -Channel Both` to create online and full media folders. Use the full media folder for private beta machines when you want the installer to load bundled Docker images instead of pulling from a registry.
