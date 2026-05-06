# HyperSearch 1.0 Local-Control Notes

HyperSearch 1.0 is scoped around personal local control.

## Supported

- Windows-first desktop launch flow.
- Docker-managed local backend services.
- Local SearXNG search.
- Local SQLite history.
- Local LM Studio, vLLM, or llama.cpp-compatible synthesis providers.
- LAN access only when explicitly enabled and paired.

## Not Supported In 1.0

- Cloud model providers.
- External provider API keys.
- Public internet hosting.
- Guaranteed automatic model downloads on every machine.
- Fully automated LM Studio model loading.

## Expected User Flow

1. Install/open HyperSearch Desktop.
2. Let installer setup verify Docker Desktop, image availability, LM Studio, and hardware profile.
3. Start the HyperSearch backend from the launcher.
4. Open the console.
5. Configure or verify the local provider profile.
6. Run search normally.
7. Run research only when a local provider and preferred model are available.

## Release Candidate Packaging

- Online media installs HyperSearch and pulls prebuilt service images.
- Full media installs HyperSearch and loads bundled service image archives.
- Both paths keep HyperSearch localhost-first and use LAN pairing only when explicitly enabled.
