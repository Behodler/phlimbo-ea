# Vault-RM

A secure vault contract system extracted from behodler3-tokenlaunch-RM, providing foundational vault functionality with access control and security features.

## Overview

This project contains the core vault contracts that provide:

- **Abstract Yield Strategy Contract**: Base vault implementation with security features and access control
- **Multi-client Authorization**: Support for multiple authorized client contracts
- **Owner Access Control**: Emergency functions restricted to contract owner
- **Security Features**: Comprehensive access control and validation

## Architecture

### Core Contracts

- `src/AYieldStrategy.sol` - Abstract base yield strategy contract with security and access control
- `src/interfaces/IYieldStrategy.sol` - YieldStrategy interface defining core functionality  
- `src/mocks/MockVault.sol` - Concrete test implementation of AYieldStrategy
- `src/mocks/MockERC20.sol` - Mock ERC20 token for testing

### Key Features

#### Access Control
- **Owner Functions**: `setClient()`, `emergencyWithdraw()`, `totalWithdrawal()` - restricted to contract owner
- **Client Functions**: `deposit()`, `withdraw()` - restricted to authorized client contracts  
- **Multi-client Support**: Multiple contracts can be authorized simultaneously

#### Security
- Zero address validation for all parameters
- Amount validation (must be > 0)
- Balance checks for withdrawals
- Event emission for all state changes
- **Two-Phase Emergency Withdrawal**: Provides community protection against rugpulls while enabling legitimate fund migrations

#### Extensibility
- Abstract base contract allows for concrete implementations
- Virtual functions for custom withdrawal logic
- Interface-based design for interoperability

## Dependencies

- **OpenZeppelin Contracts**: Access control (Ownable) and token interfaces
- **Forge-std**: Testing framework

## Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Installation

1. Clone the repository
2. Install dependencies:
```bash
forge install
```

### Build

```bash
forge build
```

### Test

Run all tests:
```bash
forge test
```

Run specific test contract:
```bash
forge test --match-contract VaultSecurityTest
```

### Security Tests

The `VaultSecurityTest.sol` provides comprehensive test coverage including:

- Access control enforcement (owner vs client vs unauthorized users)
- Multi-client authorization scenarios  
- Input validation and edge cases
- Event emission verification
- Integration testing across multiple tokens

## Usage

### Implementing a Concrete Vault

To create a concrete vault implementation, extend the abstract `AYieldStrategy` contract:

```solidity
import "./AYieldStrategy.sol";

contract MyVault is AYieldStrategy {
    constructor(address _owner) AYieldStrategy(_owner) {}
    
    function deposit(address token, uint256 amount, address recipient) 
        external override onlyAuthorizedClient {
        // Implement deposit logic
    }
    
    function withdraw(address token, uint256 amount, address recipient) 
        external override onlyAuthorizedClient {
        // Implement withdrawal logic  
    }
    
    function _emergencyWithdraw(uint256 amount) internal override {
        // Implement emergency withdrawal logic
    }

    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        // Implement total withdrawal logic for emergency fund migration
    }
}
```

### Access Control Setup

1. Deploy your vault implementation
2. Set authorized client contracts:
```solidity
vault.setClient(bondingCurveAddress, true);  // Authorize
vault.setClient(oldClientAddress, false);    // Revoke
```

## Emergency Withdrawal Procedure

The vault implements a two-phase emergency withdrawal system (`totalWithdrawal`) designed to protect the community while enabling legitimate protocol upgrades or emergency fund migrations.

### Overview

The two-phase mechanism provides a 72-hour window that allows community members to detect and respond to potentially malicious actions, while still permitting necessary emergency procedures.

### Phase Structure

- **Phase 1 (Initiation)**: 24-hour waiting period
- **Phase 2 (Execution)**: 48-hour execution window
- **Total Duration**: 72 hours maximum from initiation to completion

### Usage

#### Phase 1: Initiate Withdrawal
```solidity
// Only contract owner can initiate
vault.totalWithdrawal(tokenAddress, clientAddress);
```

**What happens:**
- Current balance is cached to prevent manipulation
- Withdrawal state is set to "Initiated"
- `WithdrawalInitiated` event is emitted with execution timestamp
- 24-hour waiting period begins

#### Phase 2: Execute Withdrawal
After the 24-hour waiting period, call the same function again:

```solidity
// Same function call, now executes the withdrawal
vault.totalWithdrawal(tokenAddress, clientAddress);
```

**What happens:**
- Cached balance is withdrawn to the contract owner
- Withdrawal state is reset
- `WithdrawalExecuted` event is emitted
- Client's balance becomes zero

### State Management

The system tracks withdrawal state per token/client combination:

- **None**: No withdrawal process active
- **Initiated**: Waiting period active, execution not yet available
- **Executable**: Execution window open (after 24h, within 72h total)
- **Expired**: Window has passed, state resets automatically

### Security Features

- **Reentrancy Protection**: Uses OpenZeppelin's `nonReentrant` modifier
- **Balance Caching**: Amount is locked at initiation to prevent manipulation
- **Access Control**: Only contract owner can initiate/execute withdrawals
- **Time Windows**: Strict enforcement of waiting and execution periods
- **State Reset**: Automatic cleanup on expiration
- **Event Monitoring**: All actions emit trackable events

### Community Protection

This mechanism allows community members to:

1. **Monitor Initiations**: `WithdrawalInitiated` events provide 24-hour advance notice
2. **Respond to Threats**: Time to withdraw funds if malicious intent is suspected
3. **Verify Legitimacy**: Evaluate whether withdrawals are for valid protocol upgrades
4. **Exit if Needed**: Full 24-hour window to remove funds before execution

### Error Handling

- **During Waiting Period**: Calls revert with explicit timestamp for when execution becomes available
- **After Expiration**: State automatically resets, allowing new initiation
- **Zero Balances**: Cannot initiate withdrawal if client has no tokens
- **Invalid Addresses**: Zero address validation prevents invalid operations

### Best Practices

1. **Communication**: Announce intended emergency withdrawals to the community in advance
2. **Documentation**: Clearly explain the reason for emergency procedures
3. **Monitoring**: Watch for unexpected `WithdrawalInitiated` events
4. **Response Time**: Act within 24 hours if you suspect malicious activity

## Source Attribution

These contracts were extracted from the behodler3-tokenlaunch-RM project, preserving the security features and multi-client permissioning developed in stories 006 and 008. The extraction maintains all functionality while establishing an independent vault-focused codebase.

## Foundry Reference

This project uses Foundry for development and testing:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

For more information: https://book.getfoundry.sh/