-- =============================================================
-- Payments Module
-- Handles fcrypto:addBalance (cross-module credit) and the
-- admin addcrypto command. All mutations are logged. (Review Note 8)
-- =============================================================

-- ---- Internal event: credit a wallet after a confirmed P2P transfer ----
AddEventHandler("fcrypto:addBalance", function(walletId, amount)
    if type(walletId) ~= "string" or #walletId == 0 then return end
    if type(amount) ~= "number" or amount <= 0 then return end

    amount = math.floor(amount)

    -- Apply with clamping (Review Note 3)
    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
        { amount, Config.MaxWalletBalance, walletId }
    )

    CryptoDebug("fcrypto:addBalance –", walletId, "+=", amount)
end)

-- ---- Admin command: manually credit a wallet ----
RegisterCommand("addcrypto", function(source, args)
    -- Reject non-console, non-ace callers
    if source ~= 0 then
        if not IsPlayerAceAllowed(source, "crypto.admin") then return end
    end

    local walletId = args[1]
    local amount   = tonumber(args[2])

    if not walletId or not amount or amount <= 0 then
        print("[CRYPTO] Usage: addcrypto <wallet_id> <amount>")
        return
    end

    amount = math.floor(amount)

    local exists = MySQL.scalar.await(
        'SELECT id FROM crypto_wallets WHERE wallet_id = ?',
        { walletId }
    )
    if not exists then
        print("[CRYPTO] Wallet not found: " .. walletId)
        return
    end

    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
        { amount, Config.MaxWalletBalance, walletId }
    )

    -- Log admin credit as a transaction (Review Note 8)
    MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { "ADMIN", walletId, amount, "admin_credit", "confirmed" }
    )

    print(("[CRYPTO] Admin credited %d to %s"):format(amount, walletId))
end, false)
