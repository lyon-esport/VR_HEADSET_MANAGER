-- Every kiosk row in display order, with the legacy CSV column names.
SELECT ID, Name, IPAddress, Port, PushedURL, LastPushedAt, SortOrder
FROM v_kiosks
ORDER BY SortOrder, CAST(ID AS INTEGER);
