-- The newest recorded firmware of EVERY known headset, with its model, in
-- display order. Backs the fleet comparison on the DIAG page: the caller
-- groups by Model, takes the highest version and flags the headsets behind it.
-- Headsets that never reported a version simply have no row here.
SELECT h.ID AS ID, h.Name AS Name, h.Model AS Model,
       f.firmware_version AS FirmwareVersion, f.environment AS Environment,
       f.ts AS ts
FROM v_headsets h
JOIN firmware_history f ON f.headset_id = CAST(h.ID AS INTEGER)
WHERE f.ts = (SELECT MAX(ts) FROM firmware_history WHERE headset_id = f.headset_id)
ORDER BY h.SortOrder, CAST(h.ID AS INTEGER);
