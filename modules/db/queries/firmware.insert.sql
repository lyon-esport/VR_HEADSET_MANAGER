-- Record one firmware version for one headset.
--
-- Called by the monitor ONLY when the version it just read differs from the
-- newest row (firmware.latest), so the table holds changes, not samples.
-- OR IGNORE: two reads landing in the same second collapse to the first, which
-- is harmless - the version is identical by construction.
INSERT OR IGNORE INTO firmware_history (headset_id, ts, firmware_version, environment)
VALUES (@headset_id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), @firmware_version, @environment);
