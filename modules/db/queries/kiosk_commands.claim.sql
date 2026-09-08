-- Claim the oldest pending command for one kiosk: read and delete in a SINGLE
-- statement, so two concurrent claimers can never both receive it.
--
-- This is what replaces the one-file-per-command queue. That design existed
-- only because there was no cross-process lock and an atomic file create was
-- the cheapest way to avoid one; a single DELETE ... RETURNING is both simpler
-- and stronger. Needs SQLite 3.35+, which Import-DatabaseAssembly asserts.
--
-- Property names are lowercase on purpose: this object is serialised straight
-- into the agent-report HTTP reply and the kiosk agents parse these exact keys.
DELETE FROM kiosk_commands
 WHERE id = (SELECT id FROM kiosk_commands WHERE ip_address = @ip_address ORDER BY id LIMIT 1)
RETURNING id, ip_address AS ip, cmd, nonce, delay_sec AS delaySec,
          queued_at AS queuedAt, queued_unix;
