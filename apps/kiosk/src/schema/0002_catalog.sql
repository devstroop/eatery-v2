-- 0002_catalog.sql - what the restaurant sells.
--
-- The menu is the spine of a POS: products, their categories, the
-- modifier groups that change them, and the tax slab each product
-- sits under. Prices are minor units.

CREATE TABLE product_category (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE tax_slab (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    -- Basis points: 5% is 500. 10000 = 100%.
    rate_bps    INTEGER NOT NULL DEFAULT 0 CHECK (rate_bps BETWEEN 0 AND 10000),
    inclusive   INTEGER NOT NULL DEFAULT 0 CHECK (inclusive IN (0, 1)),
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE product (
    id            INTEGER PRIMARY KEY,
    category_id   INTEGER NOT NULL REFERENCES product_category(id) ON DELETE RESTRICT,
    name          TEXT    NOT NULL,
    -- Minor units. A negative price is a data error, not a discount:
    -- discounts live in their own table.
    price_minor   INTEGER NOT NULL DEFAULT 0 CHECK (price_minor >= 0),
    product_type  INTEGER NOT NULL DEFAULT 0 CHECK (product_type IN (0, 1, 2, 3, 4)),
    food_type     INTEGER NOT NULL DEFAULT 0 CHECK (food_type IN (0, 1, 2, 3)),
    tax_slab_id   INTEGER NOT NULL DEFAULT 0 REFERENCES tax_slab(id) ON DELETE RESTRICT,
    -- Stock in whole units. NULL means "not stock controlled" (the
    -- common case for a restaurant menu).
    stock_qty     INTEGER,
    track_stock   INTEGER NOT NULL DEFAULT 0 CHECK (track_stock IN (0, 1)),
    description   TEXT    NOT NULL DEFAULT '',
    image_path    TEXT    NOT NULL DEFAULT '',
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    sort_order    INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX product_category_id ON product(category_id);
CREATE INDEX product_active ON product(active);

-- A modifier group is a set of choices attached to a product ("size",
-- "spice level"). A modifier is one choice inside a group.
CREATE TABLE modifier_group (
    id           INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL,
    -- A group is required when the order cannot be prepared without a
    -- choice from it.
    required     INTEGER NOT NULL DEFAULT 0 CHECK (required IN (0, 1)),
    min_select   INTEGER NOT NULL DEFAULT 0 CHECK (min_select >= 0),
    max_select   INTEGER NOT NULL DEFAULT 1 CHECK (max_select >= 1),
    sort_order   INTEGER NOT NULL DEFAULT 0,
    active       INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE modifier (
    id                INTEGER PRIMARY KEY,
    group_id          INTEGER NOT NULL REFERENCES modifier_group(id) ON DELETE CASCADE,
    name              TEXT    NOT NULL,
    price_delta_minor INTEGER NOT NULL DEFAULT 0,
    sort_order        INTEGER NOT NULL DEFAULT 0,
    active            INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE INDEX modifier_group_id ON modifier(group_id);

-- Which groups apply to which product.
CREATE TABLE product_modifier (
    product_id        INTEGER NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    modifier_group_id INTEGER NOT NULL REFERENCES modifier_group(id) ON DELETE CASCADE,
    PRIMARY KEY (product_id, modifier_group_id)
) STRICT;

-- Discounts: a percentage (basis points) or a fixed amount. At most
-- one of the two is set.
CREATE TABLE discount (
    id              INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    percent_bps     INTEGER NOT NULL DEFAULT 0 CHECK (percent_bps BETWEEN 0 AND 10000),
    amount_minor    INTEGER NOT NULL DEFAULT 0 CHECK (amount_minor >= 0),
    active          INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at      INTEGER NOT NULL
) STRICT;
