# InheritChain Smart Contract

A Clarity smart contract for managing on-chain inheritance vaults on the Stacks blockchain.

## Overview

InheritChain allows users to create inheritance vaults that can hold STX, fungible tokens, and NFTs. The contract implements a heartbeat mechanism to ensure active ownership and automatic inheritance distribution when the owner becomes inactive.

## Features

- 🔐 Create inheritance vaults
- 💰 Deposit/withdraw STX and tokens
- 🎨 Register/unregister NFTs
- 👥 Assign multiple heirs with custom share distributions
- ❤️ Heartbeat mechanism for proving owner activity
- ⚡ Automatic inheritance claiming after inactivity period
- 🔄 Round-robin NFT distribution system

## Contract Functions

### Vault Management
- `create-vault`: Create a new vault with specified inactivity period
- `heartbeat`: Update last activity timestamp
- `set-heirs`: Assign heirs and their inheritance shares

### Asset Management
- `deposit-stx`: Deposit STX into vault
- `withdraw-stx`: Withdraw STX (owner only)
- `deposit-token`: Deposit fungible tokens
- `withdraw-token`: Withdraw tokens (owner only)
- `register-nft`: Register NFT ownership
- `unregister-nft`: Remove NFT registration

### Inheritance Claims
- `claim-inheritance`: Initiate inheritance distribution
- `claim-token`: Claim allocated tokens
- `claim-nft`: Claim registered NFTs

### View Functions
- `get-vault`: Get vault details
- `get-vault-stx`: Get STX balance
- `get-vault-token`: Get token balance
- `get-heirs`: Get heir information
- `is-claimable`: Check if vault is claimable
- `get-next-vault-id`: Get next available vault ID

## Error Codes

- `ERR-UNAUTHORIZED (u100)`: Unauthorized access
- `ERR-BAD-ARGS (u101)`: Invalid arguments
- `ERR-NOT-FOUND (u102)`: Resource not found
- `ERR-ALREADY (u103)`: Action already performed
- `ERR-INSUFFICIENT (u104)`: Insufficient balance
- `ERR-NOT-YET (u105)`: Time conditions not met
- `ERR-ALREADY-CLAIMED (u106)`: Inheritance already claimed
- `ERR-NO-HEIRS (u107)`: No heirs assigned
- `ERR-NFT-MISMATCH (u108)`: NFT ownership mismatch

## Usage

1. Deploy contract to Stacks blockchain
2. Create vault with `create-vault`
3. Add heirs using `set-heirs`
4. Deposit assets (STX/tokens/NFTs)
5. Maintain regular heartbeat
6. Heirs can claim after inactivity period

## Safety Features

- ✅ Safe state updates before transfers
- ✅ Comprehensive error handling
- ✅ Proper access controls
- ✅ Sequential operation execution
- ✅ Vault ID validation


Contributions are welcome! Please feel free to submit a Pull Request.
