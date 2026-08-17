# Quick Start

From a downloaded archive to a working `SELECT` through an Oracle client.
Everything you need is in the archive and this distribution repository; you
should not need access to the private product source to complete this page. If
you do, that is a bug in this page — please report it.

Русская версия: **[QUICKSTART_RU.md](QUICKSTART_RU.md)**.

> orapglink is an **experimental preview**. It is not an Oracle product, it is
> not production-ready, and it is read-only by design. Read
> [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) before you rely on anything here.

## 1. What you need

| | |
|---|---|
| **OS / architecture** | Linux x86-64, Linux arm64, or macOS on Apple Silicon (arm64). Windows and macOS Intel are not part of this preview. |
| **Linux runtime** | Tested on `debian:bookworm-slim` with **no extra packages installed**. See "Linux runtime libraries" below for the exact requirement. |
| **PostgreSQL** | Version **16** is the tested version. It can be local or remote. |
| **`psql` and an admin account** | Needed **once**, for setup: creating two roles and installing an extension and a set of views. The proxy itself never does any of this. |
| **The `orafce` extension** | Mandatory. On Debian/Ubuntu with the PGDG packages: `postgresql-16-orafce`. |
| **One Oracle client, to test with** | Easiest is `python-oracledb` in thin mode (`pip install oracledb`) — pure Python, no Oracle software needed. DBeaver also works. |
| **A free local port** | `1521` by default. |

**You do not need an Oracle Database.** Thin clients and DBeaver talk to
orapglink directly. A real Oracle Database is needed only if you want the
`DATABASE LINK` scenario in section 7, which is optional.

## 2. Unpack and check the binary

```sh
# Check the download first (SHA256SUMS is published next to the archives).
sha256sum -c SHA256SUMS          # macOS: shasum -a 256 -c SHA256SUMS

tar -xzf orapglink_0.1.0-preview.2_linux_amd64.tar.gz
cd orapglink_0.1.0-preview.2_linux_amd64

./orapglink --version
```

`--version` must print exactly:

```text
v0.1.0-preview.2
```

If it prints `dev` or a git hash, you have a development build, not a release
archive — do not use it for anything you intend to trust.

The public release notes and [Testing and verification](doc/testing.md) state
the client families exercised by this build, the passing case count, and the
known compatibility limits. Read them before connecting a production tool.

On macOS the first run may be blocked by Gatekeeper because the binary is not
notarized. Allow it in **System Settings → Privacy & Security**, or run
`xattr -d com.apple.quarantine ./orapglink`.

### Linux runtime libraries

The Linux binaries are **not** statically linked. They embed the PostgreSQL SQL
parser as C code (see `THIRD_PARTY_NOTICES.md`), so they need the system C and
C++ runtimes used by the release build:

```text
libc.so.6  libm.so.6  libgcc_s.so.1  libstdc++.so.6
```

The published Linux archives are built on **Ubuntu 22.04 (glibc 2.35)**, and each
one is verified by running the unpacked binary inside a clean
`debian:bookworm-slim` container with **nothing installed on top** — all four
libraries are already present there. Concretely:

- **Verified runtime:** a clean Debian 12 (`bookworm-slim`) container. The
  build host is Ubuntu 22.04. Other glibc-based distributions with the four
  libraries above are expected to work, but are not claimed as tested.
- **An older distribution** (glibc below 2.35) — fails at startup with a
  `version 'GLIBC_2.xx' not found` message. Run the published binary in a
  compatible glibc-based container instead.
- **A minimal image without a C++ runtime** (Alpine, `distroless/static`,
  `scratch`) — will not work. Alpine uses musl rather than glibc; use a
  glibc-based image such as `debian:bookworm-slim`.

Check yours with `ldd ./orapglink` — no line may say `not found`. Then run
`./orapglink --version`; those checks are more useful than assuming support from
the distribution's name alone.

What is stated here is exactly what was tested, and no wider: "works on any
Linux" is not being promised.

## 3. Prepare PostgreSQL

