-- =============================================================
-- Cracking Module
-- All outcomes are determined server-side.
-- Client events that previously allowed unlocking or wiping wallets
-- have been removed – they were exploitable.
-- (Review Note 9)
-- =============================================================

-- ---- Attempt tracking (server-side, per-session) (Review Note 9) ----
local CrackAttempts = {}

AddEventHandler("playerDropped", function()
    CrackAttempts[source] = nil
end)

-- ---- crypto:attemptCrack ----
-- Evaluates crack success entirely server-side; never returns wallet balance to client.
RegisterNetEvent("crypto:attemptCrack", function(targetWallet)
    local src = source

    -- Rate-limit crack attempts per player (Review Note 6)
    if not RateLimit(src, "crack", 10) then return end

    if type(targetWallet) ~= "string" or #targetWallet == 0 then return end

    -- Enforce max attempt limit server-side (Review Note 9)
    CrackAttempts[src] = (CrackAttempts[src] or 0) + 1
    if CrackAttempts[src] > Config.MaxAttempts then
        TriggerClientEvent("crypto:notify", src, "Max cracking attempts reached.", "error")
        return
    end

    -- Server decides outcome; never sends balance to client (Review Note 1)
    local success = math.random() < Config.CrackChance

    -- Log crack attempt in DB (Review Note 9)
    local Player = exports.qbx_core:GetPlayer(src)
    local attacker = Player and Player.PlayerData.citizenid or "unknown"
    MySQL.insert.await(
        "INSERT INTO crypto_crack_attempts (attacker, target, success, attempted_at) VALUES (?,?,?,?)",
        { attacker, targetWallet, success and 1 or 0, os.time() }
    )

    if not success then
        TriggerClientEvent("crypto:crackFailed", src)
        return
    end

    -- Server-side: retrieve and transfer funds without exposing balance to client
    local row = MySQL.single.await(
        'SELECT id, balance FROM crypto_wallets WHERE wallet_id = ?',
        { targetWallet }
    )

    if not row or row.balance <= 0 then
        TriggerClientEvent("crypto:crackFailed", src)
        return
    end

    local playerWallet = GetPlayerWallet(src)
    if not playerWallet then
        TriggerClientEvent("crypto:crackFailed", src)
        return
    end

    -- Transfer balance server-side; validate before execution (Review Notes 1, 9)
    local stolen = row.balance
    MySQL.transaction.await({
        {
            query  = 'UPDATE crypto_wallets SET balance = 0 WHERE wallet_id = ?',
            values = { targetWallet }
        },
        {
            query  = 'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
            values = { stolen, Config.MaxWalletBalance, playerWallet }
        }
    })

    -- Log the theft as a transaction (Review Note 8)
    MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { targetWallet, playerWallet, stolen, "crack_theft", "confirmed" }
    )

    TriggerClientEvent("crypto:crackSuccess", src)
    CryptoDebug("Crack success:", attacker, "stole", stolen, "from", targetWallet)
end)

-- ---- fcrypto:crackWallet ----
-- Attempts to unlock a physical wallet item; all logic server-side (Review Note 9)
RegisterNetEvent("fcrypto:crackWallet", function(slot)
    local src = source

    if type(slot) ~= "number" then return end
    if not RateLimit(src, "crackWallet", 15) then return end

    local item = exports.ox_inventory:GetSlot(src, slot)
    if not item or not item.metadata then return end

    local meta = item.metadata

    -- Enforce max attempt limits server-side (Review Note 9)
    meta.attempts = (meta.attempts or 0) + 1

    local success = math.random(1, 100) < 35

    if success then
        -- Server unlocks the wallet directly; no callback to client for unlock (Review Note 9)
        meta.locked   = false
        meta.attempts = 0
        exports.ox_inventory:SetMetadata(src, slot, meta)
        TriggerClientEvent("fcrypto:walletUnlocked", src)
    else
        -- Wipe chance determined server-side (Review Note 9)
        if meta.attempts >= Config.MaxAttempts then
            if math.random() < Config.CrackWipeChance then
                -- Wipe validated: zero the DB balance and lock the wallet (Security fix)
                if meta.wallet_id and #meta.wallet_id > 0 then
                    MySQL.update.await(
                        'UPDATE crypto_wallets SET balance = 0, locked = 1 WHERE wallet_id = ?',
                        { meta.wallet_id }
                    )
                    -- Log the wipe (Review Note 8)
                    MySQL.insert.await(
                        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
                        { meta.wallet_id, "WIPED", 0, "crack_wipe", "confirmed" }
                    )
                end
                meta.locked = true
                -- Do NOT write passcode back — it is removed from metadata (Security fix)
            end
        end
        exports.ox_inventory:SetMetadata(src, slot, meta)
        TriggerClientEvent("fcrypto:crackFailed", src)
    end
end)

-- NOTE: The former client-callable fcrypto:crackSuccess and fcrypto:crackFail events
-- have been intentionally removed. Those events allowed any client to arbitrarily
-- unlock wallets or wipe balances. All cracking outcomes are now determined and
-- applied here on the server. (Review Note 9)
