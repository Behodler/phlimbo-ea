# Flax Token - TDD Foundation

## Overview

This project implements the **Test-Driven Development (TDD) foundation** for the Flax ERC20 token with advanced minting capabilities. The Flax token is designed with:

- **ERC20 compliance** with "FLX" symbol
- **Ownable access control**
- **Zero initial supply**
- **Advanced mint-version system** for global permission revocation
- **Comprehensive test coverage** for all planned functionality

## Project Structure

```
├── src/
│   ├── IFlax.sol           # Complete interface definition
│   └── FlaxToken.sol       # Skeleton implementation (red phase)
├── test/
│   ├── FlaxAuthorizationTest.sol   # Authorization functionality tests
│   ├── FlaxMintingTest.sol        # Minting functionality tests  
│   ├── FlaxRevocationTest.sol     # Privilege revocation tests
│   ├── FlaxERC20Test.sol          # ERC20 integration tests
│   ├── FlaxEdgeCasesTest.sol      # Edge cases and security tests
│   └── TestContract.sol           # Helper contract for testing
├── lib/                    # Dependencies (OpenZeppelin, Forge-std)
├── foundry.toml           # Foundry configuration
└── README.md              # This documentation
```

## TDD Approach - RED PHASE ✅

This project follows strict **Test-Driven Development** principles. Currently in the **RED PHASE**:

### What We Have ✅
- ✅ **Complete Interface**: `IFlax.sol` defines all required functions and events
- ✅ **Skeleton Implementation**: `FlaxToken.sol` compiles but all business logic reverts with "not implemented"  
- ✅ **Comprehensive Tests**: 104+ test cases covering all functionality
- ✅ **Red Phase Verification**: All tests expecting business logic fail as intended

### Current State
- All basic ERC20 functions (name, symbol, decimals, balanceOf) work via inheritance
- All custom business logic functions revert with "not implemented"
- Tests pass when they expect "not implemented" reverts
- Tests fail when they expect actual functionality (proving red phase)

## Key Features to Implement (Next Story)

### 1. Advanced Minting System
- **Permissioned Minting**: Only authorized addresses can mint tokens
- **Version-Based Revocation**: Global version system invalidates all existing minters
- **Owner Control**: Only contract owner can authorize/revoke minters

### 2. Core Functions
```solidity
function setMinter(address minter, bool canMint) external onlyOwner;
function mint(address recipient, uint256 amount) external;
function revokeAllMintPrivileges() external onlyOwner;
function authorizedMinters(address minter) external view returns (MinterInfo memory);
```

### 3. Version Control Logic
- `mintVersion` starts at 0
- When `setMinter(address, true)` is called, minter gets current `mintVersion`
- When `mint()` is called, it checks caller's version against global version
- `revokeAllMintPrivileges()` increments global `mintVersion` by 1
- Old minters can't mint even if `canMint = true` due to version mismatch

## Test Coverage

Our comprehensive test suite includes **5 test files** with **104+ test cases**:

### 1. FlaxAuthorizationTest.sol
- Owner authorization requirements
- Minter permission assignment and revocation
- Mint version assignment logic
- Event emissions for authorization changes
- Multiple simultaneous minters

### 2. FlaxMintingTest.sol  
- Access control for minting
- Version checking against global version
- Balance and supply updates
- Transfer event emissions
- Edge cases (zero amounts, zero addresses)

### 3. FlaxRevocationTest.sol
- Global privilege revocation
- Mint version increment behavior
- Existing minter disabling
- New minter authorization after revocation
- Multiple sequential revocations

### 4. FlaxERC20Test.sol
- Standard ERC20 functionality
- Integration with minting system
- Transfer and approval workflows
- Balance and supply queries
- Token properties validation

### 5. FlaxEdgeCasesTest.sol
- Contract deployment scenarios
- Ownership transfer edge cases
- Large amounts and overflow protection
- Contract-to-contract interactions
- Boundary conditions and stress tests

## Running Tests

```bash
# Install dependencies
forge install

# Compile contracts
forge build

# Run all tests (expect many failures - red phase!)
forge test

# Run specific test categories
forge test --match-test "testSetMinter"
forge test --match-test "testMint" 
forge test --match-test "testRevoke"

# Run with verbose output
forge test -v

# Check test coverage
forge coverage
```

## Expected Test Results (Red Phase)

- ✅ **Basic ERC20 tests pass**: name(), symbol(), decimals(), balanceOf()
- ❌ **Business logic tests fail**: All custom minting functionality
- ✅ **Access control tests pass**: OpenZeppelin Ownable works
- ❌ **State change tests fail**: No actual state changes implemented
- ✅ **Revert tests pass**: All expect "not implemented" and get it

## Next Steps (GREEN PHASE)

The next story will implement the actual business logic to make all tests pass:

1. **Implement `setMinter`**: Update `_authorizedMinters` mapping with permission and version
2. **Implement `mint`**: Check authorization, version, then mint tokens
3. **Implement `revokeAllMintPrivileges`**: Increment global version
4. **Implement `authorizedMinters`**: Return minter info from storage
5. **Add proper event emissions**: Emit all required events
6. **Handle edge cases**: Zero addresses, overflows, etc.

## Architecture Notes

### Interface-First Design
- `IFlax.sol` defines the complete contract interface
- Includes comprehensive natspec documentation
- Separates interface from implementation for clarity

### Version-Based Security
- Global `mintVersion` provides O(1) revocation of all minters
- Individual minter versions prevent stale authorizations
- Owner can selectively re-authorize after global revocation

### ERC20 Integration
- Inherits from OpenZeppelin's battle-tested ERC20 implementation
- Adds custom minting on top of standard functionality
- Maintains full ERC20 compatibility

## Dependencies

- **OpenZeppelin Contracts v5.4.0**: ERC20 and Ownable implementations
- **Forge-std**: Testing framework and utilities
- **Foundry**: Development and testing environment

## Foundry Commands

### Build
```shell
$ forge build
```

### Test
```shell
$ forge test
```

### Format
```shell
$ forge fmt
```

### Gas Snapshots
```shell
$ forge snapshot
```

## License

MIT License - see LICENSE file for details.

---

**Current Status**: RED PHASE COMPLETE ✅
**Next Story**: Implement business logic to achieve GREEN PHASE ✅
