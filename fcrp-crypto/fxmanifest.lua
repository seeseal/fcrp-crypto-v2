fx_version 'cerulean'
game 'gta5'

lua54 'yes'

name 'fcrp-crypto'
description 'QBX Crypto System'
version '2.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/database.lua',
    'server/blockchain.lua',
    'server/cracking.lua',
    'server/darkmarket.lua',
    'server/debug.lua',
    'server/exchange.lua',
    'server/market.lua',
    'server/mining.lua',
    'server/payments.lua',
    'server/robbery.lua',
    'server/security.lua',
    'server/terminal.lua',
    'server/transactions.lua',
    'server/wallet.lua',
    'server/warehouse.lua',
}

client_scripts {
    'client/cracking.lua',
    'client/terminal.lua',
    'client/terminal_target.lua',
    'client/trading.lua',
    'client/wallet.lua',
    'client/nui_bridge.lua',
}

files {
    'sql/crypto.sql',
}

dependencies {
    'qbx_core',
    'ox_inventory',
    'oxmysql',
    'ox_lib'
}

ui_page 'ui/index.html'

files {
    'ui/index.html',
    'ui/app.js',
    'ui/images/*.png',
    'ui/images/*.jpg',
    'ui/*.png',
    'ui/*.jpg',
    'ui/*.svg'
}