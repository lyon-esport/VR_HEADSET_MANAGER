-- One headset's live status.
--
-- The poll runspace used to call this to preload its packed battery history;
-- that column is gone (migration 005) and the runspace reads battery.recent
-- instead. Kept because "one status row by id" is the natural single-row read
-- of this table.
SELECT ID, Ping, ADBWifi, Battery, Charging, ChargingWattage, Temp,
       BatteryControllerLeft, BatteryControllerRight, PowerState,
       TimeRemainingMin, SCRCPY, RunningApp, RunningAppIcon
FROM v_headset_status
WHERE ID = CAST(@headset_id AS TEXT);
