-- =============================================================
-- Transactions Module
-- Handles the ledger – every wallet mutation creates a record.
-- (Review Notes 1, 8, 16)
-- =============================================================

-- ---- Create a pending transaction record ----
function CreateTransaction(walletFrom, walletTo, amount, txType)
    if type(walletFrom) ~= "string" or type(walletTo) ~= "string" then return false end
    if type(amount) ~= "number" or amount <= 0 then return false end

    -- Verify sender has sufficient balance before inserting (Review Note 1)
    local sender = MySQL.single.await(
        'SELECT balance FROM crypto_wallets WHERE wallet_id = ?',
        { walletFrom }
    )

    if not sender then return false end
    if sender.balance < amount then return false end

    local txId = lib.string.random('XXXXXXXXXXXX')

    MySQL.insert.await(
        'INSERT INTO crypto_transactions (tx_id, wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,?,NOW())',
        { txId, walletFrom, walletTo, amount, txType or "transfer", 'pending' }
    )

    return txId
end

-- ---- Confirm a pending transaction ----
function ConfirmTransaction(txId)
    local tx = MySQL.single.await(
        'SELECT * FROM crypto_transactions WHERE tx_id = ?',
        { txId }
    )

    if not tx then return false end
    if tx.status ~= "pending" then return false end

    -- Apply debit and credit atomically with balance clamping (Review Note 3)
    MySQL.transaction.await({
        {
            query  = 'UPDATE crypto_wallets SET balance = balance - ? WHERE wallet_id = ? AND balance >= ?',
            values = { tx.amount, tx.wallet_from, tx.amount }
        },
        {
            query  = 'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
            values = { tx.amount, Config.MaxWalletBalance, tx.wallet_to }
        },
        {
            query  = 'UPDATE crypto_transactions SET status = "confirmed", confirmed_at = NOW() WHERE tx_id = ?',
            values = { txId }
        }
    })

    return true
end

-- ---- Queue a transaction with a short confirmation delay ----
function QueueTransaction(txId, delay)
    SetTimeout(delay * 1000, function()
        ConfirmTransaction(txId)
    end)
end

-- ---- Wallet transfer event ----
-- Amount is ALWAYS calculated server-side; client-supplied amount is validated
-- strictly (type, floor, range). (Review Notes 1, 8)
RegisterNetEvent("crypto:transfer", function(targetWallet, amount)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)

    if not Player then return end

    -- Validate all inputs server-side (Review Note 1)
    if type(targetWallet) ~= "string" or #targetWallet == 0 then return end
    if type(amount) ~= "number" then return end

    amount = math.floor(amount)

    if amount <= 0 then return end
    if amount > Config.MaxWalletBalance then return end

    -- Rate-limit transfer events (Review Note 6)
    if not RateLimit(src, "transfer", Config.EventCooldown) then return end

    local senderWallet = GetPlayerWallet(src)
    if not senderWallet then return end

    -- Sender cannot transfer to themselves
    if senderWallet == targetWallet then return end

    -- Verify target wallet exists (Review Note 1)
    local target = MySQL.single.await(
        'SELECT wallet_id FROM crypto_wallets WHERE wallet_id = ?',
        { targetWallet }
    )
    if not target then
        TriggerClientEvent("crypto:notify", src, "Wallet not found.", "error")
        return
    end

    -- Calculate fee server-side (Review Note 1)
    local fee  = math.floor(amount * Config.TransactionFee)
    local net  = amount - fee

    if net <= 0 then
        TriggerClientEvent("crypto:notify", src, "Amount too small after fee.", "error")
        return
    end

    -- Atomic transaction with balance guard (Review Notes 1, 3, 8)
    local ok, err = pcall(function()
        MySQL.transaction.await({
            {
                query  = 'UPDATE crypto_wallets SET balance = balance - ? WHERE wallet_id = ? AND balance >= ?',
                values = { amount, senderWallet, amount }
            },
            {
                query  = 'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
                values = { net, Config.MaxWalletBalance, targetWallet }
            },
            {
                query  = 'INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, fee, type, status, created_at) VALUES (?,?,?,?,?,?,NOW())',
                values = { senderWallet, targetWallet, net, fee, "transfer", "confirmed" }
            }
        })
    end)

    if not ok then
        local reason = (tostring(err):find("insufficient")) and "Insufficient funds." or "Transfer failed."
        TriggerClientEvent("crypto:notify", src, reason, "error")
        return
    end

    TriggerClientEvent("crypto:notify", src,
        ("Sent %d %s to %s (fee: %d)"):format(net, Config.Symbol, targetWallet, fee),
        "success"
    )
    CryptoDebug("Transfer:", senderWallet, "->", targetWallet, "amount:", net, "fee:", fee)
end)
