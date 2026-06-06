# HyperSearch 1.1

HyperSearch 1.1 is the installer reliability release for the local-first Windows research workstation. It keeps the same unsigned, SHA256-verifiable release posture as 1.0, and adds a fuller guided setup path for Docker Desktop, WSL, bundled service images, LM Studio, service startup, diagnostics, and optional Windows sign-in autostart.

## Recommended Download

Use **Full Installation Media** for the 1.1 public release. It includes the HyperSearch desktop installer, bundled container image archive, installer prerequisites, and release metadata needed for the Standard setup path.

This release still uses unsigned Windows binaries. Verify the ZIP and installer hashes before running the installer. Windows SmartScreen may warn on first launch because the binaries are not Authenticode-signed.

## Downloads

| Asset | Use this when | SHA256 |
| --- | --- | --- |
| `HyperSearch_1.1.0_Full_20260606.zip` | You want the supported first-install path with bundled images and prerequisites. | `48893ec80265f087c4058f0baa6776620941a52d0dba8530a7dc1a6c8cc7c443` |
| `HyperSearch_1.1.0_x64-setup.exe` | You only need the Windows installer from inside the media package. | `e20e1b15a844b71db94b3f54ba2f12ff5a660ca6490bc4a15cf74dd7a0c22a93` |
| `HyperSearch_1.1.0_x64_en-US.msi` | You need the generated MSI from inside the media package. | `486130444093c7716321638e4fc39b01336c7c46768173e5ee050350e488dc48` |
| `hypersearch-desktop.exe` | You need to verify the direct desktop executable inside the media package. | `598506d78c74b017f4cadd9a46fe6992dcecf9cbe1e948b035b58b10401dfff8` |
| `hypersearch-images-1.1.0.tar` | You need to verify the bundled Docker image archive inside the Full media. | `70fdfbcd2b89f33280ba9710a56b102ca4a1962a358487a008a825632f70c1b5` |

## What Changed

- New guided HyperSearch Installation Wizard with Standard and Custom setup profiles.
- Standard Full setup validates Docker Desktop, WSL2 readiness, bundled image loading, Docker Compose startup, health checks, LM Studio detection, and `lms.exe` readiness.
- WSL repair handling now detects the Windows 10 post-install state where the WSL service is unavailable until reboot, records a clear resume plan, and avoids continuing into a known-bad Docker setup.
- LM Studio retry handling keeps failed attempt details in installer diagnostics without turning recovered attempts into global installer warnings.
- Optional Windows sign-in autostart can start HyperSearch and the managed Docker stack asynchronously.
- Search-only setup remains supported when LM Studio is intentionally skipped.
- Installer lab automation now includes strict Standard Full assertions and a real NSIS Standard Full lane.

## Release Validation

Final release-gate run:

- Gate ID: `20260526-215927`
- Matrix ID: `20260526-215933`
- Result: `passed`
- Matrix: `9/9` scenarios passed, `0` failed
- Full media source: `Installation Media\RC_20260526_1_1_win10fix\Full`
- Final public media source: `Installation Media\PublicRelease_20260606_1_1\Full`
- Final public media ZIP: `Installation Media\PublicRelease_20260606_1_1\HyperSearch_1.1.0_Full_20260606.zip`
- Image archive SHA256: `70fdfbcd2b89f33280ba9710a56b102ca4a1962a358487a008a825632f70c1b5`

Validated scenarios:

- `win10-nsis-bootstrap-smoke`
- `win10-fresh-standard-full`
- `win10-compose-env-bom`
- `win10-search-only-skip-lmstudio`
- `win11-nsis-bootstrap-smoke`
- `win11-fresh-standard-full`
- `win11-nsis-standard-full`
- `win11-compose-env-bom`
- `win11-search-only-skip-lmstudio`

Strict Standard Full acceptance passed with zero installer warnings, Docker Desktop ready, Compose ready, bundled images loaded and verified, `/v1/live` and `/v1/ready` returning HTTP 200, LM Studio detected, and `lms.exe` ready. The NSIS Standard Full lane also verified the login autostart profile and Windows registration path.

Local preflight checks passed:

- `pytest`: `33 passed, 1 skipped`
- UI production build: passed
- Desktop frontend build: passed
- Desktop native `cargo check`: passed
- Installer parser/unit gate: passed as part of full `pytest`
- Docker Compose config and release+dev override config: passed
- Release security check: license notices current, npm audits reported `0` vulnerabilities
- Final media ZIP integrity probe: 18 entries, setup/MSI/image archive/prerequisites present

## First Run

1. Download the **Full Installation Media** ZIP.
2. Verify the ZIP SHA256 value from the release page.
3. Extract the ZIP to a local folder.
4. Run `HyperSearch_1.1.0_x64-setup.exe`.
5. Choose Standard setup unless you need to customize prerequisite handling.
6. Let the wizard set up Docker Desktop, WSL, bundled service images, LM Studio, and the HyperSearch stack.
7. Optionally enable **Start HyperSearch when I sign into Windows**.

Some Windows systems must restart after WSL is installed or updated before Docker Desktop can run correctly. The 1.1 installer records that condition and resumes cleanly after reboot.

## Verify The Download

PowerShell example:

```powershell
Get-FileHash .\HyperSearch_1.1.0_Full_20260606.zip -Algorithm SHA256
```

Compare the result with the SHA256 value on the release page. After extraction, compare individual file hashes with the included `checksums.sha256`.

## Compatibility Notes

- Docker Desktop remains the supported Windows runtime for HyperSearch 1.1.
- Supported Docker/WSL baselines are Windows 10 22H2 build 19045+ and Windows 11 23H2 build 22631+.
- Docker Desktop, WSL, and LM Studio are third-party prerequisites governed by their own licenses and update behavior.
- Local LLM features require LM Studio and an available local model. Search-only workflows can run without LM Studio.

## Support

Use GitHub Issues for bugs and support questions. Include installer diagnostics or the generated lab artifact bundle when reporting setup failures. For security issues, follow the process in `SECURITY.md`.

Release posture:

- HyperSearch-owned code is licensed as AGPL-3.0-only.
- License file, third-party notices, and source-offer materials are included in the repository and release media.
- Release media is unsigned but SHA256-verifiable.
- Docker Desktop and LM Studio are third-party software installed or launched through documented vendor-supported paths.
