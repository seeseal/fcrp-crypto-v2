RegisterNUICallback("buyCrypto", function(data,cb)

    local amount = tonumber(data.amount)

    if not amount then
        cb({})
        return
    end

    TriggerServerEvent("crypto:buy", amount)

    cb({})

end)

RegisterNUICallback("sellCrypto", function(data,cb)

    local amount = tonumber(data.amount)

    if not amount then
        cb({})
        return
    end

    TriggerServerEvent("crypto:sell", amount)

    cb({})

end)
