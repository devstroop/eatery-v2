-- 0001_core.sql - the company, its currency, its people and its settings.
--
-- House rules for every table in this schema:
--   * STRICT tables only. The schema checker refuses anything else, and
--     it is right: STRICT is what makes a column's declared type mean
--     something. Eatery v1 learned this the expensive way.
--   * Money is INTEGER minor units. No REAL money, ever.
--   * Time is INTEGER epoch milliseconds, UTC.
--   * Booleans are INTEGER 0/1 with a CHECK.
--   * Enumerations are INTEGER codes with a CHECK listing the codes.
--   * Text that is machine-readable (order numbers, hashes) is TEXT and
--     never a number.

CREATE TABLE company (
    id                INTEGER PRIMARY KEY,
    name              TEXT    NOT NULL,
    currency_code     TEXT    NOT NULL DEFAULT 'USD',
    currency_symbol   TEXT    NOT NULL DEFAULT '$',
    tax_inclusive     INTEGER NOT NULL DEFAULT 0 CHECK (tax_inclusive IN (0, 1)),
    address           TEXT    NOT NULL DEFAULT '',
    phone             TEXT    NOT NULL DEFAULT '',
    email             TEXT    NOT NULL DEFAULT '',
    tax_number        TEXT    NOT NULL DEFAULT '',
    created_at        INTEGER NOT NULL
) STRICT;

-- One currency row per supported currency; the company points at one
-- by code. Kept as a table (not a free-text column) so the currency
-- picker has a list to offer.
CREATE TABLE currency (
    code        TEXT    PRIMARY KEY,
    symbol      TEXT    NOT NULL,
    name        TEXT    NOT NULL,
    minor_units INTEGER NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 4)
) STRICT;

-- Staff. The PIN is stored as a salted SHA-256 hex digest; the
-- plaintext never touches the disk.
CREATE TABLE employee (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    role        INTEGER NOT NULL DEFAULT 0 CHECK (role IN (0, 1, 2, 3)),
    pin_hash    TEXT    NOT NULL DEFAULT '',
    phone       TEXT    NOT NULL DEFAULT '',
    email       TEXT    NOT NULL DEFAULT '',
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX employee_active ON employee(active);

-- Key/value settings the app owns: the schema version, the device
-- role, the PIN salt, the current shift, and anything else that is a
-- setting rather than a record.
CREATE TABLE app_config (
    key         TEXT    PRIMARY KEY,
    value       TEXT    NOT NULL DEFAULT '',
    updated_at  INTEGER NOT NULL
) STRICT;
