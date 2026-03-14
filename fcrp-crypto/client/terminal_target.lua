CreateThread(function()
    for i, pos in ipairs(Config.Terminals) do
        exports.ox_target:addBoxZone({
            coords   = pos,
            size     = vec3(1.2, 1.2, 1.2),
            rotation = 0,
            debug    = false,
            options  = {
                {
                    name  = "crypto_terminal_" .. i,
                    label = "Access Crypto Terminal",
                    icon  = "fa-solid fa-bitcoin",
                    event = "crypto:openTerminal"
                }
            }
        })
    end
end)
