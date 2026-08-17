# Observability

orapglink exposes structured logs, Prometheus metrics, and HTTP health probes.
The operations server is disabled by default and has **no authentication and no
TLS**.

## Enable the operations endpoint

In `config.env`:

```sh
ORAPGLINK_METRICS_LISTEN=127.0.0.1:9109
```

Or on the command line:

```sh
./orapglink --metrics-listen 127.0.0.1:9109
```

Never bind it to an untrusted interface. If a remote monitoring system must
scrape it, use an authenticating reverse proxy or a private monitoring network.

## Health probes

| Path | Purpose | Success response |
|---|---|---|
| `/healthz` | Process liveness | HTTP 200, `{"status":"ok"}` |
| `/readyz` | Readiness after PostgreSQL and catalog wiring | HTTP 200, `{"status":"ready"}` |
| `/metrics` | Prometheus text exposition | HTTP 200 |

```sh
curl -fsS http://127.0.0.1:9109/healthz
curl -fsS http://127.0.0.1:9109/readyz
curl -fsS http://127.0.0.1:9109/metrics
```

Readiness is deliberately simple in this release: PostgreSQL is mandatory at
startup, so a serving process is already wired to its backend and catalog. A
successful `/readyz` does not execute a test query on every probe.

## Metric groups

### Oracle-wire layer

- `orawire_connections_active`
- `orawire_connections_accepted_total`
- `orawire_connections_refused_total`
- `orawire_queries_total`
- `orawire_query_errors_total`
- `orawire_interrupts_total`
- `orawire_protocol_timeouts_total`
- `orawire_compatibility_warnings_total`
- `orawire_diagnostic_bundles_total`
- `orawire_diagnostic_bundle_errors_total`

The inherited BI Publisher/SOAP latency metric is intentionally omitted because
this product uses PostgreSQL, not SOAP.

### PostgreSQL backend

- `orapglink_backend_queries_total`
- `orapglink_backend_translate_errors_total`
- `orapglink_backend_query_errors_total`
- `orapglink_backend_results_capped_total`
- `orapglink_backend_rows_returned_total`
- `orapglink_backend_admission_waits_total`
- `orapglink_backend_admission_timeouts_total`
- `orapglink_backend_query_duration_seconds` (histogram)

### Streaming cursors

- `orapglink_backend_cursors_opened_total`
- `orapglink_backend_cursors_closed_total`
- `orapglink_backend_cursors_expired_total`
- `orapglink_backend_cursors_refused_total`
- `orapglink_backend_cursor_errors_total`
- `orapglink_backend_cursor_pages_total`
- `orapglink_backend_cursor_rows_total`
- `orapglink_backend_cursor_page_seconds_total`

### PostgreSQL pool

- `orapglink_backend_pool_total_conns`
- `orapglink_backend_pool_idle_conns`
- `orapglink_backend_pool_acquired_conns`
- `orapglink_backend_pool_max_conns`
- `orapglink_backend_pool_acquire_total`
- `orapglink_backend_pool_empty_acquire_total`
- `orapglink_backend_pool_canceled_acquire_total`
- `orapglink_backend_pool_new_conns_total`

## Useful PromQL

Query error ratio over five minutes:

```promql
rate(orapglink_backend_query_errors_total[5m])
/
clamp_min(rate(orapglink_backend_queries_total[5m]), 1)
```

95th-percentile backend query latency:

```promql
histogram_quantile(
  0.95,
  sum by (le) (rate(orapglink_backend_query_duration_seconds_bucket[5m]))
)
```

Pool saturation:

```promql
orapglink_backend_pool_acquired_conns
/
clamp_min(orapglink_backend_pool_max_conns, 1)
```

Open streaming cursors as a derived gauge:

```promql
orapglink_backend_cursors_opened_total
-
orapglink_backend_cursors_closed_total
```

## What to alert on

- `/readyz` unavailable for longer than the normal restart window.
- Any sustained increase in `orapglink_backend_query_errors_total`.
- `orapglink_backend_results_capped_total` increasing: clients are requesting
  more than the configured envelope.
- `orapglink_backend_admission_timeouts_total` increasing: the query
  concurrency guard is saturated.
- Pool acquired connections remaining near the maximum.
- Cursor refusals or expirations increasing unexpectedly.
- Compatibility warnings after a client upgrade.

## Logs

Logs are structured `slog` text on stderr. The normal startup sequence includes
orafce verification, catalog snapshot loading, the effective resource envelope,
and the bound Oracle listener. Use `--log-level debug` only while diagnosing a
problem; query text and backend error details can be sensitive.

The binary does not send telemetry or analytics to the project owner.
