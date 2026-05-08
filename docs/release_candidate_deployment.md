# HyperSearch 1.0 Private Release Candidate Deployment

This guide is the durable reference for building and testing the private HyperSearch 1.0 release candidate.

## Release Shape

HyperSearch now has two installer media channels:

- **Online media**: small GitHub-friendly installer. It installs HyperSearch, guides Docker Desktop setup, optionally guides LM Studio setup, and pulls pinned prebuilt Docker images during setup. During private beta, if the registry rejects the pull, setup falls back to building the HyperSearch API/UI images locally from the installed source payload and records that choice in the setup summary.
- **Full media**: beta-testing package. It includes the installer plus `payload\images` Docker image archives and digest manifests so setup can run `docker load` instead of depending on Docker Hub or GHCR during first launch.

The private beta should use full media whenever possible. The online installer is still useful for connected developer systems and later public release testing.

For GitHub distribution, do not commit generated binaries or image archives. Zip the generated `Online` and `Full` media folders and upload those zip files as release assets. See `docs/beta_github_distribution_2026-05-08.md` for the current private beta asset names, checksums, and release description template.

## Repository And Registries

The planned private repository is:

```text
git@github.com:Nacsez/HyperSearch.git
```

Container images are built for both registries:

```text
ghcr.io/nacsez/hypersearch-api:1.0.0
ghcr.io/nacsez/hypersearch-ui:1.0.0
docker.io/nacsez/hypersearch-api:1.0.0
docker.io/nacsez/hypersearch-ui:1.0.0
```

For private beta media, bundled image archives are preferred because private registry pulls require authentication. The local-build fallback keeps developer/tester machines unblocked, but full media remains the expected beta path because it avoids both private registry credentials and first-run source builds. Public release can switch online installs to unauthenticated public pulls after the images are made public.

## Build Commands

Build local images and create an image archive:

```powershell
.\scripts\Build-ContainerImages.ps1 -Version 1.0.0 -RegistryMode Both -SaveArchive
```

Build both installer channels:

```powershell
.\scripts\Build-InstallationMedia.ps1 -RunName RC1 -Channel Both -Version 1.0.0 -ImageArchivePath .\artifacts\images\hypersearch-images-1.0.0.tar
```

Optionally include locally downloaded prerequisite installers in the full media payload:

```powershell
.\scripts\Build-InstallationMedia.ps1 `
  -RunName RC1-Full `
  -Channel Full `
  -Version 1.0.0 `
  -ImageArchivePath .\artifacts\images\hypersearch-images-1.0.0.tar `
  -DockerDesktopInstallerPath "C:\Installers\Docker Desktop Installer.exe" `
  -LmStudioInstallerPath "C:\Installers\LM Studio.exe"
```

Only bundle third-party installers after confirming their redistribution terms. If they are not bundled, the installer still guides official download/install paths.

## Runtime Behavior

Release startup uses:

```text
.\scripts\Deploy-HyperSearch.cmd -Action up
```

If the release startup path fails with a registry authorization error, the desktop app runs:

```text
docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

After that fallback succeeds, the runtime `.env` files are updated to use `hypersearch-api:dev` and `hypersearch-ui:dev` so later starts do not retry the denied private registry.

Developer builds use:

```text
docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

The desktop launcher and helper scripts use the fixed project name `hypersearch`, so containers and networks are easier to identify and less likely to collide with unrelated Compose projects. Before opening sessions, the launcher requires structured Compose status for API, UI/Caddy, SearXNG, and Valkey plus HTTP probes for `/v1/live` and search readiness.

## Installer Diagnostics

The prerequisite helper writes:

- `%LOCALAPPDATA%\HyperSearch\logs\installer-*.log`
- `%LOCALAPPDATA%\HyperSearch\logs\installer-transcript-*.log`
- `%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json`
- `%LOCALAPPDATA%\HyperSearch\logs\commands\*.log`

The desktop launcher writes:

- `%LOCALAPPDATA%\HyperSearch\logs\desktop.log`
- `%LOCALAPPDATA%\HyperSearch\logs\commands\*.log`
- `%LOCALAPPDATA%\HyperSearch\diagnostics\hypersearch-diagnostics-*`

Use **Settings > Export Diagnostics** in the desktop launcher before collecting manual issue notes. The bundle redacts token, key, password, auth, and credential values across env files, compose output, command logs, and desktop logs.

## Beta Acceptance Criteria

- Full media installs on a clean Windows 11 test machine.
- Docker images load from bundled archives without registry access.
- HyperSearch starts from bundled images on full media, or clearly reports and logs the local-build fallback when online private-registry access is unavailable.
- Search works without LM Studio.
- Research fallback works without LM Studio and returns `trace.mode="search-only-fallback"`.
- Research synthesis clearly reports local-model readiness and succeeds when LM Studio has a loaded matching model.
- Diagnostics export does not contain sentinel token/key/password/auth values.
- Installer result screen and diagnostic logs explain any incomplete prerequisite.
- Reinstall preserves local data, exports, settings, logs, and history.
