-- 0009_printing.sql - receipt printers.
--
-- The app never talks to a printer directly: it writes a print job and
-- a sidecar process owns the device. The `transport` column says which
-- sidecar route to use.

CREATE TABLE printer (
    id             INTEGER PRIMARY KEY,
    name           TEXT    NOT NULL,
    -- 'escpos' (thermal), 'system' (the OS print queue).
    kind           TEXT    NOT NULL DEFAULT 'escpos' CHECK (kind IN ('escpos', 'system')),
    -- 'ble', 'tcp', 'usb', 'file'.
    transport      TEXT    NOT NULL DEFAULT 'ble' CHECK (transport IN ('ble', 'tcp', 'usb', 'file')),
    -- For a TCP printer: host:port. For BLE: the device address.
    address        TEXT    NOT NULL DEFAULT '',
    -- What this printer prints: 'receipt', 'kot', 'report'.
    job            TEXT    NOT NULL DEFAULT 'receipt' CHECK (job IN ('receipt', 'kot', 'report')),
    paper_width_mm INTEGER NOT NULL DEFAULT 80,
    active         INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at     INTEGER NOT NULL
) STRICT;

-- Which printer takes which job. A kitchen has a KOT printer and a
-- counter has a receipt printer.
CREATE TABLE auto_print (
    id          INTEGER PRIMARY KEY,
    printer_id  INTEGER NOT NULL REFERENCES printer(id) ON DELETE CASCADE,
    job         TEXT    NOT NULL CHECK (job IN ('receipt', 'kot', 'report')),
    enabled     INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
) STRICT;

CREATE INDEX auto_print_printer ON auto_print(printer_id);
