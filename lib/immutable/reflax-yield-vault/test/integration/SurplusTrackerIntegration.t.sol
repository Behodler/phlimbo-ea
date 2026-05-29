// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/SurplusTracker.sol";
import "../../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import "../../src/mocks/MockMainRewarder.sol";

/**
 * @title SurplusTrackerIntegrationTest
 * @notice Integration tests for SurplusTracker with AutoDolaYieldStrategy
 * @dev Uses AutoDolaYieldStrategy (real implementation) with mocked external dependencies
 */
contract SurplusTrackerIntegrationTest is Test {
    SurplusTracker public tracker;
    AutoDolaYieldStrategy public autoDolaVault;
    AutoDolaYieldStrategy public secondVault; // For multi-vault tests

    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDola;
    MockMainRewarder public mainRewarder;

    MockAutoDOLA public autoDola2; // For second vault
    MockMainRewarder public mainRewarder2; // For second vault

    address public owner;
    address public client1;
    address public client2;

    function setUp() public {
        owner = address(this);
        client1 = address(0x1);
        client2 = address(0x2);

        // Deploy tracker
        tracker = new SurplusTracker();

        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock external dependencies for first vault
        mainRewarder = new MockMainRewarder(address(tokeToken));
        autoDola = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy mock external dependencies for second vault
        mainRewarder2 = new MockMainRewarder(address(tokeToken));
        autoDola2 = new MockAutoDOLA(address(dolaToken), address(mainRewarder2));

        // Deploy first AutoDolaYieldStrategy
        autoDolaVault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDola),
            address(mainRewarder)
        );
        autoDolaVault.setClient(client1, true);
        autoDolaVault.setClient(client2, true);

        // Deploy second AutoDolaYieldStrategy for multi-vault tests
        secondVault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDola2),
            address(mainRewarder2)
        );
        secondVault.setClient(client1, true);
        secondVault.setClient(client2, true);

        // Mint tokens to clients and external vaults
        dolaToken.mint(client1, 10000e18);
        dolaToken.mint(client2, 10000e18);
        dolaToken.mint(address(autoDola), 10000e18);
        dolaToken.mint(address(autoDola2), 10000e18);
    }

    // ============ BASIC SURPLUS CALCULATION TESTS ============

    function testBasicSurplusCalculation() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Simulate yield accrual (10% = 100 DOLA)
        dolaToken.mint(address(autoDola), 100e18); // Mint tokens for yield payout
        autoDola.simulateYield(100e18); // Update internal accounting

        // Calculate surplus (internal balance = 900)
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            900e18
        );

        assertGt(surplus, 100e18, "Surplus should be greater than 100 (yield + principal diff)");
    }

    function testNoSurplusWhenBalancesMatch() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Calculate surplus (internal balance matches principal, no yield)
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // With no yield accrual, surplus should be 0 or very small (rounding)
        assertLt(surplus, 1e18, "Surplus should be minimal with no yield");
    }

    // ============ AUTODOLAVAULT INTEGRATION TESTS ============
    //
    // RESTORED in Story 022: Now that totalBalanceOf() includes yield, we can correctly
    // calculate surplus from AutoDolaYieldStrategy. SurplusTracker now uses totalBalanceOf()
    // which returns principal + yield, making surplus calculation work as expected.

    function testAutoDolaVaultSurplusWithYield() public {
        // Client1 deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Verify principal is tracked correctly
        assertEq(autoDolaVault.principalOf(address(dolaToken), client1), 1000e18);

        // Simulate yield accrual in autoDola (5% yield = 50 DOLA)
        dolaToken.mint(address(autoDola), 50e18); // Mint tokens for yield payout
        autoDola.simulateYield(50e18); // Update internal accounting

        // totalBalanceOf should now include yield
        uint256 totalBalance = autoDolaVault.totalBalanceOf(address(dolaToken), client1);
        assertGt(totalBalance, 1000e18, "Total balance should include yield");

        // Calculate surplus with internal balance = principal (1000)
        // Surplus = totalBalanceOf() - clientInternalBalance
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should approximately equal the yield (50 DOLA)
        // Use approximate equality due to potential rounding
        assertApproxEqAbs(surplus, 50e18, 1e18, "Surplus should approximately equal yield");
        assertGt(surplus, 0, "Surplus should be positive when yield exists");
    }

    function testAutoDolaVaultSurplusNoYield() public {
        // Client1 deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // No yield accrual - totalBalanceOf should equal principal
        assertEq(autoDolaVault.principalOf(address(dolaToken), client1), 1000e18);
        assertApproxEqAbs(
            autoDolaVault.totalBalanceOf(address(dolaToken), client1),
            1000e18,
            1,
            "Total balance should equal principal with no yield"
        );

        // Calculate surplus with internal balance matching principal
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should be 0 when no yield has accrued
        assertEq(surplus, 0, "Surplus should be 0 with no yield");
    }

    function testAutoDolaVaultSurplusMultipleClients() public {
        // Client1 deposits 2000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 2000e18);
        autoDolaVault.deposit(address(dolaToken), 2000e18, client1);
        vm.stopPrank();

        // Client2 deposits 1000 DOLA
        vm.startPrank(client2);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client2);
        vm.stopPrank();

        // Simulate yield accrual (10% yield on 3000 total = 300 DOLA)
        dolaToken.mint(address(autoDola), 300e18); // Mint tokens for yield payout
        autoDola.simulateYield(300e18); // Update internal accounting

        // Calculate surplus for client1 (should get 2/3 of yield = 200 DOLA)
        uint256 surplus1 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            2000e18
        );

        // Calculate surplus for client2 (should get 1/3 of yield = 100 DOLA)
        uint256 surplus2 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client2,
            1000e18
        );

        // Verify proportional surplus distribution
        assertApproxEqAbs(surplus1, 200e18, 2e18, "Client1 should get ~200 DOLA surplus");
        assertApproxEqAbs(surplus2, 100e18, 1e18, "Client2 should get ~100 DOLA surplus");

        // Ratio should be approximately 2:1
        assertApproxEqAbs(surplus1, surplus2 * 2, 2e18, "Surplus ratio should match deposit ratio");
    }

    // ============ CROSS-VAULT TESTS ============
    //
    // RESTORED in Story 022: Now that SurplusTracker uses totalBalanceOf(), it correctly
    // works with all vault types including AutoDolaYieldStrategy with yield.

    function testSurplusTrackerWorksWithMultipleVaults() public {
        // Test with first AutoDolaYieldStrategy vault
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Accrue yield in first vault
        dolaToken.mint(address(autoDola), 100e18); // Mint tokens for yield payout
        autoDola.simulateYield(100e18); // Update internal accounting

        uint256 firstVaultSurplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18 // Internal balance is principal only
        );
        assertGt(firstVaultSurplus, 0, "First vault should have positive surplus from yield");
        assertApproxEqAbs(firstVaultSurplus, 100e18, 2e18, "First vault surplus should approximately equal yield");

        // Test with second AutoDolaYieldStrategy vault
        vm.startPrank(client1);
        dolaToken.approve(address(secondVault), 2000e18);
        secondVault.deposit(address(dolaToken), 2000e18, client1);
        vm.stopPrank();

        // Accrue different yield in second vault
        dolaToken.mint(address(autoDola2), 200e18); // Mint tokens for yield payout
        autoDola2.simulateYield(200e18); // Update internal accounting

        uint256 secondVaultSurplus = tracker.getSurplus(
            address(secondVault),
            address(dolaToken),
            client1,
            2000e18
        );
        assertGt(secondVaultSurplus, 0, "Second vault should have positive surplus from yield");
        assertApproxEqAbs(secondVaultSurplus, 200e18, 4e18, "Second vault surplus should approximately equal its yield");
    }

    // ============ REALISTIC SCENARIO TESTS ============
    //
    // RESTORED in Story 022: Now that SurplusTracker uses totalBalanceOf(), we can correctly
    // identify harvestable surplus from AutoDolaYieldStrategy yield.

    function testRealisticBehodlerScenario() public {
        // Behodler has virtualInputTokens = 10000 (internal accounting)
        // User deposits 10000 DOLA into AutoDolaYieldStrategy
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 10000e18);
        autoDolaVault.deposit(address(dolaToken), 10000e18, client1);
        vm.stopPrank();

        // Verify principal matches deposit
        assertEq(autoDolaVault.principalOf(address(dolaToken), client1), 10000e18);

        // AutoDola vault accrues 5% yield (500 DOLA)
        dolaToken.mint(address(autoDola), 500e18); // Mint tokens for yield payout
        autoDola.simulateYield(500e18); // Update internal accounting

        // Now totalBalanceOf should return ~10500 (principal + yield)
        uint256 totalBalance = autoDolaVault.totalBalanceOf(address(dolaToken), client1);
        assertApproxEqAbs(totalBalance, 10500e18, 10e18, "Total balance should include yield");

        // SurplusTracker calculates surplus
        // Internal balance (virtualInputTokens) = 10000
        // Vault balance (totalBalanceOf) = 10500
        // Surplus = 500 (harvestable yield)
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            10000e18
        );

        // Verify surplus equals the yield
        assertApproxEqAbs(surplus, 500e18, 10e18, "Surplus should equal accrued yield");
        assertGt(surplus, 0, "Surplus should be positive");

        // This surplus can now be harvested via SurplusWithdrawer (future story)
        // Behodler's virtualInputTokens stays at 10000
        // But SurplusWithdrawer can extract the 500 DOLA yield for protocol revenue
    }

    function testSurplusAfterPartialWithdrawal() public {
        // Client deposits 10000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 10000e18);
        autoDolaVault.deposit(address(dolaToken), 10000e18, client1);
        vm.stopPrank();

        // Accrue yield
        dolaToken.mint(address(autoDola), 1000e18); // Mint tokens for yield payout
        autoDola.simulateYield(1000e18); // Update internal accounting

        // Initial surplus calculation (internal = 9000, vault has principal + yield)
        uint256 surplusBefore = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            9000e18
        );
        assertGt(surplusBefore, 1000e18, "Initial surplus should be greater than 1000 (yield + principal diff)");

        // Client withdraws 2000 tokens (principal only)
        vm.prank(client1);
        autoDolaVault.withdraw(address(dolaToken), 2000e18, client1);

        // After withdrawal, vault has 8000 principal + remaining yield
        // If client's internal accounting is now 7000, surplus should still include yield
        uint256 surplusAfter = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            7000e18
        );

        // Surplus should still be positive (yield remains)
        assertGt(surplusAfter, 1000e18, "Surplus should remain after withdrawal");
    }

    // ============ STRESS TESTS ============
    //
    // RESTORED in Story 022: High yield and multiple accrual scenarios now work correctly
    // because SurplusTracker uses totalBalanceOf() which includes yield.

    function testHighYieldScenario() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Simulate extremely high yield (100% return)
        dolaToken.mint(address(autoDola), 1000e18); // Mint tokens for yield payout
        autoDola.simulateYield(1000e18); // Update internal accounting

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should approximately equal the high yield
        assertApproxEqAbs(surplus, 1000e18, 20e18, "High yield scenario surplus");
        assertGt(surplus, 900e18, "Surplus should reflect substantial yield");
    }

    function testMultipleYieldAccruals() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // First yield accrual (5%)
        dolaToken.mint(address(autoDola), 50e18); // Mint tokens for yield payout
        autoDola.simulateYield(50e18); // Update internal accounting

        uint256 surplus1 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );
        assertApproxEqAbs(surplus1, 50e18, 2e18, "First accrual surplus");

        // Second yield accrual (another 5%)
        dolaToken.mint(address(autoDola), 50e18); // Mint tokens for yield payout
        autoDola.simulateYield(50e18); // Update internal accounting

        uint256 surplus2 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );
        assertApproxEqAbs(surplus2, 100e18, 3e18, "Cumulative surplus after second accrual");

        // Third yield accrual (10%)
        dolaToken.mint(address(autoDola), 100e18); // Mint tokens for yield payout
        autoDola.simulateYield(100e18); // Update internal accounting

        uint256 surplus3 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );
        assertApproxEqAbs(surplus3, 200e18, 5e18, "Cumulative surplus after third accrual");
    }
}
