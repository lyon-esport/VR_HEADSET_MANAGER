-- Rename one kiosk.
UPDATE kiosks SET name = @value WHERE id = @id;
