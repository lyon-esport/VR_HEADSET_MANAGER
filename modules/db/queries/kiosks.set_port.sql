-- Change one kiosk's Chrome remote-debugging port.
UPDATE kiosks SET port = CAST(@value AS INTEGER) WHERE id = @id;
