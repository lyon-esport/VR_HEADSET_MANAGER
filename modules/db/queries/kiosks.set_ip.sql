-- Move one kiosk to a different address.
UPDATE kiosks SET ip_address = @value WHERE id = @id;
