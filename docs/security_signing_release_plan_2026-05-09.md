# HyperSearch Security, Signing, and Program Registration Plan - 2026-05-09

This plan covers the remaining security and Windows program-registration work before the public HyperSearch release. It assumes the owner-selected project license is `AGPL-3.0-only`, the solo publisher identity is Robert Choudury, and GitHub is the public project home.

This is an engineering release plan, not legal advice.

## AGPL-3.0-Only Check

Using `AGPL-3.0-only` is acceptable if the goal is to avoid automatic adoption of future GNU AGPL versions.

Practical implications:

- Use SPDX `AGPL-3.0-only`, not bare `AGPL-3.0`, for unambiguous package metadata and automated license tooling.
- Keep the full GNU AGPL v3 text in `COPYING`.
- SearXNG's upstream `AGPL-3.0-or-later` posture remains compatible for the current release because version 3 is available.
- Future compatibility is narrower. If a future dependency or ecosystem tool requires AGPLv4-or-later, HyperSearch would need an explicit relicensing decision.

## Current Repo Status

Completed:

- Tauri application identifier is `io.github.nacsez.hypersearch`.
- Tauri Windows publisher metadata is `Robert Choudury`.
- `SECURITY.md` points reporters to GitHub private vulnerability reporting instead of a temporary private-maintainer channel.
- GitHub issue templates warn users not to publish secrets or full diagnostics bundles.
- Dependabot is configured for npm, pip, Cargo, and Docker dependency tracking.
- A no-cost signing/verification helper exists at `scripts/Sign-HyperSearchRelease.ps1`.
- A release security metadata scan exists at `scripts/Test-ReleaseSecurity.ps1`.
- Prerequisite installers are verified by Authenticode signature and SHA256 where expected before execution.
- Diagnostics redaction is part of release readiness.
- LAN mode is opt-in and pairing-token protected.
- Release media includes checksums and Docker image digest manifests.
- `LICENSE.md`, `COPYING`, `THIRD_PARTY_NOTICES.md`, and `SOURCE_OFFER.md` are bundled into desktop resources and installation media.

Open before public release:

- GitHub private vulnerability reporting must be enabled by the repository owner after the repository is public or before inviting public testers.
- No-cost/self-signed signatures do not create public Windows trust.
- Windows desktop artifacts are not configured for public-trust code signing because no trusted certificate or Artifact Signing account is available.
- GitHub Actions cannot provide Microsoft-trusted Authenticode signing for free by itself.
- The 1.0 release uses the no-cost unsigned path. Release notes must clearly disclose unsigned artifacts and require SHA256 verification from GitHub Releases.

## Signing Strategy

Recommended paid path for public Windows distribution:

1. Use Microsoft Artifact Signing if eligible.
2. Use a traditional OV code-signing certificate if Artifact Signing is not practical.
3. Avoid paying extra for EV solely for SmartScreen. Microsoft's current guidance says EV no longer bypasses SmartScreen reputation for new file hashes.
4. Keep Microsoft Store distribution as a later option if avoiding SmartScreen prompts entirely becomes important.

No-cost path for the 1.0 release:

1. Publish only through GitHub Releases.
2. Publish SHA256 checksums for every asset.
3. Run `scripts/Sign-HyperSearchRelease.ps1 -Mode Verify` and include `signing-summary.json` in media.
4. Optionally use `scripts/Sign-HyperSearchRelease.ps1 -Mode SelfSigned` for local/test signing. This proves the signing pipeline and gives local integrity metadata, but it is not public trust.
5. Do not ask normal users to install a self-signed root certificate.

Expected user-facing behavior:

- Unsigned or self-signed builds produce the strongest Windows warning and may be blocked by some enterprise policies.
- Signed builds show a verified publisher, but new file hashes can still show SmartScreen warnings until reputation builds.
- Every new release artifact hash starts with no SmartScreen file reputation, so signing is necessary but not a complete first-download warning fix.

Artifacts to sign:

- `apps/desktop/src-tauri/target/release/hypersearch-desktop.exe`
- NSIS installer: `HyperSearch_<version>_x64-setup.exe`
- MSI installer: `HyperSearch_<version>_x64_en-US.msi`

Artifacts to hash and publish:

- Full media zip
- Online media zip
- Standalone NSIS installer if published separately
- Standalone MSI if published separately
- Docker image archive and image digest manifest when included in full media

## Owner Decisions Required

These cannot be completed purely from the local repo:

