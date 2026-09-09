-- Registry identity plus live status in one row, in display order.
--
-- This is the join Get-HeadsetInfosMerged used to do by hand: read the status
-- file, build a hashtable of the registry, graft Name/IPAddress/Brand/Model/
-- SerialNumber back on by ID and drop rows whose headset is gone. The INNER
-- JOIN in v_headset_full gives the same drop for free - a status row cannot
-- outlive its headset, and one without a headset is not displayable.
SELECT ID, Name, IPAddress, scrcpy_AutoRestart, Record, ScrcpyProfile,
       Brand, Model, SerialNumber,
       Ping, ADBWifi, Battery, Charging, ChargingWattage, Temp,
       BatteryControllerLeft, BatteryControllerRight, PowerState,
       TimeRemainingMin, BatteryHistory, SCRCPY, RunningApp, RunningAppIcon
FROM v_headset_full
ORDER BY SortOrder, CAST(ID AS INTEGER);
