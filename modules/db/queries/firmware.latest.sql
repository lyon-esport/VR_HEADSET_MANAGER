-- Newest firmware reading of EVERY known headset, with its model, for the
-- DIAG page fleet comparison. A headset never sampled yet has no row.
SELECT h.ID AS ID, h.Name AS Name, h.Model AS Model, f.ts AS ts,
       f.firmware_version AS firmware_version, f.environment AS environment
FROM v_headsets h
JOIN firmware_history f ON f.headset_id = CAST(h.ID AS INTEGER)
WHERE f.ts = (SELECT MAX(ts) FROM firmware_history WHERE headset_id = f.headset_id)
ORDER BY h.SortOrder, CAST(h.ID AS INTEGER);
