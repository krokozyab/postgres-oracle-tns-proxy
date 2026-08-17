# Limits and guardrails

orapglink is read-only and bounded by default. The limits protect PostgreSQL and
the proxy from accidental unbounded reports, hostile client-supplied sizes, and
connections that stop halfway through the wire protocol.

## Buffered results

| Limit | Default | Failure |
|---|---:|---|
| Rows per result | `50000` | Result is refused once the configured envelope is exceeded. |
| Bytes per result | `64 MiB` | `ORA-04030` with the session left usable. |
| Bytes per cell | `32 MiB` | `ORA-04030`; this is also the practical LOB ceiling. |
| Concurrent materializations | `8` | Waits for a slot, then `ORA-07454` after the query timeout. |
| Query duration | `30s` | Final timeout error; the backend query is canceled. |

The approximate maximum for buffered results is:

```text
max-concurrent-queries × max-result-bytes
```

The defaults therefore allow about 512 MiB of in-flight result memory. This is
not the complete process footprint: allow room for row bookkeeping, wire
buffers, PostgreSQL driver state, the binary, and streamed pages. The startup
log prints the configured envelope and warns about unusually large values.

Prefer bounding SQL with selective predicates or `ROWNUM` instead of increasing
the caps globally.

## Streaming cursors

| Limit | Default | Purpose |
|---|---:|---|
| Open cursors | `16` | Each open cursor holds a PostgreSQL connection and read-only transaction. |
| Idle cursor time | `45s` | Reclaims cursors abandoned between pages. |
| Page memory | `8 MiB` | Bounds one streamed page. |
| All page memory | `128 MiB` | Bounds aggregate page memory across cursors. |
| Rows requested by one FETCH | `100000` | Refuses absurd client-supplied FETCH sizes. |

`--max-open-cursors` is clamped at startup so cursors cannot consume the entire
PostgreSQL pool. Keep `--cursor-idle-timeout` below
`--pg-idle-in-transaction-timeout`.

## Connections and protocol state

- `--max-connections=512` closes new connections immediately when the cap is
  reached. Set `0` only if another layer enforces a suitable limit.
- `--protocol-timeout=1m` reclaims a connection stuck mid-handshake or in a
  protocol exchange it has already committed to completing. It does not close
  an ordinary idle interactive session.
- `--strict-version-match` refuses unknown client versions instead of choosing
  a best-effort compatible profile. This is safer but may reject clients that
  would otherwise work.

## PostgreSQL backstops

Each pooled PostgreSQL connection is configured with:

- `default_transaction_read_only=on`;
- an explicit `search_path` without `$user`;
- `statement_timeout=35s` by default;
- `lock_timeout=10s`;
- `idle_in_transaction_session_timeout=1m`.

The Go query timeout is intentionally shorter than PostgreSQL's statement
timeout so the proxy can return a clean Oracle-shaped error first.

## Read-only is layered

The translator rejects DML and DDL with `ORA-16000`. Independently, every query
runs in a PostgreSQL read-only transaction using the restricted runtime role.
The supplied SQL provisioning creates that role without write grants. Validate
both read success and write failure before deployment; the exact commands are
in [`QUICKSTART.md`](../QUICKSTART.md).

## Result-shape and SQL limits

Resource bounds do not imply language or protocol coverage. Some thick-client
and database-link result shapes are outside the validated compatibility scope
and are refused rather than approximated.
The SQL translator also implements a documented subset of Oracle SQL.

- [`TRANSLATOR_SUPPORT.md`](../TRANSLATOR_SUPPORT.md) is the SQL contract.
- [`KNOWN_LIMITATIONS.md`](../KNOWN_LIMITATIONS.md) lists user-visible limits.
- [Testing and verification](testing.md) reports the published release's
  client coverage and test scale.
