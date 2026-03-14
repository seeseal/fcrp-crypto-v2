-- =============================================================
-- Debug Module
-- All output is gated behind Config.Debug (disabled in production).
-- (Review Note 2)
-- =============================================================

local function DebugPrint(...)
    if not Config.Debug then return end

    local parts = { "[CRYPTO DEBUG]" }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end

    print(table.concat(parts, " "))
end

-- Public alias used throughout server modules
function CryptoDebug(...)
    DebugPrint(...)
end
