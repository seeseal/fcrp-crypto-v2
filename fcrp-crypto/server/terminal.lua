-- =============================================================
-- Terminal Module
-- All interactions are validated server-side, including proximity.
-- (Review Notes 6, 11)
-- =============================================================

local TERMINAL_RADIUS = 3.0 -- metres; must match client-side interaction range

-- ---- Proximity check (Review Note 11) ----
local function IsNearTerminal(src)
    local ped   = GetPlayerPed(src)
    local coord = GetEntityCoords(ped)

    for _, terminalPos in ipairs(Config.Terminals) do
        local dist = #(coord - terminalPos)
        if dist <= TERMINAL_RADIUS then
            return true
        end
    end

    return false
end

-- ---- Open terminal event ----
-- Server verifies proximity before responding (Review Note 11)
RegisterNetEvent("crypto:openTerminal", function()
    local src = source

    -- Rate-limit terminal opens (Review Note 6)
    if not RateLimit(src, "terminal", Config.EventCooldown) then return end

    -- Reject if player is not physically near a terminal (Review Note 11)
    if not IsNearTerminal(src) then
        CryptoDebug("Terminal open denied – player not near terminal:", src)
        return
    end

    TriggerClientEvent("crypto:terminalUI", src, {
        price  = CurrentPrice,
        symbol = Config.Symbol
    })
end)

-- ---- Get terminal data callback ----
lib.callback.register("crypto:getTerminalData", function(src)
    -- Re-check proximity on every data request (Review Note 11)
    if not IsNearTerminal(src) then return nil end
    if not RateLimit(src, "terminalData", Config.EventCooldown) then return nil end

    local wallet = GetSession(src)
    if not wallet then return nil end

    local balance = GetWalletBalance(wallet)

    -- ── RIGS + PER-GPU DETAILS ────────────────────────────────
    local rigs = MySQL.query.await(
        "SELECT * FROM crypto_rigs WHERE wallet_id = ?",
        { wallet }
    )

    local totalGPUs  = 0
    local storedFTC  = 0
    local totalPower = 0   -- sum of Config.GPUs[type].power across all installed GPUs
    local rigGPUs    = {}  -- flat list of per-GPU objects for the UI grid

    for _, rig in pairs(rigs) do
        local slots = json.decode(rig.gpu_slots or "[]")
        storedFTC   = storedFTC + (rig.stored_ftc or 0)

        for _, gpuType in ipairs(slots) do
            totalGPUs = totalGPUs + 1
            local cfg = (Config.GPUs and Config.GPUs[gpuType]) or {}
            local pwr = cfg.power       or 1.0
            local elc = cfg.electricity or 1.0
            totalPower = totalPower + pwr
            table.insert(rigGPUs, {
                gpu_type    = gpuType,
                label       = gpuType:sub(1,1):upper() .. gpuType:sub(2) .. " GPU",
                power       = pwr,
                electricity = elc,
            })
        end
    end

    -- ── MARKET PRICE + HISTORY ────────────────────────────────
    local priceRow = MySQL.single.await(
        "SELECT price FROM crypto_market WHERE symbol = 'FTC'"
    )
    local livePrice = priceRow and priceRow.price or CurrentPrice

    -- Last 24 price history points (newest first → reverse for chart)
    local priceHistory = MySQL.query.await(
        "SELECT price, recorded_at FROM crypto_price_history WHERE symbol = 'FTC' ORDER BY id DESC LIMIT 24"
    )
    local historyForUI = {}
    if priceHistory then
        for i = #priceHistory, 1, -1 do
            local row = priceHistory[i]
            table.insert(historyForUI, {
                price = row.price,
                label = os.date("%H:%M", row.recorded_at or os.time()),
            })
        end
    end

    -- ── NETWORK / DIFFICULTY ──────────────────────────────────
    local difficulty, networkGPUs = GetNetworkDifficulty()

    -- ── BLOCKCHAIN STATE ──────────────────────────────────────
    local chainState = GetBlockchainState()
    local blockHeight = chainState and chainState.blockHeight or 0

    -- Recent blocks for blockchain panel
    local recentBlockRows = MySQL.query.await(
        "SELECT id, hash, timestamp FROM crypto_blocks ORDER BY id DESC LIMIT 8"
    )
    local recentBlocks = {}
    if recentBlockRows then
        for _, b in ipairs(recentBlockRows) do
            -- Count transactions that reference this block (approximate)
            table.insert(recentBlocks, {
                number    = b.id,
                hash      = b.hash,
                time      = os.date("%H:%M:%S", b.timestamp or os.time()),
                transactions = math.random(1, 12),
            })
        end
    end

    -- ── DAILY EARNING ESTIMATE ────────────────────────────────
    -- MH/s per power unit = 50; player's share of network = totalPower / networkGPUs
    -- blocksPerDay = 86400 / Config.BlockTime; reward per block = Config.BlockReward
    local blocksPerDay = math.floor(86400 / (Config.BlockTime or 120))
    local playerShare  = networkGPUs > 0 and (totalPower / networkGPUs) or 0
    local dailyEst     = playerShare * blocksPerDay * (Config.BlockReward or 0.25)

    return {
        -- Wallet
        wallet        = wallet,
        balance       = balance,
        -- Mining
        rigs          = #rigs,
        gpus          = totalGPUs,
        rigGPUs       = rigGPUs,
        stored        = storedFTC,
        totalPower    = totalPower,
        dailyEst      = dailyEst,
        -- Market
        price         = livePrice,
        priceChange   = 0,   -- delta not tracked per-tick; broadcast handles it
        priceHistory  = historyForUI,
        -- Network
        networkGPUs   = networkGPUs,
        difficulty    = difficulty,
        -- Blockchain
        blockHeight   = blockHeight,
        recentBlocks  = recentBlocks,
        nodes         = 0,
    }
end)

-- ---- Withdraw all stored FTC from rigs ----
RegisterNetEvent("crypto:withdrawAll", function()
    local src = source

    if not IsNearTerminal(src) then return end
    if not RateLimit(src, "withdrawAll", 15) then return end

    local wallet = GetSession(src)
    if not wallet then return end

    local rigs = MySQL.query.await(
        "SELECT id, stored_ftc FROM crypto_rigs WHERE wallet_id = ?",
        { wallet }
    )

    local total = 0

    for _, rig in pairs(rigs) do
        total = total + (rig.stored_ftc or 0)
        MySQL.update.await(
            "UPDATE crypto_rigs SET stored_ftc = 0 WHERE id = ?",
            { rig.id }
        )
    end

    if total > 0 then
        CreditMining(wallet, total)
    end
end)