Five things happen here, once, as a PostgreSQL administrator: a database, the
`orafce` extension, two roles, the Oracle dictionary views, and a check that the
read-only role really is read-only.

### 3.0 Set five values ONCE — everything below reuses them

This is the part that trips people up: the same handful of values reappear in
later steps and again when you start the proxy, and if two copies disagree
things fail quietly. So decide them **once**, here, as shell variables, and then
paste the commands below unchanged. Nothing is hard-coded further down.

```sh
# The admin (superuser) connection — where you CREATE things. Adjust host/port/
# user to your PostgreSQL. (For the throwaway container in this guide's setup it
# is postgres:postgres @ 127.0.0.1:5544.)
export PGHOST=127.0.0.1
export PGPORT=5432
export PGADMIN_USER=postgres
export PGADMIN_PASSWORD=postgres

# What you are creating. Pick your own passwords for the two orapglink roles.
export DBNAME=appdb
export RUNTIME_PW='pick-a-strong-password'
export INSTALL_PW='pick-another-strong-password'

# The one Oracle schema name the proxy reports. It MUST be the UPPERCASE form of
# the PostgreSQL schema your data lives in — for the default `public` that is
# PUBLIC. This one value shows up in THREE places (3.4, section 4, section 5);
# setting it here keeps them in sync.
export LOGICAL_SCHEMA=PUBLIC
```

Here is where each value you just set is used again — keep this in view while
you go:

| Value | Used again in |
|---|---|
| `RUNTIME_PW` | the runtime DSN when you start the proxy (§4) |
| `INSTALL_PW` | installing the dictionary views (§3.4) |
| `DBNAME` | every step, and the proxy's DSN (§4) |
| `LOGICAL_SCHEMA` | the dictionary views (§3.4), `ORAPGLINK_LOGICAL_SCHEMA` (§4), and the client's service name (§5) — **all three must be identical** |

Two derived DSNs the commands below reuse — paste these too:

```sh
export PGADMIN_DB_DSN="postgresql://${PGADMIN_USER}:${PGADMIN_PASSWORD}@${PGHOST}:${PGPORT}/${DBNAME}"
export PGADMIN_ROOT_DSN="postgresql://${PGADMIN_USER}:${PGADMIN_PASSWORD}@${PGHOST}:${PGPORT}/postgres"
```

### 3.1 Create (or choose) the database

```sh
psql "$PGADMIN_ROOT_DSN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DBNAME;"
```

(If the database already exists — for example the one the setup container
created — this errors harmlessly; skip it.) Using an existing database with your
real data is fine — nothing in this guide modifies your tables.

### 3.2 Install `orafce`

`orafce` supplies the Oracle-semantic functions (`NVL`, `DECODE`, `ADD_MONTHS`,
`LAST_DAY`, `MONTHS_BETWEEN`, 4-argument `INSTR`, Oracle `SUBSTR`, `TO_CHAR` /
`TO_DATE` format masks, `REGEXP_LIKE`, `RTRIM`, `RPAD`, …) that orapglink
deliberately does not reimplement. It is **required by default**, and for a good
reason: several of those names also exist in PostgreSQL with *different*
behaviour, so a missing `orafce` would not fail — it would quietly give you
PostgreSQL's answer instead of Oracle's.

```sh
# Debian/Ubuntu with the PGDG repository, on the PostgreSQL host:
sudo apt-get install -y postgresql-16-orafce

psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS orafce;"
```

