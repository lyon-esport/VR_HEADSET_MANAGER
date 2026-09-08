-- Record when a URL was last pushed to one kiosk ('yyyy-MM-dd HH:mm:ss').
UPDATE kiosks SET last_pushed_at = @value WHERE id = @id;
