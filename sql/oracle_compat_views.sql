-- orapglink: Oracle dictionary-compatibility views over pg_catalog.
--
-- Run ONCE (and again after every upgrade) by the orapglink_install role
-- (see provision_roles.sql) — orapglink's own runtime connection
-- (orapglink_runtime) only ever SELECTs from what this file creates, never
-- runs it. This is a transactional, idempotent, versioned,
-- grants-included migration — not just a scratch file of CREATE VIEWs.
--
-- Phase 1 scope: just enough for the headline dblink demo and DUAL-based
-- connectivity probes to work — `dual` plus the version/install
-- bookkeeping. The fuller object-tree views (all_tables,
-- all_tab_columns, all_constraints, all_indexes, all_triggers,
-- all_procedures, all_source, all_sequences, all_objects, the USER_*/DBA_*
-- forms, …) land in Phase 3 as further versioned migrations appended below
-- (bump SCHEMA_VERSION and add a new versioned block — never edit an
-- already-shipped block in place once a deployment may have run it).
--
-- Replace <RUNTIME_ROLE> below if you changed the role name in
-- provision_roles.sql.

BEGIN;

CREATE SCHEMA IF NOT EXISTS oradict;

CREATE TABLE IF NOT EXISTS oradict.schema_version (
    version     integer PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Version 1 (Phase 1): DUAL only.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 1) THEN
        CREATE OR REPLACE VIEW oradict.dual AS SELECT 'X'::varchar(1) AS dummy;

        INSERT INTO oradict.schema_version (version) VALUES (1);
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 2 (Phase 3): the DBeaver object-tree core — schemas/users,
-- tables, views, columns, comments, and a first cut of ALL_OBJECTS.
-- These public views provide the object-tree core used by supported clients.
--
-- User model: Oracle schema/user == a Postgres
-- schema (namespace). OWNER/USERNAME = uppercased pg_namespace.nspname,
-- excluding system schemas.
--
-- Type mapping: oradict.pg_to_ora_type_name(atttypid, charlen) mirrors the
-- proxy's PostgreSQL-to-Oracle wire type mapping. DATA_LENGTH is BYTES
-- (AL32UTF8: up to 4/char);
-- CHAR_LENGTH is characters.
-- ---------------------------------------------------------------------
DO $$
BEGIN
IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 2) THEN

-- RETURNS varchar(30) alone is NOT enough: Postgres never records a scalar
-- function's declared return typmod anywhere a view column can see it
-- (pg_proc has no typmod slot for a function's result the way pg_attribute
-- does for a table column) — every caller of a varchar(N)-returning function
-- sees an UNBOUNDED varchar (typmod -1) in its own view column, function
-- signature notwithstanding. Verified directly: even with this function's
-- CASE cast to ::varchar(30) below, a plain `CREATE VIEW v AS SELECT
-- oradict.pg_to_ora_type_name(...) AS dt` still showed dt's atttypmod = -1;
-- only adding ::varchar(30) AT THE VIEW'S OWN CALL SITE (both call sites in
-- this file, all_tab_columns and all_arguments) fixed it. An unbounded
-- varchar maps to CLOB (pgTypeToOracle), which modern-classic's
-- mcColumnTypeSupported doesn't cover — every dictionary column-listing
-- query failed over that dialect until both the inner AND the call-site
-- casts were in place; keep the call-site casts below.
CREATE OR REPLACE FUNCTION oradict.pg_to_ora_type_name(typ regtype, charlen integer)
RETURNS varchar(30) LANGUAGE sql IMMUTABLE AS $f$
    SELECT (CASE typ::text
        WHEN 'smallint' THEN 'NUMBER'
        WHEN 'integer' THEN 'NUMBER'
        WHEN 'bigint' THEN 'NUMBER'
        WHEN 'numeric' THEN 'NUMBER'
        WHEN 'real' THEN 'NUMBER'
        WHEN 'double precision' THEN 'NUMBER'
        WHEN 'boolean' THEN 'NUMBER'
        WHEN 'character varying' THEN CASE WHEN charlen > 0 THEN 'VARCHAR2' ELSE 'CLOB' END
        WHEN 'character' THEN 'CHAR'
        WHEN 'text' THEN 'CLOB'
        WHEN 'date' THEN 'DATE'
        WHEN 'timestamp without time zone' THEN 'TIMESTAMP'
        WHEN 'timestamp with time zone' THEN 'TIMESTAMP_TZ'
        WHEN 'time without time zone' THEN 'VARCHAR2'
        WHEN 'time with time zone' THEN 'VARCHAR2'
        WHEN 'interval' THEN 'VARCHAR2'
        WHEN 'bytea' THEN 'BLOB'
        WHEN 'uuid' THEN 'VARCHAR2'
        WHEN 'json' THEN 'CLOB'
        WHEN 'jsonb' THEN 'CLOB'
        WHEN 'xml' THEN 'CLOB'
        ELSE 'VARCHAR2'
    END)::varchar(30);
$f$;

