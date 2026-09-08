-- One registry row by its permanent id, with the legacy CSV column names.
SELECT ID, Name, IPAddress, scrcpy_AutoRestart, Record, ScrcpyProfile,
       Brand, Model, SerialNumber, SortOrder
FROM v_headsets
WHERE CAST(ID AS INTEGER) = @id;
