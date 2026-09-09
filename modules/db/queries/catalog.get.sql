-- One catalogue entry by package name, legacy column names.
SELECT PackageName, DisplayName, IconUrl, LocalIconPath, ThirdParty, LatestVersion
FROM v_app_catalog
WHERE PackageName = @package_name;
