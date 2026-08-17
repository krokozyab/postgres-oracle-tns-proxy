# Installation and deployment

There are two supported ways to try orapglink: the zero-configuration Docker
demo and a manual installation against your own PostgreSQL database.

## Fastest path: Docker demo

The demo provisions PostgreSQL 16, `orafce`, the read-only roles, Oracle
dictionary views, and sample data. No `.env` edits are required.

```sh
git clone https://github.com/krokozyab/postgres-oracle-tns-proxy.git
cd postgres-oracle-tns-proxy/deploy/docker
docker compose up -d db
```

To run the full Oracle-wire smoke, download the Linux amd64 release archive,
unpack it, and place the `orapglink` binary in `deploy/docker/`:

```sh
docker compose --profile proxy up --build --abort-on-container-exit smoke
```

The smoke container uses python-oracledb in thin mode to query sample
PostgreSQL data through the real Oracle Net listener. See
[`deploy/docker/README.md`](../deploy/docker/README.md) for architecture,
commands, and cleanup.

## Manual installation

1. Download the archive for your platform from
   [Releases](https://github.com/krokozyab/postgres-oracle-tns-proxy/releases).
2. Download `SHA256SUMS` and verify the archive.
3. Provision PostgreSQL 16, `orafce`, runtime/install roles, and dictionary
   views using the included SQL files.
4. Copy `config.env.example` to `config.env` and replace every `change-me`
   placeholder.
5. Load the file into your shell and start the binary.
6. Connect an Oracle client using the configured logical schema as service
   name and the shared Oracle-side password.

The exact copy-paste walkthrough is in [`QUICKSTART.md`](../QUICKSTART.md), with
a Russian translation in [`QUICKSTART_RU.md`](../QUICKSTART_RU.md).

## Running as a service

The binary runs in the foreground and logs to stderr. A service manager should:

- set the working directory to the unpacked release directory;
- load secrets from a protected environment file or secret manager;
- run as an unprivileged operating-system user;
- restart on unexpected exit, but not in a tight loop;
- send `SIGTERM` for graceful shutdown;
- keep the Oracle listener on loopback or a trusted network;
- expose the optional health endpoint only through a protected monitoring
  path.

Example systemd unit:

```ini
[Unit]
Description=orapglink Oracle Net to PostgreSQL proxy
After=network-online.target postgresql.service

[Service]
Type=simple
User=orapglink
Group=orapglink
WorkingDirectory=/opt/orapglink
EnvironmentFile=/etc/orapglink/config.env
ExecStart=/opt/orapglink/orapglink
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

The file referenced by `EnvironmentFile` uses systemd environment syntax; do
not add shell commands such as `export` or `set -a` to it.

## Network placement

There is no Oracle Net native encryption and no TCPS in this preview.

- Local tools: keep `ORAPGLINK_ORACLE_LISTEN=127.0.0.1:1521`.
- Remote tools or a database link: bind a reachable private address and use a
  trusted network, VPN, or TLS tunnel.
- Never publish port 1521 directly to the Internet.

The PostgreSQL DSN has its own TLS setting. Use `sslmode=require` or stronger
for a remote PostgreSQL connection. That does not encrypt the Oracle side.

## Upgrading

1. Keep the previous binary and configuration available for rollback.
2. Verify the new archive with its own `SHA256SUMS`.
3. Read the release notes and `KNOWN_LIMITATIONS.md`.
4. Re-run the included `sql/oracle_compat_views.sql` migration; it is designed
   to be idempotent and transactional.
5. Check `--version` and the release's published compatibility matrix before
   starting.
6. Run representative queries with the real client versions you use.
7. Replace the binary and restart the service.

Do not copy `SHA256SUMS` between releases; verify each version against the file
published next to that version.
