#!/usr/bin/env bash
# One-time provisioning, run by the postgres image's own init mechanism the
# first time the data directory is created (docker-entrypoint-initdb.d). It
# does exactly what QUICKSTART.md §3 tells an operator to do by hand — create
# the two roles, install orafce, install the oradict dictionary views — so a
# `docker compose up` needs none of that by hand.
#
# The proxy still creates NOTHING in PostgreSQL at runtime: this is separate,
# one-shot setup that finishes before the proxy ever connects. The runtime role
# it creates has SELECT/USAGE only.
#
# Idempotency is provided by the init mechanism itself: these scripts run ONLY
# on a fresh data directory. `docker compose down -v` (removing the volume) is
# what re-runs them.
set -euo pipefail

: "${ORAPGLINK_RUNTIME_PASSWORD:?set it in .env}"
: "${ORAPGLINK_INSTALL_PASSWORD:?set it in .env}"
: "${ORAPGLINK_LOGICAL_SCHEMA:?set it in .env}"

DB="${POSTGRES_DB:-postgres}"
SU="${POSTGRES_USER:-postgres}"
SQL_DIR="/opt/orapglink/sql"

psql_su() { psql -v ON_ERROR_STOP=1 --username "$SU" --dbname "$DB" "$@"; }
psql_install() {
	PGPASSWORD="$ORAPGLINK_INSTALL_PASSWORD" \
		psql -v ON_ERROR_STOP=1 --username orapglink_install --dbname "$DB" "$@"
}

echo "orapglink init: provisioning roles"
sed -e "s/<RUNTIME_PASSWORD>/${ORAPGLINK_RUNTIME_PASSWORD}/g" \
    -e "s/<INSTALL_PASSWORD>/${ORAPGLINK_INSTALL_PASSWORD}/g" \
    -e "s/<DATABASE_NAME>/${DB}/g" \
    "${SQL_DIR}/provision_roles.sql" | psql_su

echo "orapglink init: installing orafce (mandatory)"
psql_su <<SQL
CREATE EXTENSION IF NOT EXISTS orafce;
GRANT USAGE ON SCHEMA oracle TO orapglink_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracle TO orapglink_runtime;
SQL

echo "orapglink init: installing the oradict dictionary views (schema ${ORAPGLINK_LOGICAL_SCHEMA})"
sed -e "s/<RUNTIME_ROLE>/orapglink_runtime/g" \
    -e "s/'APP'/'${ORAPGLINK_LOGICAL_SCHEMA}'/g" \
    "${SQL_DIR}/oracle_compat_views.sql" | psql_install

# Make sure the runtime role can read whatever the user later creates in
# `public` without re-granting — matching provision_roles.sql's own intent.
psql_su <<SQL
GRANT USAGE ON SCHEMA public TO orapglink_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO orapglink_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO orapglink_runtime;
SQL

echo "orapglink init: done"
