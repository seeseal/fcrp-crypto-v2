-- =============================================================
-- Robbery Module
-- Wallet theft is validated server-side; inventory is only
-- manipulated after confirming the target has a wallet item.
-- (Review Note 1)
-- =============================================================

RegisterNetEvent("fcrypto:stealWallet", function(target)
    local src = source

    if type(target) ~= "number" then return end

    -- Rate-limit robbery attempts (Review Note 6)
    if not RateLimit(src, "stealWallet", 30) then return end

    -- Verify target is a valid, connected player
    if not GetPlayerName(target) then return end

    -- Server-side proximity check — player must be within 2m of target (Security fix)
    local srcCoords    = GetEntityCoords(GetPlayerPed(src))
    local targetCoords = GetEntityCoords(GetPlayerPed(target))
    if #(srcCoords - targetCoords) > 2.0 then
        CryptoDebug("Robbery denied – player not close enough:", src, "->", target)
        return
    end

    -- Server reads the inventory directly; do not trust any client-supplied data (Review Note 1)
    local wallets = exports.ox_inventory:Search(target, 'slots', 'crypto_wallet')
    if not wallets or #wallets == 0 then
        TriggerClientEvent("crypto:notify", src, "Target has no wallet.", "error")
        return
    end

    -- Take the first wallet found
    local walletItem = wallets[1]
    if not walletItem or not walletItem.metadata then return end

    exports.ox_inventory:RemoveItem(target, 'crypto_wallet', 1)

    -- Passcode is NOT included — it lives only in crypto_wallets DB
    exports.ox_inventory:AddItem(src, 'stolen_wallet', 1, {
        wallet_id = walletItem.metadata.wallet_id,
        locked    = true,
        attempts  = 0,
        encrypted = true
    })

    TriggerClientEvent("crypto:notify", src, "Wallet stolen.", "success")
    CryptoDebug("Wallet stolen:", src, "from:", target, "wallet_id:", walletItem.metadata.wallet_id)
end)
