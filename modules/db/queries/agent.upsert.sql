-- Latest heartbeat from one advanced kiosk agent. Keyed on the IP taken from
-- the request's remote endpoint, never from the request body.
INSERT INTO kiosk_agent_reports (ip_address, machine_id, hostname, os, os_family,
       interface_type, interface_name, link_speed_mbps, browser, browser_running,
       cdp_port, current_url, uptime_sec, auto_restart_browser, agent_version,
       last_ack, last_report_at)
VALUES (@ip_address, @machine_id, @hostname, @os, @os_family,
        @interface_type, @interface_name, @link_speed_mbps, @browser, @browser_running,
        @cdp_port, @current_url, @uptime_sec, @auto_restart_browser, @agent_version,
        @last_ack, @last_report_at)
ON CONFLICT(ip_address) DO UPDATE SET
    machine_id           = excluded.machine_id,
    hostname             = excluded.hostname,
    os                   = excluded.os,
    os_family            = excluded.os_family,
    interface_type       = excluded.interface_type,
    interface_name       = excluded.interface_name,
    link_speed_mbps      = excluded.link_speed_mbps,
    browser              = excluded.browser,
    browser_running      = excluded.browser_running,
    cdp_port             = excluded.cdp_port,
    current_url          = excluded.current_url,
    uptime_sec           = excluded.uptime_sec,
    auto_restart_browser = excluded.auto_restart_browser,
    agent_version        = excluded.agent_version,
    last_ack             = excluded.last_ack,
    last_report_at       = excluded.last_report_at;
