-- Every cached advanced-kiosk heartbeat. Column aliases match the property
-- names Save-KioskAgentReport used to write into kiosks_agent.json, because
-- the console and /api/kiosks read them by name. IsStale is computed by the
-- caller, not here: the staleness threshold is a parameter of the question,
-- not a property of the row.
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
FROM kiosk_agent_reports;
