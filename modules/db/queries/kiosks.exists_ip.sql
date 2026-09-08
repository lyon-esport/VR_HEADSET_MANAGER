-- 1 when any kiosk already holds this address. Used by the duplicate guard in
-- Add-Kiosk; ip_address is UNIQUE, so this turns a constraint violation into a
-- readable operator message instead.
SELECT COUNT(*) FROM kiosks WHERE ip_address = @ip_address;
