# Connecting clients

All clients use the same four values:

| Setting | Value |
|---|---|
| Host | Host running orapglink |
| Port | `1521` by default |
| Service name | `ORAPGLINK_LOGICAL_SCHEMA`, for example `PUBLIC` |
| Password | `ORAPGLINK_ORACLE_PASSWORD` |

The username is accepted but not validated. It is not a PostgreSQL identity;
every connection uses the single read-only PostgreSQL DSN configured for the
process.

## python-oracledb (thin)

```sh
python -m pip install oracledb
```

```python
import oracledb

with oracledb.connect(
    user="APP",
    password="your-orapglink-password",
    dsn="127.0.0.1:1521/PUBLIC",
) as connection:
    with connection.cursor() as cursor:
        cursor.execute("SELECT 1 FROM dual")
        print(cursor.fetchone())
```

Thin mode needs no Oracle Client installation.

## DBeaver

Create an **Oracle** connection using the thin driver and **Basic** connection
type:

| Field | Example |
|---|---|
| Host | `127.0.0.1` |
| Port | `1521` |
| Service name | `PUBLIC` |
| Username | `APP` (any value works) |
| Password | the shared orapglink password |

Schemas, tables, columns, and table data are available through the emulated
dictionary views. Deep Oracle-only panels such as partitions, triggers, and
internal statistics are incomplete. DBeaver is the recommended GUI for this
preview.

## SQLcl, SQL*Plus, and SQL Developer

Easy Connect form:

```sh
sql APP/your-orapglink-password@//127.0.0.1:1521/PUBLIC
sqlplus APP/your-orapglink-password@//127.0.0.1:1521/PUBLIC
```

SQL Developer worksheets use the same host, port, service, username, and
password. Its object tree depends on Oracle internal catalog tables and is not
supported; use DBeaver for browsing or run dictionary queries manually.

SQL*Plus and other thick OCI clients have narrower validated result-shape
coverage. Read [Testing and verification](testing.md) and
[`KNOWN_LIMITATIONS.md`](../KNOWN_LIMITATIONS.md) before relying on them.

## JDBC

Use the ordinary Oracle thin JDBC URL:

```text
jdbc:oracle:thin:@//127.0.0.1:1521/PUBLIC
```

No orapglink-specific JDBC driver or adapter is required.

## ODP.NET managed

```text
User Id=APP;Password=your-orapglink-password;
Data Source=127.0.0.1:1521/PUBLIC;
```

The release matrix verifies managed ODP.NET. Unmanaged ODP.NET and Power Query
paths are regression-tested but are not part of the same live-client claim.

## go-ora

```go
db, err := sql.Open("oracle", "oracle://APP:your-orapglink-password@127.0.0.1:1521/PUBLIC")
```

Use `github.com/sijms/go-ora/v2` as you would against an Oracle database.

## Oracle DATABASE LINK

The initiating Oracle database must be able to reach the orapglink listener.
That normally requires binding the listener to a trusted non-loopback address:

```sql
CREATE DATABASE LINK pglink
  CONNECT TO appuser IDENTIFIED BY "your-orapglink-password"
  USING '(DESCRIPTION=
    (ADDRESS=(PROTOCOL=TCP)(HOST=orapglink-host)(PORT=1521))
    (CONNECT_DATA=(SERVICE_NAME=PUBLIC)))';

SELECT *
FROM   demo_customers@pglink
WHERE  ROWNUM <= 10;
```

This is a normal Oracle database link, not DG4ODBC or Heterogeneous Services.
The target speaks Oracle Net directly. Oracle 19c and the 23ai/26ai protocol
generation are the live-tested initiators.

The Oracle-side connection is not encrypted. Use a trusted network, VPN, or TLS
tunnel, and never expose the listener directly to the Internet.

## Native PostgreSQL passthrough

Clients may send a native read-only PostgreSQL statement by prefixing it with
`/*pg*/`:

```sql
/*pg*/ SELECT relname, n_live_tup
       FROM pg_stat_user_tables
       ORDER BY n_live_tup DESC
       LIMIT 10;
```

Passthrough does not bypass the read-only transaction, runtime role, timeout,
or result caps.
