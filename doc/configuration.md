# Configuration reference

orapglink accepts command-line flags and a small set of environment variables.
An explicit command-line flag wins over its environment variable. The binary
does not parse `config.env` itself; load it through your shell before starting
the process:

```sh
set -a
. ./config.env
set +a
./orapglink
```

Start from [`config.env.example`](../config.env.example). It contains safe
defaults and placeholders, never working credentials.

## Required settings

| Flag | Environment variable | Meaning |
|---|---|---|
| `--oracle-password` | `ORAPGLINK_ORACLE_PASSWORD` | One shared password accepted from every Oracle client. Usernames are not validated. |
| `--postgres-dsn` | `ORAPGLINK_POSTGRES_DSN` | DSN for the read-only PostgreSQL runtime role. Never use a superuser or table owner. |

## Listener and identity

| Flag | Environment variable | Default | Meaning |
|---|---|---:|---|
| `--oracle-listen` | `ORAPGLINK_ORACLE_LISTEN` | `127.0.0.1:1521` | Oracle Net listener address. Keep it on loopback unless a remote client or database link must reach it. |
| `--logical-schema` | `ORAPGLINK_LOGICAL_SCHEMA` | `APP` | Single Oracle schema/user identity reported to every client. |
| `--pg-schemas` | `ORAPGLINK_PG_SCHEMAS` | `public` | Comma-separated PostgreSQL schemas exposed through the runtime `search_path`. |
| `--dict-schema` | `ORAPGLINK_DICT_SCHEMA` | `oradict` | PostgreSQL schema containing `DUAL` and the emulated Oracle dictionary views. |
| `--max-connections` | `ORAPGLINK_MAX_CONNECTIONS` | `512` | Maximum simultaneous Oracle-wire connections. `0` disables this guard. |
| `--protocol-timeout` | `ORAPGLINK_PROTOCOL_TIMEOUT` | `1m` | Timeout for an incomplete handshake or protocol chain. It does not expire an ordinary idle session. |
| `--strict-version-match` | `ORAPGLINK_STRICT_VERSION_MATCH` | `false` | Refuse unverified client/protocol versions instead of selecting the nearest compatible profile. |

`ORAPGLINK_LOGICAL_SCHEMA`, the owner literal installed by
`sql/oracle_compat_views.sql`, and the Oracle client service name must agree.
For PostgreSQL schema `public`, use Oracle logical schema and service name
`PUBLIC`.

## PostgreSQL and translation

| Flag | Default | Meaning |
|---|---:|---|
| `--require-orafce` | `true` | Refuse startup unless the required Oracle-semantic functions are available. Environment: `ORAPGLINK_REQUIRE_ORAFCE`. |
| `--fold-quoted-upper` | `true` | Map Oracle-style quoted uppercase identifiers to ordinary lowercase PostgreSQL identifiers. |
| `--catalog-refresh-interval` | `5m` | Reload the live `pg_catalog` type snapshot. `0` loads it only at startup. |
| `--query-timeout` | `30s` | Go-level deadline for one query. |
| `--pg-statement-timeout` | `35s` | PostgreSQL backstop. Keep it above `--query-timeout`. |
| `--pg-lock-timeout` | `10s` | PostgreSQL `lock_timeout`. |
| `--pg-idle-in-transaction-timeout` | `1m` | PostgreSQL timeout protecting streaming-cursor transactions. Keep it above `--cursor-idle-timeout`. |

For native PostgreSQL SQL that the Oracle translator does not model, prefix a
read-only statement with `/*pg*/`. It still runs with the runtime role, inside
a read-only transaction, under the same timeout and result limits.

## Resource limits

| Flag | Default | Meaning |
|---|---:|---|
| `--max-result-rows` | `50000` | Rows materialized by one buffered query. |
| `--max-result-bytes` | `67108864` (64 MiB) | Estimated retained bytes for one buffered result. |
| `--max-cell-bytes` | `33554432` (32 MiB) | Maximum encoded size of one cell. |
| `--max-concurrent-queries` | `8` | Buffered results materialized concurrently. A negative value disables the guard. |
| `--max-open-cursors` | `16` | Streaming cursors. It is clamped at startup to leave pool capacity for other work. |
| `--cursor-idle-timeout` | `45s` | Reclaim an unused streaming cursor. |
| `--max-page-bytes` | `8388608` (8 MiB) | Estimated memory for one streamed page. |
| `--cursor-memory-budget` | `134217728` (128 MiB) | Aggregate memory budget for outstanding streamed pages. |
| `--max-fetch-rows` | `100000` | Largest client-supplied FETCH row count accepted. |

The main buffered-result envelope is approximately:

```text
max-concurrent-queries × max-result-bytes
```

At the defaults that is about 512 MiB before protocol copies, driver buffers,
the process itself, and streaming pages. See [Limits and guardrails](limits.md)
before raising any cap.

## Operations and development endpoints

| Flag | Environment variable | Default | Meaning |
|---|---|---:|---|
| `--metrics-listen` | `ORAPGLINK_METRICS_LISTEN` | off | Prometheus `/metrics`, `/healthz`, and `/readyz`. No authentication or TLS. |
| `--playground-listen` | `ORAPGLINK_PLAYGROUND_LISTEN` | off | Browser-based Oracle-to-PostgreSQL translator. No authentication or TLS. |
| `--log-level` | — | `info` | `debug`, `info`, `warn`, or `error`. |

Keep both HTTP listeners on `127.0.0.1` or place an authenticating reverse
proxy in front. Details and example probes are in
[Observability](observability.md).

## Inspection commands

```sh
./orapglink --version
./orapglink --help
```

Published client coverage and known limits are documented in
[Testing and verification](testing.md) and
[`KNOWN_LIMITATIONS.md`](../KNOWN_LIMITATIONS.md).
