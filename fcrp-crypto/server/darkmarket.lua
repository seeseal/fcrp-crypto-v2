-- =============================================================
-- Dark Market Module
-- All prices are calculated server-side; wallet ownership is
-- verified before any balance deduction. (Review Note 1)
-- =============================================================

local DarkItems = {
    laptop = {
        price = 12
    },
    thermite = {
        price = 25
    },
    advancedlockpick = {
        price = 8
    }
}

RegisterNetEvent("crypto:buyDarkItem", function(item)
    local src = source

    -- Rate-limit dark market purchases (Review Note 6)
    if not RateLimit(src, "darkmarket", 5) then return end

    -- Validate item name server-side (Review Note 1)
    if type(item) ~= "string" or not DarkItems[item] then return end

    local wallet = GetPlayerWallet(src)
    if not wallet then return end

    -- Price is calculated server-side; never supplied by client (Review Note 1)
    local data  = DarkItems[item]
    local price = math.ceil(data.price * Config.DarkMarket.multiplier)

    -- Atomic balance check and deduct (Review Note 1)
    local ok, err = pcall(function()
        MySQL.transaction.await(function(tx)
            local balance = tx.scalar(
                'SELECT balance FROM crypto_wallets WHERE wallet_id = ? FOR UPDATE',
                { wallet }
            )
            if not balance or balance < price then error("insufficient") end
            tx.update(
                'UPDATE crypto_wallets SET balance = balance - ? WHERE wallet_id = ?',
                { price, wallet }
            )
        end)
    end)

    if not ok then
        TriggerClientEvent("crypto:notify", src, "Insufficient balance.", "error")
        return
    end

    -- Log dark market transaction (Review Note 8)
    MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { wallet, "DARK_MARKET", price, "dark_market_purchase", "confirmed" }
    )

    exports.ox_inventory:AddItem(src, item, 1)

    TriggerClientEvent("crypto:notify", src, "Item purchased.", "success")
    CryptoDebug("Dark market purchase:", wallet, item, price)
end)
