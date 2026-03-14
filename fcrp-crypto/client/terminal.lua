-- ── TABLET PROP / ANIMATION CONFIG ───────────────────────────
local ANIM_DICT = 'amb@world_human_seat_wall_tablet@female@base'
local PROP_MODEL = 'prop_cs_tablet'
local PROP_BONE  = 28422   -- right hand

local tabletProp = nil

local function LoadDict(dict)
    RequestAnimDict(dict)
    local t = 0
    while not HasAnimDictLoaded(dict) do
        Wait(100)
        t = t + 100
        if t > 5000 then break end
    end
end

local function LoadModel(model)
    local hash = GetHashKey(model)
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) do
        Wait(100)
        t = t + 100
        if t > 5000 then break end
    end
    return hash
end

local function SpawnTabletProp()
    if tabletProp then return end
    local ped   = PlayerPedId()
    local hash  = LoadModel(PROP_MODEL)
    local coord = GetEntityCoords(ped)
    local boneIdx = GetPedBoneIndex(ped, PROP_BONE)

    tabletProp = CreateObject(hash, coord, true, true, true)
    AttachEntityToEntity(tabletProp, ped, boneIdx,
        0.0, 0.0, 0.03,
        0.0, 0.0, 0.0,
        true, true, false, true, 0, true)

    SetModelAsNoLongerNeeded(hash)
end

local function RemoveTabletProp()
    if tabletProp then
        DetachEntity(tabletProp, true, true)
        DeleteEntity(tabletProp)
        tabletProp = nil
    end
end

-- ── OPEN TERMINAL ─────────────────────────────────────────────
-- ox_target fires this as a LOCAL client event.
-- We forward it to the server so proximity + rate-limit are validated.
-- The server responds with crypto:terminalUI, which nui_bridge.lua
-- handles to actually open the NUI with wallet/dashboard data.
RegisterNetEvent('crypto:openTerminal', function()
    TriggerServerEvent('crypto:openTerminal')
end)

-- ── TERMINAL UI OPEN (called by nui_bridge after server responds) ──
-- Spawn prop + animation BEFORE the NUI opens so it looks seamless.
RegisterNetEvent('crypto:tabletOpen', function()
    local ped = PlayerPedId()
    LoadDict(ANIM_DICT)
    SpawnTabletProp()

    if not IsEntityPlayingAnim(ped, ANIM_DICT, 'base', 3) then
        TaskPlayAnim(ped, ANIM_DICT, 'base', 8.0, 1.0, -1, 49, 1.0, 0, 0, 0)
    end
end)

-- ── CLOSE TERMINAL ────────────────────────────────────────────
RegisterNUICallback('closeTerminal', function(_, cb)
    SetNuiFocus(false, false)
    RemoveTabletProp()
    ClearPedTasks(PlayerPedId())
    cb({})
end)