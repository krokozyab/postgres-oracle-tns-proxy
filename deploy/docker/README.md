# Ready-to-run Docker demo

This stack provides PostgreSQL 16 with `orafce`, the `oradict` compatibility
views, read-only roles and deterministic demo data. It can also run a downloaded
`orapglink` Linux binary and verify it through a real python-oracledb client.
It contains and builds no private product source.

## PostgreSQL demo only

This part works before an orapglink binary is available:

```sh
cd deploy/docker
docker compose up -d --build postgres
docker compose exec postgres psql -U postgres -d appdb \
  -c 'TABLE public.demo_customers'
```

The image contains everything it initializes; it does not depend on bind mounts
from the checkout. The first startup creates `orafce`, the read-only runtime
role, the install role, `oradict` views and two demo tables. No `.env` file or
configuration editing is required.

## Full proxy demo

1. Download the release archive for Linux amd64, verify `SHA256SUMS`, and copy
   the extracted binary to this directory as `orapglink`.
2. Start the database and proxy:

   ```sh
   docker compose up -d --build postgres orapglink
   ```

3. Run the black-box test through Oracle Net:

   ```sh
   docker compose --profile test run --rm smoke
   ```

   A successful run ends with:

   ```text
   orapglink smoke: PASS (read, translation, aggregation, and read-only refusal)
   ```

4. Connect another Oracle client to `127.0.0.1:1521`, service `PUBLIC`, any
   username and password `orapglink-demo-oracle`. Try:

   ```sql
   SELECT customer_id, customer_name, status
   FROM demo_customers
   ORDER BY customer_id;
   ```

The smoke client proves four paths: Oracle Net login, table reads, Oracle SQL
translation (`NVL` plus aggregation), and rejection of an `INSERT` with
`ORA-16000`.

All built-in credentials are fixed, public demo values. Both published ports
bind to `127.0.0.1`, so this is safe for a local evaluation but must not be
reused for a shared or remotely exposed deployment. To customize anything,
copy `.env.example` to `.env`; every field is already populated and can be
changed independently.

## Published PostgreSQL image

The repository workflow publishes the self-contained database image as:

```text
ghcr.io/krokozyab/postgres-oracle-tns-proxy-demo:pg16
```

The package is public and can be pulled without GitHub authentication. Compose
can also build the identical image locally from this checkout.

To force the published image, set this in `.env` and run Compose without
`--build`:

```sh
ORAPGLINK_POSTGRES_IMAGE=ghcr.io/krokozyab/postgres-oracle-tns-proxy-demo:pg16
```

## Reset and safety

Initialization runs only for a new PostgreSQL volume. To recreate the demo from
scratch, remove only this Compose project's volume:

```sh
docker compose down -v
```

Both PostgreSQL and Oracle Net ports bind to loopback deliberately. Oracle Net
is unencrypted; do not change that binding on an untrusted network. The demo
passwords are examples, not production credentials.
