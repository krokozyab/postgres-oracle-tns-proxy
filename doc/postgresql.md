# PostgreSQL prerequisites

orapglink does not create databases, roles, extensions, or dictionary views at
runtime. Provision them once with a PostgreSQL administrator, then run the proxy
with a restricted read-only role.

## Supported baseline

- PostgreSQL 16 is the tested server version.
- The `orafce` extension is required by default.
- The runtime role needs only `CONNECT`, schema `USAGE`, table `SELECT`, and
  access to the required `oracle` functions.
- A separate install role owns the `oradict` compatibility schema.

The included Docker demo is the executable reference configuration.

## Why orafce is mandatory

The translator delegates Oracle semantics for functions such as `ADD_MONTHS`,
`LAST_DAY`, `MONTHS_BETWEEN`, `INSTR`, `SUBSTR`, `TO_CHAR`, `TO_DATE`, `RTRIM`,
`RPAD`, and `REGEXP_LIKE` to orafce.

Without it, some functions fail, while others silently resolve to PostgreSQL
built-ins with different behavior. The default startup check prevents that
unsafe partial compatibility.

## Provisioning files

| File | Purpose |
|---|---|
| [`sql/provision_roles.sql`](../sql/provision_roles.sql) | Creates the restricted runtime role and the dictionary-install role. Replace its documented placeholders first. |
| [`sql/oracle_compat_views.sql`](../sql/oracle_compat_views.sql) | Installs `DUAL` and `ALL_*`/`USER_*`/`DBA_*` views over live `pg_catalog`. |

The full commands, including database selection and grants, are in
[`QUICKSTART.md`](../QUICKSTART.md). Run schema grants while connected to the
target database, not the maintenance `postgres` database.

## Runtime role test

Before starting orapglink, prove both halves of the security model:

```sh
PGPASSWORD="$RUNTIME_PW" psql "$RUNTIME_DSN" -c \
  'SELECT * FROM oradict.dual;'

PGPASSWORD="$RUNTIME_PW" psql "$RUNTIME_DSN" -c \
  'CREATE TABLE should_fail (i integer);'
```

The first command must succeed and the second must fail with a permission
error. If a write succeeds, do not start the proxy with that DSN.

## Schema mapping

PostgreSQL database and schema names are different concepts:

```text
PostgreSQL database appdb
└── PostgreSQL schema public
    └── tables

Oracle clients see one logical owner/service: PUBLIC
```

For this example:

```sh
ORAPGLINK_POSTGRES_DSN='postgresql://orapglink_runtime:...@db:5432/appdb?sslmode=require'
ORAPGLINK_PG_SCHEMAS=public
ORAPGLINK_LOGICAL_SCHEMA=PUBLIC
```

The `PUBLIC` owner literal installed in the dictionary views must match
`ORAPGLINK_LOGICAL_SCHEMA`, and clients use the same value as their Oracle
service name.

## Multiple PostgreSQL schemas

`ORAPGLINK_PG_SCHEMAS` accepts a comma-separated list and becomes an explicit
runtime `search_path`. Grant the runtime role `USAGE` and `SELECT` in every
listed schema. Name collisions follow PostgreSQL search-path order, so avoid
exposing identically named relations unless that precedence is deliberate.

The Oracle-facing identity remains one logical schema; this is not a per-user
or per-PostgreSQL-schema tenancy mechanism. Run separate processes with separate
roles and ports when isolation is required.

## Catalog behavior

The proxy reads relation/type metadata directly from live `pg_catalog`. It does
not use a DuckDB or other separate metadata database. A snapshot loads at
startup and refreshes every five minutes by default; change this with
`--catalog-refresh-interval`.

Oracle dictionary queries are ordinary reads of the installed `oradict` views.
Re-run the shipped migration after upgrades so the views stay aligned with the
binary's expected contract.
