-- One installed-app row for a headset, addressed by headset id (never by the
-- mutable display name the CSV era used as a filename).
INSERT INTO headset_installed_apps (headset_id, package_name, version,
                                    pending_version, store_version, size_bytes)
VALUES (@headset_id, @package_name, @version, @pending_version, @store_version, @size_bytes)
ON CONFLICT(headset_id, package_name) DO UPDATE SET
    version         = excluded.version,
    pending_version = excluded.pending_version,
    store_version   = excluded.store_version,
    size_bytes      = excluded.size_bytes;
