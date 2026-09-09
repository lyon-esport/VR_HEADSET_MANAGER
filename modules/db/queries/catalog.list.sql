-- Whole app catalogue through the compatibility view, so the rows carry the
-- legacy known_apps.csv header names and ThirdParty as 'True'/'False'.
-- Sorted by display name, matching the order the CSV was always written in.
SELECT PackageName, DisplayName, IconUrl, LocalIconPath, ThirdParty, LatestVersion
FROM v_app_catalog
ORDER BY DisplayName COLLATE NOCASE, PackageName COLLATE NOCASE;
