Config = {}
Config.Debug = false -- Disabled for production; enable only on staging environments

Config.Symbol = "FTC"
Config.BasePrice = 2500
Config.MinimumPrice = 1

Config.Volatility = 25
Config.PriceUpdateInterval = 600
Config.PressureMultiplier = 0.1   -- how strongly buy/sell volume moves the price

Config.ExchangeSpread = 0.03
Config.TransactionFee = 0.02
Config.TransactionDelay = { 2, 5 } -- seconds {min, max} before exchange tx confirms

Config.MaxWalletBalance = 100000000

Config.EventCooldown = 2

Config.CrackChance = 0.55
Config.CrackWipeChance = 0.25
Config.MaxAttempts = 3

Config.BlockTime = 120
Config.BlockDifficulty = 4

Config.BlockReward = 0.25
Config.HalvingInterval = 500

Config.MiningInterval = 60

Config.GPUs = {

    basic = {
        power = 0.5,
        electricity = 0.6,
        price = 5000
    },

    advanced = {
        power = 1.5,
        electricity = 1.2,
        price = 15000
    },

    industrial = {
        power = 4.0,
        electricity = 3.0,
        price = 45000
    }

}

Config.Terminals = {

    vector3(148.89,-1040.12,29.37),
    vector3(-1212.94,-331.13,37.78),
    vector3(1175.06,2707.19,38.09)

}

Config.DarkMarket = {

    multiplier = 1.4,
    deliveryTime = 600

}

Config.Warehouses = {

    small = {
        power = 50,
        price = 150000
    },

    medium = {
        power = 120,
        price = 350000
    },

    industrial = {
        power = 300,
        price = 900000
    }

}

Config.MaxGPUInstall = 10
Config.MiningRewardMultiplier = 2
Config.PowerCostPerKW = 1
Config.SoloMiningReward = 0.001
Config.MinDifficulty = 0.5
Config.MaxDifficulty = 5
Config.BaseNetworkGPUs = 100
Config.GPULife = 604800
Config.TickSeconds = 60
