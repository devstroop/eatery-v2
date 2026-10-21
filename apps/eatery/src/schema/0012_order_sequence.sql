-- 0012_order_sequence.sql - the order number is a sequence.
--
-- The order number is the number on the ticket, and a jurisdiction may
-- ask for it to be sequential. The wall clock is not sequential, and
-- two tickets in the same millisecond want the same number.
--
-- The sequence is a row in this table, bumped in the same transaction
-- as the order insert. That has three consequences worth naming:
--
--   * a failed sale does not consume a number - the transaction rolls
--     back, and the number is not on any ticket;
--   * two devices writing to the same database cannot take the same
--     number, because SQLite serialises the two transactions;
--   * the number that is on the ticket is the number that was stored,
--     because the database is what assigns it.

CREATE TABLE sequence (
    name       TEXT    PRIMARY KEY,
    value      INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL
) STRICT;
