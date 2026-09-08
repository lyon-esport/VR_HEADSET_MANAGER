-- Insert or update one registry row, addressed by its permanent id.
-- Used by the legacy importer and by Save-Headsets. sort_order carries the
-- display order that used to be implicit in CSV row order.
INSERT INTO headsets (id, name, ip_address, scrcpy_auto_restart, record,
                      scrcpy_profile, brand, model, serial_number, sort_order)
VALUES (@id, @name, @ip_address, @scrcpy_auto_restart, @record,
        @scrcpy_profile, @brand, @model, @serial_number, @sort_order)
ON CONFLICT(id) DO UPDATE SET
    name                = excluded.name,
    ip_address          = excluded.ip_address,
    scrcpy_auto_restart = excluded.scrcpy_auto_restart,
    record              = excluded.record,
    scrcpy_profile      = excluded.scrcpy_profile,
    brand               = excluded.brand,
    model               = excluded.model,
    serial_number       = excluded.serial_number,
    sort_order          = excluded.sort_order;
