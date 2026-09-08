-- Live reachability for every kiosk the monitor has polled, keyed on address.
-- Property names match what the /api/kiosks merge already reads.
SELECT ip_address  AS IPAddress,
       port        AS Port,
       CASE reachable WHEN 1 THEN 1 ELSE 0 END AS Reachable,
       latency_ms  AS LatencyMs,
       CASE cdp_open  WHEN 1 THEN 1 ELSE 0 END AS CdpOpen,
       current_url AS CurrentUrl,
       updated_at  AS LastChecked
FROM kiosk_status;
