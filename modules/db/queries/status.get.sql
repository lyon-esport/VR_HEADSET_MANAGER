-- One headset's live status. Used by the per-headset poll runspace to preload
-- its packed battery history at startup, which used to mean scanning the whole
-- CSV for one row.
SELECT ID, Ping, ADBWifi, Battery, Charging, ChargingWattage, Temp,
       BatteryControllerLeft, BatteryControllerRight, PowerState,
       TimeRemainingMin, BatteryHistory, SCRCPY, RunningApp, RunningAppIcon
FROM v_headset_status
WHERE ID = CAST(@headset_id AS TEXT);
