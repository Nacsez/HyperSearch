# HyperSearch Beta GitHub Distribution Notes - 2026-05-08

This note records the current private beta handoff state. It is intended to make the GitHub page usable for testers after the maintainer creates a manual release or pre-release, without making the repository public and without committing generated installer binaries to git.

## Repository State

- Repository: `git@github.com:Nacsez/HyperSearch.git`
- Visibility: keep private until the project owner changes it.
- Release action: owner creates the GitHub release or pre-release manually.
- License/signing cadence: leave final license and final release-signing decisions to the owner release step.
- Generated media remains ignored by git under `Installation Media/`; publish it as GitHub release assets.

## Current Local Media

Generated folder:

```text
Installation Media\WslUpdatePolish_20260508
```

Upload-ready zip assets:

| Asset | Size | SHA256 |
| --- | ---: | --- |
| `HyperSearch_1.0.0_Online_WslUpdatePolish_20260508.zip` | 10,414,076 bytes | `9A82A1CE41F124FD4252A4B4A51680BEFCC0EC0EC3BA5072E9080537B66409A4` |
| `HyperSearch_1.0.0_Full_WslUpdatePolish_20260508.zip` | 301,922,262 bytes | `E0B509667E6E86A2D21B6E6B167460C86B7349CEFCD5968ACA4932866E2FA890` |

Important component hashes from the full media:

| Component | SHA256 |
| --- | --- |
| `Full\HyperSearch_1.0.0_x64-setup.exe` | `6AD68F38389C2BDAB3215074D5B44AFA88B0ADD11F146AB4FF00014EC7DB3051` |
| `Full\payload\images\hypersearch-images-1.0.0.tar` | `46EEF7016CD961DC89AB7E3443B480A57DD290F6573E1A4C2FFAF404ECAC518E` |

## Recommended GitHub Assets

Upload these assets to a private GitHub release or pre-release:

- `HyperSearch_1.0.0_Full_WslUpdatePolish_20260508.zip`
- `HyperSearch_1.0.0_Online_WslUpdatePolish_20260508.zip`
- Optionally, standalone installer files from `Online\` for connected users who do not need the full media package.

Recommended tester guidance:

- Use **Full** media for beta testers, clean Windows machines, offline-prone systems, or systems that may not have registry access.
- Use **Online** media for connected machines where pulling public or authenticated images is acceptable.
- Use the repository source path only for developers who intentionally want to run `scripts\Deploy-HyperSearch.cmd` or local builds.

## Release Description Template

```markdown
HyperSearch 1.0 private beta focuses on local-control search, optional local-model research synthesis, and a Windows-first desktop launcher.

Recommended install:
- Download the Full media zip.
- Extract it to a writable folder.
- Run `HyperSearch_1.0.0_x64-setup.exe`.
- Launch HyperSearch from the installed shortcut.

Use the Online media only when the machine has reliable internet access and can pull the required Docker images.

Search-only mode is supported. LM Studio is optional; when no local model is connected, HyperSearch still supports search, source review, session saving, diagnostics export, and later model setup from Operations.

Expected prerequisites:
- Windows 10/11.
- Docker Desktop for the backend runtime.
- Optional LM Studio or another local OpenAI-compatible provider for LLM synthesis.

Installer behavior:
- Setup checks WSL status and runs `wsl --update` before Docker image setup.
- If Windows requires elevation for the WSL update, setup requests elevation and records the result in `%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json`.

Checksums:
- Full media zip: `E0B509667E6E86A2D21B6E6B167460C86B7349CEFCD5968ACA4932866E2FA890`
- Online media zip: `9A82A1CE41F124FD4252A4B4A51680BEFCC0EC0EC3BA5072E9080537B66409A4`
```

## Validation Recorded For This Candidate

- Python test suite: `19 passed, 1 skipped`.
- UI build: passed.
- Desktop frontend build: passed.
- Desktop native `cargo check`: passed.
- Installer PowerShell parse check: passed.
- Production npm audits for UI and desktop: zero reported vulnerabilities.
- Docker Compose release and development config validation: passed. This machine emitted the known `%USERPROFILE%\.docker\config.json` access warning during validation, which Docker doctor reports with remediation guidance.
- Tauri release build, MSI, and NSIS installer generation: passed.
- Docker image archive and both installer media channels: built successfully with WSL update setup included.
- Release stack readiness: `/v1/ready` reported search ready and LLM ready with LM Studio loaded.
- Research synthesis smoke: returned `llm-synthesis` with two requested and two retrieved sources.
