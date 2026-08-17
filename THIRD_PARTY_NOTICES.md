# Third-party notices

`orapglink` distribution materials are licensed under the Apache License 2.0
(see `LICENSE` and `NOTICE`). Compiled release binaries include third-party
components with their own licenses. The corresponding license texts are kept
under `licenses/` and will also ship in every release archive.

This is the expected dependency inventory before the first binary is attached
to this repository. Each release will be checked against its actual build graph
and will carry the inventory matching that binary.

## Go modules linked into the binary

| Component | Version | License | Project | Full text |
|---|---|---|---|---|
| github.com/jackc/pgx/v5 | v5.10.0 | MIT | <https://github.com/jackc/pgx> | `licenses/jackc-pgx.txt` |
| github.com/jackc/pgpassfile | v1.0.0 | MIT | <https://github.com/jackc/pgpassfile> | `licenses/jackc-pgpassfile.txt` |
| github.com/jackc/pgservicefile | v0.0.0-20240606120523-5a60cdf6a761 | MIT | <https://github.com/jackc/pgservicefile> | `licenses/jackc-pgservicefile.txt` |
| github.com/jackc/puddle/v2 | v2.2.2 | MIT | <https://github.com/jackc/puddle> | `licenses/jackc-puddle.txt` |
| github.com/pganalyze/pg_query_go/v6 | v6.2.2 | BSD-3-Clause | <https://github.com/pganalyze/pg_query_go> | `licenses/pganalyze-pg_query_go.txt` |
| golang.org/x/crypto | v0.54.0 | BSD-3-Clause | <https://cs.opensource.google/go/x/crypto> | `licenses/golang-x-crypto.txt` |
| golang.org/x/sync | v0.22.0 | BSD-3-Clause | <https://cs.opensource.google/go/x/sync> | `licenses/golang-x-sync.txt` |
| golang.org/x/sys | v0.47.0 | BSD-3-Clause | <https://cs.opensource.google/go/x/sys> | `licenses/golang-x-sys.txt` |
| golang.org/x/text | v0.40.0 | BSD-3-Clause | <https://cs.opensource.google/go/x/text> | `licenses/golang-x-text.txt` |
| google.golang.org/protobuf | v1.36.1 | BSD-3-Clause | <https://google.golang.org/protobuf> | `licenses/google-protobuf.txt` |

## Embedded C code

| Component | How it gets in | Version | License | Full text |
|---|---|---|---|---|
| libpg_query | Vendored C sources inside `pg_query_go` v6.2.2 | Derived from PostgreSQL 17.7 | PostgreSQL License plus `pg_query_go` BSD-3-Clause | `licenses/libpg_query-postgresql.txt` |

The released binary is cgo-linked because libpg_query is implemented in C. On
Linux it therefore requires the glibc runtime documented in `QUICKSTART.md`.

## Components not distributed here

No Oracle software is included in this repository or in any release archive:
no Oracle Database, Oracle Client, Oracle Instant Client, SQL\*Plus, Oracle
JDBC driver or Oracle container image. Operators obtain any optional Oracle
client or database separately under the applicable vendor terms.

Test-only tooling is not linked into the product binary and is not part of this
redistribution inventory.
