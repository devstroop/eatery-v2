-- 0005_orders.sql - the sale.
--
-- An order is immutable once paid except for its status: the lines
-- carry the price that was charged, so a price change tomorrow cannot
-- rewrite yesterday's bill.

CREATE TABLE orders (
    id               INTEGER PRIMARY KEY,
    order_no         TEXT    NOT NULL UNIQUE,
    order_type       INTEGER NOT NULL DEFAULT 0 CHECK (order_type IN (0, 1, 2)),
    status           INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0, 1, 2, 3, 4, 5)),
    dining_table_id  INTEGER REFERENCES dining_table(id) ON DELETE SET NULL,
    customer_id      INTEGER REFERENCES customer(id) ON DELETE SET NULL,
    employee_id      INTEGER REFERENCES employee(id) ON DELETE SET NULL,
    subtotal_minor   INTEGER NOT NULL DEFAULT 0,
    tax_minor        INTEGER NOT NULL DEFAULT 0,
    discount_minor   INTEGER NOT NULL DEFAULT 0,
    total_minor      INTEGER NOT NULL DEFAULT 0,
    placed_at        INTEGER NOT NULL,
    notes            TEXT    NOT NULL DEFAULT '',
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
) STRICT;

CREATE INDEX orders_status ON orders(status);
CREATE INDEX orders_placed_at ON orders(placed_at);
CREATE INDEX orders_table ON orders(dining_table_id);

CREATE TABLE order_line (
    id                INTEGER PRIMARY KEY,
    order_id          INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id        INTEGER REFERENCES product(id) ON DELETE SET NULL,
    -- The name and the price are frozen at the moment of the sale.
    product_name      TEXT    NOT NULL,
    qty               INTEGER NOT NULL DEFAULT 1 CHECK (qty > 0),
    unit_price_minor  INTEGER NOT NULL DEFAULT 0,
    tax_bps           INTEGER NOT NULL DEFAULT 0 CHECK (tax_bps BETWEEN 0 AND 10000),
    discount_minor    INTEGER NOT NULL DEFAULT 0,
    notes             TEXT    NOT NULL DEFAULT '',
    station_id        INTEGER REFERENCES kds_station(id) ON DELETE SET NULL,
    created_at        INTEGER NOT NULL
) STRICT;

CREATE INDEX order_line_order ON order_line(order_id);

CREATE TABLE order_line_modifier (
    id            INTEGER PRIMARY KEY,
    order_line_id INTEGER NOT NULL REFERENCES order_line(id) ON DELETE CASCADE,
    modifier_id   INTEGER REFERENCES modifier(id) ON DELETE SET NULL,
    modifier_name TEXT    NOT NULL,
    price_delta_minor INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX order_line_modifier_line ON order_line_modifier(order_line_id);

CREATE TABLE order_discount (
    id           INTEGER PRIMARY KEY,
    order_id     INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    discount_id  INTEGER REFERENCES discount(id) ON DELETE SET NULL,
    name         TEXT    NOT NULL,
    amount_minor INTEGER NOT NULL DEFAULT 0
) STRICT;

-- The lifecycle ledger. The kitchen board and the receipt both read it,
-- so it is written in the same transaction as the status change.
CREATE TABLE order_status_history (
    id          INTEGER PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    status      INTEGER NOT NULL CHECK (status IN (0, 1, 2, 3, 4, 5)),
    changed_at  INTEGER NOT NULL,
    changed_by  INTEGER REFERENCES employee(id) ON DELETE SET NULL
) STRICT;

CREATE INDEX order_status_history_order ON order_status_history(order_id);

CREATE TABLE payment (
    id          INTEGER PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    mode        INTEGER NOT NULL DEFAULT 0 CHECK (mode IN (0, 1, 2, 3, 4)),
    amount_minor INTEGER NOT NULL DEFAULT 0,
    reference   TEXT    NOT NULL DEFAULT '',
    paid_at     INTEGER NOT NULL,
    created_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX payment_order ON payment(order_id);

CREATE TABLE reservation (
    id             INTEGER PRIMARY KEY,
    customer_id    INTEGER REFERENCES customer(id) ON DELETE SET NULL,
    dining_table_id INTEGER REFERENCES dining_table(id) ON DELETE SET NULL,
    name           TEXT    NOT NULL DEFAULT '',
    phone          TEXT    NOT NULL DEFAULT '',
    guests         INTEGER NOT NULL DEFAULT 1 CHECK (guests > 0),
    reserved_at    INTEGER NOT NULL,
    status         INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0, 1, 2)),
    notes          TEXT    NOT NULL DEFAULT '',
    created_at     INTEGER NOT NULL
) STRICT;

CREATE INDEX reservation_at ON reservation(reserved_at);
