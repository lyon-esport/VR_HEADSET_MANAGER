-- Remove one kiosk. Its live status and agent report are keyed on the address,
-- not the id, so they are cleaned up separately by the caller.
DELETE FROM kiosks WHERE id = @id;
