-- =============================================================
-- Mining Module
-- All reward calculations are performed exclusively server-side.
-- (Review Notes 4, 5, 10, 12, 17)
-- =============================================================

local Miners = {}

-- ---- CalculateOutput: per-GPU FTC produced per tick based on age (Review Note 17) ----
-- Returns a base output value that declines linearly over the GPU's lifetime.
-- A brand-new GPU produces Config.SoloMiningReward per tick;
-- at Config.GPULife seconds it produces 0 (and is skipped by the caller).
local function CalculateOutput(age)
    local lifespan = Config.GPULife or 604800
    local base     = Config.SoloMiningReward or 0.001
    -- Linear decay: starts at base, reaches 0 at lifespan
    local decay = math.max(0, 1.0 - (age / lifespan))
    return base * decay
end

-- ---- GetCurrentBlockReward: applies halving every Config.HalvingInterval blocks ----
local function GetCurrentBlockReward()
    local state    = GetBlockchainState()
    local height   = state and state.blockHeight or 0
    local interval = Config.HalvingInterval or 500
    local halvings = math.floor(height / interval)
    -- Each halving halves the reward; floor at a minimum of 0.00000001
    return math.max(0.00000001, Config.BlockReward / (2 ^ halvings))
end

-- ---- Cached per-warehouse GPU power totals (Review Note 12) ----
local WarehousePowerCache = {}
local lastCacheRefresh    = 0
local CACHE_TTL           = 120 -- seconds

local function RefreshWarehousePowerCache()
    local now = os.time()
    if now - lastCacheRefresh < CACHE_TTL then return end

    local rigs = MySQL.query.await(
        "SELECT warehouse_id, gpu_slots FROM crypto_rigs WHERE power_on = 1"
    )

    local cache = {}
    for _, rig in ipairs(rigs) do
        local wid   = rig.warehouse_id
        local slots = json.decode(rig.gpu_slots or "[]")
        if type(slots) == "table" then
            cache[wid] = (cache[wid] or 0) + #slots
        end
    end

    WarehousePowerCache = cache
    lastCacheRefresh    = now
end

-- ---- Network difficulty (uses cached data where possible) ----
function GetNetworkDifficulty()
    RefreshWarehousePowerCache()

    local totalGPUs = 0
    for _, count in pairs(WarehousePowerCache) do
        totalGPUs = totalGPUs + count
    end

    local difficulty = math.max(
        Config.MinDifficulty,
        math.min(Config.MaxDifficulty, totalGPUs / Config.BaseNetworkGPUs)
    )

    return difficulty, totalGPUs
end

-- ---- Diminishing returns helper (Review Note 10) ----
-- Returns an effective GPU multiplier that scales down with quantity
local function DiminishingMultiplier(gpuCount)
    -- Square-root scaling: 4 GPUs ≈ 2x, 9 GPUs ≈ 3x, etc.
    return math.sqrt(math.max(1, gpuCount))
end

-- ---- Mining credit (all balance mutations go through transaction log) ----
function CreditMining(wallet, amount)
    if type(wallet) ~= "string" or type(amount) ~= "number" then return end
    if amount <= 0 then return end

    amount = math.floor(amount)

    -- Record transaction before touching balance (Review Note 8)
    local txId = MySQL.insert.await(
        "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
        { "MINING_POOL", wallet, amount, "mining", "pending" }
    )

    if not txId then return end

    QueueTransaction(txId, 5)
end

-- ---- Event: client requests to start mining ----
-- GPU count is NEVER trusted from the client; it is read from the database.
RegisterNetEvent("crypto:startMining", function()
    local src = source
    if not RateLimit(src, "startMining", 10) then return end

    local wallet = GetPlayerWallet(src)
    if not wallet then return end

    -- Fetch actual GPU count from DB (Review Note 1 / Note 4)
    local rig = MySQL.single.await(
        "SELECT gpu_slots FROM crypto_rigs WHERE wallet_id = ? AND power_on = 1 LIMIT 1",
        { wallet }
    )

    local gpuCount = 0
    if rig then
        local slots = json.decode(rig.gpu_slots or "[]")
        if type(slots) == "table" then
            gpuCount = #slots
        end
    end

    if gpuCount <= 0 then
        TriggerClientEvent("crypto:notify", src, "No active GPUs found.", "error")
        return
    end

    -- Apply diminishing returns so large farms don't inflate rewards (Review Note 10)
    local effectiveHashrate = DiminishingMultiplier(gpuCount) * 0.5

    Miners[src] = {
        wallet   = wallet,
        hashrate = effectiveHashrate
    }

    TriggerClientEvent("crypto:notify", src, "Mining started.", "success")
    CryptoDebug("Player", src, "started mining – gpus:", gpuCount, "effective hash:", effectiveHashrate)
end)

