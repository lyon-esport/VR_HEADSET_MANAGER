-- One live-status row (ADR-0016: id-keyed, no identity columns).
-- Driven by the monitor fast path through Invoke-DbBatch.
INSERT INTO headset_status (headset_id, ping, adb_wifi, battery, charging,
       charging_wattage, temp, battery_controller_left, battery_controller_right,
       power_state, time_remaining_min, battery_history, scrcpy, running_app,
       running_app_icon, updated_at)
VALUES (@ID, @Ping, @ADBWifi, @Battery, @Charging,
        @ChargingWattage, @Temp, @BatteryControllerLeft, @BatteryControllerRight,
        @PowerState, @TimeRemainingMin, @BatteryHistory, @SCRCPY, @RunningApp,
        @RunningAppIcon, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(headset_id) DO UPDATE SET
    ping                     = excluded.ping,
    adb_wifi                 = excluded.adb_wifi,
    battery                  = excluded.battery,
    charging                 = excluded.charging,
    charging_wattage         = excluded.charging_wattage,
    temp                     = excluded.temp,
    battery_controller_left  = excluded.battery_controller_left,
    battery_controller_right = excluded.battery_controller_right,
    power_state              = excluded.power_state,
    time_remaining_min       = excluded.time_remaining_min,
    battery_history          = excluded.battery_history,
    scrcpy                   = excluded.scrcpy,
    running_app              = excluded.running_app,
    running_app_icon         = excluded.running_app_icon,
    updated_at               = excluded.updated_at;
