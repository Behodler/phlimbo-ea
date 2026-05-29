// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockMainRewarder.sol";

contract AutoDolaVaultTest is Test {
    AutoDolaYieldStrategy vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MockAutoDOLA autoDolaVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client1 = address(0x5678);
    address client2 = address(0x9ABC);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);

    uint256 constant INITIAL_DOLA_SUPPLY = 10000000e18; // 10M DOLA
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18;  // 1M TOKE

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder first
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoDOLA vault
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy the actual vault
        vm.prank(owner);
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Mint tokens to test addresses
        dolaToken.mint(client1, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(client2, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_DOLA_SUPPLY); // For autoDOLA mock

        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize clients
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vault.setClient(client2, true);
        vm.stopPrank();
    }

    function testConstructor() public {
        // Test constructor requirements
        vm.expectRevert("AutoDolaYieldStrategy: DOLA token cannot be zero address");
        new AutoDolaYieldStrategy(owner, address(0), address(tokeToken), address(autoDolaVault), address(mainRewarder));

        vm.expectRevert("AutoDolaYieldStrategy: TOKE token cannot be zero address");
        new AutoDolaYieldStrategy(owner, address(dolaToken), address(0), address(autoDolaVault), address(mainRewarder));

        vm.expectRevert("AutoDolaYieldStrategy: autoDOLA vault cannot be zero address");
        new AutoDolaYieldStrategy(owner, address(dolaToken), address(tokeToken), address(0), address(mainRewarder));

        vm.expectRevert("AutoDolaYieldStrategy: MainRewarder cannot be zero address");
        new AutoDolaYieldStrategy(owner, address(dolaToken), address(tokeToken), address(autoDolaVault), address(0));

        // Test successful construction
        assertTrue(address(vault.dolaToken()) == address(dolaToken));
        assertTrue(address(vault.tokeToken()) == address(tokeToken));
        assertTrue(address(vault.autoDolaVault()) == address(autoDolaVault));
        assertTrue(address(vault.mainRewarder()) == address(mainRewarder));
    }

    function testDeposit() public {
        uint256 depositAmount = 1000e18; // 1000 DOLA

        // Approve vault to spend DOLA
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);

        // Get initial balances
        uint256 initialClientDola = dolaToken.balanceOf(client1);
        uint256 initialVaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 initialStakedShares = mainRewarder.balanceOf(address(vault));

        // Perform deposit
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify DOLA transferred from client
        assertEq(dolaToken.balanceOf(client1), initialClientDola - depositAmount);

        // Verify autoDOLA shares received and staked
        uint256 finalVaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 finalStakedShares = mainRewarder.balanceOf(address(vault));

        assertTrue(finalVaultShares > initialVaultShares);
        assertTrue(finalStakedShares > initialStakedShares);

        // Verify user balance is tracked
        assertEq(vault.balanceOf(address(dolaToken), user1), depositAmount);

        // Verify total deposited is updated
        assertEq(vault.getTotalDeposited(address(dolaToken)), depositAmount);
    }

    function testDepositRequirements() public {
        uint256 depositAmount = 1000e18;

        // Test unauthorized client
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(address(0x9999));
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Test wrong token
        vm.expectRevert("AutoDolaYieldStrategy: only DOLA token supported");
        vm.prank(client1);
        vault.deposit(address(tokeToken), depositAmount, user1);

        // Test zero amount
        vm.expectRevert("AutoDolaYieldStrategy: amount must be greater than zero");
        vm.prank(client1);
        vault.deposit(address(dolaToken), 0, user1);

        // Test zero recipient
        vm.expectRevert("AutoDolaYieldStrategy: recipient cannot be zero address");
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, address(0));
    }

    function testWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // First deposit - client1 deposits for client1 (themselves)
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client1);

        // Get initial balances
        uint256 initialUserBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 initialRecipientDola = dolaToken.balanceOf(client1);

        // Perform withdrawal - client1 withdraws their own balance to themselves
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, client1);

        // Verify balances
        uint256 finalUserBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 finalRecipientDola = dolaToken.balanceOf(client1);

        assertEq(finalUserBalance, initialUserBalance - withdrawAmount);
        assertEq(finalRecipientDola, initialRecipientDola + withdrawAmount);
    }

    function testWithdrawRequirements() public {
        uint256 withdrawAmount = 1000e18;

        // Test unauthorized client
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(address(0x9999));
        vault.withdraw(address(dolaToken), withdrawAmount, user1);

        // Test wrong token
        vm.expectRevert("AutoDolaYieldStrategy: only DOLA token supported");
        vm.prank(client1);
        vault.withdraw(address(tokeToken), withdrawAmount, user1);

        // Test zero amount
        vm.expectRevert("AutoDolaYieldStrategy: amount must be greater than zero");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), 0, user1);

        // Test zero recipient
        vm.expectRevert("AutoDolaYieldStrategy: recipient cannot be zero address");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, address(0));

        // Test insufficient balance
        vm.expectRevert("AutoDolaYieldStrategy: no shares available");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, user1);
    }

    // DELETED: testYieldCalculation
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield)
    // Users cannot access yield - it's locked in the vault
    // This test expected users to see yield, which is no longer the case

    function testTokeRewardsClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Only owner can claim
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.claimTokeRewards(user1);

        // Owner claims rewards
        uint256 initialTokeBalance = tokeToken.balanceOf(user1);
        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // Verify rewards transferred
        assertEq(tokeToken.balanceOf(user1), initialTokeBalance + rewardAmount);
        assertEq(vault.getTokeRewards(), 0);
    }

    function testEmergencyWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 emergencyAmount = 500e18;

        // Deposit first
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Only owner can emergency withdraw
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.emergencyWithdraw(emergencyAmount);

        // Owner performs emergency withdraw
        uint256 initialOwnerDola = dolaToken.balanceOf(owner);
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // Verify withdrawal with precise assertion
        uint256 finalOwnerDola = dolaToken.balanceOf(owner);
        assertApproxEqAbs(finalOwnerDola, initialOwnerDola + emergencyAmount, 1, "Emergency withdrawal should transfer requested amount within 1 wei");
    }

    // DELETED: testEmergencyWithdrawPartial
    // Reason: Story 018 removed yield visibility. This test expected user balance to decrease
    // when emergency withdraw reduced vault assets, which tested yield-aware balanceOf().
    // With story 018, balanceOf() returns only principal, so emergency withdrawals don't affect user balances.

    /**
     * @notice Test emergency withdraw when staked shares are less than needed
     * @dev Tests sharesToWithdraw > stakedShares scenario (lines 298-301)
     *      When requested amount requires more shares than are staked,
     *      the function should unstake all available shares and redeem what it can
     */
    function testEmergencyWithdrawWhenStakedLessThanNeeded() public {
        uint256 depositAmount = 3000e18;

        // Setup: Make a deposit (this stakes the shares)
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify shares are staked
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertGt(stakedShares, 0, "Shares should be staked after deposit");

        // Manually unstake SOME shares to create the condition where staked < needed
        uint256 sharesToUnstake = stakedShares / 2; // Unstake half
        vm.prank(address(vault));
        mainRewarder.withdraw(address(vault), sharesToUnstake, false);

        // Now try to emergency withdraw a large amount that would need ALL shares
        // This creates the condition: sharesToWithdraw > stakedShares
        uint256 largeWithdrawAmount = depositAmount; // Try to withdraw everything

        uint256 ownerBalanceBefore = dolaToken.balanceOf(owner);
        vm.prank(owner);
        vault.emergencyWithdraw(largeWithdrawAmount);

        // Should succeed and withdraw what's possible
        uint256 ownerBalanceAfter = dolaToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore, "Should withdraw some amount even with insufficient staked shares");
    }

    /**
     * @notice Test emergency withdraw with no staked shares
     * @dev Edge case: user has balance but nothing is staked (stakedShares = 0)
     *      Tests the condition at line 298: if (stakedShares > 0)
     *      When stakedShares = 0, the function should skip unstaking and proceed to redeem
     */
    function testEmergencyWithdrawZeroStaked() public {
        uint256 depositAmount = 1500e18;

        // Setup: Make a deposit
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Manually unstake ALL shares to create zero-staked condition
        uint256 allStakedShares = mainRewarder.balanceOf(address(vault));
        vm.prank(address(vault));
        mainRewarder.withdraw(address(vault), allStakedShares, false);

        // Verify zero staked
        assertEq(mainRewarder.balanceOf(address(vault)), 0, "Should have zero staked shares");

        // But vault still has shares (just not staked)
        assertGt(autoDolaVault.balanceOf(address(vault)), 0, "Vault should still have autoDOLA shares");

        // After bug fix: Emergency withdraw requires staked shares > 0
        // This scenario (manually unstaking all shares) should now revert
        uint256 withdrawAmount = 500e18;

        vm.prank(owner);
        vm.expectRevert("AutoDolaYieldStrategy: no shares to withdraw");
        vault.emergencyWithdraw(withdrawAmount);
    }

    // DELETED: testEmergencyWithdrawDuringPendingTotalWithdrawal
    // Reason: Story 018 removed yield visibility. This test expected user balance to decrease
    // when emergency withdraw reduced vault assets. With principal-only balanceOf(),
    // emergency withdrawals no longer affect user balances in the expected way.

    // DELETED: testMultipleClients (yield benefit portion)
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield)
    // The test expected users to benefit from yield, which is no longer accessible
    // Basic multi-client deposit/withdraw testing is covered in other tests

    function testZeroBalanceQueries() public {
        // Test balance queries for non-existent deposits
        assertEq(vault.balanceOf(address(dolaToken), user1), 0);
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0);
        assertEq(vault.getTotalShares(), 0);
        assertEq(vault.getTokeRewards(), 0);
    }

    function testOnlyDolaTokenSupported() public {
        // Create another ERC20 token
        MockERC20 otherToken = new MockERC20("OTHER", "OTHER", 18);

        // Verify balance query rejects non-DOLA tokens
        vm.expectRevert("AutoDolaYieldStrategy: only DOLA token supported");
        vault.balanceOf(address(otherToken), user1);
    }

    function testWithdrawWithClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;
        uint256 rewardAmount = 50e18;

        // First deposit
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Get initial TOKE balance of vault
        uint256 initialVaultToke = tokeToken.balanceOf(address(vault));

        // Perform withdrawal with claim=true (this happens inside AutoDolaYieldStrategy.withdraw)
        // Note: The actual claim happens when mainRewarder.withdraw is called with claim=true
        // For this test, we need to verify the mock behavior works correctly
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, client1);

        // Note: AutoDolaYieldStrategy currently calls withdraw with claim=false
        // This test verifies the mock implementation works correctly when claim=true
        // We'll test the mock directly
        uint256 stakeAmount = 100e18;
        mainRewarder.stake(user1, stakeAmount);
        mainRewarder.simulateRewards(user1, rewardAmount);

        uint256 userTokeBalanceBefore = tokeToken.balanceOf(user1);
        mainRewarder.withdraw(user1, stakeAmount, true);
        uint256 userTokeBalanceAfter = tokeToken.balanceOf(user1);

        // Verify rewards were claimed during withdrawal
        assertEq(userTokeBalanceAfter, userTokeBalanceBefore + rewardAmount);
        assertEq(mainRewarder.earned(user1), 0);
    }

    function testGetRewardWithRecipient() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate earning TOKE rewards for the vault
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Test the mock directly to verify recipient parameter works
        mainRewarder.simulateRewards(user1, rewardAmount);

        uint256 user2TokeBalanceBefore = tokeToken.balanceOf(user2);
        mainRewarder.getReward(user1, user2, false);
        uint256 user2TokeBalanceAfter = tokeToken.balanceOf(user2);

        // Verify rewards were sent to user2 (not user1)
        assertEq(user2TokeBalanceAfter, user2TokeBalanceBefore + rewardAmount);
        assertEq(mainRewarder.earned(user1), 0);
        assertEq(tokeToken.balanceOf(user1), 0);
    }

    function testGetRewardWithClaimExtras() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Test with claimExtras=true (currently just a placeholder in mock)
        uint256 initialTokeBalance = tokeToken.balanceOf(address(vault));
        bool success = mainRewarder.getReward(address(vault), address(vault), true);
        uint256 finalTokeBalance = tokeToken.balanceOf(address(vault));

        // Verify the call succeeded
        assertTrue(success);
        assertEq(finalTokeBalance, initialTokeBalance + rewardAmount);

        // Test with claimExtras=false
        mainRewarder.simulateRewards(address(vault), rewardAmount);
        initialTokeBalance = tokeToken.balanceOf(address(vault));
        success = mainRewarder.getReward(address(vault), address(vault), false);
        finalTokeBalance = tokeToken.balanceOf(address(vault));

        // Verify the call succeeded with claimExtras=false as well
        assertTrue(success);
        assertEq(finalTokeBalance, initialTokeBalance + rewardAmount);
    }

    // ============ _totalWithdraw Unit Tests ============

    /**
     * @notice Test that _totalWithdraw correctly calculates shares to withdraw
     * @dev Verifies the calculation at line 328: sharesToWithdraw = (totalShares * clientStoredBalance) / totalDeposited[token]
     */
    function testTotalWithdrawCalculatesCorrectShares() public {
        uint256 deposit1 = 1000e18; // Client 1 deposits 1000 DOLA
        uint256 deposit2 = 3000e18; // Client 2 deposits 3000 DOLA (total = 4000 DOLA)

        // Client 1 deposits for user1
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Client 2 deposits for user2
        vm.prank(client2);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Get total shares and verify client 1 should get 25% of shares
        uint256 totalSharesBefore = autoDolaVault.balanceOf(address(vault));
        uint256 expectedSharesForUser1 = (totalSharesBefore * deposit1) / (deposit1 + deposit2);

        // Initiate total withdrawal for user1
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Advance time past waiting period (24 hours)
        vm.warp(block.timestamp + 24 hours + 1);

        // Get owner's initial DOLA balance
        uint256 ownerDolaBalanceBefore = dolaToken.balanceOf(owner);

        // Execute total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Verify correct amount of shares were withdrawn
        uint256 totalSharesAfter = autoDolaVault.balanceOf(address(vault));
        uint256 sharesWithdrawn = totalSharesBefore - totalSharesAfter;

        // Allow for small rounding errors (within 0.1%)
        uint256 tolerance = expectedSharesForUser1 / 1000;
        assertTrue(
            sharesWithdrawn >= expectedSharesForUser1 - tolerance &&
            sharesWithdrawn <= expectedSharesForUser1 + tolerance,
            "Share calculation should be accurate"
        );

        // Verify owner received approximately the right amount of DOLA
        uint256 ownerDolaBalanceAfter = dolaToken.balanceOf(owner);
        uint256 dolaReceived = ownerDolaBalanceAfter - ownerDolaBalanceBefore;
        assertTrue(dolaReceived >= deposit1 - tolerance && dolaReceived <= deposit1 + tolerance);
    }

    /**
     * @notice Test _totalWithdraw with partial unstaking scenario
     * @dev Verifies behavior when stakedShares > sharesToWithdraw (line 334)
     */
    function testTotalWithdrawPartialUnstake() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 9000e18; // Much larger deposit to ensure partial unstaking

        // Client 1 deposits for user1
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Client 2 deposits for user2
        vm.prank(client2);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Verify all shares are staked
        uint256 totalShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(totalShares, stakedShares, "All shares should be staked");

        // Initiate total withdrawal for user1 (small portion)
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Advance time past waiting period
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 stakedSharesBefore = mainRewarder.balanceOf(address(vault));

        // Execute total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Verify partial unstaking occurred
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        uint256 sharesUnstaked = stakedSharesBefore - stakedSharesAfter;

        // User1 should have unstaked ~10% of total shares (1000 out of 10000)
        uint256 expectedUnstaked = (stakedSharesBefore * deposit1) / (deposit1 + deposit2);
        uint256 tolerance = expectedUnstaked / 100; // 1% tolerance

        assertTrue(
            sharesUnstaked >= expectedUnstaked - tolerance &&
            sharesUnstaked <= expectedUnstaked + tolerance,
            "Should unstake correct proportion of shares"
        );

        // Verify remaining shares are still staked
        assertTrue(stakedSharesAfter > 0, "Remaining shares should still be staked");
    }

    /**
     * @notice Test _totalWithdraw with full unstaking scenario
     * @dev Verifies complete unstaking when sharesToWithdraw >= stakedShares
     */
    function testTotalWithdrawFullUnstake() public {
        uint256 depositAmount = 1000e18;

        // Single client deposits
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify shares are staked
        uint256 totalShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(totalShares, stakedShares, "All shares should be staked");
        assertTrue(stakedShares > 0, "Shares should be staked");

        // Initiate total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Advance time past waiting period
        vm.warp(block.timestamp + 24 hours + 1);

        // Execute total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Verify complete unstaking occurred
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        assertEq(stakedSharesAfter, 0, "All shares should be unstaked");

        // Verify all shares are redeemed
        uint256 totalSharesAfter = autoDolaVault.balanceOf(address(vault));
        assertEq(totalSharesAfter, 0, "All shares should be redeemed");
    }

    /**
     * @notice Test _totalWithdraw correctly resets client balance to zero
     * @dev Verifies lines 342-343: clientBalances[token][client] = 0 and totalDeposited update
     */
    function testTotalWithdrawBalanceReset() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;

        // Client 1 deposits for user1
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Client 2 deposits for user2
        vm.prank(client2);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Verify initial balances
        assertEq(vault.balanceOf(address(dolaToken), user1), deposit1);
        assertEq(vault.getTotalDeposited(address(dolaToken)), deposit1 + deposit2);

        // Initiate total withdrawal for user1
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Advance time past waiting period
        vm.warp(block.timestamp + 24 hours + 1);

        // Execute total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Verify user1 balance is reset to zero
        assertEq(vault.balanceOf(address(dolaToken), user1), 0, "Client balance should be reset to zero");

        // Verify totalDeposited is updated correctly (should only have user2's deposit)
        assertEq(vault.getTotalDeposited(address(dolaToken)), deposit2, "Total deposited should be reduced");

        // Verify user2 balance is unaffected
        assertEq(vault.balanceOf(address(dolaToken), user2), deposit2, "Other client balance should be unchanged");
    }

    /**
     * @notice Test _totalWithdraw edge case with zero shares
     * @dev Verifies that attempting withdrawal with zero balance reverts at initiation
     *      The Vault base contract prevents zero-balance withdrawals before _totalWithdraw is called
     */
    function testTotalWithdrawZeroShares() public {
        // Try to withdraw from a client with no balance
        // This should revert during initiation phase because balance is zero

        // Attempt to initiate total withdrawal for user1 who has no deposits
        // This should fail with "AYieldStrategy: no balance to withdraw"
        vm.expectRevert("AYieldStrategy: no balance to withdraw");
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Verify vault state is unchanged
        assertEq(vault.getTotalShares(), 0, "Total shares should remain zero");
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should remain zero");
    }

    // ============ balanceOf() Edge Case Tests ============

    /**
     * @notice Test balanceOf() precision with small deposits (1-1000 wei)
     * @dev Verifies that balanceOf() maintains precision with tiny values
     *      Tests edge cases where rounding errors could cause issues
     */
    function testBalanceOfPrecisionWithSmallValues() public {
        // Test with 1 wei
        vm.prank(client1);
        dolaToken.approve(address(vault), 1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), 1, user1);

        uint256 balance1Wei = vault.balanceOf(address(dolaToken), user1);
        assertGe(balance1Wei, 1, "Balance should be at least 1 wei");

        // Test with 100 wei
        vm.prank(client1);
        dolaToken.approve(address(vault), 100);
        vm.prank(client1);
        vault.deposit(address(dolaToken), 100, user1);

        uint256 balance101Wei = vault.balanceOf(address(dolaToken), user1);
        assertGe(balance101Wei, 101, "Balance should be at least 101 wei");

        // Test with 1000 wei
        vm.prank(client1);
        dolaToken.approve(address(vault), 899);
        vm.prank(client1);
        vault.deposit(address(dolaToken), 899, user1);

        uint256 balance1000Wei = vault.balanceOf(address(dolaToken), user1);
        assertGe(balance1000Wei, 1000, "Balance should be at least 1000 wei");

        // Verify precision is maintained (no significant rounding loss)
        // With small values, even 1 wei difference is significant
        assertLe(balance1000Wei, 1001, "Balance should not exceed deposit by more than 1 wei");
    }

    /**
     * @notice Test balanceOf() precision with massive deposits (1e30+)
     * @dev Verifies that balanceOf() handles extremely large values without overflow
     *      Tests the upper bounds of uint256 calculations
     */
    function testBalanceOfPrecisionWithLargeValues() public {
        // Mint large amounts for testing
        uint256 largeAmount = 1e30; // 1 trillion DOLA (with 18 decimals)
        dolaToken.mint(client1, largeAmount);
        dolaToken.mint(address(autoDolaVault), largeAmount);

        // Deposit large amount
        vm.prank(client1);
        dolaToken.approve(address(vault), largeAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), largeAmount, user1);

        uint256 balanceLarge = vault.balanceOf(address(dolaToken), user1);
        assertGe(balanceLarge, largeAmount, "Balance should be at least the deposit amount");

        // Allow for minimal rounding (within 0.01%)
        uint256 maxTolerance = largeAmount / 10000;
        assertLe(balanceLarge, largeAmount + maxTolerance, "Balance should not significantly exceed deposit");

        // Test even larger amount (approaching uint256 limits)
        uint256 extremeAmount = 1e35; // Even larger
        dolaToken.mint(client2, extremeAmount);
        dolaToken.mint(address(autoDolaVault), extremeAmount);

        vm.prank(client2);
        dolaToken.approve(address(vault), extremeAmount);
        vm.prank(client2);
        vault.deposit(address(dolaToken), extremeAmount, user2);

        uint256 balanceExtreme = vault.balanceOf(address(dolaToken), user2);
        assertGe(balanceExtreme, extremeAmount, "Balance should handle extreme values");

        // Verify first user's balance is unaffected
        uint256 balanceUser1After = vault.balanceOf(address(dolaToken), user1);
        assertGe(balanceUser1After, largeAmount, "First user balance should be maintained");
    }

    /**
     * @notice Test balanceOf() with zero totalDeposited but non-zero balance
     * @dev Tests the corruption recovery path at line 133
     *      This scenario shouldn't normally occur but tests defensive programming
     */
    function testBalanceOfWithZeroTotalDepositedButNonZeroBalance() public {
        uint256 depositAmount = 1000e18;

        // Make a normal deposit
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify normal operation first
        uint256 normalBalance = vault.balanceOf(address(dolaToken), user1);
        assertEq(normalBalance, depositAmount, "Normal balance should equal deposit");

        // Now test the corruption recovery path by simulating a scenario
        // where totalShares becomes zero (all shares redeemed externally)
        // This would trigger the line 133 check: if (totalShares == 0 || totalDeposited[token] == 0)

        // We'll test by having the vault lose all shares through emergency withdrawals
        // and seeing what balanceOf returns

        // Make another deposit from client2 to have multiple users
        vm.prank(client2);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client2);
        vault.deposit(address(dolaToken), depositAmount, user2);

        // Emergency withdraw all shares (this will reduce totalShares to 0)
        uint256 totalAssets = vault.getTotalShares();
        uint256 totalDola = autoDolaVault.convertToAssets(totalAssets);

        vm.prank(owner);
        vault.emergencyWithdraw(totalDola);

        // Now totalShares should be 0, triggering the corruption recovery path
        assertEq(vault.getTotalShares(), 0, "Total shares should be zero after emergency withdraw");

        // balanceOf should return the stored balance (corruption recovery)
        uint256 balanceAfterCorruption = vault.balanceOf(address(dolaToken), user1);

        // In corruption recovery mode, it returns the stored balance
        // The stored balance might have been reduced by emergency withdraw affecting proportions
        // But the function should still return a value without reverting
        assertGe(balanceAfterCorruption, 0, "Balance should not revert in corruption recovery");
    }

    // DELETED: testBalanceOfUnderYieldLoss
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield).
    // This test expected balances to decrease when vault lost value, testing yield-aware balanceOf().
    // With principal-only accounting, vault asset changes don't affect user balances.

    // DELETED: testBalanceOfUnderExtremeYieldGain
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield)
    // This test expected balances to increase with yield, which no longer happens
    // balanceOf() now returns only the principal amount deposited, regardless of yield

    // ============ Rounding Error Tests (Story 008.9) ============

    /**
     * @notice Test deposit and withdraw with minimum amount (1 wei)
     * @dev Verifies that 1 wei operations work correctly without rounding to zero
     *      Tests the absolute minimum amount that can be deposited and withdrawn
     */
    function testDepositWithdrawOneWei() public {
        uint256 oneWei = 1;

        // Approve and deposit exactly 1 wei - client1 deposits for themselves
        vm.prank(client1);
        dolaToken.approve(address(vault), oneWei);
        vm.prank(client1);
        vault.deposit(address(dolaToken), oneWei, client1);

        // Verify shares were received (should be at least 1 share due to 1:1 ratio in mock)
        uint256 sharesReceived = autoDolaVault.balanceOf(address(vault));
        assertGe(sharesReceived, 1, "Should receive at least 1 share for 1 wei deposit");

        // Verify client1 balance is tracked correctly
        uint256 clientBalance = vault.balanceOf(address(dolaToken), client1);
        assertApproxEqAbs(clientBalance, oneWei, 1, "Client balance should be approximately 1 wei within 1 wei tolerance");

        // Withdraw the 1 wei - client1 withdraws their own balance to themselves
        uint256 recipientBalanceBefore = dolaToken.balanceOf(client1);
        vm.prank(client1);
        vault.withdraw(address(dolaToken), oneWei, client1);

        // Verify withdrawal succeeded
        uint256 recipientBalanceAfter = dolaToken.balanceOf(client1);
        uint256 amountReceived = recipientBalanceAfter - recipientBalanceBefore;

        // With 1 wei operations, we allow 1 wei tolerance for rounding
        assertApproxEqAbs(amountReceived, oneWei, 1, "Should receive approximately 1 wei within rounding tolerance");

        // Verify client1 balance is now zero or near zero
        uint256 clientBalanceAfter = vault.balanceOf(address(dolaToken), client1);
        assertLe(clientBalanceAfter, 1, "Client balance should be zero or dust after withdrawing all");
    }

    /**
     * @notice Test accounting accuracy with multiple small deposits (dust amounts)
     * @dev Verifies that multiple deposits of very small amounts maintain accurate accounting
     *      Tests that rounding errors don't accumulate over multiple operations
     */
    function testMultipleSmallDepositsAccounting() public {
        uint256 dustAmount = 10; // 10 wei per deposit
        uint256 numDeposits = 100; // 100 deposits
        uint256 totalExpected = dustAmount * numDeposits; // 1000 wei total

        // Perform multiple small deposits - client1 deposits for themselves
        vm.startPrank(client1);
        dolaToken.approve(address(vault), totalExpected);

        for (uint256 i = 0; i < numDeposits; i++) {
            vault.deposit(address(dolaToken), dustAmount, client1);
        }
        vm.stopPrank();

        // Verify total shares were accumulated
        uint256 totalShares = autoDolaVault.balanceOf(address(vault));
        assertGt(totalShares, 0, "Should have accumulated shares from dust deposits");

        // Verify client1 balance matches expected total within rounding tolerance
        uint256 clientBalance = vault.balanceOf(address(dolaToken), client1);

        // Allow for accumulated rounding errors (1 wei per deposit max = 100 wei tolerance)
        uint256 tolerance = numDeposits; // 1 wei per operation
        assertApproxEqAbs(clientBalance, totalExpected, tolerance, "Total balance should match sum of deposits within rounding tolerance");

        // Verify total deposited is tracked accurately
        uint256 totalDeposited = vault.getTotalDeposited(address(dolaToken));
        assertApproxEqAbs(totalDeposited, totalExpected, tolerance, "Total deposited should be accurate");

        // Test withdrawal to ensure accounting remains accurate
        uint256 withdrawAmount = totalExpected / 2; // Withdraw half
        uint256 recipientBalanceBefore = dolaToken.balanceOf(client1);

        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, client1);

        uint256 recipientBalanceAfter = dolaToken.balanceOf(client1);
        uint256 actualWithdrawn = recipientBalanceAfter - recipientBalanceBefore;

        // Verify withdrawal amount is accurate
        assertApproxEqAbs(actualWithdrawn, withdrawAmount, tolerance, "Withdrawal should be accurate after dust deposits");
    }

    /**
     * @notice Test behavior when withdrawal rounding leaves dust amount
     * @dev Verifies that dust left after rounding is handled properly
     *      Tests the case where shares conversion leaves tiny remainder
     */
    function testWithdrawLeavingDustAmount() public {
        uint256 depositAmount = 1000e18;

        // Make initial deposit - client1 deposits for themselves
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client1);

        // Withdraw an amount that might leave dust due to rounding
        // Use a prime number that's likely to create rounding issues
        uint256 withdrawAmount = depositAmount / 3; // 333.333... DOLA

        uint256 recipientBalanceBefore = dolaToken.balanceOf(client1);
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, client1);

        uint256 recipientBalanceAfter = dolaToken.balanceOf(client1);
        uint256 actualWithdrawn = recipientBalanceAfter - recipientBalanceBefore;

        // Verify withdrawal succeeded with reasonable precision
        assertApproxEqAbs(actualWithdrawn, withdrawAmount, 1, "Withdrawal should be accurate within 1 wei");

        // Check remaining balance
        uint256 remainingBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 expectedRemaining = depositAmount - withdrawAmount;

        // Remaining balance should be close to expected (allowing for rounding)
        assertApproxEqAbs(remainingBalance, expectedRemaining, 1, "Remaining balance should be accurate within 1 wei");

        // Verify that dust doesn't accumulate in the vault
        // The sum of withdrawn + remaining should approximately equal original deposit
        assertApproxEqAbs(actualWithdrawn + remainingBalance, depositAmount, 2, "Sum of withdrawn and remaining should equal deposit within 2 wei tolerance");

        // Test second withdrawal to verify dust handling continues to work
        uint256 secondWithdrawAmount = remainingBalance / 2;

        recipientBalanceBefore = dolaToken.balanceOf(client1);
        vm.prank(client1);
        vault.withdraw(address(dolaToken), secondWithdrawAmount, client1);

        recipientBalanceAfter = dolaToken.balanceOf(client1);
        uint256 secondActualWithdrawn = recipientBalanceAfter - recipientBalanceBefore;

        // Verify second withdrawal also accurate
        assertApproxEqAbs(secondActualWithdrawn, secondWithdrawAmount, 1, "Second withdrawal should be accurate within 1 wei");

        // Final balance should still be reasonable
        uint256 finalBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 totalWithdrawn = actualWithdrawn + secondActualWithdrawn;

        assertApproxEqAbs(totalWithdrawn + finalBalance, depositAmount, 3, "Total accounting should remain accurate after multiple dust-creating withdrawals");
    }

    // DELETED: testExtremeShareRatioScenarios
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield).
    // This test expected "Original user should have benefited from yield" - testing yield visibility.
    // With principal-only accounting, users don't see yield benefits in balanceOf().

    // ============ TOKE Reward Interference Tests (Story 008.11) ============

    /**
     * @notice Test claiming TOKE rewards during a pending total withdrawal
     * @dev Verifies that claiming rewards doesn't corrupt withdrawal state or interfere with pending total withdrawals
     *      Tests the critical scenario where rewards are claimed while a total withdrawal is in progress
     *      This ensures reward claiming and withdrawal mechanisms are independent and don't conflict
     */
    function testClaimRewardsDuringPendingTotalWithdrawal() public {
        uint256 depositAmount = 5000e18;
        uint256 rewardAmount = 100e18;

        // Setup: Make a deposit
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available before total withdrawal
        uint256 rewardsBeforeWithdrawal = vault.getTokeRewards();
        assertEq(rewardsBeforeWithdrawal, rewardAmount, "Rewards should be available before total withdrawal");

        // Initiate total withdrawal (starts 24-hour waiting period)
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Record user balance before claiming rewards
        uint256 userBalanceBeforeClaim = vault.balanceOf(address(dolaToken), user1);
        uint256 totalDepositedBeforeClaim = vault.getTotalDeposited(address(dolaToken));
        uint256 totalSharesBeforeClaim = vault.getTotalShares();

        // While total withdrawal is pending, claim TOKE rewards
        uint256 ownerTokeBalanceBefore = tokeToken.balanceOf(owner);
        vm.prank(owner);
        vault.claimTokeRewards(owner);

        // Verify rewards were claimed successfully
        uint256 ownerTokeBalanceAfter = tokeToken.balanceOf(owner);
        assertEq(ownerTokeBalanceAfter, ownerTokeBalanceBefore + rewardAmount, "Owner should receive TOKE rewards");
        assertEq(vault.getTokeRewards(), 0, "Rewards should be fully claimed");

        // CRITICAL: Verify that claiming rewards didn't corrupt withdrawal state
        uint256 userBalanceAfterClaim = vault.balanceOf(address(dolaToken), user1);
        uint256 totalDepositedAfterClaim = vault.getTotalDeposited(address(dolaToken));
        uint256 totalSharesAfterClaim = vault.getTotalShares();

        assertEq(userBalanceAfterClaim, userBalanceBeforeClaim, "User balance should not change when rewards are claimed");
        assertEq(totalDepositedAfterClaim, totalDepositedBeforeClaim, "Total deposited should not change when rewards are claimed");
        assertEq(totalSharesAfterClaim, totalSharesBeforeClaim, "Total shares should not change when rewards are claimed");

        // Fast forward to complete total withdrawal window (24 hours + 1 second)
        vm.warp(block.timestamp + 24 hours + 1 seconds);

        // Complete the total withdrawal (should still work correctly despite rewards being claimed)
        vm.prank(owner);
        vault.totalWithdrawal(address(dolaToken), user1);

        // Verify total withdrawal completed successfully
        assertEq(vault.balanceOf(address(dolaToken), user1), 0, "Total withdrawal should complete and zero user balance");

        // This test proves that reward claiming and total withdrawal are independent mechanisms
        // and that claiming rewards during pending withdrawal doesn't corrupt state
    }

    /**
     * @notice Test claiming TOKE rewards when user has no staked shares
     * @dev Verifies proper handling of edge case where rewards are claimed with zero stake
     *      This tests defensive programming - claiming with no stake should not revert
     *      but should return zero rewards or handle gracefully
     */
    function testClaimRewardsNoStake() public {
        // Verify vault starts with no staked shares
        uint256 initialStakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(initialStakedShares, 0, "Vault should have no staked shares initially");

        // Verify no rewards are available
        uint256 initialRewards = vault.getTokeRewards();
        assertEq(initialRewards, 0, "No rewards should be available with no stake");

        // Attempt to claim rewards with zero stake
        uint256 ownerTokeBalanceBefore = tokeToken.balanceOf(owner);

        vm.prank(owner);
        vault.claimTokeRewards(owner);

        // Verify claim succeeded but transferred zero tokens
        uint256 ownerTokeBalanceAfter = tokeToken.balanceOf(owner);
        assertEq(ownerTokeBalanceAfter, ownerTokeBalanceBefore, "Owner should receive zero TOKE with no stake");
        assertEq(vault.getTokeRewards(), 0, "Rewards should remain zero");

        // Make a deposit to create stake, then fully withdraw to return to zero stake
        uint256 depositAmount = 1000e18;
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client1);

        // Verify shares are now staked
        uint256 stakedAfterDeposit = mainRewarder.balanceOf(address(vault));
        assertGt(stakedAfterDeposit, 0, "Shares should be staked after deposit");

        // Withdraw all funds to return to zero stake
        vm.prank(client1);
        vault.withdraw(address(dolaToken), depositAmount, client1);

        // Verify no shares are staked again
        uint256 stakedAfterWithdraw = mainRewarder.balanceOf(address(vault));
        assertEq(stakedAfterWithdraw, 0, "All shares should be unstaked after full withdrawal");

        // Attempt to claim rewards again with zero stake
        ownerTokeBalanceBefore = tokeToken.balanceOf(owner);

        vm.prank(owner);
        vault.claimTokeRewards(owner);

        // Verify claim succeeded but transferred zero tokens
        ownerTokeBalanceAfter = tokeToken.balanceOf(owner);
        assertEq(ownerTokeBalanceAfter, ownerTokeBalanceBefore, "Owner should receive zero TOKE after full withdrawal");

        // This test proves the vault handles claiming with no stake gracefully
    }

    /**
     * @notice Improved test for TOKE reward claiming with intermediate assertion
     * @dev Enhances existing testTokeRewardsClaim with better validation of reward calculations
     *      Adds intermediate checks to verify reward amounts are accurate during the claim process
     *      This strengthens test quality by validating state at multiple points
     */
    function testTokeRewardsClaimImproved() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify shares are staked
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertGt(stakedShares, 0, "Shares should be staked after deposit");

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // INTERMEDIATE ASSERTION: Verify exact reward amount is available before claiming
        uint256 rewardsAvailableBeforeClaim = vault.getTokeRewards();
        assertEq(rewardsAvailableBeforeClaim, rewardAmount, "Exact reward amount should be available before claim");

        // Record vault's TOKE balance before claim (should be zero initially)
        uint256 vaultTokeBalanceBeforeClaim = tokeToken.balanceOf(address(vault));
        assertEq(vaultTokeBalanceBeforeClaim, 0, "Vault should have no TOKE tokens before claim");

        // Only owner can claim (verify authorization)
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.claimTokeRewards(user1);

        // Owner claims rewards
        uint256 recipientTokeBalanceBefore = tokeToken.balanceOf(user1);

        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // INTERMEDIATE ASSERTION: Verify exact reward amount was transferred to recipient
        uint256 recipientTokeBalanceAfter = tokeToken.balanceOf(user1);
        uint256 actualRewardsReceived = recipientTokeBalanceAfter - recipientTokeBalanceBefore;
        assertEq(actualRewardsReceived, rewardAmount, "Recipient should receive exact reward amount");

        // Verify rewards are now zero after claiming
        uint256 rewardsAfterClaim = vault.getTokeRewards();
        assertEq(rewardsAfterClaim, 0, "Rewards should be zero after claiming");

        // Verify vault doesn't retain any TOKE (all transferred to recipient)
        uint256 vaultTokeBalanceAfterClaim = tokeToken.balanceOf(address(vault));
        assertEq(vaultTokeBalanceAfterClaim, 0, "Vault should not retain TOKE tokens after claim");

        // ADDITIONAL ASSERTION: Verify claiming when no rewards available
        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // Balance should remain unchanged when claiming with no rewards
        assertEq(tokeToken.balanceOf(user1), recipientTokeBalanceAfter, "Balance should not change when claiming zero rewards");

        // This improved test validates reward amounts at multiple points in the process
        // providing stronger guarantees about the accuracy of reward calculations
    }
}