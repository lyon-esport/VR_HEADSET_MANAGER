-- The healing key. Set-HeadsetIdentity resolves a headset by serial and then
-- writes its address; an empty serial matches nothing on purpose, since
-- several rows may legitimately have none yet.
SELECT ID, Name, IPAddress, scrcpy_AutoRestart, Record, ScrcpyProfile,
       Brand, Model, SerialNumber, SortOrder
FROM v_headsets
WHERE SerialNumber <> '' AND SerialNumber = @serial_number;
