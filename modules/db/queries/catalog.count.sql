-- Number of catalogue entries. Used by Initialize-AppNamesCache to decide
-- whether the template seed still has to run; an already-populated catalogue
-- is never re-seeded.
SELECT COUNT(*) FROM app_catalog;
