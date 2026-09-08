-- Resolve a display name to its registry row. Name is the human-facing key
-- everywhere in the UI, but never the storage key.
SELECT ID, Name, IPAddress, scrcpy_AutoRestart, Record, ScrcpyProfile,
       Brand, Model, SerialNumber, SortOrder
FROM v_headsets
WHERE Name = @name;
