-- =============================================================
-- Warehouse Module
-- Validates ownership, GPU capacity, power limits, and inventory
-- before any installation or mutation. (Review Notes 1, 13)
-- =============================================================

-- ---- Buy a warehouse ----
RegisterNetEvent("crypto:buyWarehouse", function(warehouseType)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    -- Server validates type from config, not from client value (Review Note 1)
    if type(warehouseType) ~= "string" then return end

    local config = Config.Warehouses[warehouseType]
    if not config then return end
    if type(config.price) ~= "number" or config.price <= 0 then return end

    if not Player.Functions.RemoveMoney("bank", config.price, "crypto-warehouse") then
        return
    end

    MySQL.insert.await(
        "INSERT INTO crypto_warehouses (owner, location, power_capacity, power_usage) VALUES (?,?,?,0)",
        { Player.PlayerData.citizenid, warehouseType, config.power }
    )
end)

-- ---- Install GPUs ----
-- Validates: warehouse ownership, power limits, item ownership in inventory (Review Note 13)
RegisterNetEvent("crypto:installGPU", function(warehouseId, gpuType, count)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    if type(warehouseId) ~= "number" then return end
    if type(gpuType) ~= "string" then return end
    if type(count) ~= "number" then return end

    count = math.floor(count)

    if count <= 0 or count > Config.MaxGPUInstall then return end

    local gpu = Config.GPUs[gpuType]
    if not gpu then return end

    -- Verify warehouse ownership server-side (Review Note 13)
    local warehouse = MySQL.single.await(
        "SELECT owner, power_capacity, power_usage FROM crypto_warehouses WHERE id = ?",
        { warehouseId }
    )

    if not warehouse then return end
    if warehouse.owner ~= Player.PlayerData.citizenid then return end

    -- Enforce power limits (Review Note 13)
    local powerNeeded = gpu.electricity * count
    if powerNeeded <= 0 then return end
    if warehouse.power_usage + powerNeeded > warehouse.power_capacity then
        TriggerClientEvent("crypto:powerExceeded", src)
        return
    end

    -- Validate the player actually holds the GPU items in inventory (Review Note 13)
    -- Do NOT trust client inventory data; read from ox_inventory directly
    local gpuItemName = "gpu_" .. gpuType
    local held = exports.ox_inventory:Search(src, "count", gpuItemName)
    if not held or held < count then
        TriggerClientEvent("crypto:notify", src, "You don't have enough GPU items.", "error")
        return
    end

    -- Remove items server-side before installing (Review Note 13)
    if not exports.ox_inventory:RemoveItem(src, gpuItemName, count) then
        TriggerClientEvent("crypto:notify", src, "Failed to remove GPU items.", "error")
        return
    end

    MySQL.insert.await(
        "INSERT INTO crypto_rigs (owner, gpu_type, gpu_count, hashrate, warehouse_id) VALUES (?,?,?,?,?)",
        { Player.PlayerData.citizenid, gpuType, count, gpu.power * count, warehouseId }
    )

    MySQL.update.await(
        "UPDATE crypto_warehouses SET power_usage = power_usage + ? WHERE id = ?",
        { powerNeeded, warehouseId }
    )
end)

-- ---- Electricity billing cycle ----
CreateThread(function()
    while true do
        Wait(600000)

        local warehouses = MySQL.query.await(
            "SELECT owner, power_usage FROM crypto_warehouses WHERE power_usage > 0"
        )

        for _, w in ipairs(warehouses) do
            local cost = math.floor(w.power_usage * Config.PowerCostPerKW)
            if cost <= 0 then goto continue end

            -- Find the online player by citizenid (GetPlayerByCitizenId is not a standard
            -- Qbox export — iterate active players instead)
            local onlinePlayer = nil
            for _, src in ipairs(GetPlayers()) do
                local p = exports.qbx_core:GetPlayer(tonumber(src))
                if p and p.PlayerData.citizenid == w.owner then
                    onlinePlayer = p
                    break
                end
            end

            if onlinePlayer then
                onlinePlayer.Functions.RemoveMoney("bank", cost, "crypto-electricity")
            else
                -- Player is offline — deduct directly from the players table
                MySQL.update.await(
                    "UPDATE players SET money = JSON_SET(money, '$.bank', GREATEST(0, JSON_EXTRACT(money, '$.bank') - ?)) WHERE citizenid = ?",
                    { cost, w.owner }
                )
            end

            ::continue::
        end
    end
end)
        end
    end
end)

-- ---- Mining reward distribution for warehouse rigs ----
-- Rewards are batched globally per interval; transaction log is created per payment.
-- (Review Notes 5, 8, 12, 17)
CreateThread(function()
    while true do
        Wait(Config.MiningInterval * 1000)

        -- JOIN on wallet_id, not owner — rigs may be connected to non-owner wallets
        -- via crypto:connectRigWallet (Bug fix: wrong join key)
        local rigs = MySQL.query.await([[
            SELECT
                r.hashrate,
                r.gpu_count,
                r.wallet_id
            FROM crypto_rigs r
            JOIN crypto_warehouses wh ON wh.id = r.warehouse_id
            WHERE wh.power_usage <= wh.power_capacity
              AND r.hashrate > 0
              AND r.wallet_id IS NOT NULL
              AND r.power_on = 1
        ]])

        local totalHashrate = 0
        for _, rig in ipairs(rigs) do
            totalHashrate = totalHashrate + rig.hashrate
        end

        local blockReward = GetCurrentBlockReward()

        for _, rig in ipairs(rigs) do
            local share  = (totalHashrate > 0) and (rig.hashrate / totalHashrate) or 0
            local reward = math.floor(share * blockReward * Config.MiningRewardMultiplier)

            if reward > 0 and rig.wallet_id then
                MySQL.insert.await(
                    "INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())",
                    { "WAREHOUSE_POOL", rig.wallet_id, reward, "warehouse_mining", "confirmed" }
                )
                MySQL.update.await(
                    "UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?",
                    { reward, Config.MaxWalletBalance, rig.wallet_id }
                )
            end
        end
    end
end)
