// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import "../../src/mocks/MockMainRewarder.sol";

/**
 * @title EmergencyWithdrawYieldLossTest
 * @notice Proof-of-concept test demonstrating yield loss after emergency withdrawal
 * @dev Tests vulnerability L1 from security audit report
 *
 * VULNERABILITY: _emergencyWithdraw does not re-stake remaining shares after partial withdrawal
 *
 * IMPACT:
 * - Remaining shares sit unstaked in the contract
 * - No longer earning TOKE rewards
 * - Yield generation stops for remaining user funds
 *
 * SEVERITY: LOW (funds safe, but yield impaired)
 */
contract EmergencyWithdrawYieldLossTest is Test {
    AutoDolaYieldStrategy vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MockAutoDOLA autoDolaVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);

    uint256 constant INITIAL_SUPPLY = 10000000e18;

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock contracts
        mainRewarder = new MockMainRewarder(address(tokeToken));
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy vault
        vm.prank(owner);
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Mint tokens
        dolaToken.mint(client, INITIAL_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_SUPPLY);
        tokeToken.mint(address(mainRewarder), INITIAL_SUPPLY);

        // Authorize client
        vm.prank(owner);
        vault.setClient(client, true);
    }

    /**
     * @notice Test that emergency withdrawal leaves shares unstaked
     */
    function testEmergencyWithdrawLeavesSharesUnstaked() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify shares are staked
        uint256 stakedSharesBefore = mainRewarder.balanceOf(address(vault));
        assertGt(stakedSharesBefore, 0, "Shares should be staked after deposit");

        // Owner performs emergency withdrawal of 50%
        uint256 emergencyAmount = 5000e18;
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // VULNERABILITY: Check that remaining shares are NOT re-staked
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        uint256 unstakedShares = autoDolaVault.balanceOf(address(vault));

        // Remaining shares should be in vault but NOT staked
        assertEq(stakedSharesAfter, 0, "VULNERABILITY: All shares unstaked, not re-staked");
        assertGt(unstakedShares, 0, "VULNERABILITY: Shares sitting unstaked in vault");

        // Impact: TOKE rewards stop accumulating
        // Normally, shares would be re-staked and continue earning TOKE
        // But now they sit idle until next user operation
    }

    /**
     * @notice Test that TOKE rewards stop accumulating after emergency withdrawal
     */
    function testTokeRewardsStopAfterEmergencyWithdrawal() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Fast forward time to accumulate TOKE rewards
        vm.warp(block.timestamp + 7 days);
        uint256 rewardsBefore = vault.getTokeRewards();
        assertGt(rewardsBefore, 0, "Should have accumulated TOKE rewards");

        // Owner performs emergency withdrawal
        uint256 emergencyAmount = 5000e18;
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // Fast forward time again
        vm.warp(block.timestamp + 7 days);

        // VULNERABILITY: TOKE rewards should NOT increase (shares unstaked)
        uint256 rewardsAfter = vault.getTokeRewards();

        // In the vulnerable contract, rewards stop increasing because shares are unstaked
        // In a fixed contract, rewards would continue accumulating
        assertEq(rewardsAfter, 0, "VULNERABILITY: TOKE rewards stop accumulating");
    }

    /**
     * @notice Test comparison: Regular withdraw correctly re-stakes shares
     */
    function testRegularWithdrawCorrectlyReStakes() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, client);

        // User performs regular withdrawal of 50%
        uint256 withdrawAmount = 5000e18;
        vm.prank(client);
        vault.withdraw(address(dolaToken), withdrawAmount, client);

        // CORRECT BEHAVIOR: Remaining shares should be re-staked
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        uint256 unstakedShares = autoDolaVault.balanceOf(address(vault));

        assertGt(stakedSharesAfter, 0, "Remaining shares should be re-staked");
        assertEq(unstakedShares, 0, "No shares should be sitting unstaked");

        // Verify TOKE rewards continue accumulating
        vm.warp(block.timestamp + 7 days);
        uint256 rewards = vault.getTokeRewards();
        assertGt(rewards, 0, "TOKE rewards should continue accumulating");
    }

    /**
     * @notice Test that user funds remain safe despite yield loss
     */
    function testUserFundsRemainSafeDespiteYieldLoss() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Owner performs emergency withdrawal
        uint256 emergencyAmount = 5000e18;
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // User principal should remain accurate
        uint256 userPrincipal = vault.principalOf(address(dolaToken), user1);
        assertEq(userPrincipal, depositAmount, "User principal should be unaffected");

        // User should still be able to withdraw their principal
        vm.prank(client);
        vault.withdraw(address(dolaToken), depositAmount, user1);

        // Verify withdrawal succeeded
        uint256 principalAfter = vault.principalOf(address(dolaToken), user1);
        assertEq(principalAfter, 0, "User should be able to withdraw full principal");
    }
}
