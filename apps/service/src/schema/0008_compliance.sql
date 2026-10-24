-- 0008_compliance.sql - the records a tax authority can ask for.
--
-- These tables are the reason v2 keeps money in integer minor units
-- and every void with a reason: an X/Z report has to be reconstructible
-- from the database alone, months later.

CREATE TABLE compliance_report (
    id                 INTEGER PRIMARY KEY,
    report_type        TEXT    NOT NULL CHECK (report_type IN ('X', 'Z')),
    shift_id           INTEGER REFERENCES shift(id) ON DELETE SET NULL,
    employee_id        INTEGER REFERENCES employee(id) ON DELETE SET NULL,
    gross_minor        INTEGER NOT NULL DEFAULT 0,
    discount_minor     INTEGER NOT NULL DEFAULT 0,
    tax_minor          INTEGER NOT NULL DEFAULT 0,
    net_minor          INTEGER NOT NULL DEFAULT 0,
    -- The payment split, as one JSON object per mode.
    payment_split_json TEXT    NOT NULL DEFAULT '{}',
    generated_at       INTEGER NOT NULL
) STRICT;

CREATE INDEX compliance_report_generated ON compliance_report(generated_at);

CREATE TABLE void_log_entry (
    id            INTEGER PRIMARY KEY,
    order_id      INTEGER REFERENCES orders(id) ON DELETE SET NULL,
    employee_id   INTEGER REFERENCES employee(id) ON DELETE SET NULL,
    reason        TEXT    NOT NULL,
    amount_minor  INTEGER NOT NULL DEFAULT 0,
    voided_at     INTEGER NOT NULL
) STRICT;

CREATE INDEX void_log_entry_order ON void_log_entry(order_id);

CREATE TABLE subscription (
    id            INTEGER PRIMARY KEY,
    plan          TEXT    NOT NULL,
    started_at    INTEGER NOT NULL,
    expires_at    INTEGER,
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;
