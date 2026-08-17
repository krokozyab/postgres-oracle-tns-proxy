# Known limitations

This is the short, user-facing list — what you will actually run into, and what
to do about it. It is not an internal bug database or implementation log.

Every entry below is in one shape:

> **What is limited** → how it shows up → the safe way around it.

For the exhaustive, machine-checked view of the SQL translator specifically,
read **`TRANSLATOR_SUPPORT.md`**. For the tested scope of each client family,
read [Testing and verification](doc/testing.md).

## 1. Experimental preview, and read-only by design

**The project is an experimental preview, not production software, and it never
writes.** → Any `INSERT`/`UPDATE`/`DELETE`/DDL you send is refused (`ORA-16000`),
and it would still be refused even if that check were bypassed, because every
query runs inside a PostgreSQL `READ ONLY` transaction. Behaviour, flags and
wire coverage may change between preview releases. → Use it for evaluation,
reporting and interoperability testing. Keep writes on the PostgreSQL side,
through PostgreSQL's own tooling. Do not put it on a critical path yet.

## 2. Single-tenant user model: one schema, one shared password

**There is exactly one logical Oracle schema (`--logical-schema`, default `APP`)
and one shared password (`--oracle-password`); the username is not checked at
all.** → Any username connects, as long as the password matches, and every
session sees the same PostgreSQL data through the same single backend DSN.
`SYS_CONTEXT('USERENV', …)` and `USER` report the configured logical schema, not
whatever name the client typed. → Treat the shared password as a service
credential for one application, not as per-user authentication. If you need
several isolated views of the data, run several orapglink processes, each with
its own DSN, PostgreSQL role and port.

**A wrong password closes the connection instead of returning ORA-01017.** →
Clients see a transport-level failure rather than "invalid username/password":
`sqlplus` reports `ORA-03113: end-of-file on communication channel`, and a
`DATABASE LINK` initiator reports `ORA-03150`. The authentication itself is
correct — the peer is rejected before any session state exists — but the
*message* is not what a real Oracle would send. A consistent Oracle-style
authentication error is not yet available across every supported client
dialect, so the connection is failed closed instead of returning a potentially
misleading response.

## 3. No Oracle Net encryption, no TCPS

**The Oracle Net listener answers "no native security" to the ANO negotiation
and does not speak TCPS.** → Credentials and every returned row cross the
network in the clear. A client configured with `SQLNET.ENCRYPTION_CLIENT=REQUIRED`
or a `TCPS` address fails during the handshake. The proxy logs a warning at
startup when the listener is not on loopback. → Keep the listener on
`127.0.0.1` when the client is local. Otherwise put it on a trusted network
segment or a VPN, or terminate TLS in front of it with a tunnel (stunnel,
`socat`, a service mesh sidecar). Do not expose port 1521 to the Internet.

## 4. Metrics and playground endpoints have no authentication

**`--metrics-listen` (Prometheus `/metrics`, `/healthz`, `/readyz`) and
`--playground-listen` (the SQL translation playground) have no auth, no TLS and
no rate limiting.** → Anyone who can reach the port can read operational
counters or use the translator. Both are **off by default** and must be
explicitly enabled. → Leave them off unless you need them. When you do enable
them, bind to `127.0.0.1` and put a reverse proxy in front if remote access is
required; the binary warns if you bind either to a non-loopback address.

## 5. PostgreSQL plus `orafce` are required

**Oracle-semantic functions are not reimplemented — they are delegated to the
`orafce` extension, which the proxy verifies at startup and which is mandatory
by default.** → Without `orafce`, startup fails with `orafce verification
failed`. If you force it off with `--require-orafce=false`, functions like
`ADD_MONTHS`/`LAST_DAY`/`MONTHS_BETWEEN` fail with an unhelpful "does not exist",
and — worse — `SUBSTR`, `TO_CHAR`, `TO_DATE`, `RTRIM`, `RPAD` silently resolve to
PostgreSQL's own same-named built-ins, which have *different* semantics, with no
error anywhere. → Install `orafce` (`CREATE EXTENSION orafce;` plus `GRANT
USAGE`/`EXECUTE` on schema `oracle` to the runtime role) and leave
`--require-orafce` at its default. PostgreSQL **16** is the tested version;
other versions are unverified here, not known-broken.

## 6. Only a subset of Oracle SQL is translated

**The SQL translator covers a documented feature set, not the Oracle SQL
language.** → Anything outside it is either rejected with a stable `ORA-` code
or, for `passthrough` features, forwarded to PostgreSQL/orafce with no
compatibility claim at all. → Read **`TRANSLATOR_SUPPORT.md`** before assuming a
construct works; it states, per feature, whether the project claims semantic
equivalence (`supported`), a deliberate documented divergence (`approximation`),
an outright refusal (`rejected`), or nothing at all (`passthrough`). For native
PostgreSQL constructs the translator does not model (CTEs, `EXPLAIN`, window and
JSON functions, `pg_catalog`), prefix the statement with the `/*pg*/` marker to
bypass translation — still read-only, still under the same caps.

## 7. Unsupported-but-recognizable SQL fails loudly, not silently

