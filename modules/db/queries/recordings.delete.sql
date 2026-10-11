-- Remove one catalogue row (the file itself is deleted by the caller).
DELETE FROM recordings WHERE id = @id;