-- Every registry row in display order, with the legacy CSV column names.
SELECT ID, Name, IPAddress, scrcpy_AutoRestart, Record, ScrcpyProfile,
       Brand, Model, SerialNumber, SortOrder
FROM v_headsets
ORDER BY SortOrder, CAST(ID AS INTEGER);
