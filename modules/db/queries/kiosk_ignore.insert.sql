-- Denylist one kiosk IP from agent-report auto-add.
INSERT OR IGNORE INTO kiosk_autoadd_ignore (ip_address) VALUES (@ip_address);
