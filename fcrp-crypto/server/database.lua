-- =============================================================
-- Database Module
-- Schema validation only. Tables are created via sql/crypto.sql.
-- (Review Note 12: no schema creation inside gameplay loops)
-- =============================================================

CreateThread(function()
    local exists = MySQL.scalar.await([[
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = DATABASE()
          AND table_name = 'crypto_wallets'
    ]])

    if (exists or 0) == 0 then
        print("^1[CRYPTO]^7 Database not installed.")
        print("^1Import sql/crypto.sql manually.")
    end
end)
