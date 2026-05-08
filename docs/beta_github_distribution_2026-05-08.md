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
Installation Media\ResearchReliabilityPolish_20260508
```

Upload-ready zip assets:

| Asset | Size | SHA256 |
| --- | ---: | --- |
| `HyperSearch_1.0.0_Online_ResearchReliabilityPolish_20260508.zip` | 10,406,237 bytes | `30EF8E9E29E6915831D010D36C3A1A3A271A5081207208323F39CF49A78CD31C` |
| `HyperSearch_1.0.0_Full_ResearchReliabilityPolish_20260508.zip` | 301,914,423 bytes | `37A1CD2C95E435141CE8FD8E8DC10FE6BD44EC354B04A0C1C00140CEAA850222` |

Important component hashes from the full media:

| Component | SHA256 |
| --- | --- |
| `Full\HyperSearch_1.0.0_x64-setup.exe` | `B8DA56C3FBBDA03ACC765D2E7B4246C24A9455359DE5439E8D407BF2619E0635` |
| `Full\payload\images\hypersearch-images-1.0.0.tar` | `46EEF7016CD961DC89AB7E3443B480A57DD290F6573E1A4C2FFAF404ECAC518E` |

## Recommended GitHub Assets

Upload these assets to a private GitHub release or pre-release:

- `HyperSearch_1.0.0_Full_ResearchReliabilityPolish_20260508.zip`
- `HyperSearch_1.0.0_Online_ResearchReliabilityPolish_20260508.zip`
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

Checksums:
- Full media zip: `37A1CD2C95E435141CE8FD8E8DC10FE6BD44EC354B04A0C1C00140CEAA850222`
- Online media zip: `30EF8E9E29E6915831D010D36C3A1A3A271A5081207208323F39CF49A78CD31C`
```

## Validation Recorded For This Candidate

- Python test suite: `19 passed, 1 skipped`.
- UI build: passed.
- Desktop frontend build: passed.
- Desktop native `cargo check`: passed.
- Production npm audits for UI and desktop: zero reported vulnerabilities.
- Docker Compose release and development config validation: passed. This machine emitted the known `%USERPROFILE%\.docker\config.json` access warning during validation, which Docker doctor reports with remediation guidance.
- Tauri release build, MSI, and NSIS installer generation: passed.
- Docker image archive and both installer media channels: built successfully.
- Release stack readiness: `/v1/ready` reported search ready and LLM ready with LM Studio loaded.
- Research synthesis smoke: returned `llm-synthesis` with two requested and two retrieved sources.
