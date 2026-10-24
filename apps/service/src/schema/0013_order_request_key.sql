-- 0013_order_request_key.sql - a sale can be retried.
--
-- A write can land and the answer can be lost: the database is busy,
-- the app is closed, the connection drops. The cashier taps again, and
-- without a key the second write is a second sale - two tickets, one
-- table, and money that is taken twice.
--
-- The request key is generated when the sale is submitted and kept
-- until it lands. A write that carries a key the database has already
-- seen is the same sale, and the database keeps the one that is
-- already there.
--
-- The column is nullable on purpose: the rows that predate this
-- migration have no key, and a NULL is never equal to another NULL in
-- a unique index. The index is therefore on the key alone, and the
-- application always writes one.

ALTER TABLE orders ADD COLUMN request_key TEXT;

CREATE UNIQUE INDEX orders_request_key ON orders(request_key);
