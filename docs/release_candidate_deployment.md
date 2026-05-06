# HyperSearch 1.0 Private Release Candidate Deployment

This guide is the durable reference for building and testing the private HyperSearch 1.0 release candidate.

## Release Shape

HyperSearch now has two installer media channels:

- **Online media**: small GitHub-friendly installer. It installs HyperSearch, guides Docker Desktop and LM Studio setup, and pulls prebuilt Docker images during setup.
- **Full media**: beta-testing package. It includes the installer plus `payload\images` Docker image archives so setup can run `docker load` instead of depending on Docker Hub or GHCR during first launch.

The private beta should use full media whenever possible. The online installer is still useful for connected developer systems and later public release testing.

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

For private beta media, bundled image archives are preferred because private registry pulls require authentication. Public release can switch online installs to unauthenticated public pulls after the images are made public.

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
docker compose --project-name hypersearch up -d
```

Developer builds use:

```text
docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

The desktop launcher and helper scripts use the fixed project name `hypersearch`, so containers and networks are easier to identify and less likely to collide with unrelated Compose projects.

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

Use **Settings > Export Diagnostics** in the desktop launcher before collecting manual issue notes.

## Beta Acceptance Criteria

- Full media installs on a clean Windows 11 test machine.
- Docker images load from bundled archives without registry access.
- HyperSearch starts without building images on the tester machine.
- Search works without LM Studio.
- Research mode clearly reports local-model readiness and succeeds when LM Studio has a loaded matching model.
- Installer result screen and diagnostic logs explain any incomplete prerequisite.
- Reinstall preserves local data, exports, settings, logs, and history.
