-- 0010_sync.sql - the operation log.
--
-- v1 spoke WebSocket to a sync host from inside the app. v2 does not:
-- the app writes its changes here and watches this table; a sidecar
-- process owns the socket and the mDNS announcement. The app never
-- speaks the network protocol - it only reads and writes rows.
--
-- The conflict rule is last-writer-wins on (logical_clock, device_id).
-- Every mutation gets a logical clock; the sidecar bumps the local
-- clock to max(local, highest seen) + 1.

CREATE TABLE device (
    id            TEXT    PRIMARY KEY,
    name          TEXT    NOT NULL DEFAULT '',
    -- 'admin', 'waiter', 'kds', 'display'.
    role          TEXT    NOT NULL DEFAULT 'admin' CHECK (role IN ('admin', 'waiter', 'kds', 'display')),
    last_seen_at  INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE op_log (
    id             TEXT    PRIMARY KEY,
    -- The table the operation touched, so a subscriber can be woken
    -- only for the tables it cares about.
    entity_table  TEXT    NOT NULL,
    entity_id      TEXT    NOT NULL DEFAULT '',
    -- 'create', 'update', 'delete'.
    operation     TEXT    NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    -- The full row snapshot. v1 sent the same shape; a snapshot beats
    -- a field merge when the clients can disagree.
    data_json      TEXT    NOT NULL DEFAULT '{}',
    previous_json  TEXT    NOT NULL DEFAULT '{}',
    -- The logical clock. Higher wins.
    logical_clock  INTEGER NOT NULL DEFAULT 0,
    device_id      TEXT    NOT NULL,
    -- The host that accepted the operation.
    host_id        TEXT    NOT NULL DEFAULT '',
    parent_id      TEXT    NOT NULL DEFAULT '',
    created_at     INTEGER NOT NULL
) STRICT;

CREATE INDEX op_log_entity ON op_log(entity_table, entity_id);
CREATE INDEX op_log_clock ON op_log(logical_clock);
CREATE INDEX op_log_device ON op_log(device_id);

-- The local clock, so a device keeps counting up even while it is
-- offline.
CREATE TABLE sync_state (
    key           TEXT    PRIMARY KEY,
    value         TEXT    NOT NULL DEFAULT ''
) STRICT;
