-- 1 when this address is denylisted from agent-report auto-add.
SELECT COUNT(*) FROM kiosk_autoadd_ignore WHERE ip_address = @ip_address;
