-- Protect (or unprotect) a recording from the wipe, with an optional note.
UPDATE recordings SET keep = @keep, note = @note WHERE id = @id;