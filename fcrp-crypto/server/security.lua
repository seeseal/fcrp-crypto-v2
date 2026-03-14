-- =============================================================
-- Security Module
-- Rate limiting, session management, and wallet verification.
-- (Review Notes 1, 6, 11)
-- =============================================================

local cooldowns     = {}
local WalletSessions = {}

-- ---- Rate limiting (Review Note 6) ----
function RateLimit(src, key, time)
    cooldowns[src] = cooldowns[src] or {}
    local last = cooldowns[src][key]
    if last and os.time() - last < time then
        return false
    end
    cooldowns[src][key] = os.time()
    return true
end

AddEventHandler("playerDropped", function()
    local src = source
    cooldowns[src]      = nil
    WalletSessions[src] = nil
end)

-- ---- Session management ----
function SetSession(src, id, slot)
    WalletSessions[src] = {
        wallet = id,
        slot   = slot,
        opened = os.time()
    }
end

function GetSession(src)
    return WalletSessions[src] and WalletSessions[src].wallet
end

function GetSessionSlot(src)
    return WalletSessions[src] and WalletSessions[src].slot
end

function GetPlayerWallet(src)
    local s = WalletSessions[src]
    if not s then return nil end
    return s.wallet
end

-- ---- Wallet ownership verification (Review Note 1) ----
local function GetIdentifier(src)
    local Player = exports.qbx_core:GetPlayer(src)
    if not Player then return nil end
    return Player.PlayerData.citizenid
end

local function VerifyWalletOwnership(src, walletId)
    local identifier = GetIdentifier(src)
    if not identifier then return false end
    local row = MySQL.single.await(
        'SELECT owner FROM crypto_wallets WHERE wallet_id = ?',
        { walletId }
    )
    -- A NULL owner means the wallet was created without binding — deny session access
    if not row or not row.owner then return false end
    return row.owner == identifier
end

-- ---- Session registration (kicked if spoofed) (Review Note 1) ----
RegisterNetEvent("crypto:setSession", function(walletId, slot)
    local src = source
    if not VerifyWalletOwnership(src, walletId) then
        DropPlayer(src, "crypto exploit detected")
        return
    end
    SetSession(src, walletId, slot)
end)

-- ---- Wallet passcode verification (Review Note 6) ----
-- Passcode is verified against the DB record — never from item metadata,
-- which is client-readable. (Security fix: passcode removed from metadata)
RegisterNetEvent("fcrypto:verifyWallet", function(slot, code)
    local src = source

    if not RateLimit(src, "verifyWallet", Config.EventCooldown) then
        TriggerClientEvent('ox_lib:notify', src, {
            description = "Too many attempts. Please wait.",
            type        = "error"
        })
        return
    end

    if type(slot) ~= "number" or code == nil then return end

    local item = exports.ox_inventory:GetSlot(src, slot)
    if not item or not item.metadata then return end

    local meta = item.metadata

    -- Fetch the authoritative record from the DB
    local row = MySQL.single.await(
        'SELECT passcode, locked, attempts FROM crypto_wallets WHERE wallet_id = ?',
        { meta.wallet_id }
    )

    if not row then return end

    if row.locked == 1 then
        TriggerClientEvent('ox_lib:notify', src, {
            description = "Wallet locked.",
            type        = "error"
        })
        return
    end

    if tostring(code) == tostring(row.passcode) then
        SetSession(src, meta.wallet_id, slot)
        -- Reset attempts in DB on success
        MySQL.update.await(
            'UPDATE crypto_wallets SET attempts = 0 WHERE wallet_id = ?',
            { meta.wallet_id }
        )
        -- Sync item metadata (locked/attempts only — no passcode)
        meta.locked   = false
        meta.attempts = 0
        exports.ox_inventory:SetMetadata(src, slot, meta)
        TriggerClientEvent('ox_lib:notify', src, {
            description = "Wallet connected.",
            type        = "success"
        })
    else
        local newAttempts = (row.attempts or 0) + 1
        local locked = newAttempts >= Config.MaxAttempts

        MySQL.update.await(
            'UPDATE crypto_wallets SET attempts = ?, locked = ? WHERE wallet_id = ?',
            { newAttempts, locked and 1 or 0, meta.wallet_id }
        )

        meta.attempts = newAttempts
        meta.locked   = locked
        exports.ox_inventory:SetMetadata(src, slot, meta)

        if locked then
            TriggerClientEvent('ox_lib:notify', src, {
                description = "Too many failed attempts. Wallet locked.",
                type        = "error"
            })
        else
            TriggerClientEvent('ox_lib:notify', src, {
                description = ("Wrong passcode. %d attempt(s) remaining."):format(Config.MaxAttempts - newAttempts),
                type        = "error"
            })
        end
    end
end)

-- ---- Helpers used by other modules ----
function GetPlayer(src)
    return exports.qbx_core:GetPlayer(src)
end

AddEventHandler("onResourceStop", function(resource)
    if resource ~= GetCurrentResourceName() then return end
    WalletSessions = {}
    cooldowns      = {}
end)