RegisterNetEvent("crypto:stopMining", function()
    local src = source
    Miners[src] = nil
end)

AddEventHandler("playerDropped", function()
    Miners[source] = nil
end)

-- ---- Batch mining reward cycle (Review Notes 5, 17) ----
-- A single server-side loop calculates rewards for all miners at once
-- instead of per-player ticks.
CreateThread(function()
    while true do
        Wait(Config.MiningInterval * 1000)

        local difficulty, totalNetworkGPUs = GetNetworkDifficulty()
        local blockReward = GetCurrentBlockReward()

        -- One global pass over all active miners (Review Note 5)
        for src, data in pairs(Miners) do
            -- Reward scaled against total network hashrate (Review Note 10)
            local networkShare = data.hashrate / math.max(1, totalNetworkGPUs)
            local reward = math.floor(networkShare * blockReward * Config.MiningRewardMultiplier)

            if reward > 0 then
                -- Log transaction (Review Note 8)
                MySQL.insert.await(
                    "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
                    { "NETWORK", data.wallet, reward, "mining_reward", "confirmed" }
                )
                -- Apply balance with clamping (Review Note 3)
                MySQL.update.await(
                    "UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?",
                    { reward, Config.MaxWalletBalance, data.wallet }
                )
                CryptoDebug("Mining reward –", data.wallet, "amount:", reward)
            end
        end
    end
end)

-- ---- Per-rig warehouse tick (batched, cached) (Review Notes 5, 12) ----
CreateThread(function()
    while true do
        Wait(Config.TickSeconds * 1000)

        -- Invalidate cache so next GetNetworkDifficulty call re-reads
        lastCacheRefresh = 0

        local difficulty, _ = GetNetworkDifficulty()
        local blockReward = GetCurrentBlockReward()

        local rigs = MySQL.query.await(
            "SELECT id, gpu_slots, power_on, cooling_installed FROM crypto_rigs"
        )

        local now = os.time()

        for _, rig in ipairs(rigs) do
            if rig.power_on ~= 1 or rig.cooling_installed ~= 1 then goto continue end

            local slots = json.decode(rig.gpu_slots or "[]")
            if type(slots) ~= "table" then goto continue end

            local produced  = 0
            local liveSlots = {}

            for _, gpu in ipairs(slots) do
                local age = now - (gpu.installed or now)
                if age < Config.GPULife then
                    produced = produced + (CalculateOutput(age) / math.max(1, difficulty))
                    liveSlots[#liveSlots + 1] = gpu
                end
                -- Expired GPUs are simply not added to liveSlots — cleaned up below
            end

            -- Persist cleaned slot list if any GPUs expired this tick
            if #liveSlots ~= #slots then
                MySQL.update.await(
                    "UPDATE crypto_rigs SET gpu_slots = ?, gpu_count = ? WHERE id = ?",
                    { json.encode(liveSlots), #liveSlots, rig.id }
                )
            end

            -- Apply diminishing returns per rig as well (Review Note 10)
            produced = math.floor(DiminishingMultiplier(#liveSlots) * produced * blockReward * 1000)

            if produced > 0 then
                MySQL.update.await(
                    "UPDATE crypto_rigs SET stored_ftc = stored_ftc + ? WHERE id = ?",
                    { produced, rig.id }
                )
            end

            ::continue::
        end
    end
end)

-- ---- Withdraw rig earnings ----
RegisterNetEvent("crypto:withdrawRig", function(rigId)
    local src = source

    if type(rigId) ~= "number" then return end
    if not RateLimit(src, "withdrawRig", 15) then return end

    local playerWallet = GetPlayerWallet(src)
    if not playerWallet then return end

    -- Verify rig ownership before any payout (Review Note 1)
    local rig = MySQL.single.await(
        "SELECT stored_ftc, wallet_id FROM crypto_rigs WHERE id = ? AND wallet_id = ?",
        { rigId, playerWallet }
    )

    if not rig then return end
    if rig.stored_ftc <= 0 then return end

    local rows = MySQL.update.await(
        "UPDATE crypto_rigs SET stored_ftc = 0 WHERE id = ? AND stored_ftc > 0",
        { rigId }
    )

    if not rows or rows == 0 then return end

    CreditMining(rig.wallet_id, rig.stored_ftc)
end)
