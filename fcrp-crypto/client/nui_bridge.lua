-- ============================================================
--  client/nui_bridge.lua  –  FlameNet Terminal NUI callbacks
--
--  Add this file to fxmanifest.lua under client_scripts:
--    'client/nui_bridge.lua',

-- Client-side cache for the connected wallet address.
-- Populated when terminalUI data arrives; used by any handler
-- that needs the address without a server round-trip.
local _cachedWalletAddress = nil
--
--  This file bridges the UI actions that have no existing
--  RegisterNUICallback handler in the original client files.
-- ============================================================

-- ── WALLET CREATED – push real address to UI ─────────────────
-- Fired by server/wallet.lua after crypto:createWallet succeeds.
RegisterNetEvent("crypto:walletCreated", function(walletID)
    SendNUIMessage({
        action = "setWallet",
        wallet = walletID
    })
end)

-- ── PROMPT PIN (physical wallet creation via /createwallet) ──
-- Server fires this to open the PIN modal in the NUI.
-- We send openTerminal first so the body becomes visible, then promptPin.
RegisterNetEvent("crypto:promptPin", function()
    TriggerEvent("crypto:tabletOpen")
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openTerminal" })   -- makes tablet-frame visible
    SendNUIMessage({ action = "promptPin" })       -- opens PIN modal on top
end)

-- ── CREATE PHYSICAL WALLET (PIN confirmed in UI) ──────────────
-- UI sends: { passcode = "1234" }
-- Triggered by the PIN modal confirm button after /createwallet.
RegisterNUICallback("createPhysicalWallet", function(data, cb)
    local passcode = tostring(data.passcode or "")
    if #passcode < 4 then
        cb({ success = false, message = "PIN must be exactly 4 digits." })
        return
    end
    TriggerServerEvent("crypto:createPhysicalWallet", passcode)
    cb({ success = true })
end)

-- ── CREATE WALLET (session wallet with player-set PIN) ─────────
-- UI sends: { passcode = "1234" }
-- Flow: terminal → create wallet → UI asks for PIN → send to server
RegisterNUICallback("createWallet", function(data, cb)
    local passcode = tostring(data.passcode or "")
    if #passcode < 4 then
        cb({ success = false, message = "PIN must be at least 4 digits." })
        return
    end
    TriggerServerEvent("crypto:createWallet", passcode)
    cb({ success = true })
end)

-- ── SEND TRANSACTION ─────────────────────────────────────────
-- UI sends: { address = "FTCxxxxxxxx", amount = 100.0 }
-- Routes to: server/transactions.lua  RegisterNetEvent("crypto:transfer")
RegisterNUICallback("sendTransaction", function(data, cb)
    local address = data.address
    local amount  = tonumber(data.amount)

    if type(address) ~= "string" or #address < 4 then
        cb({})
        return
    end

    if not amount or amount <= 0 then
        cb({})
        return
    end

    TriggerServerEvent("crypto:transfer", address, amount)
    cb({})
end)

-- ── COPY ADDRESS ─────────────────────────────────────────────
-- UI sends clipboard copy; Lua side is a no-op but must exist.
RegisterNUICallback("copyAddress", function(_, cb)
    cb({})
end)

-- ── CLOSE TERMINAL ───────────────────────────────────────────
-- Already in client/terminal.lua as "closeTerminal".
-- Listed here as a reference. Do NOT duplicate it.
-- RegisterNUICallback("closeTerminal", function(_, cb) ... end)

-- ── RECEIVE TRANSACTION RESULT FROM SERVER ───────────────────
-- server/transactions.lua fires crypto:notify; re-map to UI action.
RegisterNetEvent("crypto:notify", function(message, notifType)
    local success = (notifType == "success")

    -- ── EXCHANGE (buy/sell) ───────────────────────────────────
    if message and (message:find("Bought") or message:find("Sold")) then
        local tradeType = message:find("Bought") and "buy" or "sell"
        local amount    = tonumber(message:match("(%d+%.?%d*)%s*FTC")) or 0

        SendNUIMessage({
            action    = "exchangeResult",
            success   = success,
            message   = message,
            tradeType = tradeType,
            amount    = amount,
        })

        if success then
            -- Ask server for fresh balance; crypto:updateBalance will SendNUIMessage
            TriggerServerEvent("crypto:getBalance")
        end
        return
    end

    -- ── TRANSFER (send FTC) ────────────────────────────────────
    -- Message format: "Sent <net> FTC to <addr> (fee: <fee>)"
    local sentAmount = tonumber(message and message:match("Sent%s+(%d+%.?%d*)%s+FTC")) or 0
    local toAddr     = message and message:match("to%s+(0x%x+)") or "—"

    SendNUIMessage({
        action  = "transactionResult",
        success = success,
        message = message,
        -- Pass parsed values so the UI can show them without re-parsing
        sentAmount = sentAmount,
        toAddr     = toAddr,
    })

    if success then
        -- Request fresh balance from server; it will send crypto:updateBalance back
        TriggerServerEvent("crypto:getBalance")

        -- Push a live activity entry
        SendNUIMessage({
            action  = "newActivity",
            type    = "send",
            message = ("Sent %s FTC → %s"):format(sentAmount, toAddr),
        })
    end
end)

