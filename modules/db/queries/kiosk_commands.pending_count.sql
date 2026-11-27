-- Is one queued kiosk command still waiting for its agent? 1 while the row
-- exists, 0 once the agent claimed it (kiosk_commands.claim deletes it).
-- Used by Wait-KioskCommandsDelivered before the app or host shuts down.
SELECT COUNT(*) FROM kiosk_commands WHERE nonce = @nonce;
