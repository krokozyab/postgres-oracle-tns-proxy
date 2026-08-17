# SQL translator support contract

This is the user-facing support contract for Oracle-to-PostgreSQL translation
in the released binary. Claims below are backed by the project's private unit,
translator, parser, PostgreSQL execution, regression and Oracle differential
test suites.

## What the four states mean

- **`supported`** — semantic equivalence is a release claim: at least one
  live-verified `equivalent` differential case backs it (Oracle and
  PostgreSQL agree on the actual returned value, not just row/column
  counts), plus unit-level NULL/boundary/composition/rejection coverage
  where relevant.
- **`approximation`** — a *deliberate, documented* difference, not full
  equivalence. Its own corpus case(s) pin the EXACT accepted divergence via
  `known_bug`, rather than claiming a value match that can't hold.
- **`rejected`** — this proxy refuses the construct outright with a stable
  `ORA-NNNNN` code, rather than translating it unfaithfully or forwarding
  Oracle-only syntax for PostgreSQL to fail on with a confusing native
  error.
- **`passthrough`** — forwarded to PostgreSQL/orafce verbatim, best-effort,
  with **no translator-owned compatibility claim at all**. A passing
  `passthrough_probe` corpus case is telemetry only — it never counts toward
  the numbers above, and it never gets silently promoted to `supported`
  just because it happened to pass once.

## Supported (semantic equivalence claimed)