If your PostgreSQL runs in a container that already carries the orafce package
(the setup container in this guide does), **skip the `apt-get` line** and just
run the `CREATE EXTENSION`. Other platforms package it too (`yum install
orafce_16`, Homebrew via `pgxnclient install orafce`, or a source build from
<https://github.com/orafce/orafce>). Any method is fine as long as `CREATE
EXTENSION orafce;` succeeds and creates a schema named `oracle`.

### 3.3 Create the two roles

`sql/provision_roles.sql` ships with three placeholders — `<RUNTIME_PASSWORD>`,
`<INSTALL_PASSWORD>`, `<DATABASE_NAME>`. Rather than editing the file by hand,
substitute them from the variables you set in §3.0 and pipe the result straight
into `psql`, so there is no partly-edited file to get wrong and no plaintext
password left on disk:

```sh
sed -e "s/<RUNTIME_PASSWORD>/${RUNTIME_PW}/g" \
    -e "s/<INSTALL_PASSWORD>/${INSTALL_PW}/g" \
    -e "s/<DATABASE_NAME>/${DBNAME}/g" \
    sql/provision_roles.sql \
  | psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1
```

> **`<DATABASE_NAME>` must be a database that already exists.** The file runs
> `GRANT CONNECT ON DATABASE <DATABASE_NAME> …`, and PostgreSQL refuses to grant
> on a database it can't find (`ERROR: database "…" does not exist`). It has to
> be the exact same `$DBNAME` you **created in §3.1** — not a new name invented
> here. If you sed in a name that was never created, go back and run §3.1 for it
> first. When you drive everything from the §3.0 `$DBNAME` variable this stays
> consistent automatically; the error only shows up if you type a different name
> by hand.

What it creates:

- **`orapglink_runtime`** — the role orapglink itself connects as. `CONNECT`,
  `USAGE` and `SELECT` only; no `INSERT`/`UPDATE`/`DELETE`, no DDL. Its password
  is `RUNTIME_PW` — you will hand this to the proxy in §4.
- **`orapglink_install`** — used only to install the dictionary views in the
  next step (§3.4), with password `INSTALL_PW`. orapglink never authenticates
  as this role.

Then one grant the SQL file cannot do for you — let the runtime role call
orafce's functions (the role only exists as of the step above):

```sh
psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1 -c \
  "GRANT USAGE ON SCHEMA oracle TO orapglink_runtime;
   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracle TO orapglink_runtime;"
```

If your data lives in a schema OTHER than `public`, also grant read on it now
(and remember to add that schema to `ORAPGLINK_PG_SCHEMAS` in §4):

```sh
# only if NOT using the default `public` schema — replace myschema:
# psql "$PGADMIN_DB_DSN" -c "GRANT USAGE ON SCHEMA myschema TO orapglink_runtime;
#   GRANT SELECT ON ALL TABLES IN SCHEMA myschema TO orapglink_runtime;
#   ALTER DEFAULT PRIVILEGES IN SCHEMA myschema GRANT SELECT ON TABLES TO orapglink_runtime;"
```

> **Every command in this step must be connected to your target database
> (`$DBNAME`), not to the maintenance `postgres` database.** The commands above
> use `$PGADMIN_DB_DSN`, which already points at `$DBNAME` — so if you run them
> as shown, this is handled for you. It only bites if you run the statements by
> hand from a `postgres`-database session: `GRANT CONNECT`/`CREATE ON DATABASE`
> are global and work from anywhere, but `GRANT … ON SCHEMA public`, `GRANT
> SELECT ON ALL TABLES`, `ALTER DEFAULT PRIVILEGES IN SCHEMA public` and the
> `oracle` grants all act on the `public`/`oracle` schema **of whatever database
> you are currently in**. Run them from the `postgres` database and they land on
> `postgres.public` instead of `<yourdb>.public`, and the runtime role will see
> none of your tables. If that happened, just reconnect to `$DBNAME` and re-run
> those grant lines — they are idempotent.

### 3.4 Install the Oracle dictionary views

**You have just created the roles. The next commands are run as a *different*
user** — `orapglink_install`, not the admin — **against the same `$DBNAME`
database.** So you reconnect: the DSN below switches both the user and the
password (`orapglink_install` / `$INSTALL_PW`) while keeping `$PGHOST:$PGPORT/$DBNAME`.

`sql/oracle_compat_views.sql` creates the `oradict` schema: `DUAL` and the
`ALL_*` / `USER_*` / `DBA_*` dictionary views over the live `pg_catalog`.
Without it, `SELECT … FROM dual` and every metadata query fail with a
missing-relation error.

It has two placeholders, and both come from values you already set:

- `<RUNTIME_ROLE>` → `orapglink_runtime` (the role from §3.3);
- the literal `'APP'` → `'<your LOGICAL_SCHEMA>'`. **This is the value that must
  agree in three places** — here, `ORAPGLINK_LOGICAL_SCHEMA` in §4, and the
  client's service name in §5. Using `$LOGICAL_SCHEMA` from §3.0 for all three
  is how you keep them identical; if they disagree, `USER_TABLES` and friends
  silently return zero rows.

Run it **as the install role** (note the DSN uses `orapglink_install` and
`INSTALL_PW`, not the admin user — the install role owns the `oradict` schema):

```sh
sed -e "s/<RUNTIME_ROLE>/orapglink_runtime/g" \
    -e "s/'APP'/'${LOGICAL_SCHEMA}'/g" \
    sql/oracle_compat_views.sql \
  | psql "postgresql://orapglink_install:${INSTALL_PW}@${PGHOST}:${PGPORT}/${DBNAME}" \
      -v ON_ERROR_STOP=1
```

The migration is idempotent and transactional — re-running it is safe, and you
should re-run it after upgrading orapglink.

### 3.5 Check the runtime role — it can read, and it cannot write

Both of these matter. The first proves the setup works; the second proves the
read-only guarantee is enforced by PostgreSQL itself, not only by orapglink.

```sh
export RUNTIME_DSN="postgresql://orapglink_runtime@${PGHOST}:${PGPORT}/${DBNAME}"

# reads:
PGPASSWORD="$RUNTIME_PW" psql "$RUNTIME_DSN" -c "SELECT * FROM oradict.dual;"
#  dummy
# -------
#  X

# writes must be refused:
PGPASSWORD="$RUNTIME_PW" psql "$RUNTIME_DSN" -c "CREATE TABLE should_fail (i int);"
# ERROR:  permission denied for schema public
```

If `CREATE TABLE` succeeds, stop and fix the role — you have pointed orapglink
at an account with write access.

### 3.6 Optional: a table to query

If the database is empty, give yourself something to select from:

```sh
psql "$PGADMIN_DB_DSN" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS demo_customers (
    id        integer PRIMARY KEY,
    name      varchar(60) NOT NULL,
    signed_up date
);
INSERT INTO demo_customers VALUES (1, 'Acme',    DATE '2024-03-01'),
                                  (2, 'Globex',  DATE '2025-11-17')
ON CONFLICT DO NOTHING;
GRANT SELECT ON demo_customers TO orapglink_runtime;
SQL
```

That last `GRANT` is not decoration. `ALTER DEFAULT PRIVILEGES` in
`provision_roles.sql` only covers tables created *by the same role that ran it*.
Whenever a table is created by some other role, grant `SELECT` on it explicitly —
or the table simply will not be visible to orapglink.

## 4. Configure and start orapglink

```sh
cp config.env.example config.env
```

> **`config.env` is read by the shell (`. ./config.env`), so it follows shell
> syntax, not `.ini` syntax.** Three rules save a lot of confusion:
> - **No spaces around `=`.** `KEY=value`, never `KEY = value` — with spaces the
>   shell treats it as a command, not an assignment.
> - **No trailing `;`.** A semicolon ends up inside the value and breaks it.
> - **Quote values with special characters.** The DSN contains a `?`
>   (`…/test?sslmode=disable`), which zsh tries to expand as a filename glob
>   (`no matches found`). Wrap such values in single quotes:
>   `ORAPGLINK_POSTGRES_DSN='postgresql://…/test?sslmode=disable'`.
>
> `config.env.example` already follows all three — start from it (as above) and
> only change the text to the right of each `=`.

Edit `config.env` and set these values. Three of them are the §3.0 variables you
already chose — copy them across exactly:

- `ORAPGLINK_ORACLE_PASSWORD` — the shared password Oracle **clients** will use.
  This is a *new* password you invent here; it is unrelated to any PostgreSQL
  role. Any username is accepted with it; the username is not a PostgreSQL
  account.
- `ORAPGLINK_POSTGRES_DSN` — the **runtime** DSN. This is `orapglink_runtime`
  with your `RUNTIME_PW`, pointing at `PGHOST:PGPORT/DBNAME` from §3.0. To print
  the exact string to paste:

  ```sh
  echo "postgresql://orapglink_runtime:${RUNTIME_PW}@${PGHOST}:${PGPORT}/${DBNAME}?sslmode=disable"
  ```

  Use `sslmode=require` for a remote PostgreSQL; `sslmode=disable` is reasonable
  only for a loopback database. This setting concerns the connection to
  PostgreSQL and has no effect on the Oracle-side listener.
- `ORAPGLINK_LOGICAL_SCHEMA` — set it to your `$LOGICAL_SCHEMA` from §3.0 (e.g.
  `PUBLIC`). **This is the third of the three places that must agree** — it has
  to equal the value you substituted for `'APP'` in §3.4, and the service name
  the client uses in §5.
- `ORAPGLINK_PG_SCHEMAS` — the lowercase PostgreSQL schema(s) to expose (default
  `public`). If your data lives elsewhere, list it here — and it must be a schema
  you granted `SELECT` on in §3.3.

> **Database vs. schema — why `LOGICAL_SCHEMA` is `PUBLIC`, not your database
> name.** These are two different levels and it is easy to conflate them. The
> **database** name (e.g. `test`) appears *only* inside `ORAPGLINK_POSTGRES_DSN`;
> it is how the proxy reaches PostgreSQL and it is never shown to Oracle clients
> (Oracle has no concept of a Postgres "database"). What clients see is a single
> Oracle **schema/service**, and that name comes from the PostgreSQL *schema*
> your tables live in — `public`, uppercased to `PUBLIC`:
>
> ```text
> PostgreSQL server (127.0.0.1:5432)
> └── database  test          ← the /test in ORAPGLINK_POSTGRES_DSN
>     └── schema  public       ← ORAPGLINK_PG_SCHEMAS=public   (lowercase, PG side)
>         └── your tables
>
> Oracle client sees:
> service/owner  PUBLIC        ← ORAPGLINK_LOGICAL_SCHEMA=PUBLIC (uppercase) + §5 service name
> ```
>
> So the "three places that must agree" — `'APP'`→`'PUBLIC'` in §3.4,
> `ORAPGLINK_LOGICAL_SCHEMA` here, and the client's service name in §5 — are all
> about the **schema** `public`, never about the database `test`.

Then:

```sh
set -a
. ./config.env
set +a
./orapglink
```

A healthy startup looks like this:

```text
level=INFO msg="orapglink: orafce verified"
level=INFO msg="pgmeta: catalog snapshot loaded" relations=... columns=...
level=INFO msg="orapglink: Oracle-wire (TNS) listening" addr=127.0.0.1:1521
       logical_schema=PUBLIC search_path="public", "oracle", "pg_catalog"
       build_version=v0.1.0-preview.2
```

If the listener is bound anywhere other than loopback you will also see a
warning that this protocol carries no encryption here. That warning is correct;
see [KNOWN_LIMITATIONS.md §3](KNOWN_LIMITATIONS.md).

Stop it with `Ctrl-C`. It shuts down cleanly on `SIGINT`/`SIGTERM`.

### 4.1 Optional: the translation playground

A built-in web page that runs *this* proxy's Oracle→PostgreSQL translator (plus
libpg_query validation) so you can paste Oracle SQL and see exactly what it
becomes. It is off by default. Enable it either in `config.env`:

```sh
ORAPGLINK_PLAYGROUND_LISTEN=127.0.0.1:8099
```

or as a one-off flag without touching `config.env`:

```sh
./orapglink --playground-listen 127.0.0.1:8099
```

On startup you will see `translation playground listening addr=127.0.0.1:8099`;
open <http://127.0.0.1:8099> in a browser. It has **no authentication** — bind it
to loopback only (`127.0.0.1`); the proxy warns in the log if you point it
anywhere else. It is a development tool and does not touch PostgreSQL — it only
translates and validates SQL text.

### 4.2 Result-size limits and memory

orapglink builds **the entire result in memory** before it sends the first row —
the Oracle wire format needs the widest value in the result to encode it, so
there is no streaming path today. That makes these limits the only thing
standing between an accidental `SELECT * FROM huge_table` and the process being
killed by the OOM killer. Leaving them at their defaults is safe; **raising them
without doing the arithmetic below is not.**

| Setting | Default | What it caps |
| --- | --- | --- |
| `--max-result-rows` | `50000` | rows in one result |
| `--max-result-bytes` | `64 MiB` | estimated memory one result retains |
| `--max-cell-bytes` | `32 MiB` | one value (this is the LOB ceiling) |
| `--max-concurrent-queries` | `8` | results materialized **at the same time** |

The first three are **per query**. Only the fourth bounds the process, and the
number that actually matters is the product:

```text
worst-case memory ≈ --max-concurrent-queries × --max-result-bytes
                  = 8 × 64 MiB ≈ 512 MiB      (the defaults)
```

orapglink prints exactly this at startup, so you never have to guess:

```text
level=INFO msg="resource envelope" max_result_rows=50000 max_result_bytes=67108864
       max_concurrent_queries=8 worst_case_inflight_bytes=536870912
```

If that line is a `WARN`, the configured envelope is larger than a small
container can hold — lower `--max-result-bytes` or `--max-concurrent-queries`.
Give the process real headroom on top of the number (PostgreSQL driver buffers,
the wire copy, and rows kept for later `FETCH` all sit above it); the defaults
assume roughly a 1 GiB process.

`--max-result-bytes` counts the container overhead of the result, not just the
characters in it. A wide row is expensive before it holds any data — a
130-column row costs about 6 KB in bookkeeping alone — which is why a
130-column table hits the byte cap far sooner than the row cap.

When a limit is reached the query stops cleanly and **the session survives**:

- too large → `ORA-04030: out of process memory when trying to allocate bytes
  for the result (result exceeded this proxy's configured size limit …)`
- too slow (past `--query-timeout`) → `ORA-00040: active time limit exceeded -
  call aborted`
- server saturated (no free slot within `--query-timeout`) →
  `ORA-07454: queue timeout exceeded`

All three mean "ask for less at a time" — add a `WHERE` clause or a `ROWNUM`
bound. None leaves the proxy in a bad state.

These codes matter more than they look. The first two used to be reported as
`ORA-01013: user requested cancel of current operation`, and an Oracle database
querying through a `DATABASE LINK` reads that as *the user cancelled* — a
transient condition — so it re-issues the statement. Forever. In practice the
client simply hung, was never shown any error, and the proxy re-ran the doomed
query thousands of times. `ORA-04030`/`ORA-00040` are final, so the query stops
on the first attempt and the error reaches you.

## 5. Your first query

### With python-oracledb (thin mode)

No Oracle client software is involved — thin mode is the library's own default.

```sh
pip install oracledb
```

```python
import oracledb

conn = oracledb.connect(
    user="APP",                     # any username; it is not checked
    password="change-me",           # ORAPGLINK_ORACLE_PASSWORD
    dsn="127.0.0.1:1521/PUBLIC",    # service name = ORAPGLINK_LOGICAL_SCHEMA
)
with conn.cursor() as cur:
    cur.execute("SELECT 1 FROM dual")
    print(cur.fetchone())                       # (1,)

    cur.execute("SELECT SYSDATE FROM dual")
    print(cur.fetchone())                       # (datetime.datetime(...),)

    cur.execute("SELECT table_name FROM user_tables ORDER BY table_name")
    print([r[0] for r in cur.fetchall()])       # ['DEMO_CUSTOMERS', ...]

    cur.execute("SELECT id, name, signed_up FROM demo_customers ORDER BY id")
    for row in cur.fetchall():
        print(row)
```

That is the whole loop: an Oracle driver, Oracle SQL, Oracle data types — with
PostgreSQL underneath.

Note the single-tenant model at work: `user="APP"` connects, but so does
`user="anything"`. The username is not a PostgreSQL account and is not checked;
every session reads through the one configured backend DSN. The **service name**
is what has to be right — it must equal `ORAPGLINK_LOGICAL_SCHEMA`.

### With DBeaver

| Field | Value |
|---|---|
| Driver | Oracle (Thin driver, "Basic" connection type) |
| Host | `127.0.0.1` |
| Port | `1521` |
| Service name | your `ORAPGLINK_LOGICAL_SCHEMA`, e.g. `PUBLIC` |
| Username | anything, e.g. `APP` |
| Password | your `ORAPGLINK_ORACLE_PASSWORD` |

The object browser will show schemas, tables, columns and table data. Deeper
metadata panels (constraints, indexes, triggers) are limited — see
[KNOWN_LIMITATIONS.md §11](KNOWN_LIMITATIONS.md). In the SQL editor you can
prefix a statement with `/*pg*/` to send native PostgreSQL straight through,
bypassing the Oracle→PostgreSQL translator:

```sql
/*pg*/ SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY 2 DESC LIMIT 10;
```

It is still read-only: passthrough statements run inside the same `READ ONLY`
transaction, under the same caps and timeout.

## 6. What to expect from the SQL

orapglink translates a documented subset of Oracle SQL into PostgreSQL SQL.
`TRANSLATOR_SUPPORT.md` (in this archive) is the contract: it says, per feature,
whether semantic equivalence is claimed, whether the difference is a documented
approximation, or whether the construct is refused outright.

A refusal looks like an ordinary Oracle error — most often `ORA-03001` — and the
**session survives it**; keep working in the same connection. That is deliberate:
declining is safer than returning a plausible-looking wrong answer.

## 7. Optional: a `DATABASE LINK` from a real Oracle Database

This is the scenario the project exists for, and it needs a real Oracle Database
that you already have. Everything above works without it.

On the Oracle side:

```sql
CREATE DATABASE LINK pglink
  CONNECT TO appuser IDENTIFIED BY "<ORAPGLINK_ORACLE_PASSWORD>"
  USING '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=<orapglink-host>)(PORT=1521))
          (CONNECT_DATA=(SERVICE_NAME=PUBLIC)))';

SELECT * FROM demo_customers@pglink WHERE ROWNUM <= 10;
```

- `SERVICE_NAME` must be your `ORAPGLINK_LOGICAL_SCHEMA`.
- `CONNECT TO <user>` can be any name; only the password matters.
- The Oracle database must be able to reach the orapglink host on port 1521,
  which means `ORAPGLINK_ORACLE_LISTEN` cannot stay on `127.0.0.1`.

> **This connection is not encrypted.** orapglink's listener supports neither
> Oracle native encryption nor TCPS, so the link password and every returned row
> cross the network in the clear. Use it only inside a trusted network or over a
> VPN, or put a TLS-terminating tunnel in front of the listener. Do not expose
> port 1521 to the Internet.

Over `DATABASE LINK` specifically, the type coverage is narrower than over thin
clients, and a few shapes are refused with `ORA-03001` rather than guessed at —
see [KNOWN_LIMITATIONS.md §10](KNOWN_LIMITATIONS.md) and
[Testing and verification](doc/testing.md).

## 8. Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `ERROR: database "…" does not exist` while running `provision_roles.sql` | you substituted a `<DATABASE_NAME>` that was never created | create it (step 3.1) or use an existing name — the same value goes in all three `<DATABASE_NAME>` spots (step 3.3) |
| `zsh: no matches found: postgresql://…?sslmode=disable` | an unquoted `?` in `config.env` was treated as a filename glob | single-quote the value; see the `config.env` syntax note in step 4 |
| `no such file or directory: ./orapglink` | the release binary is absent or you are in the wrong directory | download and unpack the release archive for your platform, then run the command from that directory |
| reads work, but the runtime role sees **none** of your tables (`USER_TABLES` empty) | the `GRANT`/`ALTER DEFAULT PRIVILEGES` on `public` were run while connected to the wrong database (e.g. `postgres` instead of your target) | re-run those three grants connected to your target `$DBNAME` — see the "which database" note in step 3.3 |
| an ORA error ends with `(translated SQL line N, column M)` | that coordinate indexes the **translated** PostgreSQL SQL, not your original Oracle SQL | paste the query into the translation playground (step 4.1) — it shows that line with a caret under the spot |
| `orafce verification failed` at startup | the extension is missing, or the runtime role cannot use it | `CREATE EXTENSION orafce;`, then `GRANT USAGE ON SCHEMA oracle` and `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracle` to `orapglink_runtime` (step 3.2 / 3.3a) |
| `connection refused` from the client | the proxy is not listening where the client is looking | check the `Oracle-wire (TNS) listening addr=…` line in the log, check `ORAPGLINK_ORACLE_LISTEN`, and check the firewall. A remote client needs a non-loopback bind |
| `password authentication failed for user "orapglink_runtime"` | the PostgreSQL runtime DSN is wrong | verify the role, password, database and `sslmode` in `ORAPGLINK_POSTGRES_DSN` — the same DSN must work in `psql` |
| `ORA-01017: invalid username/password` from the client | the client's password is not `ORAPGLINK_ORACLE_PASSWORD` | fix the password. The username genuinely does not matter |
| `ORA-12514` / service name errors | the client's service name is not `ORAPGLINK_LOGICAL_SCHEMA` | make them equal |
| `ORA-03001: unimplemented feature` | the query or the wire shape was safely refused | check `TRANSLATOR_SUPPORT.md` and the public verification matrix. Rewrite the query, or use `/*pg*/` passthrough. The session stays usable |
| `relation "oradict.dual" does not exist`, or dictionary views missing | `sql/oracle_compat_views.sql` was not installed, or went into another database | re-run step 3.4 against the same database the runtime DSN points at |
| `USER_TABLES` returns zero rows but `ALL_TABLES` does not | the `'APP'` literal in the dictionary migration does not match `ORAPGLINK_LOGICAL_SCHEMA` | make them equal (uppercase PostgreSQL schema name), then re-run step 3.4 |
| a table is invisible to orapglink but exists in `psql` | it was created after provisioning, by a different role | `GRANT SELECT ON <table> TO orapglink_runtime;` (step 3.6) |
| the username in the client differs from the PostgreSQL role | that is the single-tenant model | expected — every session uses the one configured backend DSN (KNOWN_LIMITATIONS.md §2) |
| `ORA-16000` on a write | the proxy is read-only | writes belong on the PostgreSQL side, through PostgreSQL's own tools |
| the query times out or returns fewer rows than expected | the result caps and query timeout fired | raise `--query-timeout`, `--max-result-rows`, `--max-result-bytes` — deliberately, they exist to protect the database |

To collect more detail, restart with `--log-level debug`. To watch it
operationally, set `ORAPGLINK_METRICS_LISTEN=127.0.0.1:9109` and read
`/metrics`, `/healthz`, `/readyz` — bear in mind that endpoint has no
authentication, so keep it on loopback.

## Where to go next

- **[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)** — what does not work, and the
  safe way around each item.
- **`TRANSLATOR_SUPPORT.md`** — the per-feature Oracle→PostgreSQL translation
  contract.
- **[Testing and verification](doc/testing.md)** — per-client release coverage
  and the 722-case verification matrix.
- **`./orapglink -h`** — every flag: resource caps, timeouts, catalog refresh,
  identifier folding.
- **[README.md](README.md)** — what the project is, and the full documentation
  index.
