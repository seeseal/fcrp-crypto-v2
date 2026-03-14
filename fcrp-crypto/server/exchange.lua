-- =============================================================
-- Exchange Module
-- Buy/sell and transfer are validated entirely server-side.
-- Price is read from the server market module; clients cannot
-- supply or recalculate prices. (Review Notes 1, 14)
-- =============================================================

local function FindWallet(src, walletId)
    local items = exports.ox_inventory:Search(src, 'slots', 'crypto_wallet')
    if not items then return nil end

    for _, item in pairs(items) do
        if item.metadata and item.metadata.wallet_id == walletId then
            return item
        end
    end
end

-- ---- Internal: confirm a pending exchange transaction ----
local function ConfirmExchangeTx(txId)
    local transaction = MySQL.single.await(
        'SELECT * FROM crypto_transactions WHERE tx_id = ?',
        { txId }
    )
    if not transaction then return end

    MySQL.update.await(
        'UPDATE crypto_transactions SET status = "confirmed", confirmed_at = NOW() WHERE tx_id = ?',
        { txId }
    )

    -- Find the player's active session
    local playerSource
    for _, s in ipairs(GetPlayers()) do
        if GetSession(tonumber(s)) == transaction.wallet_id then
            playerSource = tonumber(s)
            break
        end
    end
    if not playerSource then return end

    local item = FindWallet(playerSource, transaction.wallet_id)
    if not item then return end

    local meta = item.metadata

    if transaction.type == "buy" then
        meta.balance = (meta.balance or 0) + transaction.amount
    elseif transaction.type == "transfer_in" then
        meta.balance = (meta.balance or 0) + transaction.amount
    elseif transaction.type == "transfer_out" then
        meta.balance = math.max(0, (meta.balance or 0) - transaction.amount)
    end

    exports.ox_inventory:SetMetadata(playerSource, item.slot, meta)

    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = ? WHERE wallet_id = ?',
        { meta.balance, transaction.wallet_id }
    )
end

local function CreateExchangeTx(wallet, txType, amount, price)
    local txId = lib.string.random('XXXXXXXXXXXX')
    MySQL.insert.await(
        'INSERT INTO crypto_transactions (tx_id, wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,?,NOW())',
        { txId, wallet, "EXCHANGE", amount, txType, "pending" }
    )
    local delay = math.random(Config.TransactionDelay and Config.TransactionDelay[1] or 2,
                               Config.TransactionDelay and Config.TransactionDelay[2] or 5)
    SetTimeout(delay * 1000, function()
        ConfirmExchangeTx(txId)
    end)
end

-- ---- Buy crypto ----
-- Amount validated; price is read from CurrentPrice (server-controlled). (Review Notes 1, 14)
RegisterNetEvent("crypto:buy", function(amount)
    local src = source

    if not RateLimit(src, "buy", 2) then return end

    -- Validate amount server-side (Review Note 1)
    if type(amount) ~= "number" then return end
    amount = math.floor(amount)
    if amount <= 0 then return end

    local wallet = GetPlayerWallet(src)
    if not wallet then return end

    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    -- Price is always CurrentPrice from the market module; never client-supplied (Review Note 14)
    local price = CurrentPrice * (1 + Config.ExchangeSpread)
    local cost  = math.ceil(amount * price)

    if not Player.Functions.RemoveMoney("bank", cost, "crypto-buy") then
        TriggerClientEvent("crypto:notify", src, "Insufficient bank balance.", "error")
        return
    end

    -- Apply balance with clamping (Review Note 3)
    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
        { amount, Config.MaxWalletBalance, wallet }
    )

    -- Log the purchase (Review Note 8)
    MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { "EXCHANGE", wallet, amount, "buy", "confirmed" }
    )

    TriggerClientEvent("crypto:notify", src,
        ("Bought %d %s for $%d"):format(amount, Config.Symbol, cost),
        "success"
    )
    CryptoDebug("Buy:", wallet, "amount:", amount, "cost:", cost)
end)

-- ---- Sell crypto ----
RegisterNetEvent("crypto:sell", function(amount)
    local src = source

    if not RateLimit(src, "sell", 2) then return end

    if type(amount) ~= "number" then return end
    amount = math.floor(amount)
    if amount <= 0 then return end

    local wallet = GetPlayerWallet(src)
    if not wallet then return end

    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    -- Price is always CurrentPrice; never client-supplied (Review Note 14)
    local price   = CurrentPrice * (1 - Config.ExchangeSpread)
    local payout  = math.floor(amount * price)

    -- Atomic balance check and deduct (Review Note 1)
    local ok, err = pcall(function()
        MySQL.transaction.await(function(tx)
            local balance = tx.scalar(
                'SELECT balance FROM crypto_wallets WHERE wallet_id = ? FOR UPDATE',
                { wallet }
            )
            if not balance or balance < amount then error("insufficient") end
            tx.update(
                'UPDATE crypto_wallets SET balance = balance - ? WHERE wallet_id = ?',
                { amount, wallet }
            )
        end)
    end)

    if not ok then
        TriggerClientEvent("crypto:notify", src, "Insufficient crypto balance.", "error")
        return
    end

    Player.Functions.AddMoney("bank", payout, "crypto-sell")

    -- Log the sale (Review Note 8)
    MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { wallet, "EXCHANGE", amount, "sell", "confirmed" }
    )

    TriggerClientEvent("crypto:notify", src,
        ("Sold %d %s for $%d"):format(amount, Config.Symbol, payout),
        "success"
    )
    CryptoDebug("Sell:", wallet, "amount:", amount, "payout:", payout)
end)

-- ---- P2P transfer callback ----
lib.callback.register("fcrypto:transfer", function(src, targetWallet, amount)
    if type(amount) ~= "number" or amount <= 0 then return false end

    local wallet = GetSession(src)
    if not wallet then return false end

    if targetWallet == wallet then return false end

    local exists = MySQL.single.await(
        'SELECT wallet_id FROM crypto_wallets WHERE wallet_id = ?',
        { targetWallet }
    )
    if not exists then return false end

    local slot = GetSessionSlot(src)
    local item = slot and exports.ox_inventory:GetSlot(src, slot) or FindWallet(src, wallet)
    if not item then return false end

    local meta = item.metadata
    if (meta.balance or 0) < amount then return false end

    meta.balance = meta.balance - amount

    exports.ox_inventory:SetMetadata(src, item.slot, meta)

    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = ? WHERE wallet_id = ?',
        { meta.balance, wallet }
    )

    -- Log the transfer (Review Note 8)
    MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { wallet, targetWallet, amount, "p2p_transfer", "confirmed" }
    )

    TriggerEvent("fcrypto:addBalance", targetWallet, amount)

    return true
end)

-- ---- Get transaction history ----
lib.callback.register('fcrypto:getHistory', function(src)
    local wallet = GetSession(src)
    if not wallet then return {} end

    return MySQL.query.await(
        'SELECT * FROM crypto_transactions WHERE wallet_from = ? OR wallet_to = ? ORDER BY created_at DESC LIMIT 50',
        { wallet, wallet }
    )
end)
