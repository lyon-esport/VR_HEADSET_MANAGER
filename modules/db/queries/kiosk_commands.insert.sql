-- Queue one operator command for a kiosk. The nonce is unique, so replaying
-- the same command is rejected rather than duplicated.
INSERT INTO kiosk_commands (ip_address, cmd, nonce, delay_sec, queued_at, queued_unix)
VALUES (@ip_address, @cmd, @nonce, @delay_sec, @queued_at, @queued_unix);