| Feature | What it covers |
|---|---|
| `identifier-folding` | A double-quoted ALL-UPPERCASE identifier folds to quoted lowercase (Oracle's own convention → an ordinary unquoted-DDL Postgres table). |
| `dictionary-qualification` | A table reference matching the Oracle dictionary whitelist is qualified to `<dict-schema>.<name>`. |
| `dual` | `DUAL` (bare, quoted, `SYS.`/`SYSTEM.`-qualified) — dictionary-qualification's own special case. |
| `rownum-filter` | `WHERE ROWNUM <op> N` → `LIMIT`, scoped to shapes proven safe (sole predicate, AND-conjoined anywhere, never combined with `ORDER BY`/`GROUP BY`/set-ops/`OR` in the same block). |
| `rownum-projection` | A projected `ROWNUM` → `row_number() OVER ()`. |
| `outer-join-plus` | Oracle's legacy `(+)` outer-join operator → an ANSI `LEFT JOIN`, including outer-table filters moving into `ON`. |
| `nvl` | `NVL(a, b)` → `COALESCE(a, b)`. |
| `nvl2` | `NVL2(a, b, c)` → `CASE WHEN a IS NOT NULL THEN b ELSE c END`. |
| `decode` | `DECODE(...)` → `CASE ... IS NOT DISTINCT FROM ...` (Oracle's `NULL = NULL` DECODE semantics, which a plain `CASE ... WHEN` doesn't have). |
| `bitand` | `BITAND(a, b)` → a `numeric`-cast bigint `&`, avoiding both Postgres's missing `numeric &` operator and its integer-division truncation on a bare large literal. |
| `sysdate` | `SYSDATE` and `SYSDATE ± N` (integer or fractional days, including parenthesized terms) → `date_trunc('second', LOCALTIMESTAMP)` scaled by `INTERVAL '1 day'`. |
| `systimestamp` | `SYSTIMESTAMP` → `CURRENT_TIMESTAMP`. |
| `sys-context` | The well-defined `SYS_CONTEXT('USERENV', <attr>)` attributes. |
| `xs-sys-context` | `XS_SYS_CONTEXT('XS$SESSION','USERNAME')`, including nested in `DECODE` (sqlplus's own login probe shape). |
| `dbms-lob-getlength` | `DBMS_LOB.GETLENGTH(x)` → `length(x)` — see its own astral-Unicode caveat below. |
| `greatest-least` | `GREATEST`/`LEAST` guarded for Oracle's any-NULL-poisons semantics (Postgres's native forms silently ignore NULL arguments instead). |
| `hextoraw` | `HEXTORAW('...')` → `decode('...', 'hex')`. |
| `listagg` | `LISTAGG(...) WITHIN GROUP (ORDER BY ...)` → `string_agg(...)`, including the 1-argument (no delimiter) form; `ON OVERFLOW` and an analytic `OVER (...)` are `translate_error`, not silently mistranslated. |
| `concat-null` | Oracle `\|\|` treats NULL as empty string; Postgres's native `\|\|` returns NULL for the whole expression instead — rewritten to `concat(...)`. |
| `cast-types` | Oracle→Postgres `CAST` type-name mapping (`VARCHAR2`→`varchar`, `NUMBER(p,s)`→`numeric(p,s)`, etc.). |
| `connect-by` | `START WITH ... CONNECT BY PRIOR ...` → `WITH RECURSIVE`, for the single-table, no-`SYS_CONNECT_BY_PATH`/`CONNECT_BY_ROOT`/`ORDER SIBLINGS BY` shape this rewrite can prove faithful. **Known gap:** a genuine cyclic-data query is NOT rejected the way real Oracle rejects it (`ORA-01436`) — see `connect_by_cycle_not_exercised` in the corpus and `rewriteConnectBy`'s own scope notes. |
| `minus` | `MINUS`/`MINUS ALL` → `EXCEPT`/`EXCEPT ALL`. |
| `mixed-set-precedence` | Forces Oracle's strict left-to-right `UNION`/`INTERSECT`/`MINUS` evaluation order — Postgres natively gives `INTERSECT` higher precedence, which can silently return a **different row set**, not just a different order. |
| `alternative-quoting` | Oracle's `` q'delim...delim' `` literal syntax → an ordinary `'...'` literal. |
| `hash-identifiers` | A `#`-containing qualified column reference (`xt.obj#`, legal unquoted in Oracle, illegal unquoted in Postgres) gets quoted. |
| `user-pseudocolumn` | Oracle's bare `USER` → this proxy's configured logical schema, as a literal. |
| `to-char-datetime` | `TO_CHAR(date/timestamp, model)` format-model validation — an allowed element passes through untouched; a same-named-but-different-meaning element (`RR`, `RRRR`, bare `FF`, `TZR`, `TZD`, ...) is `translate_error`, never silently mis-rendered. |
| `to-char-numeric` | Same validation for `TO_CHAR(number, model)` — a locale-dependent element (`L`, `C`, `B`, `X`) is `translate_error`. |

## Approximation (deliberate, documented divergence)

| Feature | The divergence |
|---|---|
| `rowid` | Real Oracle's `ROWID` is its own 18-character base64 value; this proxy returns PostgreSQL's `(block,offset)` `ctid` rendered as text. Never byte-identical to a real Oracle `ROWID` — useful as a per-row locator, not as a portable value. |
| `empty-string-compare` | `col = ''` / `col <> ''` / `col != ''` are rewritten to `col IS [NOT] NULL` (the "developer intent" reading — Oracle can't store an empty `VARCHAR2` distinct from NULL). Real Oracle's `col = ''` is really `col = NULL`, which is `UNKNOWN` and matches **no rows at all** — not even NULL ones. Confirmed live: against a NULL-modeling fixture row, real Oracle's `col = ''` returns 0 rows while the translated `col IS NULL` returns every NULL row. A real, value-level difference, not just a caveat about a PostgreSQL column that happens to hold a physical empty string. |

## Rejected (refused with a stable `ORA-` code)

| Feature | Why |
|---|---|
| `sequence-pseudocolumn-rejection` | `seq.NEXTVAL`/`seq.CURRVAL` — this proxy is read-only, and even a read-only `CURRVAL` depends on the SAME pooled Postgres connection having called `NEXTVAL` first, which cannot be reliably guaranteed. |
| `residual-oracle-grammar` | A fixed list of Oracle-only constructs with no rewrite: `PIVOT`, `UNPIVOT`, analytic `IGNORE NULLS`, `KEEP (DENSE_RANK ...)`, `AS OF TIMESTAMP`/`SCN` flashback, `SELECT UNIQUE`, `RATIO_TO_REPORT`, and any `DBMS_*` package call this proxy doesn't otherwise translate. |

Every non-DML/DDL statement that isn't a `SELECT`/`WITH` is also rejected
(`ORA-00900`), as is any text containing more than one statement
(`ORA-00933`) — read-only defense in depth, ahead of the backend's own
`READ ONLY` transaction, which is the actual authoritative guard.

## Passthrough (forwarded verbatim, best-effort — orafce-backed)

No dedicated rewrite exists for any of these; they reach PostgreSQL exactly
as written and resolve through **orafce**, the Postgres extension this
project installs specifically to give these Oracle-semantic behavior
(`ADD_MONTHS`, `SUBSTR`'s 1-based/negative-start indexing, etc.) that
Postgres's own native functions of the same name don't have. **A passing
`passthrough_probe` case proves the plumbing works end to end — it does
not mean this translator vouches for the function's own semantics.**

`add-months` · `last-day` · `instr` · `substr` · `to-date` · `to-number`

## What "supported" does NOT mean

A `supported` feature is faithful **for the shapes its differential cases and
unit tests actually cover** — this is a token-based translator, not a full
Oracle SQL parser, so it
recognizes and rewrites a documented, provable subset and otherwise leaves
text untouched for PostgreSQL to accept or reject on its own. It never
claims — and cannot verify — that arbitrary surrounding SQL is even
syntactically sane Oracle to begin with.

Two additional narrow, real gaps, found live and documented rather than
silently left uncovered:

- **`DBMS_LOB.GETLENGTH`** on text containing an astral (non-BMP) Unicode
  character (most emoji): real Oracle's CLOB-internal length counts it as
  its own UTF-16 surrogate pair (2 units); PostgreSQL's `length()` and even
  Oracle's own plain `LENGTH()`/`LENGTHC()` count it as one codepoint.
  PostgreSQL has no built-in UTF-16-code-unit counter, so this is not
  implemented and remains a documented approximation.
- **`CHAR(n)`/`char(n)`**: PostgreSQL's own `length()` and `\|\|` silently
  strip trailing spaces from a `char(n)` value (a well-known PostgreSQL
  quirk, not a translator bug — the raw stored/returned value itself stays
  fully padded on both sides). This behavior is pinned by byte-level tests.

## Supported Oracle and PostgreSQL versions

Live-verified this project's own differential corpus and dictionary work
against **Oracle Database 26ai Free** (`gvenzl/oracle-free:slim`, currently
built on Oracle 23ai/26ai) and **Oracle Database 19c** (dblink-initiator
flows only — see the `oracle-19c-dblink-support` project history), both
against **PostgreSQL 16**. Other Oracle/PostgreSQL versions are untested,
not unsupported by design — the translator makes no version-specific
assumptions its own tests don't already probe.

The contract is versioned with each release. If a query falls outside the
documented shapes, treat it as untested even when PostgreSQL happens to accept
the translated text. Please report mismatches with the exact release, client
version, SQL and redacted result details.
