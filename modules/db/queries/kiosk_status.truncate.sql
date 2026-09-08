-- Drop every live kiosk reachability row at startup, for the same reason as
-- status.truncate: it is live state, not persistent state.
DELETE FROM kiosk_status;
