# Source Offer and Corresponding Source

HyperSearch-owned source code is licensed under `AGPL-3.0-only`. Public binary releases, installer media, and container images should be accompanied by the complete corresponding HyperSearch source for the exact release tag or commit used to build them.

For public releases, provide source access through the GitHub release tag and keep these files in the release assets or repository root:

- `LICENSE.md`
- `COPYING`
- `THIRD_PARTY_NOTICES.md`
- `SOURCE_OFFER.md`
- media `manifest.json` and `checksums.sha256` files
- Docker image digest manifest files produced by `scripts/Build-ContainerImages.ps1`

The complete corresponding HyperSearch source includes the API, UI, desktop launcher, Docker/Compose configuration, build scripts, installer helper scripts, documentation, and test assets needed to rebuild the shipped HyperSearch binaries and images.

Third-party service images and tools are provided under their own licenses. Their source-code locations are summarized in `THIRD_PARTY_NOTICES.md`. SearXNG is an AGPL-licensed upstream service and must remain attributable with source access preserved in any redistributed media.

If a binary or installer package is separated from its matching source release, the distributor should provide the matching source archive or release tag location for at least the period required by the applicable free-software licenses.
