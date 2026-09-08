-- One kiosk row by its permanent id, with the legacy CSV column names.
SELECT ID, Name, IPAddress, Port, PushedURL, LastPushedAt, SortOrder
FROM v_kiosks
WHERE CAST(ID AS INTEGER) = @id;
