-- Record or refresh one pending discovery proposal, deduped by serial.
INSERT INTO discovered_headsets (serial_number, ip_address, model, brand, first_seen, last_seen)
VALUES (@serial_number, @ip_address, @model, @brand, @first_seen, @last_seen)
ON CONFLICT(serial_number) DO UPDATE SET
    ip_address = excluded.ip_address,
    model      = excluded.model,
    brand      = excluded.brand,
    last_seen  = excluded.last_seen;
