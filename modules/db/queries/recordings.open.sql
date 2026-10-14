-- Rows still marked as being recorded (closed by Complete-RecordingEntry or, after
-- a crash, by the catalogue rescan).
SELECT * FROM recordings WHERE status = 'recording';