local walletOpen = false

RegisterNetEvent("crypto:openWallet", function()
    if walletOpen then return end
    walletOpen = true

    TriggerServerEvent("crypto:getBalance")
end)

RegisterNetEvent("crypto:updateBalance", function(balance, walletAddress)
    SendNUIMessage({
        action        = "updateBalance",
        balance       = balance,
        walletAddress = walletAddress,
    })
end)

RegisterNUICallback("closeWallet", function(_, cb)
    walletOpen = false
    cb({})
end)

RegisterNetEvent("fcrypto:inspectWallet", function(slot)
    local options = {
        {
            title = "Enter Passcode",
            event = "fcrypto:enterPasscode",
            args  = slot
        },
        {
            title = "Attempt Crack",
            event = "fcrypto:startCrack",
            args  = slot
        }
    }
    lib.registerContext({
        id      = "wallet_menu",
        title   = "Crypto Wallet",
        options = options
    })
    lib.showContext("wallet_menu")
end)