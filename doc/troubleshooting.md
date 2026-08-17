# Troubleshooting

Start with the process log and the three independent layers: Oracle client to
orapglink, orapglink to PostgreSQL, and SQL translation.

## Startup failures

### `--oracle-password ... is required`

Load `config.env` into the shell or pass `--oracle-password`. The file is not
read automatically:

```sh
set -a; . ./config.env; set +a
./orapglink
```

### PostgreSQL authentication or database errors

Test the exact runtime DSN outside the proxy:

```sh
psql "$ORAPGLINK_POSTGRES_DSN" -c 'select 1'
```

The DSN must select the same database in which `orafce`, runtime grants, and
`oradict` views were installed.

### `orafce verification failed`

Install the extension in the target database and grant the runtime role access:

```sql
CREATE EXTENSION IF NOT EXISTS orafce;
GRANT USAGE ON SCHEMA oracle TO orapglink_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracle TO orapglink_runtime;
```

Do not disable the check in production. Native PostgreSQL functions with the
same names can have different semantics without producing an error.

### Listener bind failure

Another process owns the configured address, or the address is unavailable.
Check the port and `ORAPGLINK_ORACLE_LISTEN`. Do not kill an unknown process;
choose another port or identify the owner first.

## Client connection failures

### Connection refused / `ORA-12541`

Confirm the startup log contains `Oracle-wire (TNS) listening`, then verify the
client can reach that host and port. A remote client cannot reach a listener
bound to `127.0.0.1`.

### Service-name errors

Use `ORAPGLINK_LOGICAL_SCHEMA` as the client service name. For PostgreSQL schema
`public`, the common value is `PUBLIC`.

### Authentication fails

The client password must equal `ORAPGLINK_ORACLE_PASSWORD`. The username is not
validated. Some rejected dialects currently surface a connection close rather
than Oracle's usual `ORA-01017`; see the authentication section of
[`KNOWN_LIMITATIONS.md`](../KNOWN_LIMITATIONS.md).

### A client worked before an upgrade

Oracle clients can change behavior between versions. Check the public release
verification matrix for the versions and families covered. With
`--strict-version-match`, an unverified version is deliberately refused.

## Query and catalog problems

### `relation "oradict.dual" does not exist`

Install `sql/oracle_compat_views.sql` into the same database used by the runtime
DSN. Re-run the migration after upgrading.

### `USER_TABLES` is empty

Check all three identity values:

1. the owner literal substituted into `sql/oracle_compat_views.sql`;
2. `ORAPGLINK_LOGICAL_SCHEMA`;
3. the Oracle client service name.

They must match. Also confirm that the runtime role has `USAGE` on the data
schema and `SELECT` on its tables in the target database—not the maintenance
`postgres` database.

### `ORA-03001: unimplemented feature`

The proxy recognized a shape it cannot safely translate or encode. The session
normally remains usable. Check
[`TRANSLATOR_SUPPORT.md`](../TRANSLATOR_SUPPORT.md), check the public release
verification matrix, or rewrite the query. For native read-only PostgreSQL SQL,
use the `/*pg*/` prefix.

### Error points at `translated SQL line N, column M`

The location belongs to generated PostgreSQL SQL. Enable the loopback-only
translation playground and paste the Oracle statement there:

```sh
./orapglink --playground-listen 127.0.0.1:8099
```

### `ORA-16000`

The statement attempts a write or DDL operation. orapglink is intentionally
read-only; perform writes through PostgreSQL's own controlled interfaces.

### Size, queue, or timeout errors

- `ORA-04030`: a result or cell exceeded a configured size cap.
- `ORA-07454`: no query-admission slot became available before timeout.
- active-time-limit error: query execution exceeded its deadline.

Ask for fewer rows or columns first. Raise caps only after calculating the
process envelope described in [Limits and guardrails](limits.md).

## GUI behavior

- DBeaver is the recommended browser. Its deep Oracle-only metadata panels are
  incomplete.
- SQL Developer worksheets work, but its internal object navigator is not
  supported and may show an empty tree.
- Thick OCI and database-link clients have narrower zero-row/type-shape
  coverage than thin drivers.

## Collecting useful diagnostic information

1. Record `./orapglink --version` and the release tag.
2. Record the exact client product and version.
3. Reproduce with the smallest read-only query possible.
4. Retry with `--log-level debug` in a safe environment.
5. Include the `ORA-` error and proxy log, with credentials and data removed.

Do not publish passwords, DSNs containing passwords, production rows,
unredacted diagnostic bundles, or debug logs. Security issues belong through the
private process in [`SECURITY.md`](../SECURITY.md).
