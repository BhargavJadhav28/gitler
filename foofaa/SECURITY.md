# Security Policy

## Supported versions

Security fixes target the latest stable release. Older releases may remain
available for reproducibility, but they are not maintained branches.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting form:

<https://github.com/BhargavJadhav28/gitler/security/advisories/new>

Do not report an undisclosed vulnerability in a public issue, pull request, or
release discussion. Include the affected version or commit, operating system
and architecture, reproduction steps, impact, and any relevant logs stripped
of personal data or secrets.

If private vulnerability reporting is unavailable, open a minimal public issue
requesting a private contact channel without describing exploit details.

## Response and disclosure

Maintainers will acknowledge a report when practicable, investigate the report,
and coordinate a fix and disclosure timeline with the reporter. A confirmed
issue is handled by publishing a higher fixed version, preserving historical
release asset bytes, and issuing a GitHub Release advisory. Security advisories
identify affected versions, the fixed version, severity when known, and any
mitigation or upgrade guidance.

The no-cost release pipeline uses SHA-256 manifests and GitHub artifact
attestations. These controls help detect corruption and provide build
provenance; they are not platform code-signing certificates.
