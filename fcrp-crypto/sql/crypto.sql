-- =============================================================
-- Crypto Database Schema
-- =============================================================

-- Table: wallets
-- Using BIGINT for balance to prevent overflow/precision issues (Review Note 3)
CREATE TABLE IF NOT EXISTS crypto_wallets (
 id INT AUTO_INCREMENT PRIMARY KEY,
 wallet_id VARCHAR(64) NOT NULL UNIQUE,
 owner VARCHAR(64) NULL,
 balance DECIMAL(20,8) DEFAULT 0,
 passcode VARCHAR(10),
 locked TINYINT DEFAULT 1,
 attempts INT DEFAULT 0,
 created_at INT
);

-- Index for fast lookup
CREATE INDEX IF NOT EXISTS idx_wallet_owner ON crypto_wallets(owner);
CREATE INDEX IF NOT EXISTS idx_wallet_id    ON crypto_wallets(wallet_id);

-- =============================================================

-- Table: transactions
-- Full ledger entry for every wallet mutation (Review Note 8)
CREATE TABLE IF NOT EXISTS crypto_transactions (
    tx_id        VARCHAR(20) PRIMARY KEY,
    wallet_from  VARCHAR(20),
    wallet_to    VARCHAR(20),
    amount       BIGINT,
    fee          BIGINT DEFAULT 0,
    type         VARCHAR(30),
    status       VARCHAR(20) DEFAULT 'pending',
    confirmed_at DATETIME,
    created_at   DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_tx_wallet_from ON crypto_transactions(wallet_from);
CREATE INDEX IF NOT EXISTS idx_tx_wallet_to   ON crypto_transactions(wallet_to);

-- =============================================================

-- Table: blocks
-- Stores mined blocks
CREATE TABLE IF NOT EXISTS crypto_blocks (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    hash          VARCHAR(128),
    previous_hash VARCHAR(128),
    nonce         INT,
    timestamp     INT
);

-- =============================================================

-- Table: mining rigs
-- Tracks GPU installations
CREATE TABLE IF NOT EXISTS crypto_rigs (
    id                INT AUTO_INCREMENT PRIMARY KEY,
    owner             VARCHAR(50),
    wallet_id         VARCHAR(20),
    gpu_type          VARCHAR(20),
    gpu_slots         TEXT,
    gpu_count         INT DEFAULT 0,
    hashrate          DOUBLE DEFAULT 0,
    warehouse_id      INT,
    power_on          TINYINT(1) DEFAULT 0,
    cooling_installed TINYINT(1) DEFAULT 0,
    stored_ftc        BIGINT DEFAULT 0
);

-- =============================================================

-- Table: warehouses
CREATE TABLE IF NOT EXISTS crypto_warehouses (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    owner          VARCHAR(50),
    location       VARCHAR(50),
    power_capacity DOUBLE,
    power_usage    DOUBLE DEFAULT 0,
    cooling_level  INT DEFAULT 1
);

-- =============================================================

-- Table: market history (legacy, kept for compatibility)
CREATE TABLE IF NOT EXISTS crypto_market_history (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    price     DOUBLE,
    timestamp INT
);

-- Table: price history (used by market.lua inserts and terminal.lua queries)
CREATE TABLE IF NOT EXISTS crypto_price_history (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    symbol      VARCHAR(10) NOT NULL,
    price       DOUBLE NOT NULL,
    recorded_at INT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_price_history_symbol ON crypto_price_history(symbol);

-- Table: market current price
CREATE TABLE IF NOT EXISTS crypto_market (
    symbol     VARCHAR(10) PRIMARY KEY,
    price      DOUBLE,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Seed market entry if missing
INSERT IGNORE INTO crypto_market (symbol, price) VALUES ('FTC', 2500);

-- =============================================================

-- Table: blockchain state persistence (Review Note 7)
-- Ensures block height, difficulty, and last mined timestamp survive restarts
CREATE TABLE IF NOT EXISTS crypto_blockchain_state (
    id               INT PRIMARY KEY DEFAULT 1,
    block_height     INT DEFAULT 0,
    network_difficulty DOUBLE DEFAULT 1.0,
    last_block_time  INT DEFAULT 0
);

INSERT IGNORE INTO crypto_blockchain_state (id, block_height, network_difficulty, last_block_time)
VALUES (1, 0, 1.0, 0);

-- =============================================================

-- Table: economy metrics (Review Note 15)
CREATE TABLE IF NOT EXISTS crypto_economy_metrics (
    id                 INT AUTO_INCREMENT PRIMARY KEY,
    total_supply       BIGINT DEFAULT 0,
    active_miners      INT DEFAULT 0,
    total_reward_dist  BIGINT DEFAULT 0,
    exchange_volume    BIGINT DEFAULT 0,
    recorded_at        DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================

-- Table: cracking attempts (Review Note 9)
CREATE TABLE IF NOT EXISTS crypto_crack_attempts (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    attacker   VARCHAR(50),
    target     VARCHAR(20),
    success    TINYINT(1) DEFAULT 0,
    attempted_at INT
);