-- pg_charlen extracts the declared character length from atttypmod for
-- character varying(n)/character(n) ONLY (atttypmod = n+4 for those two
-- types specifically; -1 means unbounded, surfaced here as NULL). For every
-- OTHER type atttypmod means something completely different (numeric(p,s)
-- bit-packs precision+scale into it, most others don't use it at all) — a
-- naive `atttypmod - 4` applied universally produces GARBAGE for those (e.g.
-- a numeric(12,2) column showed a bogus ~786000 "char_length" before this
-- function existed). Always gate on typ FIRST.
CREATE OR REPLACE FUNCTION oradict.pg_charlen(typ regtype, typmod integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE
        WHEN typ::text IN ('character varying', 'character') AND typmod > 0
            THEN typmod - 4
        ELSE NULL
    END;
$f$;

-- Mirrors the proxy's canonical type-mapping table exactly
-- (DATA_LENGTH column) — NUMBER/DATE/TIMESTAMP/TIMESTAMP_TZ get their FIXED
-- Oracle wire-format byte sizes (22/7/11/13), not something derived from
-- atttypmod (which for numeric(p,s) encodes precision/scale, not a byte
-- length — feeding it in here would be nonsense for those types; charlen is
-- ONLY meaningful for character varying/character, see all_tab_columns
-- below, which only passes a non-null charlen for those two types).
CREATE OR REPLACE FUNCTION oradict.pg_to_ora_data_length(typ regtype, charlen integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE typ::text
        WHEN 'smallint' THEN 22
        WHEN 'integer' THEN 22
        WHEN 'bigint' THEN 22
        WHEN 'numeric' THEN 22
        WHEN 'real' THEN 22
        WHEN 'double precision' THEN 22
        WHEN 'boolean' THEN 22
        WHEN 'date' THEN 7
        WHEN 'timestamp without time zone' THEN 11
        WHEN 'timestamp with time zone' THEN 13
        WHEN 'time without time zone' THEN 40
        WHEN 'time with time zone' THEN 40
        WHEN 'interval' THEN 40
        WHEN 'uuid' THEN 36
        WHEN 'character varying' THEN
            CASE WHEN charlen > 0 THEN LEAST(charlen * 4, 4000) END -- NULL (LOB) when unbounded
        WHEN 'character' THEN
            CASE WHEN charlen > 0 THEN LEAST(charlen * 4, 4000) ELSE 4000 END
        WHEN 'text' THEN NULL -- LOB: no fixed byte length
        WHEN 'bytea' THEN NULL
        WHEN 'json' THEN NULL
        WHEN 'jsonb' THEN NULL
        WHEN 'xml' THEN NULL
        ELSE 4000 -- universal VARCHAR2 fallback
    END;
$f$;

-- ---- Schemas / users --------------------------------------------------
CREATE OR REPLACE VIEW oradict.all_users AS
SELECT upper(n.nspname)::varchar(128) AS username, n.oid::bigint AS user_id,
       NULL::timestamptz AS created, 'NO'::varchar(3) AS common,
       'NO'::varchar(3) AS oracle_maintained,
       -- Real Oracle's ALL_USERS carries ALL_SHARD (12.2+), and DBeaver's
       -- sharding probe filters on it. §112B: the old wire-side substring
       -- marker answered that probe ORA-00942 by ACCIDENT (it matched
       -- all_shard as a mere column name); with relation-context markers the
       -- probe legitimately reaches this view, so the column must exist —
       -- 'NO' everywhere, matching the supported Oracle-facing contract.
       'NO'::varchar(3) AS all_shard
FROM pg_namespace n
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict')
  AND n.nspname NOT LIKE 'pg\_temp\_%' AND n.nspname NOT LIKE 'pg\_toast\_temp\_%';

-- ---- Tables -------------------------------------------------------------
CREATE OR REPLACE VIEW oradict.all_tables AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(c.relname)::varchar(128) AS table_name,
       NULL::varchar(30) AS tablespace_name, 'VALID'::varchar(8) AS status,
       c.reltuples::bigint AS num_rows,
       (CASE c.relpersistence WHEN 't' THEN 'Y' ELSE 'N' END)::varchar(1) AS temporary,
       (CASE c.relkind WHEN 'p' THEN 'YES' ELSE 'NO' END)::varchar(3) AS partitioned,
       obj_description(c.oid, 'pg_class') AS comments
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict')
  AND n.nspname NOT LIKE 'pg\_temp\_%';

CREATE OR REPLACE VIEW oradict.all_all_tables AS
SELECT owner, table_name, NULL::varchar(128) AS table_type_owner, NULL::varchar(18) AS table_type,
       tablespace_name, status, num_rows, temporary, partitioned, comments,
       -- Oracle-specific object attributes that have no Postgres equivalent —
       -- reported as heap/plain (NULL/'N'/'NO'). DBeaver's table-tree query
       -- selects these from ALL_ALL_TABLES. Appended at the END so CREATE OR
       -- REPLACE doesn't reject a column-order change.
       NULL::varchar(12) AS iot_type, NULL::varchar(128) AS iot_name,
       'N'::varchar(1) AS secondary, 'NO'::varchar(3) AS nested
FROM oradict.all_tables;

-- ---- Views ----------------------------------------------------------
CREATE OR REPLACE VIEW oradict.all_views AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(c.relname)::varchar(128) AS view_name,
       length(pg_get_viewdef(c.oid))::bigint AS text_length,
       pg_get_viewdef(c.oid) AS text, 'VALID'::varchar(8) AS status
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'v'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- Columns & comments -------------------------------------------------
CREATE OR REPLACE VIEW oradict.all_tab_columns AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(c.relname)::varchar(128) AS table_name,
       upper(a.attname)::varchar(128) AS column_name,
       oradict.pg_to_ora_type_name(a.atttypid::regtype, oradict.pg_charlen(a.atttypid::regtype, a.atttypmod))::varchar(30) AS data_type,
       oradict.pg_to_ora_data_length(a.atttypid::regtype, oradict.pg_charlen(a.atttypid::regtype, a.atttypmod)) AS data_length,
       CASE WHEN a.atttypid::regtype::text = 'numeric' AND a.atttypmod > 0
            THEN ((a.atttypmod - 4) >> 16) & 65535 END AS data_precision,
       CASE WHEN a.atttypid::regtype::text = 'numeric' AND a.atttypmod > 0
            THEN (a.atttypmod - 4) & 65535 END AS data_scale,
       (CASE WHEN a.attnotnull THEN 'N' ELSE 'Y' END)::varchar(1) AS nullable,
       a.attnum AS column_id,
       pg_get_expr(ad.adbin, ad.adrelid) AS data_default,
       oradict.pg_charlen(a.atttypid::regtype, a.atttypmod) AS char_length,
       (CASE WHEN oradict.pg_charlen(a.atttypid::regtype, a.atttypmod) IS NOT NULL THEN 'C' END)::varchar(1) AS char_used,
       col_description(c.oid, a.attnum) AS comments
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
WHERE a.attnum > 0 AND NOT a.attisdropped
  AND c.relkind IN ('r', 'p', 'v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

CREATE OR REPLACE VIEW oradict.all_tab_cols AS SELECT * FROM oradict.all_tab_columns;

CREATE OR REPLACE VIEW oradict.all_tab_comments AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(c.relname)::varchar(128) AS table_name,
       (CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END)::varchar(18) AS table_type,
       obj_description(c.oid, 'pg_class') AS comments
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

CREATE OR REPLACE VIEW oradict.all_col_comments AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(c.relname)::varchar(128) AS table_name,
       upper(a.attname)::varchar(128) AS column_name, col_description(c.oid, a.attnum) AS comments
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE a.attnum > 0 AND NOT a.attisdropped
  AND c.relkind IN ('r', 'p', 'v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- Sequences ----------------------------------------------------------
CREATE OR REPLACE VIEW oradict.all_sequences AS
SELECT upper(schemaname)::varchar(128) AS sequence_owner, upper(sequencename)::varchar(128) AS sequence_name,
       min_value, max_value, increment_by,
       (CASE WHEN cycle THEN 'Y' ELSE 'N' END)::varchar(1) AS cycle_flag,
       'N'::varchar(1) AS order_flag, cache_size, last_value AS last_number
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- ALL_OBJECTS (first cut: tables/views/mviews/sequences; functions,
-- triggers, indexes added in version 3/4 below) ---------------------------
-- Column types here MUST match version 5's later CREATE OR REPLACE of this
-- same view exactly (varchar bounds included) — Postgres rejects CREATE OR
-- REPLACE VIEW if it would change an existing column's type, so if a real
-- deployment upgrades straight from a pre-fix v2 to this fixed v5 within one
-- run, the types must already agree here or v5's CREATE OR REPLACE errors.
CREATE OR REPLACE VIEW oradict.all_objects AS
SELECT owner, table_name AS object_name, NULL::bigint AS object_id,
       (CASE table_type WHEN 'VIEW' THEN 'VIEW' WHEN 'MATERIALIZED VIEW' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END)::varchar(18) AS object_type,
       'VALID'::varchar(8) AS status, NULL::timestamptz AS created, NULL::timestamptz AS last_ddl_time,
       'N'::varchar(1) AS temporary, 'N'::varchar(1) AS generated
FROM oradict.all_tab_comments
UNION ALL
SELECT sequence_owner AS owner, sequence_name AS object_name, NULL::bigint,
       'SEQUENCE'::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
FROM oradict.all_sequences;

-- ---- USER_*/DBA_* forms (NOT plain aliases —
-- USER_* filters to the fixed logical schema and drops OWNER; DBA_* mirrors
-- ALL_* in this single-logical-DB model). Logical schema is the STATIC
-- --logical-schema value, uppercased — 'APP' is the project default; if you
-- changed --logical-schema, edit the literal below and re-run this file. ----
CREATE OR REPLACE VIEW oradict.dba_tables AS SELECT * FROM oradict.all_tables;
CREATE OR REPLACE VIEW oradict.dba_all_tables AS SELECT * FROM oradict.all_all_tables;
CREATE OR REPLACE VIEW oradict.dba_views AS SELECT * FROM oradict.all_views;
CREATE OR REPLACE VIEW oradict.dba_tab_columns AS SELECT * FROM oradict.all_tab_columns;
CREATE OR REPLACE VIEW oradict.dba_tab_cols AS SELECT * FROM oradict.all_tab_cols;
CREATE OR REPLACE VIEW oradict.dba_tab_comments AS SELECT * FROM oradict.all_tab_comments;
CREATE OR REPLACE VIEW oradict.dba_col_comments AS SELECT * FROM oradict.all_col_comments;
CREATE OR REPLACE VIEW oradict.dba_users AS SELECT * FROM oradict.all_users;
CREATE OR REPLACE VIEW oradict.dba_sequences AS SELECT * FROM oradict.all_sequences;
CREATE OR REPLACE VIEW oradict.dba_objects AS SELECT * FROM oradict.all_objects;
CREATE OR REPLACE VIEW oradict.tabs AS SELECT * FROM oradict.all_tables;
CREATE OR REPLACE VIEW oradict.cols AS SELECT * FROM oradict.all_tab_columns;

CREATE OR REPLACE VIEW oradict.user_tables AS
SELECT table_name, tablespace_name, status, num_rows, temporary, partitioned, comments
FROM oradict.all_tables WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_all_tables AS
SELECT table_name, table_type_owner, table_type, tablespace_name, status, num_rows, temporary, partitioned, comments
FROM oradict.all_all_tables WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_views AS
SELECT view_name, text_length, text, status FROM oradict.all_views
WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_tab_columns AS
SELECT table_name, column_name, data_type, data_length, data_precision, data_scale,
       nullable, column_id, data_default, char_length, char_used, comments
FROM oradict.all_tab_columns WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_tab_cols AS SELECT * FROM oradict.user_tab_columns;
CREATE OR REPLACE VIEW oradict.user_tab_comments AS
SELECT table_name, table_type, comments FROM oradict.all_tab_comments WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_col_comments AS
SELECT table_name, column_name, comments FROM oradict.all_col_comments WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_users AS
SELECT username, user_id, created, all_shard FROM oradict.all_users WHERE username = 'APP';
CREATE OR REPLACE VIEW oradict.user_sequences AS
SELECT sequence_name, min_value, max_value, increment_by, cycle_flag, order_flag, cache_size, last_number
FROM oradict.all_sequences WHERE sequence_owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_objects AS
SELECT object_name, object_id, object_type, status, created, last_ddl_time, temporary, generated
FROM oradict.all_objects WHERE owner = 'APP';

INSERT INTO oradict.schema_version (version) VALUES (2);
END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 3 (Phase 3): constraints, indexes, triggers — the object types
-- that make DBeaver draw PK/FK badges, the ER diagram, and index/trigger
-- tree nodes.
-- ---------------------------------------------------------------------
DO $$
BEGIN
IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 3) THEN

-- ---- Constraints ----------------------------------------------------
-- R_CONSTRAINT_NAME/R_OWNER resolve a FK to the constraint it actually
-- references (its target's PK/UNIQUE constraint, matched via
-- confrelid+confkey against that constraint's own conrelid+conkey — pg_constraint
-- has no direct "referenced constraint oid" column), not just the referenced
-- TABLE (a naive confrelid-only join
-- gives the table but leaves R_CONSTRAINT_NAME wrong).
CREATE OR REPLACE VIEW oradict.all_constraints AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(co.conname)::varchar(128) AS constraint_name,
       (CASE co.contype
           WHEN 'p' THEN 'P' WHEN 'f' THEN 'R' WHEN 'u' THEN 'U' WHEN 'c' THEN 'C'
           ELSE upper(co.contype::text)
       END)::varchar(1) AS constraint_type,
       upper(c.relname)::varchar(128) AS table_name,
       CASE WHEN co.contype = 'c' THEN pg_get_constraintdef(co.oid) END AS search_condition,
       'ENABLED'::varchar(8) AS status,
       upper(rn.nspname)::varchar(128) AS r_owner,
       upper(rco.conname)::varchar(128) AS r_constraint_name,
       (CASE co.confdeltype
           WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT'
           WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION'
       END)::varchar(11) AS delete_rule
FROM pg_constraint co
JOIN pg_class c ON c.oid = co.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_constraint rco ON rco.conrelid = co.confrelid AND rco.conkey = co.confkey
                            AND rco.contype IN ('p', 'u') AND co.contype = 'f'
LEFT JOIN pg_namespace rn ON rn.oid = rco.connamespace
WHERE co.contype IN ('p', 'f', 'u', 'c')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

CREATE OR REPLACE VIEW oradict.all_cons_columns AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(co.conname)::varchar(128) AS constraint_name,
       upper(c.relname)::varchar(128) AS table_name, upper(a.attname)::varchar(128) AS column_name,
       k.ord::bigint AS position
FROM pg_constraint co
JOIN pg_class c ON c.oid = co.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL unnest(co.conkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = k.attnum
WHERE co.contype IN ('p', 'f', 'u')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- Indexes ----------------------------------------------------------
-- ALL_IND_COLUMNS caveats implemented: only
-- indnkeyatts columns are KEY columns (INCLUDE columns beyond that are
-- covering, not key — excluded here); a 0 in indkey is an expression, not a
-- real column (excluded, not synthesized); DESCEND comes from indoption's
-- bit 0, not a constant.
CREATE OR REPLACE VIEW oradict.all_indexes AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(ic.relname)::varchar(128) AS index_name,
       (CASE WHEN i.indexprs IS NOT NULL THEN 'FUNCTION-BASED NORMAL' ELSE 'NORMAL' END)::varchar(27) AS index_type,
       upper(n.nspname)::varchar(128) AS table_owner, upper(tc.relname)::varchar(128) AS table_name,
       (CASE WHEN i.indisunique THEN 'UNIQUE' ELSE 'NONUNIQUE' END)::varchar(9) AS uniqueness,
       'VALID'::varchar(8) AS status
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON n.oid = tc.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

CREATE OR REPLACE VIEW oradict.all_ind_columns AS
SELECT upper(n.nspname)::varchar(128) AS index_owner, upper(ic.relname)::varchar(128) AS index_name,
       upper(tc.relname)::varchar(128) AS table_name, upper(a.attname)::varchar(128) AS column_name,
       k.ord::bigint AS column_position,
       (CASE WHEN (i.indoption[k.ord - 1] & 1) = 1 THEN 'DESC' ELSE 'ASC' END)::varchar(4) AS descend
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON n.oid = tc.relnamespace
CROSS JOIN LATERAL unnest(i.indkey[0:i.indnkeyatts - 1]) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
WHERE k.attnum <> 0 -- excludes expression positions, not just dropped columns
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- Triggers -----------------------------------------------------------
-- pg_trigger.tgtype bit decode: bit0=row-level, bits1-2=timing
-- (BEFORE=2,AFTER=0 unless INSTEAD OF via tgisinstead), bits3-5=events
-- (INSERT=4,DELETE=8,UPDATE=16).
CREATE OR REPLACE VIEW oradict.all_triggers AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(t.tgname)::varchar(128) AS trigger_name,
       ((CASE WHEN t.tgtype::int & 2 = 2 THEN 'BEFORE'
             WHEN t.tgtype::int & 64 = 64 THEN 'INSTEAD OF'
             ELSE 'AFTER' END) || ' ' ||
       array_to_string(ARRAY(SELECT ev FROM unnest(ARRAY[
           CASE WHEN t.tgtype::int & 4 = 4 THEN 'INSERT' END,
           CASE WHEN t.tgtype::int & 8 = 8 THEN 'DELETE' END,
           CASE WHEN t.tgtype::int & 16 = 16 THEN 'UPDATE' END
       ]) AS ev WHERE ev IS NOT NULL), ' OR ') ||
       (CASE WHEN t.tgtype::int & 1 = 1 THEN ' EACH ROW' ELSE '' END))::varchar(200) AS trigger_type,
       (CASE WHEN t.tgtype::int & 4 = 4 THEN 'INSERT' END)::varchar(10) AS triggering_event,
       upper(n.nspname)::varchar(128) AS table_owner, 'TABLE'::varchar(30) AS base_object_type,
       upper(c.relname)::varchar(128) AS table_name,
       (CASE WHEN t.tgenabled = 'D' THEN 'DISABLED' ELSE 'ENABLED' END)::varchar(8) AS status,
       pg_get_triggerdef(t.oid) AS trigger_body
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- DBA_*/USER_* forms --------------------------------------------------
CREATE OR REPLACE VIEW oradict.dba_constraints AS SELECT * FROM oradict.all_constraints;
CREATE OR REPLACE VIEW oradict.dba_cons_columns AS SELECT * FROM oradict.all_cons_columns;
CREATE OR REPLACE VIEW oradict.dba_indexes AS SELECT * FROM oradict.all_indexes;
CREATE OR REPLACE VIEW oradict.dba_ind_columns AS SELECT * FROM oradict.all_ind_columns;
CREATE OR REPLACE VIEW oradict.dba_triggers AS SELECT * FROM oradict.all_triggers;

CREATE OR REPLACE VIEW oradict.user_constraints AS
SELECT constraint_name, constraint_type, table_name, search_condition, status, r_owner, r_constraint_name, delete_rule
FROM oradict.all_constraints WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_cons_columns AS
SELECT constraint_name, table_name, column_name, position FROM oradict.all_cons_columns WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_indexes AS
SELECT index_name, index_type, table_name, uniqueness, status FROM oradict.all_indexes WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_ind_columns AS
SELECT index_name, table_name, column_name, column_position, descend FROM oradict.all_ind_columns WHERE index_owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_triggers AS
SELECT trigger_name, trigger_type, triggering_event, table_owner, base_object_type, table_name, status, trigger_body
FROM oradict.all_triggers WHERE owner = 'APP';

INSERT INTO oradict.schema_version (version) VALUES (3);
END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 4 (Phase 3): procedures/functions, their source, and their
-- arguments. Postgres allows overloaded
-- routines (same name, different signature) — pg_proc.oid is the real
-- identity, NOT proname; OVERLOAD numbers same-named routines by oid order
-- so DBeaver can tell them apart. pg_get_functiondef() is invalid for
-- aggregates/window functions — prokind is filtered to 'f'/'p' throughout.
-- ---------------------------------------------------------------------
DO $$
BEGIN
IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 4) THEN

CREATE OR REPLACE VIEW oradict.all_procedures AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(p.proname)::varchar(128) AS object_name,
       upper(p.proname)::varchar(128) AS procedure_name,
       (CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END)::varchar(9) AS object_type,
       row_number() OVER (PARTITION BY n.nspname, p.proname ORDER BY p.oid) - 1 AS overload,
       p.oid::bigint AS subprogram_id
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind IN ('f', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

CREATE OR REPLACE VIEW oradict.all_source AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(p.proname)::varchar(128) AS name,
       (CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END)::varchar(9) AS type,
       p.oid::bigint AS subprogram_id,
       s.line, s.text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL (
    SELECT row_number() OVER () AS line, x || E'\n' AS text
    FROM regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') AS x
) s
WHERE p.prokind IN ('f', 'p') -- pg_get_functiondef errors on aggregates/window funcs
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

CREATE OR REPLACE VIEW oradict.all_arguments AS
SELECT upper(n.nspname)::varchar(128) AS owner, upper(p.proname)::varchar(128) AS object_name,
       NULL::varchar(128) AS package_name, p.oid::bigint AS subprogram_id,
       upper(COALESCE(a.name, ''))::varchar(128) AS argument_name,
       a.ord::bigint AS position,
       oradict.pg_to_ora_type_name(a.typ, NULL)::varchar(30) AS data_type,
       (CASE a.mode WHEN 'o' THEN 'OUT' WHEN 'b' THEN 'IN/OUT' ELSE 'IN' END)::varchar(6) AS in_out
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN LATERAL unnest(
    COALESCE(p.proallargtypes, p.proargtypes::oid[]),
    COALESCE(p.proargnames, ARRAY[]::text[]),
    COALESCE(p.proargmodes, array_fill('i'::text, ARRAY[COALESCE(array_length(p.proargtypes, 1), 0)]))
) WITH ORDINALITY AS a(typ, name, mode, ord)
WHERE p.prokind IN ('f', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');

-- ---- DBA_*/USER_* forms --------------------------------------------------
CREATE OR REPLACE VIEW oradict.dba_procedures AS SELECT * FROM oradict.all_procedures;
CREATE OR REPLACE VIEW oradict.dba_source AS SELECT * FROM oradict.all_source;
CREATE OR REPLACE VIEW oradict.dba_arguments AS SELECT * FROM oradict.all_arguments;

CREATE OR REPLACE VIEW oradict.user_procedures AS
SELECT object_name, procedure_name, object_type, overload, subprogram_id
FROM oradict.all_procedures WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_source AS
SELECT name, type, subprogram_id, line, text FROM oradict.all_source WHERE owner = 'APP';
CREATE OR REPLACE VIEW oradict.user_arguments AS
SELECT object_name, package_name, subprogram_id, argument_name, position, data_type, in_out
FROM oradict.all_arguments WHERE owner = 'APP';

INSERT INTO oradict.schema_version (version) VALUES (4);
END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 5 (Phase 3 polish): ALL_OBJECTS grows to a full UNION ALL
-- (tables/views/mviews/sequences/functions/procedures/triggers/indexes),
-- with a synthesized globally-unique OBJECT_ID
-- — raw oids collide across pg_class/pg_proc/pg_trigger, so a plain oid
-- cast is not safe as a single global key). Plus empty stub views for
-- object types Postgres has no concept of —
-- present so a client probing them gets zero rows, not ORA-00942.
-- ---------------------------------------------------------------------
DO $$
BEGIN
IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 5) THEN

CREATE OR REPLACE VIEW oradict.all_objects AS
SELECT owner, object_name, row_number() OVER (ORDER BY owner, object_type, object_name)::bigint AS object_id,
       object_type, status, created, last_ddl_time, temporary, generated
FROM (
    SELECT owner, table_name AS object_name,
           (CASE table_type WHEN 'VIEW' THEN 'VIEW' WHEN 'MATERIALIZED VIEW' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END)::varchar(18) AS object_type,
           'VALID'::varchar(8) AS status, NULL::timestamptz AS created, NULL::timestamptz AS last_ddl_time,
           'N'::varchar(1) AS temporary, 'N'::varchar(1) AS generated
    FROM oradict.all_tab_comments
    UNION ALL
    SELECT sequence_owner, sequence_name, 'SEQUENCE'::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
    FROM oradict.all_sequences
    UNION ALL
    SELECT owner, object_name, object_type::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
    FROM oradict.all_procedures
    UNION ALL
    SELECT owner, trigger_name, 'TRIGGER'::varchar(18), status::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
    FROM oradict.all_triggers
    UNION ALL
    SELECT owner, index_name, 'INDEX'::varchar(18), status::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
    FROM oradict.all_indexes
) u;

CREATE OR REPLACE VIEW oradict.dba_objects AS SELECT * FROM oradict.all_objects;
CREATE OR REPLACE VIEW oradict.user_objects AS
SELECT object_name, object_id, object_type, status, created, last_ddl_time, temporary, generated
FROM oradict.all_objects WHERE owner = 'APP';

-- ---- Empty stubs: Postgres has no equivalent, so these are always empty
-- (a correct, not just convenient, answer — nothing is ever a synonym, a
-- DB link, or Oracle-dependency-tracked in this model).
CREATE OR REPLACE VIEW oradict.all_synonyms AS
SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS synonym_name, NULL::varchar(128) AS table_owner,
       NULL::varchar(128) AS table_name, NULL::varchar(128) AS db_link
WHERE FALSE;
CREATE OR REPLACE VIEW oradict.user_synonyms AS SELECT * FROM oradict.all_synonyms;
CREATE OR REPLACE VIEW oradict.dba_synonyms AS SELECT * FROM oradict.all_synonyms;

CREATE OR REPLACE VIEW oradict.all_db_links AS
SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS db_link, NULL::varchar(128) AS username, NULL::varchar(128) AS host
WHERE FALSE;

CREATE OR REPLACE VIEW oradict.recyclebin AS
SELECT NULL::varchar(128) AS object_name WHERE FALSE;

INSERT INTO oradict.schema_version (version) VALUES (5);
END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 6: more empty stubs — Postgres has no user-defined ORDBMS types,
-- no Oracle-style dependency tracking, and no per-object grant catalog
-- distinct from what pg_catalog already exposes elsewhere in this schema —
-- same "correct empty answer, not ORA-00942" reasoning as v5's
-- ALL_SYNONYMS/ALL_DB_LINKS/RECYCLEBIN. Added for DBeaver/SQL Developer's
-- own object-tree and grants-tab queries (JDBC/thin priority), not because
-- any orapglink feature needs them.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 6) THEN
        CREATE OR REPLACE VIEW oradict.all_types AS
        SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS type_name, NULL::numeric AS type_oid,
               NULL::varchar(128) AS typecode, NULL::numeric AS attributes, NULL::numeric AS methods,
               NULL::varchar(3) AS predefined, NULL::varchar(3) AS incomplete, NULL::varchar(3) AS final,
               NULL::varchar(3) AS instantiable, NULL::varchar(128) AS supertype_owner, NULL::varchar(128) AS supertype_name
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_types AS SELECT * FROM oradict.all_types;
        CREATE OR REPLACE VIEW oradict.dba_types AS SELECT * FROM oradict.all_types;

        CREATE OR REPLACE VIEW oradict.all_dependencies AS
        SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS name, NULL::varchar(18) AS type,
               NULL::varchar(128) AS referenced_owner, NULL::varchar(128) AS referenced_name,
               NULL::varchar(18) AS referenced_type, NULL::varchar(128) AS referenced_link_name,
               NULL::varchar(4) AS dependency_type
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_dependencies AS SELECT * FROM oradict.all_dependencies;
        CREATE OR REPLACE VIEW oradict.dba_dependencies AS SELECT * FROM oradict.all_dependencies;

        CREATE OR REPLACE VIEW oradict.all_tab_privs AS
        SELECT NULL::varchar(128) AS grantor, NULL::varchar(128) AS grantee, NULL::varchar(128) AS table_schema,
               NULL::varchar(128) AS table_name, NULL::varchar(40) AS privilege, NULL::varchar(3) AS grantable,
               NULL::varchar(3) AS hierarchy
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_tab_privs AS SELECT * FROM oradict.all_tab_privs;
        CREATE OR REPLACE VIEW oradict.dba_tab_privs AS SELECT * FROM oradict.all_tab_privs;

        INSERT INTO oradict.schema_version (version) VALUES (6);
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 7: TAB$ / EXTERNAL_TAB$ — Oracle's own legacy low-level
-- dictionary pseudo-tables, which SQL Developer's (and DBeaver's) table-
-- tree query joins against directly rather than going through ALL_OBJECTS
-- for legacy client compatibility. Referenced
-- as oradict.tab$/oradict.external_tab$ via the translator's whitelist
-- qualification (both names already listed in defaultDictNames) — these
-- views just didn't exist yet, so a real query hit "relation does not
-- exist" once the separate #-in-identifier syntax bug (oratranslate's
-- rewriteHashColumns) was fixed. external_tab$ is unconditionally EMPTY:
-- this proxy has no concept of external tables, which is also the
-- semantically correct value for the tree query's own
-- "case when xt.obj# is null then 'N' else 'Y' end" probe (nothing is
-- ever external).
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 7) THEN
        CREATE OR REPLACE VIEW oradict.tab$ AS
        SELECT object_id AS "obj#", 0::bigint AS property, 0::bigint AS flags
        FROM oradict.all_objects;

        CREATE OR REPLACE VIEW oradict.external_tab$ AS
        SELECT NULL::bigint AS "obj#" WHERE FALSE;

        INSERT INTO oradict.schema_version (version) VALUES (7);
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 8: ALL_TAB_PARTITIONS / USER_TAB_PARTITIONS / DBA_TAB_PARTITIONS —
-- listed in the translator's whitelist (defaultDictNames' "tab_partitions"
-- base) since the beginning, but never actually installed, so SQL
-- Developer's own table-node expansion (queried right after
-- DBA_TAB_COLUMNS: "SELECT PARTITION_NAME FROM SYS.Dba_TAB_PARTITIONS WHERE
-- TABLE_OWNER = :SCHEMA AND TABLE_NAME = :PARENT_NAME") hit "relation
-- oradict.dba_tab_partitions does not exist" — a real ORA-00942, not a
-- crash, but it still broke the table-node expansion. Unconditionally
-- EMPTY: this catalog has no concept of partitioned tables (the
-- ALL_TABLES.PARTITIONED
-- already always reports 'NO' for the same reason), so there is never a
-- matching partition row to report.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 8) THEN
        CREATE OR REPLACE VIEW oradict.all_tab_partitions AS
        SELECT NULL::varchar(128) AS table_owner, NULL::varchar(128) AS table_name,
               NULL::varchar(128) AS partition_name, NULL::bigint AS partition_position,
               NULL::varchar(128) AS tablespace_name, NULL::bigint AS num_rows
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_tab_partitions AS SELECT * FROM oradict.all_tab_partitions;
        CREATE OR REPLACE VIEW oradict.dba_tab_partitions AS SELECT * FROM oradict.all_tab_partitions;

        INSERT INTO oradict.schema_version (version) VALUES (8);
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Version 9: a batch of gaps found in ONE SQL Developer object-node
-- expansion session (table -> columns -> constraints -> indexes ->
-- triggers -> procedures -> mviews -> queues), each hit as either a real
-- ORA-00942 (view never installed, even though whitelisted) or ORA-00904
-- (an existing view is missing a column the client actually selects):
--   - ALL_TAB_SUBPARTITIONS/USER_/DBA_ — whitelisted, never installed.
--     Empty, same "nothing is ever partitioned" reasoning as v8's
--     ALL_TAB_PARTITIONS.
--   - ALL_TAB_PARTITIONS/USER_/DBA_ (v8) — SQL Developer also selects
--     LAST_ANALYZED/BLOCKS/SAMPLE_SIZE/HIGH_VALUE, which v8 didn't have
--     (CREATE OR REPLACE VIEW only allows APPENDING columns, so these are
--     added at the end, after v8's own NUM_ROWS).
--   - ALL_OBJECTS gains SUBOBJECT_NAME (real Oracle has it; SQL Developer's
--     own object-tree query filters "SUBOBJECT_NAME IS NULL" — always true
--     here, matching this catalog having no partition-subobject concept).
--   - ALL_CONSTRAINTS gains DEFERRABLE/VALIDATED/GENERATED/BAD/RELY/
--     LAST_CHANGE/INDEX_OWNER/INDEX_NAME/INVALID/VIEW_RELATED — SQL
--     Developer's constraint-node query selects all of these. DEFERRABLE
--     and VALIDATED derive from real pg_constraint flags (condeferrable/
--     convalidated); INDEX_OWNER/INDEX_NAME derive from the constraint's
--     own supporting index (pg_constraint.conindid) where one exists (PK/
--     UNIQUE); the rest have no Postgres equivalent and report Oracle's own
--     "nothing special" default (matching this file's existing convention
--     for every other synthesized column).
--   - ALL_MVIEWS/USER_/DBA_ — whitelisted (new "mviews" base), a REAL view
--     this time (over pg_matviews), not a stub: Postgres genuinely has
--     materialized views, unlike partitions/subpartitions/AQ/PL-SQL
--     settings.
--   - ALL_PLSQL_OBJECT_SETTINGS/USER_/DBA_ — Postgres has no per-routine
--     compile-time settings (PLSQL_DEBUG/PLSQL_OPTIMIZE_LEVEL); empty. SQL
--     Developer's own query LEFT JOINs this via s.owner(+)/s.name(+)/
--     s.type(+), so an empty view is not just "good enough" but the
--     semantically correct answer (no settings row for any routine).
--   - ALL_QUEUES/USER_/DBA_ — Postgres has no Advanced Queueing concept;
--     empty.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 9) THEN
        CREATE OR REPLACE VIEW oradict.all_tab_subpartitions AS
        SELECT NULL::varchar(128) AS table_owner, NULL::varchar(128) AS table_name,
               NULL::varchar(128) AS partition_name, NULL::varchar(128) AS subpartition_name,
               NULL::timestamptz AS last_analyzed, NULL::bigint AS num_rows,
               NULL::bigint AS blocks, NULL::bigint AS sample_size, NULL::varchar(4000) AS high_value
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_tab_subpartitions AS SELECT * FROM oradict.all_tab_subpartitions;
        CREATE OR REPLACE VIEW oradict.dba_tab_subpartitions AS SELECT * FROM oradict.all_tab_subpartitions;

        CREATE OR REPLACE VIEW oradict.all_tab_partitions AS
        SELECT NULL::varchar(128) AS table_owner, NULL::varchar(128) AS table_name,
               NULL::varchar(128) AS partition_name, NULL::bigint AS partition_position,
               NULL::varchar(128) AS tablespace_name, NULL::bigint AS num_rows,
               NULL::timestamptz AS last_analyzed, NULL::bigint AS blocks,
               NULL::bigint AS sample_size, NULL::varchar(4000) AS high_value
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_tab_partitions AS SELECT * FROM oradict.all_tab_partitions;
        CREATE OR REPLACE VIEW oradict.dba_tab_partitions AS SELECT * FROM oradict.all_tab_partitions;

        CREATE OR REPLACE VIEW oradict.all_objects AS
        SELECT owner, object_name, row_number() OVER (ORDER BY owner, object_type, object_name)::bigint AS object_id,
               object_type, status, created, last_ddl_time, temporary, generated,
               NULL::varchar(128) AS subobject_name
        FROM (
            SELECT owner, table_name AS object_name,
                   (CASE table_type WHEN 'VIEW' THEN 'VIEW' WHEN 'MATERIALIZED VIEW' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END)::varchar(18) AS object_type,
                   'VALID'::varchar(8) AS status, NULL::timestamptz AS created, NULL::timestamptz AS last_ddl_time,
                   'N'::varchar(1) AS temporary, 'N'::varchar(1) AS generated
            FROM oradict.all_tab_comments
            UNION ALL
            SELECT sequence_owner, sequence_name, 'SEQUENCE'::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_sequences
            UNION ALL
            SELECT owner, object_name, object_type::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_procedures
            UNION ALL
            SELECT owner, trigger_name, 'TRIGGER'::varchar(18), status::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_triggers
            UNION ALL
            SELECT owner, index_name, 'INDEX'::varchar(18), status::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_indexes
        ) u;
        CREATE OR REPLACE VIEW oradict.dba_objects AS SELECT * FROM oradict.all_objects;
        CREATE OR REPLACE VIEW oradict.user_objects AS
        SELECT object_name, object_id, object_type, status, created, last_ddl_time, temporary, generated, subobject_name
        FROM oradict.all_objects WHERE owner = 'APP';

        CREATE OR REPLACE VIEW oradict.all_constraints AS
        SELECT upper(n.nspname)::varchar(128) AS owner, upper(co.conname)::varchar(128) AS constraint_name,
               (CASE co.contype
                   WHEN 'p' THEN 'P' WHEN 'f' THEN 'R' WHEN 'u' THEN 'U' WHEN 'c' THEN 'C'
                   ELSE upper(co.contype::text)
               END)::varchar(1) AS constraint_type,
               upper(c.relname)::varchar(128) AS table_name,
               CASE WHEN co.contype = 'c' THEN pg_get_constraintdef(co.oid) END AS search_condition,
               'ENABLED'::varchar(8) AS status,
               upper(rn.nspname)::varchar(128) AS r_owner,
               upper(rco.conname)::varchar(128) AS r_constraint_name,
               (CASE co.confdeltype
                   WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT'
                   WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION'
               END)::varchar(11) AS delete_rule,
               (CASE WHEN co.condeferrable THEN 'DEFERRABLE' ELSE 'NOT DEFERRABLE' END)::varchar(14) AS "deferrable",
               (CASE WHEN co.convalidated THEN 'VALIDATED' ELSE 'NOT VALIDATED' END)::varchar(13) AS validated,
               'USER NAME'::varchar(14) AS generated,
               NULL::varchar(3) AS bad,
               NULL::varchar(4) AS rely,
               NULL::timestamptz AS last_change,
               upper(ixn.nspname)::varchar(128) AS index_owner,
               upper(ix.relname)::varchar(128) AS index_name,
               NULL::varchar(7) AS invalid,
               'NO'::varchar(3) AS view_related
        FROM pg_constraint co
        JOIN pg_class c ON c.oid = co.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_constraint rco ON rco.conrelid = co.confrelid AND rco.conkey = co.confkey
                                    AND rco.contype IN ('p', 'u') AND co.contype = 'f'
        LEFT JOIN pg_namespace rn ON rn.oid = rco.connamespace
        LEFT JOIN pg_class ix ON ix.oid = co.conindid
        LEFT JOIN pg_namespace ixn ON ixn.oid = ix.relnamespace;

        CREATE OR REPLACE VIEW oradict.dba_constraints AS SELECT * FROM oradict.all_constraints;
        CREATE OR REPLACE VIEW oradict.user_constraints AS
        SELECT constraint_name, constraint_type, table_name, search_condition, status, r_owner, r_constraint_name,
               delete_rule, "deferrable", validated, generated, bad, rely, last_change, index_owner, index_name, invalid, view_related
        FROM oradict.all_constraints WHERE owner = 'APP';

        CREATE OR REPLACE VIEW oradict.all_mviews AS
        SELECT upper(schemaname)::varchar(128) AS owner, upper(matviewname)::varchar(128) AS mview_name,
               'VALID'::varchar(7) AS compile_state
        FROM pg_matviews
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');
        CREATE OR REPLACE VIEW oradict.user_mviews AS
        SELECT mview_name, compile_state FROM oradict.all_mviews WHERE owner = 'APP';
        CREATE OR REPLACE VIEW oradict.dba_mviews AS SELECT * FROM oradict.all_mviews;

        CREATE OR REPLACE VIEW oradict.all_plsql_object_settings AS
        SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS name, NULL::varchar(18) AS type,
               NULL::varchar(3) AS plsql_debug, NULL::bigint AS plsql_optimize_level
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_plsql_object_settings AS SELECT * FROM oradict.all_plsql_object_settings;
        CREATE OR REPLACE VIEW oradict.dba_plsql_object_settings AS SELECT * FROM oradict.all_plsql_object_settings;

        CREATE OR REPLACE VIEW oradict.all_queues AS
        SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS name, NULL::varchar(24) AS queue_type,
               NULL::varchar(2) AS enqueue_enabled
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_queues AS SELECT * FROM oradict.all_queues;
        CREATE OR REPLACE VIEW oradict.dba_queues AS SELECT * FROM oradict.all_queues;

        INSERT INTO oradict.schema_version (version) VALUES (9);
    END IF;
