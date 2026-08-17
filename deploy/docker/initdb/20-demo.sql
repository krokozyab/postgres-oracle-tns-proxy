-- Small deterministic dataset for the Docker quick-start. It contains no
-- credentials or production data and is created only on a fresh data volume.
CREATE TABLE public.demo_customers (
    customer_id   bigint PRIMARY KEY,
    customer_name varchar(100) NOT NULL,
    status        varchar(20) NOT NULL,
    created_at    timestamp NOT NULL
);

CREATE TABLE public.demo_orders (
    order_id    bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES public.demo_customers(customer_id),
    amount      numeric(12,2) NOT NULL,
    ordered_at  date NOT NULL,
    note        text
);

INSERT INTO public.demo_customers
    (customer_id, customer_name, status, created_at)
VALUES
    (1, 'Acme North', 'ACTIVE', '2026-01-10 09:00:00'),
    (2, 'Blue River', 'ACTIVE', '2026-02-14 12:30:00'),
    (3, 'Cedar Labs', 'PAUSED', '2026-03-01 08:15:00'),
    (4, 'Delta Retail', 'ACTIVE', '2026-04-20 16:45:00');

INSERT INTO public.demo_orders
    (order_id, customer_id, amount, ordered_at, note)
VALUES
    (1001, 1, 1250.00, '2026-05-01', 'first order'),
    (1002, 1, 89.50, '2026-05-04', NULL),
    (1003, 2, 740.25, '2026-05-06', 'priority'),
    (1004, 4, 19.99, '2026-05-08', NULL);

GRANT SELECT ON public.demo_customers, public.demo_orders TO orapglink_runtime;
