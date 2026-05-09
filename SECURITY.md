# Security Policy

HyperSearch 1.0 is a local-control application. It is designed for localhost use by default and opt-in LAN use with pairing-token protection.

## Supported Versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| Older prerelease builds | No |

## Supported Security Model

- Do not expose HyperSearch directly to the public internet.
- Keep LAN mode disabled unless another device on the same private network needs access.
- Rotate the pairing token if a LAN device should no longer have access.
- Use only local model providers for research synthesis.
- Do not put cloud provider API keys into HyperSearch configuration.
- Treat diagnostics bundles as sensitive until you have reviewed them, even though HyperSearch redacts common token, key, password, and auth patterns.

## Report a Vulnerability

Please do not report unpatched security vulnerabilities through public GitHub issues, discussions, or pull requests.

Use GitHub's private vulnerability reporting workflow:

1. Go to the HyperSearch repository on GitHub.
2. Open the **Security** tab.
3. Choose **Report a vulnerability**.
4. Include the affected version, operating system, install path, reproduction steps, expected impact, and any proof of concept you can safely share.

If private vulnerability reporting is not visible yet, open a minimal public GitHub issue asking for a private security intake path. Do not include exploit details, credentials, pairing tokens, diagnostics bundles, local `.env` contents, or personal machine information in that public issue.

## Bug Reports and Support

Use public GitHub issues for normal bugs, installer failures, documentation gaps, and feature-neutral usability problems. Remove secrets and local credentials from logs before attaching them.

## Response Expectations

HyperSearch is maintained by a solo publisher. Security reports will be triaged as quickly as possible, with priority given to issues that affect local-only access controls, pairing-token handling, diagnostics redaction, installer integrity, or arbitrary command execution.
