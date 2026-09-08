-- Insert or update one app-catalogue entry.
INSERT INTO app_catalog (package_name, display_name, icon_url, local_icon_path,
                         third_party, latest_version, updated_at)
VALUES (@package_name, @display_name, @icon_url, @local_icon_path,
        @third_party, @latest_version, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
ON CONFLICT(package_name) DO UPDATE SET
    display_name    = excluded.display_name,
    icon_url        = excluded.icon_url,
    local_icon_path = excluded.local_icon_path,
    third_party     = excluded.third_party,
    latest_version  = excluded.latest_version,
    updated_at      = excluded.updated_at;
