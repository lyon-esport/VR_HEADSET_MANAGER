-- Record the URL last pushed to one kiosk. May be a very long data: URI.
UPDATE kiosks SET pushed_url = @value WHERE id = @id;
