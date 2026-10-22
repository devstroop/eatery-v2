-- 0015_currency_decimals.sql - a currency's decimals are its own.
--
-- The app showed every amount with two decimals, because most
-- currencies have two. The yen has none, and the dinar and the riyal
-- have three: a restaurant in either cannot read its own totals.
--
-- The decimals belong to the COMPANY, not to the code: the owner
-- chooses the currency the restaurant trades in, and the exponent that
-- goes with it is stored with the company, so a change of currency
-- cannot leave the amounts formatted for the old one.

ALTER TABLE company ADD COLUMN currency_decimals INTEGER NOT NULL DEFAULT 2;
