-- Give every headset a default status row, leaving existing ones untouched.
--
-- Called at startup right after the truncate, so the UI renders the full list
-- of headsets immediately instead of waiting out the first poll cycle (10-20s
-- with several headsets). Every column carries its own default in the table
-- definition, so listing only headset_id here IS the default shape - it cannot
-- drift from New-DefaultHeadsetInfo the way a hand-built seed row could.
INSERT OR IGNORE INTO headset_status (headset_id)
SELECT id FROM headsets;
