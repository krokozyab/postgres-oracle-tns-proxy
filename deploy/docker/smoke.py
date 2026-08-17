#!/usr/bin/env python3
"""Black-box smoke test for the published Docker demo."""

import os
import sys
import time

import oracledb


host = os.environ.get("ORAPGLINK_HOST", "orapglink")
port = int(os.environ.get("ORAPGLINK_PORT", "1521"))
service = os.environ.get("ORAPGLINK_SERVICE", "PUBLIC")
password = os.environ["ORAPGLINK_PASSWORD"]
dsn = f"{host}:{port}/{service}"

connection = None
last_error = None
for _ in range(60):
    try:
        connection = oracledb.connect(user="demo", password=password, dsn=dsn)
        break
    except oracledb.Error as exc:
        last_error = exc
        time.sleep(1)

if connection is None:
    print(f"orapglink smoke: could not connect to {dsn}: {last_error}", file=sys.stderr)
    raise SystemExit(1)

with connection:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT customer_id, customer_name, status "
            "FROM demo_customers ORDER BY customer_id"
        )
        rows = cursor.fetchall()
        expected = [
            (1, "Acme North", "ACTIVE"),
            (2, "Blue River", "ACTIVE"),
            (3, "Cedar Labs", "PAUSED"),
            (4, "Delta Retail", "ACTIVE"),
        ]
        if rows != expected:
            raise AssertionError(f"unexpected demo rows: {rows!r}")

        cursor.execute(
            "SELECT c.customer_name, NVL(SUM(o.amount), 0) total_amount "
            "FROM demo_customers c LEFT JOIN demo_orders o "
            "ON o.customer_id = c.customer_id "
            "GROUP BY c.customer_name ORDER BY c.customer_name"
        )
        totals = cursor.fetchall()
        if len(totals) != 4:
            raise AssertionError(f"unexpected aggregate rows: {totals!r}")

        try:
            cursor.execute(
                "INSERT INTO demo_customers "
                "(customer_id, customer_name, status) VALUES (99, 'must fail', 'ACTIVE')"
            )
        except oracledb.DatabaseError as exc:
            if "ORA-16000" not in str(exc):
                raise AssertionError(f"write failed with the wrong error: {exc}") from exc
        else:
            raise AssertionError("write unexpectedly succeeded")

print("orapglink smoke: PASS (read, translation, aggregation, and read-only refusal)")
