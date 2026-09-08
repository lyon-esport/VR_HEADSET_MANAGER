-- Drop every live status row. The main process calls this at startup so
-- stale state from a previous run cannot survive a restart (ADR-0016).
DELETE FROM headset_status;