- Done: publisher identity is Robert Choudury.
- Done: stable application identifier is `io.github.nacsez.hypersearch`.
- Done: public security and bug reporting will use GitHub.
- Reported done by owner: enable GitHub private vulnerability reporting in repository settings.
- Done: the 1.0 release uses the no-cost unsigned path with SHA256 verification instructions.
- Later: choose Microsoft Artifact Signing or an OV certificate if public-trust Authenticode signing becomes worth the cost.

## Planned Repo Actions

1. Finalize license metadata as `AGPL-3.0-only`.
2. Done: update `SECURITY.md` to use GitHub reporting paths.
3. Done: add a release signing script, `scripts/Sign-HyperSearchRelease.ps1`, with:
   - SignTool discovery.
   - Azure Artifact Signing or certificate-store signing mode.
   - SHA256 file digest.
   - RFC 3161 timestamp URL.
   - verification by `signtool verify /pa /all /v`.
   - fallback `Get-AuthenticodeSignature` verification.
   - `signing-summary.json` output.
4. Done: add signing summary fields to installation media manifests.
5. Done: add a no-cost release security scan script and CI job.
6. Later: add release checks that fail if a future trusted-public release mode is requested and installer artifacts are unsigned.
7. Add a broader secrets/dependency security gate:
   - tracked-file secret scan
   - `npm audit --omit=dev` for UI and desktop
   - Python dependency audit or SBOM generation
   - Rust dependency audit or advisory check
   - container image scan or SBOM
8. Update release docs with the expected SmartScreen behavior for unsigned, self-signed, and trusted-signed builds.

## Planned Signing Commands

Traditional certificate-store mode:

```powershell
signtool sign /sha1 <certificate-thumbprint> /fd SHA256 /tr <timestamp-url> /td SHA256 /d "HyperSearch" <artifact>
signtool verify /pa /all /v <artifact>
```

Azure Artifact Signing mode:

```powershell
trusted-signing-cli -e <endpoint> -a <account> -c <certificate-profile> -d "HyperSearch" <artifact>
signtool verify /pa /all /v <artifact>
```

The signing script should not store private keys, certificate passwords, Azure secrets, or PFX files in the repository. Any credentials should come from the Windows certificate store, Azure login/session, or release-only environment variables.

No-cost local/self-signed mode:

```powershell
.\scripts\Sign-HyperSearchRelease.ps1 -Mode SelfSigned -CreateSelfSignedCertificate -SkipTimestamp
.\scripts\Sign-HyperSearchRelease.ps1 -Mode Verify
```

Use `-TrustSelfSignedCertificateForCurrentUser` only on your own test machine if you need Windows to report the self-signed signature as locally trusted. Do not use that as public installation guidance.

## Security Release Gates

Before public release:

- `SECURITY.md` has the GitHub reporting path.
- GitHub private vulnerability reporting is enabled.
- GitHub Issues templates warn users not to upload secrets, tokens, diagnostics bundles, or local `.env` files publicly.
- Branch protection or release-tag protection is enabled for the public repo.
- Dependabot or equivalent update alerts are enabled.
- No tracked `.env`, Docker credential, pairing token, API key, certificate, PFX, private key, or generated diagnostic bundle is present.
- Diagnostics export redaction is smoke-tested with sentinel secrets.
- Public release assets are trusted-signed, or the release notes clearly state that 1.0 uses the no-cost unsigned path with SHA256 verification instructions.
- Trusted-signed artifacts verify cleanly on a clean Windows machine, or no-cost unsigned artifacts have matching GitHub SHA256 checksums and a `signing-summary.json`.
- Downloaded GitHub assets match published SHA256 hashes.
- Full media install reaches search-ready from a clean Windows machine.

## Program Registration Checklist

- Finalize product name: `HyperSearch`.
- Done: publisher name is `Robert Choudury`.
- Done: Tauri `identifier` is `io.github.nacsez.hypersearch`.
- Confirm app icon and installer icon display correctly in Windows Apps and Features.
- Confirm install/uninstall display name, publisher, and version.
- Confirm GitHub repository URL and support URL for release notes.
- Consider reserving an owned domain or project website before using a reverse-DNS identifier based on it.

## References

- Microsoft SmartScreen reputation guidance: https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation
- Microsoft SignTool documentation: https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool
- Microsoft Artifact Signing quickstart: https://learn.microsoft.com/azure/trusted-signing/quickstart
- Tauri Windows signing documentation: https://v2.tauri.app/distribute/sign/windows/
