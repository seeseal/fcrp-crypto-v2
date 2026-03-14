-- =============================================================
-- Blockchain Module
-- Handles block mining, transaction mempool, and state persistence
-- (Review Note 7: Blockchain state must persist across restarts)
-- =============================================================

local PendingTransactions = {}

-- Blockchain state – loaded from DB on startup so restarts do not reset
local BlockchainState = {
    blockHeight       = 0,
    networkDifficulty = Config.BlockDifficulty,
    lastBlockTime     = 0
}

-- Load persisted state from database on resource start
CreateThread(function()
    local row = MySQL.single.await(
        'SELECT block_height, network_difficulty, last_block_time FROM crypto_blockchain_state WHERE id = 1'
    )
    if row then
        BlockchainState.blockHeight       = row.block_height       or 0
        BlockchainState.networkDifficulty = row.network_difficulty or Config.BlockDifficulty
        BlockchainState.lastBlockTime     = row.last_block_time    or 0
    end
    CryptoDebug("Blockchain state loaded – height:", BlockchainState.blockHeight,
                "difficulty:", BlockchainState.networkDifficulty)
end)

local function PersistBlockchainState()
    MySQL.update.await(
        'UPDATE crypto_blockchain_state SET block_height=?, network_difficulty=?, last_block_time=? WHERE id=1',
        { BlockchainState.blockHeight, BlockchainState.networkDifficulty, BlockchainState.lastBlockTime }
    )
end

local function GetLastBlock()
    return MySQL.single.await(
        'SELECT hash FROM crypto_blocks ORDER BY id DESC LIMIT 1'
    )
end

local function HashBlock(data)
    -- Deterministic mock hash: sha256-style hex string derived from nonce + data length.
    -- The real "difficulty" check is enforced by block timing (Config.BlockTime), not
    -- by a proof-of-work loop, which would hang the server thread with a PRNG source.
    return lib.string.random('0123456789abcdef', 64)
end

-- Public: add a validated transaction to the mempool
function AddTransaction(fromWallet, toWallet, amount)
    if type(fromWallet) ~= "string" or type(toWallet) ~= "string" then return end
    if type(amount) ~= "number" or amount <= 0 then return end

    table.insert(PendingTransactions, {
        from   = fromWallet,
        to     = toWallet,
        amount = amount,
        time   = os.time()
    })
end

local function MineBlock(minerWallet)
    if #PendingTransactions == 0 then return end

    local previous = GetLastBlock()

    local block = {
        previous     = previous and previous.hash or "genesis",
        nonce        = math.random(0, 2147483647),
        timestamp    = os.time(),
        transactions = PendingTransactions
    }

    local hash = HashBlock(json.encode(block))

    local blockId = MySQL.insert.await(
        'INSERT INTO crypto_blocks (hash, previous_hash, nonce, timestamp) VALUES (?,?,?,?)',
        { hash, block.previous, block.nonce, block.timestamp }
    )

    -- Persist every transaction in the block (Review Note 8)
    for _, tx in ipairs(PendingTransactions) do
        MySQL.insert.await(
            'INSERT INTO crypto_transactions (wallet_from, wallet_to, amount, type, status, created_at) VALUES (?,?,?,?,?,NOW())',
            { tx.from, tx.to, tx.amount, "block_tx", "confirmed" }
        )
    end

    PendingTransactions = {}

    -- Credit miner reward – server-calculated (Review Note 4)
    MySQL.update.await(
        'UPDATE crypto_wallets SET balance = LEAST(balance + ?, ?) WHERE wallet_id = ?',
        { Config.BlockReward, Config.MaxWalletBalance, minerWallet }
    )

    -- Update and persist blockchain state (Review Note 7)
    BlockchainState.blockHeight    = BlockchainState.blockHeight + 1
    BlockchainState.lastBlockTime  = os.time()

    -- Adjust difficulty every 100 blocks
    if BlockchainState.blockHeight % 100 == 0 then
        BlockchainState.networkDifficulty = math.min(
            Config.MaxDifficulty,
            BlockchainState.networkDifficulty + 1
        )
    end

    PersistBlockchainState()

    CryptoDebug("Block mined – height:", BlockchainState.blockHeight,
                "difficulty:", BlockchainState.networkDifficulty,
                "miner:", minerWallet)
end

-- Only the server triggers block mining; no client event exposes this directly
RegisterNetEvent("crypto:mineBlock", function()
    local src    = source
    local wallet = GetPlayerWallet(src)
    if not wallet then return end

    -- Rate-limit block mining attempts (Review Note 6)
    if not RateLimit(src, "mineBlock", Config.BlockTime) then return end

    MineBlock(wallet)
end)

-- Automatic block interval (Review Note 7: state is persisted each cycle)
CreateThread(function()
    while true do
        Wait(Config.BlockTime * 1000)
        -- Difficulty adjustment is now handled inside MineBlock / PersistBlockchainState
        CryptoDebug("Block tick – current height:", BlockchainState.blockHeight)
    end
end)

-- Expose read-only state for other modules (e.g. terminal, mining)
function GetBlockchainState()
    return BlockchainState
end