-- ── RECEIVE TERMINAL DATA AND PUSH TO UI ─────────────────────
-- Called after crypto:openTerminal is received from server.
-- Fetches full dashboard bundle via lib.callback.
RegisterNetEvent("crypto:terminalUI", function(initData)
    -- Spawn prop + play animation
    TriggerEvent("crypto:tabletOpen")
    -- Open the UI immediately with the basic price the server sent
    SetNuiFocus(true, true)
    SendNUIMessage({
        action      = "openTerminal",
        price       = initData and initData.price or nil,
        priceChange = 0,
    })

    -- Fetch full terminal dataset asynchronously
    local termData = lib.callback.await("crypto:getTerminalData", false)
    if not termData then return end

    -- Build per-GPU detail array for the GPU grid
    local gpuDetails  = {}
    local totalHash   = 0
    local totalPower  = 0

    if termData.rigGPUs and type(termData.rigGPUs) == "table" then
        for _, gpu in ipairs(termData.rigGPUs) do
            local hashrate = math.floor((gpu.power or 1.0) * 50)
            local wattage  = math.floor((gpu.electricity or 1.0) * 100)
            totalHash  = totalHash  + hashrate
            totalPower = totalPower + wattage
            table.insert(gpuDetails, {
                label    = gpu.label or gpu.gpu_type or "GPU",
                hashrate = hashrate,
                power    = wattage,
            })
        end
    else
        local count = termData.gpus or 0
        totalHash = count * 50
        for i = 1, count do
            table.insert(gpuDetails, { label = "GPU #"..i, hashrate = 50, power = 120 })
        end
    end

    local dailyReward = termData.dailyEst or termData.stored or 0

    -- Cache the wallet address client-side for use in subsequent balance updates
    if termData.wallet then
        _cachedWalletAddress = termData.wallet
    end

    -- Dashboard stat cards
    SendNUIMessage({
        action        = "updateDashboard",
        walletBalance = termData.balance,
        walletAddress = termData.wallet,
        price         = termData.price,
        priceChange   = termData.priceChange or 0,
        miningPower   = totalHash,
        rewards       = dailyReward,
        power         = totalPower,
    })

    -- GPU grid panel
    SendNUIMessage({
        action   = "updateMining",
        hashrate = totalHash,
        reward   = dailyReward,
        power    = totalPower,
        gpus     = gpuDetails,
    })

    -- Wallet panel hero balance
    SendNUIMessage({
        action        = "updateBalance",
        balance       = termData.balance,
        walletAddress = termData.wallet,
    })

    -- Transaction history
    local txHistory = lib.callback.await("fcrypto:getHistory", false)
    if txHistory then
        SendNUIMessage({
            action       = "updateTransactions",
            transactions = txHistory,
        })
    end

    -- Blockchain panel
    SendNUIMessage({
        action = "updateBlockchain",
        stats  = {
            blockHeight = termData.blockHeight or 0,
            networkHash = math.floor((termData.networkGPUs or 0) * 0.05 * 100) / 100,
            difficulty  = termData.difficulty  or 1,
            nodes       = termData.nodes       or 0,
        },
        blocks = termData.recentBlocks or {},
    })
end)

-- ── MINING REWARD RELAY ──────────────────────────────────────
-- server/mining.lua fires this; relay to NUI
RegisterNetEvent("crypto:miningReward", function(amount)
    SendNUIMessage({
        action = "miningReward",
        amount = amount,
    })
    -- Also refresh balance
    TriggerServerEvent("crypto:getBalance")
end)

-- ── GLOBAL PRICE BROADCAST RELAY ─────────────────────────────
-- server/market.lua broadcasts this every PriceUpdateInterval seconds
RegisterNetEvent("crypto:updatePrice", function(data)
    SendNUIMessage({
        action      = "updatePrice",
        price       = data.price,
        change      = data.change or 0,
    })
end)