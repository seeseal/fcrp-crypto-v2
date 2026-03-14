# fcrp-crypto

A cryptocurrency economy system developed for **Flamecity Roleplay**, built on the **Qbox framework** for FiveM.

This resource introduces a simulated blockchain, mining infrastructure, player wallets, and an in-server exchange designed to expand the roleplay economy with digital assets and infrastructure investment.

Developed by **seeseal**.

---

## Overview

`fcrp-crypto` provides a contained crypto ecosystem inside the server. Players interact with the system through terminals, wallets, mining hardware, and exchange mechanics integrated into the roleplay environment.

The system conceptually mirrors real cryptocurrency networks while remaining optimized for FiveM server performance and gameplay balance.

Core concepts include:

* block generation
* mining hardware participation
* wallet storage and transfers
* market exchange systems
* infrastructure ownership
* controlled market volatility

All financial and blockchain logic is processed server-side.

---

## Features

**Blockchain Simulation**

Blocks are generated at fixed intervals. Rewards are distributed based on participation within the network, creating a simplified blockchain-style reward structure.

**Mining Infrastructure**

Players can install specialized hardware within designated infrastructure spaces. Hardware tiers affect network contribution and reward potential.

**Cryptocurrency Wallets**

Each player can maintain a wallet used to store, send, and receive the server’s cryptocurrency.

**Trading & Exchange**

Terminals allow conversion between the server's standard currency and the crypto asset. Transaction fees and spread mechanics help maintain economic stability.

**Warehouse Infrastructure**

Mining operations require physical infrastructure. Facilities provide power capacity limits that determine how much hardware can be deployed.

**Terminal Access**

Crypto terminals placed around the map allow players to access wallets, perform transactions, and interact with the system.

**Risk-Based Interactions**

Certain mechanics introduce risk when interacting with the system, creating additional roleplay opportunities.

---

## Dependencies

The resource requires the following to function correctly:

* qbx_core
* ox_inventory
* ox_lib
* oxmysql

Ensure these dependencies are installed and started before the resource.

---

## Installation

1. Place the resource inside your server's `resources` directory.

2. Import the database schema located in:

```
sql/crypto.sql
```

3. Ensure dependencies load before the resource.

Example server start order:

```
ensure oxmysql
ensure ox_lib
ensure ox_inventory
ensure qbx_core
ensure fcrp-crypto
```

4. Restart the server.

---

## Configuration

All configuration values are located in:

```
shared/config.lua
```

Server administrators can adjust values controlling:

* block timing
* mining rewards
* volatility behavior
* transaction fees
* infrastructure limits
* economic balancing

Careful adjustment is recommended to match the server's economy scale.

---

## Gameplay Progression

The crypto system is designed around infrastructure and participation:

1. Players access a terminal to create or access their wallet.
2. Cryptocurrency can be obtained through mining or exchange purchases.
3. Mining requires hardware and infrastructure investment.
4. Infrastructure determines capacity and mining efficiency.
5. Assets can be traded, transferred, or used within the economy.

Additional mechanics exist within the system for players who explore deeper gameplay interactions.

---

## Database

The system stores persistent data such as:

* wallet balances
* transaction history
* mining infrastructure
* blockchain state
* warehouse ownership

These tables are defined in the provided SQL schema.

---

## Development

This resource was created specifically for **Flamecity Roleplay** and designed to integrate with the Qbox ecosystem.

The script follows a modular server architecture where major systems are separated into individual components. This allows easier maintenance and future expansion.

---

## Credits

Developer
**seeseal**

Server
**Flamecity Roleplay**

---

## Disclaimer

This system simulates cryptocurrency mechanics for roleplay purposes only. It does not interact with real-world blockchain networks or digital currencies.

---
