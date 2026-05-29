# Testing Patterns for Vault-RM

## AutoDolaYieldStrategy Testing Pattern

### Why We Use AutoDolaYieldStrategy Instead of MockVault

The vault-RM project follows a best practice of **mocking externals, not internals**:

- **Mock External Dependencies**: Mock the external contracts that our system integrates with (e.g., Tokemak's AutoDOLA vault, MainRewarder)
- **Use Real Internal Implementations**: Use the actual implementation of our own contracts (e.g., AutoDolaYieldStrategy)

This approach provides several benefits:

1. **Tests are more realistic** - They test the actual code that will run in production
2. **Better bug detection** - Tests catch issues in the real implementation, not in simplified mocks
3. **Refactoring safety** - Changes to implementation details don't require updating mocks
4. **Documentation value** - Tests serve as examples of how to use the real contracts

### Correct Testing Pattern

#### Setup

```solidity
import "../../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import "../../src/mocks/MockMainRewarder.sol";

contract MyTest is Test {
    AutoDolaYieldStrategy public vault;
    MockERC20 public token;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner;
    address public client;

    function setUp() public {
        owner = address(this);
        client = address(0x1);

        // Deploy mock tokens
        token = new MockERC20("Test Token", "TEST", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock external dependencies
        mainRewarder = new MockMainRewarder(address(tokeToken));
        autoDolaVault = new MockAutoDOLA(address(token), address(mainRewarder));

        // Deploy the REAL AutoDolaYieldStrategy
        vault = new AutoDolaYieldStrategy(
            owner,
            address(token),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Setup authorization
        vault.setClient(client, true);

        // Mint tokens for testing
        token.mint(client, 10000e18);
        token.mint(address(autoDolaVault), 10000e18); // For mock to pay out
    }
}
```

#### Setting Up Principal and Surplus

Use this helper function to create test scenarios with both principal and yield:

```solidity
function setupPrincipalAndSurplus(uint256 principalAmount, uint256 surplusAmount) internal {
    // Deposit principal
    vm.startPrank(client);
    token.approve(address(vault), principalAmount);
    vault.deposit(address(token), principalAmount, client);
    vm.stopPrank();

    // Simulate yield by updating the mock's accounting AND providing tokens
    if (surplusAmount > 0) {
        token.mint(address(autoDolaVault), surplusAmount); // Mint tokens for payout
        autoDolaVault.simulateYield(surplusAmount); // Update internal accounting
    }
}
```

#### Example Test

```solidity
function testWithdrawWithYield() public {
    // Setup: 1000 principal + 100 yield
    setupPrincipalAndSurplus(1000e18, 100e18);

    // Verify state
    assertEq(vault.principalOf(address(token), client), 1000e18);
    uint256 totalBalance = vault.totalBalanceOf(address(token), client);
    assertApproxEqAbs(totalBalance, 1100e18, 1e18);

    // Withdraw principal only
    vm.prank(client);
    vault.withdraw(address(token), 500e18, client);

    // Verify remaining balance
    assertEq(vault.principalOf(address(token), client), 500e18);
}
```

### Common Pitfalls to Avoid

1. **Don't just mint tokens to the mock** - This doesn't update `_totalAssets`:
   ```solidity
   // WRONG
   token.mint(address(autoDolaVault), 100e18);

   // CORRECT
   token.mint(address(autoDolaVault), 100e18); // Provide tokens for payout
   autoDolaVault.simulateYield(100e18); // Update internal accounting
   ```

2. **Don't forget to authorize clients**:
   ```solidity
   vault.setClient(client, true); // Required before client can deposit/withdraw
   ```

3. **Remember withdrawal recipient semantics** - In `withdraw(token, amount, recipient)`:
   - The `msg.sender` must be an authorized client
   - The `recipient` is whose balance is withdrawn from AND who receives the tokens
   - This is different from `withdrawFrom()` which separates these concerns

### Test File Examples

See these files for complete examples of the pattern:

- `/home/justin/code/product-owner/worktrees/vault-RM/clean-code-bug-fix/test/SurplusWithdrawer.t.sol`
- `/home/justin/code/product-owner/worktrees/vault-RM/clean-code-bug-fix/test/VaultWithdrawer.t.sol`
- `/home/justin/code/product-owner/worktrees/vault-RM/clean-code-bug-fix/test/integration/SurplusTrackerIntegration.t.sol`

### Migration Guide

If you're updating old tests that used MockVault:

1. Replace `import MockVault` with AutoDolaYieldStrategy + mocks
2. Update setUp() to deploy AutoDolaYieldStrategy with mock externals
3. Add `setupPrincipalAndSurplus` helper
4. Replace any `setPrincipal` calls with the helper
5. Remove tests that use arbitrary tokens (AutoDolaYieldStrategy is token-specific)
6. Update withdrawal tests to use same address for recipient as balance owner
7. Replace `getTotalDeposits()` calls with `balanceOf()` if needed

### Key Differences from MockVault

| Aspect | MockVault | AutoDolaYieldStrategy |
|--------|-----------|----------------------|
| Token support | Multi-token | Single token (DOLA) |
| Withdraw semantics | Flexible recipient | Recipient = balance owner |
| Yield tracking | Manual via setPrincipal | Automatic via external vault |
| Share management | None | ERC4626 shares + staking |
| Test realism | Low (simplified) | High (production code) |

## Testing Philosophy

Always prefer testing with real implementations over mocks when the implementation is part of our codebase. Mock only external dependencies that we don't control.

This ensures our tests:
- Catch real bugs
- Document actual usage patterns
- Remain valid through refactorings
- Build confidence in production code
