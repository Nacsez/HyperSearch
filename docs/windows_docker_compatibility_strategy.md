# Windows Docker Compatibility Strategy

Date: 2026-05-15

This note records the Windows compatibility floor for HyperSearch 1.1 installer testing and release support.

## Current Docker Desktop Floor

HyperSearch's packaged runtime uses Linux containers. On Windows, the default supported runtime remains Docker Desktop with the WSL 2 backend.

Current Docker Desktop for Windows requirements:

- WSL 2 backend requires WSL `2.1.5` or later.
- Windows 10 requires Enterprise, Pro, or Education 22H2, build `19045`.
- Windows 11 requires Enterprise, Pro, or Education 23H2, build `22631`, or higher.
- `LanmanServer` must be enabled and automatic.
- WSL 2 must be enabled.
- Hardware must provide 64-bit CPU support, SLAT, 8 GB RAM, and hardware virtualization.
- Docker only supports Docker Desktop on Windows versions still inside Microsoft's servicing timeline.

Source: Docker Desktop Windows install requirements (`https://docs.docker.com/desktop/setup/install/windows-install/`), checked 2026-05-15.

## HyperSearch 1.1 Support Tiers

### Tier 1: Fully Supported

- Windows 11 23H2+ build `22631+`, or Windows 10 22H2 build `19045`, on Pro, Enterprise, or Education client editions.
- Docker Desktop current release.
- WSL 2 backend.
- HyperSearch Full installer with bundled image archive.

This is the release gate for the standard Installation Wizard path.

### Tier 2: Supported With Warnings

- Existing Docker Desktop is present and passes all readiness checks, even if installer would not freshly install Docker on that OS.
- Example: a user already has a working Docker Desktop install and HyperSearch can verify `docker version`, `docker info`, `docker compose version`, image inspection, and stack health.

The installer should use the existing runtime but record the OS/version warning in diagnostics.

### Tier 3: Advanced Legacy Path

- Windows supports WSL 2 but does not meet current Docker Desktop support policy.
- Possible runtime: Docker Engine installed inside an Ubuntu WSL distribution, with the Windows side invoking `wsl docker`/`wsl docker compose`.

This can broaden compatibility, but it should be custom/advanced for 1.1 or later because it has different networking, service startup, filesystem, security, and support characteristics from Docker Desktop.

Microsoft's current WSL install command path requires Windows 10 version 2004/build `19041` or later, or Windows 11. Docker Engine's Ubuntu packages currently support Ubuntu 22.04 LTS, 24.04 LTS, 25.10, and 26.04 LTS on amd64.

### Tier 4: Unsupported

- Windows 10 below build `19041`: cannot use modern WSL install commands.
- Windows 10 below build `19045` for Docker Desktop standard path.
- Windows 11 below build `22631` for Docker Desktop standard path.
- Systems without virtualization/SLAT.
- Systems where WSL/Docker cannot be repaired and made ready.

The wizard should fail early with a clear reason and a search-only or manual-upgrade option rather than trying to continue into Docker image load.

## Lab Finding: WinDev2407 Image

The Microsoft `https://aka.ms/windev_VM_hyperv` Hyper-V image currently resolves to `WinDev2407Eval.HyperV.zip`, last modified 2025-03-05. That VM installs as Windows 11 Enterprise Evaluation 22H2 build `22621.3880`.

On 2026-05-15, automated Windows Update through `PSWindowsUpdate` ran multiple passes and rebooted the VM, but did not offer a feature upgrade to build `22631+`. The script therefore did not create the `clean-windows-docker-supported-ready` checkpoint.

Conclusion: this image is useful as an unsupported/legacy classification test, but it is not a valid full Docker Desktop release-gate VM.

## Recommended Lab Baselines

- `clean-windows-docker-supported-ready`: Windows 11 24H2/25H2 or Windows 10 22H2 build `19045`, no Docker, no LM Studio.
- `docker-current`: supported OS with Docker Desktop installed and ready.
- `docker-stopped`: supported OS with Docker Desktop installed but stopped.
- `docker-broken-old`: supported OS with stale/broken Docker Desktop matching Dan-style failures.
- `legacy-windows-unsupported`: current WinDev2407 build `22621`, used only to prove graceful OS classification and search-only/manual-upgrade behavior.

## Installer Implications

- Standard install should gate Docker Desktop install on the current Docker-supported Windows build matrix.
- If Windows 10 build is `19045+`, standard install can proceed with WSL 2 and Docker Desktop.
- If Windows 10 build is `19041-19044`, custom advanced install could offer a WSL Docker Engine path in the future.
- If Windows is below build `19041`, the installer should not attempt Docker automation.
- Bundled Docker images still help avoid Docker Hub sign-in/pull failures, but they do not remove the host runtime requirement.
