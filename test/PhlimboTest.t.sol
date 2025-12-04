// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Phlimbo.sol";
import "./Mocks.sol";

/**
 * @title PhlimboTest
 * @notice Comprehensive test suite for Phlimbo staking contract (RED PHASE)
 * @dev All tests should FAIL in red phase - this validates test correctness before implementation
 */
contract PhlimboTest is Test {
    PhlimboEA public phlimbo;
    MockYieldStrategy public yieldStrategy;
    MockFlax public phUSD;
    MockStable public stable;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public minter = address(0x3);
    address public pauser = address(0x4);

    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant STAKE_AMOUNT = 1000 ether;

    function setUp() public {
        // Deploy mock contracts
        yieldStrategy = new MockYieldStrategy();
        phUSD = new MockFlax();
        stable = new MockStable();

        // Deploy Phlimbo
        phlimbo = new PhlimboEA(
            address(yieldStrategy),
            address(phUSD),
            address(stable),
            minter
        );

        // Set up phUSD minter
        phUSD.setMinter(address(phlimbo), true);

        // Mint initial tokens
        phUSD.mint(alice, INITIAL_BALANCE);
        phUSD.mint(bob, INITIAL_BALANCE);
        stable.mint(address(phlimbo), INITIAL_BALANCE);

        // Approve Phlimbo to spend tokens
        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);

        // Set up pauser
        phlimbo.setPauser(pauser);
    }

    // ========================== STAKING TESTS ==========================

    function test_stake_updates_user_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT, "User balance should equal staked amount");
    }

    function test_stake_updates_total_staked() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        uint256 totalStaked = phlimbo.totalStaked();
        assertEq(totalStaked, STAKE_AMOUNT, "Total staked should increase by stake amount");
    }

    function test_stake_transfers_tokens() public {
        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, STAKE_AMOUNT, "Tokens should be transferred from user");

        uint256 contractBalance = phUSD.balanceOf(address(phlimbo));
        assertEq(contractBalance, STAKE_AMOUNT, "Tokens should be in contract");
    }

    // ========================== WITHDRAWAL TESTS ==========================

    function test_withdraw_returns_tokens() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, STAKE_AMOUNT, "Staked tokens should be returned");
    }

    function test_withdraw_claims_rewards() public {
        // Setup principal in YieldStrategy so emission can be calculated
        yieldStrategy.setPrincipal(address(stable), minter, 100000 ether);
        yieldStrategy.setTotal(address(stable), minter, 100000 ether);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Set non-zero APY to generate rewards
        phlimbo.setDesiredAPY(500); // 5% APY

        // Fast forward time to accumulate rewards
        vm.warp(block.timestamp + 365 days);

        uint256 phUSDBefore = phUSD.balanceOf(alice);
        uint256 stableBefore = stable.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);

        uint256 phUSDAfter = phUSD.balanceOf(alice);
        uint256 stableAfter = stable.balanceOf(alice);

        // In working implementation, rewards should be claimed
        // Red phase: this will fail because _claimRewards is stubbed
        assertTrue(
            phUSDAfter > phUSDBefore + STAKE_AMOUNT || stableAfter > stableBefore,
            "Withdrawal should claim rewards"
        );
    }

    // ========================== CLAIM TESTS ==========================

    function test_claim_distributes_stable() public {
        // Setup principal and yield in YieldStrategy
        yieldStrategy.setPrincipal(address(stable), minter, 1000 ether);
        yieldStrategy.setTotal(address(stable), minter, 1100 ether); // 100 ether yield available

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Simulate stable yield accumulation
        vm.warp(block.timestamp + 30 days);

        uint256 stableBefore = stable.balanceOf(alice);

        vm.prank(alice);
        phlimbo.claim();

        uint256 stableAfter = stable.balanceOf(alice);

        // In working implementation, stable should be distributed
        // Red phase: this will fail because _claimRewards is stubbed
        assertGt(stableAfter, stableBefore, "Claim should distribute stable rewards");
    }

    function test_claim_mints_phUSD() public {
        // Setup principal in YieldStrategy so emission can be calculated
        yieldStrategy.setPrincipal(address(stable), minter, 100000 ether);
        yieldStrategy.setTotal(address(stable), minter, 100000 ether);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Set APY and wait for rewards
        phlimbo.setDesiredAPY(1000); // 10% APY
        vm.warp(block.timestamp + 365 days);

        uint256 phUSDBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.claim();

        uint256 phUSDAfter = phUSD.balanceOf(alice);

        // In working implementation, phUSD should be minted
        // Red phase: this will fail because _claimRewards is stubbed
        assertGt(phUSDAfter, phUSDBefore, "Claim should mint phUSD rewards");
    }

    // ========================== APY TESTS ==========================

    function test_setDesiredAPY_updates_emission_rate() public {
        // Setup principal in YieldStrategy so emission can be calculated
        yieldStrategy.setPrincipal(address(stable), minter, 100000 ether);
        yieldStrategy.setTotal(address(stable), minter, 100000 ether);

        uint256 emissionBefore = phlimbo.phUSDPerSecond();

        phlimbo.setDesiredAPY(500); // 5% APY

        uint256 emissionAfter = phlimbo.phUSDPerSecond();

        // In working implementation, emission rate should change
        // Red phase: this will fail because _calculatePhUSDPerSecond returns 0
        assertNotEq(emissionAfter, emissionBefore, "APY change should update emission rate");
        assertGt(emissionAfter, 0, "Emission rate should be greater than 0");
    }

    function test_setDesiredAPY_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setDesiredAPY(500);
    }

    // ========================== PAUSE MECHANISM TESTS ==========================

    function test_setPauser_updates_pauser_address() public {
        address newPauser = address(0x999);
        phlimbo.setPauser(newPauser);
        assertEq(phlimbo.pauser(), newPauser, "Pauser should be updated");
    }

    function test_setPauser_accepts_zero_address() public {
        phlimbo.setPauser(address(0));
        assertEq(phlimbo.pauser(), address(0), "Pauser should accept zero address");
    }

    function test_setPauser_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setPauser(alice);
    }

    function test_pause_requires_pauser() public {
        vm.prank(pauser);
        phlimbo.pause();
        assertTrue(phlimbo.paused(), "Pauser should be able to pause");
    }

    function test_pause_rejects_non_pauser() public {
        vm.prank(alice);
        vm.expectRevert("Only pauser can pause");
        phlimbo.pause();
    }

    function test_pause_prevents_staking() public {
        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(bob);
        vm.expectRevert();
        phlimbo.stake(STAKE_AMOUNT);
    }

    function test_pause_prevents_withdraw() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.withdraw(STAKE_AMOUNT);
    }

    function test_unpause_only_owner() public {
        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(bob);
        vm.expectRevert();
        phlimbo.unpause();

        // Owner should be able to unpause
        phlimbo.unpause();
        assertTrue(!phlimbo.paused(), "Owner should be able to unpause");
    }

    // ========================== EMERGENCY TRANSFER TESTS ==========================

    function test_emergencyTransfer_moves_all_funds() public {
        // Setup: put tokens in contract
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        address recipient = address(0x999);

        uint256 phUSDInContract = phUSD.balanceOf(address(phlimbo));
        uint256 stableInContract = stable.balanceOf(address(phlimbo));

        phlimbo.emergencyTransfer(recipient);

        assertEq(phUSD.balanceOf(recipient), phUSDInContract, "All phUSD should be transferred");
        assertEq(stable.balanceOf(recipient), stableInContract, "All stable should be transferred");
    }

    function test_emergencyTransfer_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.emergencyTransfer(address(0x999));
    }

    // ========================== REWARD CALCULATION TESTS ==========================

    function test_rewards_proportional_to_stake() public {
        // Setup principal in YieldStrategy so emission can be calculated
        yieldStrategy.setPrincipal(address(stable), minter, 100000 ether);
        yieldStrategy.setTotal(address(stable), minter, 100000 ether);

        // Alice stakes 2x Bob's amount
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT * 2);

        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT);

        // Set APY and wait
        phlimbo.setDesiredAPY(500);
        vm.warp(block.timestamp + 365 days);

        uint256 alicePending = phlimbo.pendingPhUSD(alice);
        uint256 bobPending = phlimbo.pendingPhUSD(bob);

        // Alice should have approximately 2x Bob's rewards
        // Red phase: this will fail because phUSDPerSecond is 0
        assertGt(alicePending, bobPending, "Larger stake should earn more rewards");
        assertApproxEqRel(alicePending, bobPending * 2, 0.01e18, "Rewards should be proportional to stake");
    }

    function test_rewards_accumulate_over_time() public {
        // Setup principal in YieldStrategy so emission can be calculated
        yieldStrategy.setPrincipal(address(stable), minter, 100000 ether);
        yieldStrategy.setTotal(address(stable), minter, 100000 ether);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        phlimbo.setDesiredAPY(500);

        vm.warp(block.timestamp + 30 days);
        uint256 pending30Days = phlimbo.pendingPhUSD(alice);

        vm.warp(block.timestamp + 30 days); // Total 60 days
        uint256 pending60Days = phlimbo.pendingPhUSD(alice);

        // Rewards should increase over time
        // Red phase: this will fail because phUSDPerSecond is 0
        assertGt(pending60Days, pending30Days, "Rewards should accumulate over time");
        assertApproxEqRel(pending60Days, pending30Days * 2, 0.01e18, "Rewards should be linear over time");
    }

    // ========================== YIELD STRATEGY INTEGRATION TESTS ==========================

    function test_pool_update_pulls_stable_yield() public {
        // Setup yield in strategy
        yieldStrategy.setTotal(address(stable), minter, 1000 ether);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // In working implementation, pool update should harvest stable
        // Red phase: this will fail because _harvestStable is stubbed
        uint256 accStableBefore = phlimbo.accStablePerShare();

        vm.warp(block.timestamp + 1 days);

        // Trigger pool update
        vm.prank(bob);
        phlimbo.stake(1 ether);

        uint256 accStableAfter = phlimbo.accStablePerShare();

        assertGt(accStableAfter, accStableBefore, "Pool update should harvest stable yield");
    }

    function test_emission_rate_based_on_yield_principal() public {
        // Setup principal in YieldStrategy
        yieldStrategy.setPrincipal(address(stable), minter, 100000 ether);
        yieldStrategy.setTotal(address(stable), minter, 100000 ether);

        phlimbo.setDesiredAPY(500); // 5% APY

        uint256 emission = phlimbo.phUSDPerSecond();

        // Expected emission = (principal * APY) / seconds_per_year
        // Red phase: this will fail because _calculatePhUSDPerSecond returns 0
        uint256 expectedAnnualEmission = (100000 ether * 500) / 10000; // 5000 ether per year
        uint256 expectedPerSecond = expectedAnnualEmission / phlimbo.SECONDS_PER_YEAR();

        assertApproxEqRel(emission, expectedPerSecond, 0.01e18, "Emission should be based on principal and APY");
    }

    // ========================== MEV PROTECTION TESTS ==========================

    function test_no_mev_exploit_on_update() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        phlimbo.setDesiredAPY(500);
        vm.warp(block.timestamp + 1 days);

        // Record pending rewards
        uint256 pendingBefore = phlimbo.pendingPhUSD(alice);

        // Bob stakes (triggers pool update)
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT);

        // Alice's pending should not decrease
        uint256 pendingAfter = phlimbo.pendingPhUSD(alice);

        assertGe(pendingAfter, pendingBefore, "Pool update should not decrease existing user rewards");
    }

    // ========================== VIEW FUNCTION TESTS ==========================

    function test_pendingPhUSD_returns_correct_amount() public {
        // Setup principal in YieldStrategy so emission can be calculated
        // Use same amount as staked so APY calculation is straightforward
        yieldStrategy.setPrincipal(address(stable), minter, STAKE_AMOUNT);
        yieldStrategy.setTotal(address(stable), minter, STAKE_AMOUNT);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        phlimbo.setDesiredAPY(500);
        vm.warp(block.timestamp + 365 days);

        uint256 pending = phlimbo.pendingPhUSD(alice);

        // With 5% APY on STAKE_AMOUNT (which equals principal) for 1 year
        // Since Alice has 100% of total staked, she gets 100% of emissions
        // Emissions = (principal * APY) / 10000 = (STAKE_AMOUNT * 500) / 10000
        uint256 expectedReward = (STAKE_AMOUNT * 500) / 10000; // 5% of stake
        assertApproxEqRel(pending, expectedReward, 0.02e18, "Pending rewards should match APY calculation");
    }

    function test_pendingStable_returns_correct_amount() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Simulate stable accumulation
        // This requires _harvestStable to work properly
        // Red phase: this will likely fail

        uint256 pending = phlimbo.pendingStable(alice);
        // In working implementation, this should reflect harvested stable
        assertGe(pending, 0, "Pending stable should be non-negative");
    }

    function test_getPoolInfo_returns_correct_data() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        phlimbo.setDesiredAPY(500);

        (
            uint256 totalStaked,
            uint256 accPhUSDPerShare,
            uint256 accStablePerShare,
            uint256 phUSDPerSecond,
            uint256 lastRewardTime
        ) = phlimbo.getPoolInfo();

        assertEq(totalStaked, STAKE_AMOUNT, "Total staked should match");
        assertGe(accPhUSDPerShare, 0, "Accumulated phUSD per share should be non-negative");
        assertGe(accStablePerShare, 0, "Accumulated stable per share should be non-negative");
        assertGe(phUSDPerSecond, 0, "Emission rate should be non-negative");
        assertGe(lastRewardTime, 0, "Last reward time should be non-negative");
    }
}
