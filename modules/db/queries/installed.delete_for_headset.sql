-- Clear one headset's installed-app cache before a full refresh.
DELETE FROM headset_installed_apps WHERE headset_id = @headset_id;
