-- One recording by its absolute file path.
SELECT * FROM recordings WHERE file_path = @file_path;