-- 1 when this serial is already proposed. Distinguishes a brand-new device
-- (worth logging once) from a refresh of one already on the list.
SELECT COUNT(*) FROM discovered_headsets WHERE serial_number = @serial_number;
