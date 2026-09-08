-- Drop proposals whose serial has become known or been forgotten. Triggers
-- already do this at the moment either happens; this is the belt-and-braces
-- sweep for rows that predate the triggers (a legacy import, say).
DELETE FROM discovered_headsets
WHERE serial_number IN (SELECT serial_number FROM headsets WHERE serial_number <> '')
   OR serial_number IN (SELECT serial_number FROM headset_discovery_ignore);
