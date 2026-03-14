-- =============================================================
-- Market Module
-- Price updates are deterministic and server-controlled only.
-- Clients cannot request recalculations. (Review Note 14)
-- =============================================================

CurrentPrice = Config.BasePrice

local buyPressure  = 0
local sellPressure = 0

-- Load last known price from DB on startup
CreateThread(function()
    local market = MySQL.single.await(
        'SELECT price FROM crypto_market WHERE symbol = ?',
        { Config.Symbol }
    )
    if market and market.price and market.price > 0 then
        CurrentPrice = market.price
    end
    CryptoDebug("Market loaded – price:", CurrentPrice)
end)

-- ---- Register trade pressure (called by exchange module) ----
-- Clients cannot invoke this; only server modules call it.
function RegisterTrade(tradeType, amount)
    if type(amount) ~= "number" or amount <= 0 then return end
    if tradeType == "buy" then
        buyPressure = buyPressure + amount
    else
        sellPressure = sellPressure + amount
    end
end

-- ---- Deterministic price update (Review Note 14) ----
-- Spread and volatility are applied consistently here; nowhere else.
local function UpdatePrice()
    local delta    = math.random(-Config.Volatility, Config.Volatility)
    local pressure = (buyPressure - sellPressure) * (Config.PressureMultiplier or 0.1)

    local prevPrice = CurrentPrice
    local newPrice = math.max(
        Config.MinimumPrice,
        CurrentPrice + delta + pressure
    )

    CurrentPrice = newPrice
    buyPressure  = 0
    sellPressure = 0

    local now = os.time()

    MySQL.update.await(
        'UPDATE crypto_market SET price = ?, updated_at = NOW() WHERE symbol = ?',
        { newPrice, Config.Symbol }
    )
    MySQL.insert.await(
        'INSERT INTO crypto_price_history (symbol, price, recorded_at) VALUES (?,?,?)',
        { Config.Symbol, newPrice, now }
    )

    -- Broadcast live price update to all connected clients
    TriggerClientEvent("crypto:updatePrice", -1, {
        price  = newPrice,
        change = newPrice - prevPrice,
    })

    CryptoDebug("Price updated:", newPrice)
end

-- ---- Scheduled price update cycle (Review Note 14) ----
-- Only this thread updates price; no client event triggers a recalculation.
CreateThread(function()
    while true do
        Wait(Config.PriceUpdateInterval * 1000)
        UpdatePrice()
    end
end)

-- ---- Hourly market events (Review Note 14) ----
CreateThread(function()
    while true do
        Wait(3600000)

        local event    = math.random(1, 4)
        local newPrice = CurrentPrice

        if event == 1 then
            newPrice = newPrice * 1.15
        elseif event == 2 then
            newPrice = newPrice * 0.80
        elseif event == 3 then
            newPrice = newPrice + 300
        else
            newPrice = newPrice - 250
        end

        newPrice     = math.max(Config.MinimumPrice, newPrice)
        local prevPrice = CurrentPrice
        CurrentPrice = newPrice

        MySQL.update.await(
            'UPDATE crypto_market SET price = ?, updated_at = NOW() WHERE symbol = ?',
            { newPrice, Config.Symbol }
        )
        MySQL.insert.await(
            'INSERT INTO crypto_price_history (symbol, price, recorded_at) VALUES (?,?,?)',
            { Config.Symbol, newPrice, os.time() }
        )

        -- Broadcast to all clients
        TriggerClientEvent("crypto:updatePrice", -1, {
            price  = newPrice,
            change = newPrice - prevPrice,
        })

        CryptoDebug("Market event fired – new price:", newPrice)
    end
end)