END $$;

-- Version 10: a further batch of gaps from a SQL Developer index-detail node
-- expansion (table -> indexes -> index columns):
--   - ALL_IND_COLUMNS gains TABLE_OWNER (real Oracle has it; SQL Developer's
--     own index-column-expression query joins ALL_IND_COLUMNS to
--     ALL_IND_EXPRESSIONS on table_owner among other keys). Appended at the
--     end (CREATE OR REPLACE VIEW only allows appending columns).
--   - ALL_IND_EXPRESSIONS/USER_/DBA_ — whitelisted since defaultDictNames
--     added "ind_expressions" earlier, but never backed by a view
--     (ORA-00942). A REAL view this time: Postgres expression indexes store
--     each expression column's text via pg_get_indexdef(indexrelid,
--     column_no, true), keyed the same way ALL_IND_COLUMNS is (one row per
--     expression position, attnum=0 marking "this position is an expression,
--     not a plain column" in pg_index.indkey).
--   - SYS.SESSION_ROLES — not whitelisted at all (ORA-00942). No ALL_/USER_/
--     DBA_ form in real Oracle either (bare legacy synonym, like TABS/COLS).
--     A REAL one-column (ROLE) view: every Postgres role the connection's
--     current_user is a transitive member of.
--   - ALL_IND_STATISTICS/USER_/DBA_, ALL_IND_PARTITIONS/USER_/DBA_,
--     ALL_TAB_COL_STATISTICS/USER_/DBA_ — Postgres has no exposed optimizer
--     statistics history/partitioning concept matching these; empty stubs,
--     same reasoning as v8/v9's ALL_TAB_PARTITIONS/ALL_TAB_SUBPARTITIONS.
--   - ALL_COL_PRIVS/USER_/DBA_ — a REAL view this time, over
--     information_schema.column_privileges (Postgres genuinely tracks
--     column-level grants).
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 10) THEN
        CREATE OR REPLACE VIEW oradict.all_ind_columns AS
        SELECT upper(n.nspname)::varchar(128) AS index_owner, upper(ic.relname)::varchar(128) AS index_name,
               upper(tc.relname)::varchar(128) AS table_name, upper(a.attname)::varchar(128) AS column_name,
               k.ord::bigint AS column_position,
               (CASE WHEN (i.indoption[k.ord - 1] & 1) = 1 THEN 'DESC' ELSE 'ASC' END)::varchar(4) AS descend,
               upper(n.nspname)::varchar(128) AS table_owner
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_class tc ON tc.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = tc.relnamespace
        CROSS JOIN LATERAL unnest(i.indkey[0:i.indnkeyatts - 1]) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE k.attnum <> 0 -- excludes expression positions, not just dropped columns
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');
        CREATE OR REPLACE VIEW oradict.dba_ind_columns AS SELECT * FROM oradict.all_ind_columns;
        CREATE OR REPLACE VIEW oradict.user_ind_columns AS
        SELECT index_name, table_name, column_name, column_position, descend, table_owner
        FROM oradict.all_ind_columns WHERE index_owner = 'APP';

        CREATE OR REPLACE VIEW oradict.all_ind_expressions AS
        SELECT upper(n.nspname)::varchar(128) AS index_owner, upper(ic.relname)::varchar(128) AS index_name,
               upper(tc.relname)::varchar(128) AS table_name, upper(n.nspname)::varchar(128) AS table_owner,
               k.ord::bigint AS column_position,
               pg_get_indexdef(i.indexrelid, k.ord::int, true) AS column_expression
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_class tc ON tc.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = tc.relnamespace
        CROSS JOIN LATERAL unnest(i.indkey[0:i.indnkeyatts - 1]) WITH ORDINALITY AS k(attnum, ord)
        WHERE k.attnum = 0 -- an expression position, not a plain column
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');
        CREATE OR REPLACE VIEW oradict.dba_ind_expressions AS SELECT * FROM oradict.all_ind_expressions;
        CREATE OR REPLACE VIEW oradict.user_ind_expressions AS
        SELECT index_name, table_name, column_position, column_expression
        FROM oradict.all_ind_expressions WHERE index_owner = 'APP';

        CREATE OR REPLACE VIEW oradict.session_roles AS
        SELECT upper(r.rolname)::varchar(128) AS role
        FROM pg_roles r
        WHERE pg_has_role(current_user, r.oid, 'member') AND r.rolname <> current_user;

        CREATE OR REPLACE VIEW oradict.all_ind_statistics AS
        SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS index_name,
               NULL::varchar(128) AS table_owner, NULL::varchar(128) AS table_name,
               NULL::varchar(128) AS partition_name, NULL::bigint AS num_rows,
               NULL::bigint AS distinct_keys, NULL::timestamptz AS last_analyzed
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_ind_statistics AS SELECT * FROM oradict.all_ind_statistics;
        CREATE OR REPLACE VIEW oradict.dba_ind_statistics AS SELECT * FROM oradict.all_ind_statistics;

        CREATE OR REPLACE VIEW oradict.all_ind_partitions AS
        SELECT NULL::varchar(128) AS index_owner, NULL::varchar(128) AS index_name,
               NULL::varchar(128) AS partition_name, NULL::varchar(8) AS status,
               NULL::bigint AS num_rows, NULL::bigint AS distinct_keys,
               NULL::timestamptz AS last_analyzed
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_ind_partitions AS SELECT * FROM oradict.all_ind_partitions;
        CREATE OR REPLACE VIEW oradict.dba_ind_partitions AS SELECT * FROM oradict.all_ind_partitions;

        CREATE OR REPLACE VIEW oradict.all_tab_col_statistics AS
        SELECT NULL::varchar(128) AS owner, NULL::varchar(128) AS table_name,
               NULL::varchar(128) AS column_name, NULL::bigint AS num_distinct,
               NULL::varchar(32) AS low_value, NULL::varchar(32) AS high_value,
               NULL::double precision AS density, NULL::bigint AS num_nulls,
               NULL::bigint AS num_buckets, NULL::timestamptz AS last_analyzed,
               NULL::bigint AS sample_size
        WHERE FALSE;
        CREATE OR REPLACE VIEW oradict.user_tab_col_statistics AS SELECT * FROM oradict.all_tab_col_statistics;
        CREATE OR REPLACE VIEW oradict.dba_tab_col_statistics AS SELECT * FROM oradict.all_tab_col_statistics;

        CREATE OR REPLACE VIEW oradict.all_col_privs AS
        SELECT upper(grantor)::varchar(128) AS grantor, upper(grantee)::varchar(128) AS grantee,
               upper(table_schema)::varchar(128) AS owner, upper(table_name)::varchar(128) AS table_name,
               upper(column_name)::varchar(128) AS column_name, upper(privilege_type)::varchar(40) AS privilege,
               (CASE WHEN is_grantable = 'YES' THEN 'YES' ELSE 'NO' END)::varchar(3) AS grantable
        FROM information_schema.column_privileges
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict');
        CREATE OR REPLACE VIEW oradict.user_col_privs AS
        SELECT grantor, grantee, table_name, column_name, privilege, grantable
        FROM oradict.all_col_privs WHERE owner = 'APP';
        CREATE OR REPLACE VIEW oradict.dba_col_privs AS SELECT * FROM oradict.all_col_privs;

        INSERT INTO oradict.schema_version (version) VALUES (10);
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- v11 — ALL_OBJECTS and ALL_TABLES gain SECONDARY. DBeaver's
-- PUBLIC → Tables tree-load query selects o.SECONDARY (real Oracle
-- ALL_OBJECTS and ALL_TABLES both carry it — a Y/N "created as a
-- secondary object by ODCIIndexCreate" flag); without the column the
-- expand failed with ORA-00904 "o.secondary". Always 'N' here: this
-- catalog never creates secondary objects. Dependent SELECT * views
-- (dba_*, tabs) are recreated so they pick the new column up.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oradict.schema_version WHERE version = 11) THEN
        CREATE OR REPLACE VIEW oradict.all_objects AS
        SELECT owner, object_name, row_number() OVER (ORDER BY owner, object_type, object_name)::bigint AS object_id,
               object_type, status, created, last_ddl_time, temporary, generated,
               NULL::varchar(128) AS subobject_name, 'N'::varchar(1) AS secondary
        FROM (
            SELECT owner, table_name AS object_name,
                   (CASE table_type WHEN 'VIEW' THEN 'VIEW' WHEN 'MATERIALIZED VIEW' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END)::varchar(18) AS object_type,
                   'VALID'::varchar(8) AS status, NULL::timestamptz AS created, NULL::timestamptz AS last_ddl_time,
                   'N'::varchar(1) AS temporary, 'N'::varchar(1) AS generated
            FROM oradict.all_tab_comments
            UNION ALL
            SELECT sequence_owner, sequence_name, 'SEQUENCE'::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_sequences
            UNION ALL
            SELECT owner, object_name, object_type::varchar(18), 'VALID'::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_procedures
            UNION ALL
            SELECT owner, trigger_name, 'TRIGGER'::varchar(18), status::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_triggers
            UNION ALL
            SELECT owner, index_name, 'INDEX'::varchar(18), status::varchar(8), NULL::timestamptz, NULL::timestamptz, 'N'::varchar(1), 'N'::varchar(1)
            FROM oradict.all_indexes
        ) u;
        CREATE OR REPLACE VIEW oradict.dba_objects AS SELECT * FROM oradict.all_objects;
        CREATE OR REPLACE VIEW oradict.user_objects AS
        SELECT object_name, object_id, object_type, status, created, last_ddl_time, temporary, generated, subobject_name, secondary
        FROM oradict.all_objects WHERE owner = 'APP';

        CREATE OR REPLACE VIEW oradict.all_tables AS
        SELECT upper(n.nspname)::varchar(128) AS owner, upper(c.relname)::varchar(128) AS table_name,
               NULL::varchar(30) AS tablespace_name, 'VALID'::varchar(8) AS status,
               c.reltuples::bigint AS num_rows,
               (CASE c.relpersistence WHEN 't' THEN 'Y' ELSE 'N' END)::varchar(1) AS temporary,
               (CASE c.relkind WHEN 'p' THEN 'YES' ELSE 'NO' END)::varchar(3) AS partitioned,
               obj_description(c.oid, 'pg_class') AS comments,
               'N'::varchar(1) AS secondary
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'oradict')
          AND n.nspname NOT LIKE 'pg\_temp\_%';
        CREATE OR REPLACE VIEW oradict.dba_tables AS SELECT * FROM oradict.all_tables;
        CREATE OR REPLACE VIEW oradict.tabs AS SELECT * FROM oradict.all_tables;

        INSERT INTO oradict.schema_version (version) VALUES (11);
    END IF;
END $$;

-- Grants: the runtime role only ever SELECTs oradict's views, and picks up
-- anything a future versioned block adds without a separate grant step.
GRANT USAGE ON SCHEMA oradict TO <RUNTIME_ROLE>;
GRANT SELECT ON ALL TABLES IN SCHEMA oradict TO <RUNTIME_ROLE>;
ALTER DEFAULT PRIVILEGES IN SCHEMA oradict GRANT SELECT ON TABLES TO <RUNTIME_ROLE>;

COMMIT;
