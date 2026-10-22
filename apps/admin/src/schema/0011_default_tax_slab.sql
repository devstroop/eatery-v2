-- 0011_default_tax_slab.sql - the "no tax" slab.
--
-- Every product points at a tax slab. A product that is not taxed points
-- at slab 0 rather than at nothing, because a foreign key that can be
-- NULL is a foreign key that will be NULL on the day somebody adds a
-- product and forgets to choose.
--
-- The alternative - a nullable tax_slab_id - pushes a null check into
-- every price calculation in the app. This keeps the arithmetic honest:
-- the slab exists, and its rate is zero.

INSERT INTO tax_slab (id, name, rate_bps, inclusive, active)
VALUES (0, 'No tax', 0, 0, 1);
