RegisterNUICallback("crackWallet", function(data,cb)

    local targetWallet = tonumber(data.wallet)

    if not targetWallet then
        cb({})
        return
    end

    TriggerServerEvent("crypto:attemptCrack", targetWallet)

    cb({})

end)

RegisterNetEvent("crypto:crackSuccess", function(wallet,balance)

    SendNUIMessage({
        action = "crackSuccess",
        wallet = wallet,
        balance = balance
    })

end)

RegisterNetEvent("crypto:crackFailed", function()

    SendNUIMessage({
        action = "crackFailed"
    })

end)
