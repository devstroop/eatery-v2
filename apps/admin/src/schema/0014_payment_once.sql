-- 0014_payment_once.sql - an order is paid once.
--
-- Taking a payment twice is the worst thing a till can do: the
-- customer pays once and the restaurant sees two payments, or the
-- customer pays twice and the restaurant sees one. Neither is a
-- rounding error - it is the till's whole job.
--
-- The database is the one that decides. One payment belongs to one
-- order, and the index says so: a second payment for the same order
-- cannot be written at all.
--
-- The conditional update on the order is the other half: an order that
-- is already closed is not closed again, and the history says it
-- closed once.

CREATE UNIQUE INDEX payment_one_per_order ON payment(order_id);
