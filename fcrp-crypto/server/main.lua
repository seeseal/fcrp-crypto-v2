-- =============================================================
-- Main Module
-- Economy health metrics. (Review Note 15)
-- Database validation is handled by server/database.lua.
-- =============================================================
-- Logs total supply, active miners, reward distribution, and exchange volume
-- periodically so administrators can monitor economic balance.
CreateThread(function()
    while true do
        Wait(1800000) -- every 30 minutes

        local totalSupply = MySQL.scalar.await(
            'SELECT COALESCE(SUM(balance), 0) FROM crypto_wallets'
        )

        local activeMiners = MySQL.scalar.await(
            'SELECT COUNT(DISTINCT owner) FROM crypto_rigs WHERE power_on = 1'
        )

        local rewardDist = MySQL.scalar.await([[
            SELECT COALESCE(SUM(amount), 0)
            FROM crypto_transactions
            WHERE type IN ('mining_reward', 'warehouse_mining', 'mining')
              AND created_at >= NOW() - INTERVAL 30 MINUTE
        ]])

        local exchangeVol = MySQL.scalar.await([[
            SELECT COALESCE(SUM(amount), 0)
            FROM crypto_transactions
            WHERE type IN ('buy', 'sell')
              AND created_at >= NOW() - INTERVAL 30 MINUTE
        ]])

        MySQL.insert.await(
            'INSERT INTO crypto_economy_metrics (total_supply, active_miners, total_reward_dist, exchange_volume, recorded_at) VALUES (?,?,?,?,NOW())',
            { totalSupply or 0, activeMiners or 0, rewardDist or 0, exchangeVol or 0 }
        )

        if Config.Debug then
            print(("[CRYPTO METRICS] Supply:%s Miners:%s Rewards(30m):%s Exchange(30m):%s"):format(
                tostring(totalSupply), tostring(activeMiners),
                tostring(rewardDist),  tostring(exchangeVol)
            ))
        end
    end
end)
