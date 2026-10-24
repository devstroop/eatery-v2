-- 0003_floor.sql - the dining room: table categories and tables.

CREATE TABLE dining_table_category (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE dining_table (
    id           INTEGER PRIMARY KEY,
    category_id  INTEGER NOT NULL REFERENCES dining_table_category(id) ON DELETE RESTRICT,
    name         TEXT    NOT NULL,
    status       INTEGER NOT NULL DEFAULT 0 CHECK (status IN (0, 1, 2, 3)),
    seats        INTEGER NOT NULL DEFAULT 4 CHECK (seats >= 0),
    -- Position on the floor plan, in grid cells.
    pos_x        INTEGER NOT NULL DEFAULT 0,
    pos_y        INTEGER NOT NULL DEFAULT 0,
    width_cells  INTEGER NOT NULL DEFAULT 1 CHECK (width_cells >= 1),
    height_cells INTEGER NOT NULL DEFAULT 1 CHECK (height_cells >= 1),
    active       INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE INDEX dining_table_category_id ON dining_table(category_id);

-- The kitchen stations a ticket can be routed to ("Grill", "Tandoor",
-- "Bar"). A product is served by exactly one station.
CREATE TABLE kds_station (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE product_station (
    product_id   INTEGER NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    station_id   INTEGER NOT NULL REFERENCES kds_station(id) ON DELETE CASCADE,
    PRIMARY KEY (product_id, station_id)
) STRICT;
