-- orapglink: Postgres role provisioning.
--
-- Run this ONCE, manually, by a superuser/database-owner connection —
-- orapglink itself never runs this (it only ever connects as
-- orapglink_runtime, which has no DDL/role-creation rights at all). It
-- implements a strict separation between the read-only role
-- orapglink's --postgres-dsn actually uses, and a separate install role that
-- owns oracle_compat_views.sql's oradict schema. This separation is the
-- deployment's defense in depth: the running proxy never owns these objects.
--
-- Placeholders to replace before running: <RUNTIME_PASSWORD>,
-- <INSTALL_PASSWORD>, <DATABASE_NAME>. Change the role names too if your
-- deployment has naming conventions.

-- 1. The runtime role orapglink's --postgres-dsn connects as. SELECT/USAGE
--    only — no INSERT/UPDATE/DELETE/DDL grants of any kind. This is the
--    PRIMARY enforcement layer alongside the READ ONLY transaction around
--    every query — a role with genuinely no write privileges means even a bug in
--    the read-only-transaction wrapping can't actually write anything.
CREATE ROLE orapglink_runtime LOGIN PASSWORD '<RUNTIME_PASSWORD>';
GRANT CONNECT ON DATABASE <DATABASE_NAME> TO orapglink_runtime;
GRANT USAGE ON SCHEMA public TO orapglink_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO orapglink_runtime;
-- Any table created LATER in `public` is also readable, without re-granting:
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO orapglink_runtime;
-- If your real data lives in schema(s) other than `public`, repeat the
-- three GRANT/ALTER DEFAULT PRIVILEGES lines above for each, and add each
-- schema name to orapglink's --pg-schemas flag.

-- 2. The install role that owns the oradict Oracle dictionary-compatibility
--    views. Only used to run
--    oracle_compat_views.sql — orapglink's own runtime connection never
--    authenticates as this role.
CREATE ROLE orapglink_install LOGIN PASSWORD '<INSTALL_PASSWORD>';
GRANT CONNECT ON DATABASE <DATABASE_NAME> TO orapglink_install;
GRANT CREATE ON DATABASE <DATABASE_NAME> TO orapglink_install;

-- After running this file, connect AS orapglink_install and run
-- oracle_compat_views.sql (which also grants orapglink_runtime SELECT on
-- the oradict schema it creates).
