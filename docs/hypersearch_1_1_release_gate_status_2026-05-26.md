# HyperSearch 1.1 Release Gate Status - 2026-05-26

## Result

The rebuilt HyperSearch 1.1 Full media release gate passed on 2026-05-26 after repairing the Windows 10 lab baseline.

- Final gate: `20260526-215927`
- Final matrix run: `20260526-215933`
- Summary: `%LOCALAPPDATA%\HyperSearch\installer-lab\release-gates\20260526-215927\release-gate-summary.json`
- Matrix summary: `%LOCALAPPDATA%\HyperSearch\installer-lab\runs\20260526-215933\matrix-summary.json`
- Media: `Installation Media\RC_20260526_1_1_win10fix\Full`
- Result: `status=passed`, `passed=9`, `failed=0`

## Baseline Repair

The earlier rebuilt-media gate `20260526-193259` failed because all Docker-dependent Windows 10 lanes reached Docker Desktop with WSL reporting:

`Wsl/ERROR_SERVICE_DOES_NOT_EXIST`

The installer now treats that WSL service-missing state as a reboot/resume prerequisite block instead of allowing Docker setup to continue against an unusable WSL backend. A focused rerun then proved the installer requested reboot/resume, but the old Windows 10 checkpoint did not return to PowerShell Direct after that WSL servicing reboot.

The Windows 10 baseline was repaired and recaptured:

- Repair: `%LOCALAPPDATA%\HyperSearch\installer-lab\baseline-repairs\20260526-214639\baseline-repair-summary.json`
- VM: `HyperSearchLab-Win10-22H2`
- Checkpoint: `clean-windows-docker-supported-ready`
- Repair result: `passed`
- Bundled WSL MSI installed successfully
- Final WSL status: `Default Version: 2`
- Final WSL version: `2.7.3.0`
- `dockerSupportedReady=true`

After repair, focused gate `20260526-214911` passed `win10-fresh-standard-full`.

## Final Coverage

All final matrix scenarios passed:

- `win10-nsis-bootstrap-smoke`
- `win10-fresh-standard-full`
- `win10-compose-env-bom`
- `win10-search-only-skip-lmstudio`
- `win11-nsis-bootstrap-smoke`
- `win11-fresh-standard-full`
- `win11-nsis-standard-full`
- `win11-compose-env-bom`
- `win11-search-only-skip-lmstudio`

Strict Standard Full evidence:

- `win10-fresh-standard-full`: `result=passed`, warnings `0`, Docker ready, bundled images verified, `/v1/live=200`, `/v1/ready=200`, LM Studio detected, `lms.exe` ready.
- `win11-fresh-standard-full`: `result=passed`, warnings `0`, Docker ready, bundled images verified, `/v1/live=200`, `/v1/ready=200`, LM Studio detected, `lms.exe` ready.
- `win11-nsis-standard-full`: `result=passed`, warnings `0`, Docker ready, bundled images verified, `/v1/live=200`, `/v1/ready=200`, LM Studio detected, `lms.exe` ready, login autostart requested and registered.

## Local Checks

Completed before the final full VM gate:

- `pytest`: `33 passed, 1 skipped`
- Gate unit step: `python -m pytest tests/unit/test_installer_wizard.py -q` passed
- Docker Compose config check passed with the known host Docker config ACL warning
- Fresh Full media build completed with rebuilt Docker image archive
- Tauri desktop build completed and produced MSI plus NSIS bundles

## Media

Fresh Full media:

`Installation Media\RC_20260526_1_1_win10fix`

Image archive:

`Installation Media\RC_20260526_1_1_win10fix\image-build\hypersearch-images-1.1.0.tar`

Image archive SHA256:

`70a2d77b652bde5bc95ce343468be41be363e5d5b8413eeb22369dbc37aea73c`

The media signing summary was produced in `Verify` mode and reports unsigned HyperSearch EXE/MSI artifacts. That is expected for this local unsigned release-gate path, but trusted public distribution still needs a real signing certificate pass.

## Release Assessment

The automated VM release gate is green for HyperSearch 1.1 Full media on the repaired Windows 10 and Windows 11 lab baselines. The remaining release policy item is signing/freeze: commit or otherwise freeze the release-critical tree, then produce the trusted signed public media if a signed release is required.
