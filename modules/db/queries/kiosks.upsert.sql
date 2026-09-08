-- Insert or update one kiosk row by its permanent id.
INSERT INTO kiosks (id, name, ip_address, port, pushed_url, last_pushed_at, sort_order)
VALUES (@id, @name, @ip_address, @port, @pushed_url, @last_pushed_at, @sort_order)
ON CONFLICT(id) DO UPDATE SET
    name           = excluded.name,
    ip_address     = excluded.ip_address,
    port           = excluded.port,
    pushed_url     = excluded.pushed_url,
    last_pushed_at = excluded.last_pushed_at,
    sort_order     = excluded.sort_order;
