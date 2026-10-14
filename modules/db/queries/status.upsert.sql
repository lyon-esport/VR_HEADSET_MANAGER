-- One live-status row (ADR-0016: id-keyed, no identity columns).
-- Driven by the monitor fast path through Invoke-DbBatch.
-- No battery_history column any more (migration 005): the samples live in the
-- metric_history TABLE, written by the triggers this statement fires.
-- cpu_temp / gpu_temp / skin_temp / adb_transport arrived with migration 007.
INSERT INTO headset_status (headset_id, ping, adb_wifi, battery, charging,
       charging_wattage, temp, cpu_temp, gpu_temp, skin_temp,
       battery_controller_left, battery_controller_right,
       power_state, time_remaining_min, adb_transport, scrcpy, running_app,
       running_app_icon, updated_at)
VALUES (@ID, @Ping, @ADBWifi, @Battery, @Charging,
        @ChargingWattage, @Temp, @CpuTemp, @GpuTemp, @SkinTemp,
        @BatteryControllerLeft, @BatteryControllerRight,
        @PowerState, @TimeRemainingMin, @AdbTransport, @SCRCPY, @RunningApp,
        @RunningAppIcon, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(headset_id) DO UPDATE SET
    ping                     = excluded.ping,
    adb_wifi                 = excluded.adb_wifi,
    battery                  = excluded.battery,
    charging                 = excluded.charging,
    charging_wattage         = excluded.charging_wattage,
    temp                     = excluded.temp,
    cpu_temp                 = excluded.cpu_temp,
    gpu_temp                 = excluded.gpu_temp,
    skin_temp                = excluded.skin_temp,
    battery_controller_left  = excluded.battery_controller_left,
    battery_controller_right = excluded.battery_controller_right,
    power_state              = excluded.power_state,
    time_remaining_min       = excluded.time_remaining_min,
    adb_transport            = excluded.adb_transport,
    scrcpy                   = excluded.scrcpy,
    running_app              = excluded.running_app,
    running_app_icon         = excluded.running_app_icon,
    updated_at               = excluded.updated_at;
