# Security policy

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** flow in the Security tab of
this repository. Do not open a public issue for a suspected vulnerability.

Include the orapglink version, operating system and architecture, client and
PostgreSQL versions, a minimal reproduction, and the security impact. Redact
credentials, hostnames, production data and access tokens. Do not attach raw
low-level diagnostic artifacts unless explicitly requested through the private
report.

## Deployment assumptions

The preview has no Oracle native network encryption or TCPS. Its Oracle Net
listener must stay on loopback, a trusted private network or a VPN, or sit
behind a separately managed encrypted tunnel. The service must use the
read-only PostgreSQL role created by `sql/provision_roles.sql`, never a
superuser or a write-capable role.

See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) for the complete operational
security constraints.
