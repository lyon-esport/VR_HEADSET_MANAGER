-- One live kiosk reachability row. Written only by the monitor loop.
INSERT INTO kiosk_status (ip_address, port, reachable, latency_ms, cdp_open,
                          current_url, extra_json, updated_at)
VALUES (@ip_address, @port, @reachable, @latency_ms, @cdp_open,
        @current_url, @extra_json, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(ip_address) DO UPDATE SET
    port        = excluded.port,
    reachable   = excluded.reachable,
    latency_ms  = excluded.latency_ms,
    cdp_open    = excluded.cdp_open,
    current_url = excluded.current_url,
    extra_json  = excluded.extra_json,
    updated_at  = excluded.updated_at;
