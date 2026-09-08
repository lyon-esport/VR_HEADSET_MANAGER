-- Give every headset a default timer row, leaving existing ones untouched.
-- Called after any registry change, so a newly added headset has a timer
-- without overwriting one the operator already set.
INSERT OR IGNORE INTO headset_timers (headset_id, minutes, seconds, mode)
SELECT id, 5, 0, 'dec' FROM headsets;
