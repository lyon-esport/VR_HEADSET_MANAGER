-- 1 when this SERIAL is on the permanent forget list. Keyed on the serial and
-- never the address, so a forgotten device stays forgotten across a DHCP move.
SELECT COUNT(*) FROM headset_discovery_ignore WHERE serial_number = @serial_number;
