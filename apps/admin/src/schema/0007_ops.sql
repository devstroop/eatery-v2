-- 0007_ops.sql - the shift, the hours, the money that is not a sale.

CREATE TABLE shift (
    id                   INTEGER PRIMARY KEY,
    employee_id          INTEGER NOT NULL REFERENCES employee(id) ON DELETE RESTRICT,
    opened_at            INTEGER NOT NULL,
    closed_at            INTEGER,
    opening_cash_minor   INTEGER NOT NULL DEFAULT 0,
    closing_cash_minor   INTEGER,
    expected_cash_minor  INTEGER,
    notes                TEXT    NOT NULL DEFAULT ''
) STRICT;

CREATE INDEX shift_employee ON shift(employee_id);

CREATE TABLE time_entry (
    id          INTEGER PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employee(id) ON DELETE CASCADE,
    shift_id    INTEGER REFERENCES shift(id) ON DELETE SET NULL,
    clocked_at  INTEGER NOT NULL,
    clocked_out INTEGER
) STRICT;

CREATE TABLE business_hours (
    id          INTEGER PRIMARY KEY,
    weekday     INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    opens_min   INTEGER NOT NULL DEFAULT 0,
    closes_min  INTEGER NOT NULL DEFAULT 1440,
    is_closed   INTEGER NOT NULL DEFAULT 0 CHECK (is_closed IN (0, 1))
) STRICT;

CREATE TABLE holiday_hours (
    id          INTEGER PRIMARY KEY,
    holiday_date TEXT   NOT NULL,
    opens_min   INTEGER NOT NULL DEFAULT 0,
    closes_min  INTEGER NOT NULL DEFAULT 1440,
    is_closed   INTEGER NOT NULL DEFAULT 1 CHECK (is_closed IN (0, 1))
) STRICT;

CREATE TABLE expense_category (
    id      INTEGER PRIMARY KEY,
    name    TEXT    NOT NULL,
    active  INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE expense (
    id           INTEGER PRIMARY KEY,
    category_id  INTEGER REFERENCES expense_category(id) ON DELETE SET NULL,
    amount_minor INTEGER NOT NULL DEFAULT 0,
    note         TEXT    NOT NULL DEFAULT '',
    spent_at     INTEGER NOT NULL,
    created_at   INTEGER NOT NULL
) STRICT;

CREATE INDEX expense_spent_at ON expense(spent_at);
