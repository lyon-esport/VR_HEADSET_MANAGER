-- Permanently stop proposing one device. Keyed on SERIAL, never on IP, so a
-- forgotten device stays forgotten across a DHCP change.
INSERT OR IGNORE INTO headset_discovery_ignore (serial_number) VALUES (@serial_number);
