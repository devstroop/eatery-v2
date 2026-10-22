-- 0004_customers.sql - who the food is for.
--
-- A customer is optional on an order: most restaurants run a tab
-- against a table, not a person.

CREATE TABLE customer (
    id              INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    phone           TEXT    NOT NULL DEFAULT '',
    email           TEXT    NOT NULL DEFAULT '',
    address         TEXT    NOT NULL DEFAULT '',
    loyalty_points  INTEGER NOT NULL DEFAULT 0,
    notes           TEXT    NOT NULL DEFAULT '',
    active          INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at      INTEGER NOT NULL
) STRICT;

CREATE INDEX customer_name ON customer(name);

CREATE TABLE customer_loyalty (
    id            INTEGER PRIMARY KEY,
    customer_id   INTEGER NOT NULL REFERENCES customer(id) ON DELETE CASCADE,
    points        INTEGER NOT NULL DEFAULT 0,
    reason        TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX customer_loyalty_customer ON customer_loyalty(customer_id);

CREATE TABLE loyalty_transaction (
    id            INTEGER PRIMARY KEY,
    customer_id   INTEGER NOT NULL REFERENCES customer(id) ON DELETE CASCADE,
    order_id      INTEGER,
    points_delta  INTEGER NOT NULL DEFAULT 0,
    reason        TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
) STRICT;