**When the proxy cannot faithfully translate or encode something it refuses the
call rather than guessing.** → You get an Oracle-style error — most often
`ORA-03001` ("unimplemented feature"), sometimes `ORA-00900`/`ORA-00933` for a
non-`SELECT` or multi-statement text, `ORA-01008` for an unbound placeholder —
and **the session survives**; you can keep working in the same connection. → Treat
`ORA-03001` as "this shape is not supported", not as "the server crashed". Check
`TRANSLATOR_SUPPORT.md` and the public verification matrix, then rewrite the query or use `/*pg*/`
passthrough. This is deliberate: a refusal is safer than a plausible-looking
wrong answer.

## 8. `ROWID` is a `ctid` approximation

**`ROWID` is translated to PostgreSQL's `ctid`.** → The value is a
`(block,offset)` pair rendered as text, never Oracle's own 18-character base64
`ROWID`. Anything that parses, stores or compares `ROWID` values against a real
Oracle database will not match. PostgreSQL's `ctid` also changes when a row is
updated or the table is `VACUUM FULL`ed. → Use it only as a within-query,
within-snapshot row locator. Do not persist it, and do not use it as a join key
against Oracle-sourced data. Use the table's real primary key instead.

## 9. `CONNECT BY` has a depth guard, not a cycle guard

**Hierarchical queries are rewritten to `WITH RECURSIVE` with a depth limit, but
a cyclic or heavily fan-out graph can produce an enormous number of rows before
that depth limit is reached.** → A cyclic-data query does not raise real
Oracle's `ORA-01436`; it runs, and can hit the row/byte caps or the query timeout
instead. Only the single-table canonical shape (`START WITH` / `CONNECT BY
PRIOR` / `LEVEL`) is rewritten at all — `SYS_CONNECT_BY_PATH`,
`CONNECT_BY_ROOT` and `ORDER SIBLINGS BY` are refused with `ORA-03001`. → Keep
`--max-result-rows`, `--max-result-bytes` and `--query-timeout` at sane values
(they are on by default), add your own `LEVEL <= N` predicate, and make sure the
data really is acyclic before relying on the result.

## 10. Some zero-row and single-type shapes are refused over thick OCI dialects

**The thick OCI dialects (`sqlplus` and other Instant Client-based clients)
support an explicitly validated set of result shapes; unverified shapes are
refused rather than guessed at.** → Over the modern-classic `sqlplus` dialect
these specific cases answer `ORA-03001` with the session intact:

- a zero-row result with **3 or more columns**;
- a zero-row **2-column** result in any type combination other than
  NUMBER + VARCHAR2;
- a single **TIMESTAMP**, **TIMESTAMP WITH TIME ZONE** or **RAW** column;
- a zero-row **DATE** or **TIMESTAMP** result.

Zero-row NUMBER, VARCHAR2 and CHAR single-column results, and DATE *with* rows,
do work. Over dblink, a **26ai zero-row result with 2 or more columns** and a
**19c zero-row LOB** are refused for the same reason. → Use a thin client
(python-oracledb, SQLcl, DBeaver, JDBC) where none of these limits apply, or
reshape the query — adding a column of a covered type, or avoiding the empty
result, is usually enough. The public verification matrix states the tested
client scope; this section states the shape limitations.

## 11. DBeaver is the recommended GUI, but deep metadata panels are limited

**DBeaver's object browser works — schemas, table list, columns, table data —
because it drives off the standard `ALL_*`/`USER_*` dictionary views that
`oradict` emulates.** → The deeper panels (constraints, indexes, triggers, types,
partitions, statistics) reference dictionary views and columns that are not
covered, and come up empty or partially filled. → Use DBeaver's SQL editor for
those, with `/*pg*/` passthrough to query `pg_catalog`/`information_schema`
directly. Connect as Oracle → Basic, service name = your `--logical-schema`, any
username, the shared password.

## 12. SQL Developer's object tree is not supported

**SQL Developer drives its navigator off Oracle *internal* catalog tables
(`sys.tab$`, `obj#`, `sys.external_tab$`), not the public dictionary views.** →
Those are not emulated, so the object tree does not populate. Running SQL in its
worksheet does work — SQL Developer connects over the same thin/ojdbc dialect
that is verified. → Use DBeaver for browsing; use SQL Developer, SQLcl or the
JDBC driver for running statements. Do not read "the tree is empty" as "the
connection is broken".

## 13. Verified client flows — exactly these, and no wider claim

**The release verification suite exercises these flows, and the support claims
in this project mean exactly these and nothing beyond them:**

| Flow | What it actually is |
|---|---|
| `thin` | python-oracledb in thin mode |
| `goora` | `sijms/go-ora` v2, pure Go |
| `odpnet` | ODP.NET managed |
| `ojdbc` | Oracle JDBC thin driver (also covers SQLcl / SQL Developer / DBeaver) |
| `sqlplus` | SQL\*Plus from a 23.x Instant Client |
| `dblink` | a real Oracle 23ai/26ai database's own outbound `DATABASE LINK` |
| `dblink19` | a real Oracle 19c database's own outbound `DATABASE LINK` |

→ A different **version** of any of these products is not automatically covered.
Oracle clients differ in wire behaviour between releases — that is precisely the
class of problem this project keeps finding — so a flow verified on Instant
Client 23.x says nothing definitive about 12c, and `dblink` verified on 26ai
says nothing definitive about 21c. Windows-only clients (Power Query, unmanaged
ODP.NET) are graded `experimental`: implemented and regression-tested, but not
driven live end to end. → If your client or version is not in that table, treat it as
untested. Run your own real queries against a copy of your data first, and
report what breaks with the version string included.
