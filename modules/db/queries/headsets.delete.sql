-- Remove one headset. Its live status, installed apps, favourites and timer row
-- go with it through ON DELETE CASCADE - the per-headset CSV files this
-- replaces had to be deleted by hand, and were missed whenever a rename had
-- moved them first.
DELETE FROM headsets WHERE id = @id;
