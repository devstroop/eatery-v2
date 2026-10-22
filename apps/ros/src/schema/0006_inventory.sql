-- 0006_inventory.sql - what the restaurant buys and what it owes.
--
-- Stock lives on the product (stock_qty) and moves through
-- stock_adjustment, which is the ledger of why the number changed.

CREATE TABLE supplier (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    phone       TEXT    NOT NULL DEFAULT '',
    email       TEXT    NOT NULL DEFAULT '',
    address     TEXT    NOT NULL DEFAULT '',
    gstin       TEXT    NOT NULL DEFAULT '',
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE purchase_order (
    id            INTEGER PRIMARY KEY,
    supplier_id   INTEGER NOT NULL REFERENCES supplier(id) ON DELETE RESTRICT,
    order_no      TEXT    NOT NULL UNIQUE,
    status        INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0, 1, 2, 3)),
    total_minor   INTEGER NOT NULL DEFAULT 0,
    ordered_at    INTEGER NOT NULL,
    expected_at   INTEGER,
    received_at   INTEGER,
    notes         TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX purchase_order_supplier ON purchase_order(supplier_id);

CREATE TABLE purchase_order_item (
    id                INTEGER PRIMARY KEY,
    purchase_order_id INTEGER NOT NULL REFERENCES purchase_order(id) ON DELETE CASCADE,
    product_id        INTEGER REFERENCES product(id) ON DELETE SET NULL,
    name              TEXT    NOT NULL,
    qty               INTEGER NOT NULL DEFAULT 1 CHECK (qty > 0),
    unit_cost_minor   INTEGER NOT NULL DEFAULT 0,
    received_qty      INTEGER NOT NULL DEFAULT 0 CHECK (received_qty >= 0)
) STRICT;

CREATE INDEX purchase_order_item_order ON purchase_order_item(purchase_order_id);

CREATE TABLE stock_adjustment (
    id          INTEGER PRIMARY KEY,
    product_id  INTEGER NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    delta       INTEGER NOT NULL,
    reason      TEXT    NOT NULL DEFAULT '',
    reference   TEXT    NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX stock_adjustment_product ON stock_adjustment(product_id);
