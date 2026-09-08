-- One cached advanced-kiosk heartbeat by address. Same aliases as agent.list.
SELECT ip_address           AS IPAddress,
       machine_id           AS MachineId,
       hostname             AS Hostname,
       os                   AS OS,
       os_family            AS OSFamily,
       interface_type       AS InterfaceType,
       interface_name       AS InterfaceName,
       link_speed_mbps      AS LinkSpeedMbps,
       browser              AS Browser,
       browser_running      AS BrowserRunning,
       cdp_port             AS CdpPort,
       current_url          AS CurrentUrl,
       uptime_sec           AS UptimeSec,
       auto_restart_browser AS AutoRestartBrowser,
       agent_version        AS AgentVersion,
       last_ack             AS LastAck,
       last_report_at       AS LastReportAt
FROM kiosk_agent_reports
WHERE ip_address = @ip_address;
