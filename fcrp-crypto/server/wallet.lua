-- =============================================================
-- Wallet Module
-- Responsible for balance retrieval and wallet ownership only.
-- No pricing or mining logic lives here. (Review Notes 1, 3, 16)
-- =============================================================

-- ---- Balance clamping helper (Review Note 3) ----
local function ClampBalance(amount)
    if type(amount) ~= "number" then return 0 end
    if amount < 0 then return 0 end
    if amount > Config.MaxWalletBalance then return Config.MaxWalletBalance end
    return math.floor(amount)
end

-- ---- Ethereum-style wallet ID generator ----
local _hex = "0123456789abcdef"

local function GenerateWalletID()
    local addr
    repeat
        addr = "0x"
        for i = 1, 40 do
            local r = math.random(#_hex)
            addr = addr .. _hex:sub(r, r)
        end
        local exists = MySQL.scalar.await(
            "SELECT 1 FROM crypto_wallets WHERE wallet_id = ?",
            { addr }
        )
    until not exists
    return addr
end

-- ---- Read wallet balance (session wallet only – no arbitrary walletId from client) ----
RegisterNetEvent("crypto:getBalance", function()
    local src    = source
    local wallet = GetPlayerWallet(src)
    if not wallet then return end

    local balance = MySQL.scalar.await(
        'SELECT balance FROM crypto_wallets WHERE wallet_id = ?',
        { wallet }
    )

    -- Send wallet_id WITH balance so the NUI can display the connected address
    TriggerClientEvent("crypto:updateBalance", src, ClampBalance(balance or 0), wallet)
end)

-- ---- Wallet creation (one per player, tied to citizenid) ----
RegisterNetEvent("crypto:createWallet", function(passcode)
    local src    = source
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    local exists = MySQL.scalar.await(
        'SELECT id FROM crypto_wallets WHERE owner = ?',
        { citizenid }
    )
    if exists then return end

    -- Validate passcode supplied by client UI (Option A: player sets PIN)
    passcode = tostring(passcode or "")
    if #passcode < 4 then return end

    local wallet = GenerateWalletID()

    MySQL.insert.await([[
        INSERT INTO crypto_wallets
        (wallet_id, owner, balance, passcode, locked, attempts, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], {
        wallet,
        citizenid,
        0,
        passcode,
        1,
        0,
        os.time()
    })

    -- Set the session so the terminal can immediately look up this wallet
    SetSession(src, wallet, nil)
    -- Notify client so the UI can display the real wallet address
    TriggerClientEvent("crypto:walletCreated", src, wallet)
end)

-- ---- Physical wallet item creation ----
function CreateWallet(passcode, owner)
    -- passcode is optional; owner is the citizenid (may be nil for unbound physical wallets)
    passcode = tostring(passcode or math.random(1000, 9999))
    local walletId = GenerateWalletID()
    local wallet = {
        wallet_id = walletId,
        passcode  = passcode,
        locked    = false,
        attempts  = 0
    }
    MySQL.insert.await([[
        INSERT INTO crypto_wallets
        (wallet_id, owner, balance, passcode, locked, attempts, created_at)
        VALUES (?, ?, 0, ?, ?, ?, ?)
    ]], {
        wallet.wallet_id,
        owner or nil,
        wallet.passcode,
        1,
        0,
        os.time()
    })
    return wallet
end

RegisterCommand("createwallet", function(src)
    -- Open the PIN prompt in the NUI; creation happens in crypto:createPhysicalWallet
    TriggerClientEvent("crypto:promptPin", src)
end, false)

-- ---- Physical wallet creation after player sets PIN ----
RegisterNetEvent("crypto:createPhysicalWallet", function(passcode)
    local src = source

    passcode = tostring(passcode or "")
    if #passcode < 4 then return end

    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local ok, err = pcall(function()
        local wallet = CreateWallet(passcode, citizenid)
        if not wallet then
            print("[CRYPTO] CreateWallet() returned nil for src:", src)
            return
        end
        print("[CRYPTO] Wallet created:", wallet.wallet_id, "owner:", citizenid)
        -- Do NOT include passcode in metadata — it is stored only in crypto_wallets
        exports.ox_inventory:AddItem(src, 'crypto_wallet', 1, {
            wallet_id = wallet.wallet_id,
            locked    = true,
            attempts  = 0,
        })
        -- Open the session so the player can immediately use the terminal
        SetSession(src, wallet.wallet_id, nil)
        TriggerClientEvent("crypto:walletCreated", src, wallet.wallet_id)
    end)
    if not ok then
        print("[CRYPTO] crypto:createPhysicalWallet ERROR:", tostring(err))
    end
end)

-- ---- Load wallet balance by wallet_id ----
function LoadWallet(walletId)
    if type(walletId) ~= "string" or #walletId == 0 then return nil end
    local row = MySQL.single.await(
        'SELECT balance FROM crypto_wallets WHERE wallet_id = ?',
        { walletId }
    )
    if not row then return nil end
    return ClampBalance(row.balance)
end

-- ---- Add balance with clamping (Review Note 3) ----
function AddBalance(walletId, amount)
    if type(walletId) ~= "string" or #walletId == 0 then return false end
    if type(amount) ~= "number" or amount <= 0 then return false end
    amount = ClampBalance(amount)
    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
        { amount, Config.MaxWalletBalance, walletId }
    )
    return true
end

-- ---- GetWalletBalance (used by terminal and other modules) ----
function GetWalletBalance(walletId)
    if type(walletId) ~= "string" or #walletId == 0 then return 0 end
    local val = MySQL.scalar.await(
        'SELECT balance FROM crypto_wallets WHERE wallet_id = ?',
        { walletId }
    )
    return ClampBalance(val or 0)
end

-- ---- Rig wallet connection: verify ownership before linking ----
RegisterNetEvent("crypto:connectRigWallet", function(rigId, wallet)
    local src = source

    if type(rigId) ~= "number" then return end
    if type(wallet) ~= "string" or #wallet == 0 then return end

    local playerWallet = GetPlayerWallet(src)
    if not playerWallet then return end

    -- Player may only link their own session wallet (Review Note 1)
    if wallet ~= playerWallet then return end

    MySQL.update.await(
        "UPDATE crypto_rigs SET wallet_id = ? WHERE id = ?",
        { wallet, rigId }
    )
end)