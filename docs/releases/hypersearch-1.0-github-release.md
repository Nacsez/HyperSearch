# HyperSearch 1.0

![HyperSearch 1.0](https://raw.githubusercontent.com/Nacsez/HyperSearch/main/docs/assets/hypersearch-1.0-release-banner.svg)

HyperSearch is a local-first research workstation for Windows. It packages a private search stack, a desktop interface, session saving, source review, and optional local LLM synthesis into an installer flow built for people who know their PC but do not want to hand-configure Docker services.

## Recommended Download

Use **Full Installation Media** for the smoothest first install. It includes the HyperSearch desktop installer and the container image archive needed by the local Docker stack.

The installer still needs internet access when Docker Desktop or LM Studio must be downloaded or updated. HyperSearch itself can install its bundled service images from the Full media after Docker is available.

## Downloads

| Asset | Use this when | SHA256 |
| --- | --- | --- |
| `HyperSearch_1.0.0_Full_PublicRelease_20260509.zip` | You want the easiest first install or an offline-ready HyperSearch image payload after Docker is installed. | `b68858bbed2f870167998f9f20d3ceb4fac4ff3a2f3ce732ba2086dc0245a6c8` |
| `HyperSearch_1.0.0_Online_PublicRelease_20260509.zip` | You already have reliable internet and want the smaller package. | `a3770be9c219950b35638f803814308b6c3ced4d57820a670e1f6d7a40d7aa47` |
| `HyperSearch_1.0.0_x64-setup.exe` | You only need the Windows installer from inside one of the media packages. | See the included `checksums.sha256`. |

## What You Get

- A Windows desktop application from Robert Choudury, published as HyperSearch.
- Local search backed by the packaged Docker service stack.
- Search-only mode as a supported first-class setup.
- Optional LM Studio/local LLM workflows for synthesis, summaries, and deeper research.
- Saved XML sessions through the Session Library.
- Source review, citation tracking, and diagnostics designed for support without exposing secrets.
- A release posture based on AGPL-3.0-only source availability and SHA256-verifiable unsigned binaries.

## First Run

1. Download the **Full Installation Media** ZIP.
2. Extract it to a local folder.
3. Run `HyperSearch_1.0.0_x64-setup.exe`.
4. Let the installer check Docker, WSL, and optional LM Studio readiness.
5. Launch HyperSearch and start a session.

If Docker Desktop or LM Studio is missing, the installer can guide their setup. On some Windows systems the WSL engine must be updated before Docker will run; the installer checks for that and offers the update path.

## Container Images

The online install path expects these 1.0 images:

- `ghcr.io/nacsez/hypersearch-api:1.0.0`
- `ghcr.io/nacsez/hypersearch-ui:1.0.0`

The Full media includes the corresponding image archive so users do not need to pull those images during HyperSearch service setup.

## Verify The Download

This 1.0 release uses the no-cost unsigned distribution path. Before running the installer, compare the downloaded ZIP hash with the SHA256 value above or with the included `checksums.sha256` file after extraction.

PowerShell example:

```powershell
Get-FileHash .\HyperSearch_1.0.0_Full_PublicRelease_20260509.zip -Algorithm SHA256
```

Windows may show an unsigned-app warning on first launch. That is expected for this release path; verify the hash before installing.

## Support

Use GitHub Issues for bugs and support questions. For security issues, follow the process in `SECURITY.md`.

Release posture:

- HyperSearch-owned code is licensed as AGPL-3.0-only.
- License file, third-party notices, and source-offer materials are included in the repository and release media.
- The release media is unsigned but hash-verifiable.
- Docker Desktop and LM Studio are third-party downloads governed by their own licenses.
