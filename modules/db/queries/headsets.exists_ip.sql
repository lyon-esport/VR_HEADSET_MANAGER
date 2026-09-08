-- 1 when any headset already holds this address, including the 127.0.0.N
-- placeholders. Turns the UNIQUE constraint into a readable operator message.
SELECT COUNT(*) FROM headsets WHERE ip_address = @ip_address;
