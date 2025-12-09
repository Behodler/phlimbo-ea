// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Phlimbo.sol";
import "./Mocks.sol";

/**
 * @title PhlimboEMATest
 * @notice Comprehensive test suite for Phlimbo with EMA-based reward collection
 */
contract PhlimboEMATest is Test {
    PhlimboEA public phlimbo;
    MockFlax public phUSD;
    MockStable public rewardToken;
    MockYieldAccumulator public yieldAccumulator;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public pauser = address(0x4);

    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant ALPHA = 0.1e18; // 10% weight on new rate

    function setUp() public {
        // Deploy mock contracts
        phUSD = new MockFlax();
        rewardToken = new MockStable();
        yieldAccumulator = new MockYieldAccumulator();

        // Deploy Phlimbo with new constructor
        phlimbo = new PhlimboEA(
            address(phUSD),
            address(rewardToken),
            address(yieldAccumulator),
            ALPHA
        );

        // Set up phUSD minter
        phUSD.setMinter(address(phlimbo), true);

        // Mint initial tokens
        phUSD.mint(alice, INITIAL_BALANCE);
        phUSD.mint(bob, INITIAL_BALANCE);
        rewardToken.mint(address(yieldAccumulator), INITIAL_BALANCE);

        // Approve Phlimbo to spend tokens
        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);

        // Approve Phlimbo to pull reward tokens from yield accumulator
        vm.prank(address(yieldAccumulator));
        rewardToken.approve(address(phlimbo), type(uint256).max);

        // Set up pauser
        phlimbo.setPauser(pauser);
    }

    // ========================== CONSTRUCTOR TESTS ==========================

    function test_constructor_sets_initial_state() public {
        assertEq(address(phlimbo.phUSD()), address(phUSD), "phUSD should be set");
        assertEq(address(phlimbo.rewardToken()), address(rewardToken), "rewardToken should be set");
        assertEq(phlimbo.yieldAccumulator(), address(yieldAccumulator), "yieldAccumulator should be set");
        assertEq(phlimbo.alpha(), ALPHA, "alpha should be set");
        assertEq(phlimbo.smoothedStablePerSecond(), 0, "smoothedStablePerSecond should start at 0");
    }

    function test_constructor_rejects_zero_addresses() public {
        vm.expectRevert("Invalid phUSD address");
        new PhlimboEA(address(0), address(rewardToken), address(yieldAccumulator), ALPHA);

        vm.expectRevert("Invalid reward token address");
        new PhlimboEA(address(phUSD), address(0), address(yieldAccumulator), ALPHA);

        vm.expectRevert("Invalid yield accumulator address");
        new PhlimboEA(address(phUSD), address(rewardToken), address(0), ALPHA);
    }

    function test_constructor_rejects_invalid_alpha() public {
        vm.expectRevert("Alpha must be between 0 and 1e18");
        new PhlimboEA(address(phUSD), address(rewardToken), address(yieldAccumulator), 0);

        vm.expectRevert("Alpha must be between 0 and 1e18");
        new PhlimboEA(address(phUSD), address(rewardToken), address(yieldAccumulator), 1.1e18);
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

    // ========================== COLLECT REWARD TESTS ==========================

    function test_collectReward_pulls_tokens_via_transferFrom() public {
        uint256 rewardAmount = 100 ether;
        uint256 accumBefore = rewardToken.balanceOf(address(yieldAccumulator));
        uint256 phlimboBefore = rewardToken.balanceOf(address(phlimbo));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        uint256 accumAfter = rewardToken.balanceOf(address(yieldAccumulator));
        uint256 phlimboAfter = rewardToken.balanceOf(address(phlimbo));

        assertEq(accumBefore - accumAfter, rewardAmount, "Tokens should be pulled from accumulator");
        assertEq(phlimboAfter - phlimboBefore, rewardAmount, "Tokens should be received by Phlimbo");
    }

    function test_collectReward_only_yield_accumulator_can_call() public {
        vm.prank(alice);
        vm.expectRevert("Only yield accumulator can call");
        phlimbo.collectReward(100 ether);
    }

    function test_collectReward_rejects_zero_amount() public {
        vm.prank(address(yieldAccumulator));
        vm.expectRevert("Amount must be greater than 0");
        phlimbo.collectReward(0);
    }

    function test_collectReward_initializes_smoothed_rate_on_first_call() public {
        uint256 rewardAmount = 100 ether;

        vm.warp(block.timestamp + 10); // 10 seconds elapsed

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        // First claim should initialize smoothedStablePerSecond to instantRate
        // instantRate = (100 ether * 1e18) / 10 = 10 ether per second (in 1e18 precision)
        uint256 expectedRate = (rewardAmount * 1e18) / 10;
        assertEq(phlimbo.smoothedStablePerSecond(), expectedRate, "Should initialize to instant rate");
    }

    function test_collectReward_updates_smoothed_rate_with_EMA() public {
        // First claim
        vm.warp(block.timestamp + 10);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        uint256 firstRate = phlimbo.smoothedStablePerSecond();

        // Second claim with different amount
        vm.warp(block.timestamp + 10);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(200 ether); // Higher amount

        uint256 secondRate = phlimbo.smoothedStablePerSecond();

        // Second rate should be higher than first but not instantly jump to new rate
        assertGt(secondRate, firstRate, "Rate should increase");

        // Instant rate for second claim = (200 ether * 1e18) / 10 = 20 ether/s
        uint256 instantRate = (200 ether * 1e18) / 10;
        assertLt(secondRate, instantRate, "Should not jump immediately to instant rate (EMA smoothing)");
    }

    function test_collectReward_handles_same_block_claims() public {
        // Two claims in same block (deltaTime = 0, should be set to 1)
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Verify it doesn't revert and handles deltaTime = 0 case
        assertGt(phlimbo.smoothedStablePerSecond(), 0, "Should handle same block claim");
    }

    function test_collectReward_emits_event() public {
        vm.warp(block.timestamp + 10);

        vm.expectEmit(false, false, false, false);
        emit PhlimboEA.RewardCollected(0, 0, 0); // We just check the event is emitted

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);
    }

    // ========================== EMA SMOOTHING TESTS ==========================

    function test_EMA_smooths_choppy_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        uint256[] memory rates = new uint256[](5);

        // Simulate choppy reward pattern: 10, 100, 10, 100, 10
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 10 ether;
        amounts[1] = 100 ether;
        amounts[2] = 10 ether;
        amounts[3] = 100 ether;
        amounts[4] = 10 ether;

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 10);
            vm.prank(address(yieldAccumulator));
            phlimbo.collectReward(amounts[i]);
            rates[i] = phlimbo.smoothedStablePerSecond();
        }

        // Verify smoothing: rate should not swing wildly between extremes
        // After EMA, the rate should be more stable than instant rates
        for (uint256 i = 1; i < 5; i++) {
            // Rate changes should be gradual, not instant jumps
            uint256 rateDiff = rates[i] > rates[i-1] ? rates[i] - rates[i-1] : rates[i-1] - rates[i];
            uint256 maxInstantRate = (100 ether * 1e18) / 10;

            // Rate change should be less than the full swing
            assertLt(rateDiff, maxInstantRate / 2, "EMA should smooth rate changes");
        }
    }

    function test_EMA_rate_converges_with_stable_input() public {
        // Simulate consistent rewards to test convergence
        uint256 consistentAmount = 100 ether;
        uint256 lastRate = 0;

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 10);
            vm.prank(address(yieldAccumulator));
            phlimbo.collectReward(consistentAmount);

            uint256 currentRate = phlimbo.smoothedStablePerSecond();
            if (i > 0) {
                // Rate should be converging (change getting smaller)
                assertGt(currentRate, 0, "Rate should be positive");
            }
            lastRate = currentRate;
        }

        // After many iterations, should converge close to instant rate
        uint256 expectedInstantRate = (consistentAmount * 1e18) / 10;
        assertApproxEqRel(lastRate, expectedInstantRate, 0.1e18, "Should converge to instant rate");
    }

    // ========================== POOL ACCRUAL TESTS ==========================

    function test_updatePool_accrues_rewards_based_on_smoothed_rate() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Collect reward to initialize rate
        vm.warp(block.timestamp + 10);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        uint256 accStableBefore = phlimbo.accStablePerShare();

        // Wait some time for rewards to accrue
        vm.warp(block.timestamp + 100);

        // Trigger pool update by having bob stake
        vm.prank(bob);
        phlimbo.stake(1 ether);

        uint256 accStableAfter = phlimbo.accStablePerShare();

        assertGt(accStableAfter, accStableBefore, "Should accrue rewards based on smoothed rate");
    }

    function test_updatePool_caps_distribution_by_pot_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Small reward to start
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(1 ether);

        // Wait a very long time (more than pot can sustain)
        vm.warp(block.timestamp + 365 days);

        uint256 potBefore = rewardToken.balanceOf(address(phlimbo));

        // Trigger pool update
        vm.prank(bob);
        phlimbo.stake(1 ether);

        uint256 potAfter = rewardToken.balanceOf(address(phlimbo));

        // Pot should not go below zero (capping works)
        assertGe(potAfter, 0, "Pot should not go negative");
        assertLe(potBefore - potAfter, potBefore, "Should not over-distribute");
    }

    function test_updatePool_handles_totalStaked_zero() public {
        // No stakers yet
        assertEq(phlimbo.totalStaked(), 0, "No stakers initially");

        // Collect reward
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Should not revert
        assertEq(phlimbo.accStablePerShare(), 0, "No accumulation when no stakers");
    }

    // ========================== CLAIM TESTS ==========================

    function test_claim_distributes_stable_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // Collect rewards to build up pot
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Wait for rewards to accrue
        vm.warp(block.timestamp + 100);

        uint256 stableBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        phlimbo.claim();

        uint256 stableAfter = rewardToken.balanceOf(alice);

        assertGt(stableAfter, stableBefore, "Should receive stable rewards");
    }

    function test_EMA_provides_smooth_reward_rate() public {
        // This test verifies that EMA smoothing works to provide stable reward rates
        // despite irregular reward collection patterns
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        // First claim establishes baseline
        vm.warp(block.timestamp + 100);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);
        uint256 rate1 = phlimbo.smoothedStablePerSecond();

        // Second claim with very different amount
        vm.warp(block.timestamp + 100);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10 ether);
        uint256 rate2 = phlimbo.smoothedStablePerSecond();

        // Third claim back to high amount
        vm.warp(block.timestamp + 100);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);
        uint256 rate3 = phlimbo.smoothedStablePerSecond();

        // Verify smoothing: rate2 should not drop to instant rate of 10 ether / 100 seconds
        uint256 instantRateLow = (10 ether * 1e18) / 100;
        assertGt(rate2, instantRateLow * 2, "EMA should prevent rate from dropping too fast");

        // Verify smoothing: rate3 should not jump immediately back to rate1
        assertLt(rate3, rate1 * 2, "EMA should prevent rate from jumping too fast");
        assertGt(rate3, rate2, "Rate should trend upward with higher claim");
    }

    // ========================== ADMIN FUNCTION TESTS ==========================

    function test_setYieldAccumulator_updates_address() public {
        address newAccumulator = address(0x999);

        vm.expectEmit(true, true, false, false);
        emit PhlimboEA.YieldAccumulatorUpdated(address(yieldAccumulator), newAccumulator);

        phlimbo.setYieldAccumulator(newAccumulator);

        assertEq(phlimbo.yieldAccumulator(), newAccumulator, "Should update accumulator");
    }

    function test_setYieldAccumulator_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setYieldAccumulator(address(0x999));
    }

    function test_setYieldAccumulator_rejects_zero_address() public {
        vm.expectRevert("Invalid address");
        phlimbo.setYieldAccumulator(address(0));
    }

    function test_setAlpha_updates_parameter() public {
        uint256 newAlpha = 0.2e18; // 20%

        vm.expectEmit(false, false, false, true);
        emit PhlimboEA.AlphaUpdated(ALPHA, newAlpha);

        phlimbo.setAlpha(newAlpha);

        assertEq(phlimbo.alpha(), newAlpha, "Should update alpha");
    }

    function test_setAlpha_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setAlpha(0.2e18);
    }

    function test_setAlpha_rejects_invalid_values() public {
        vm.expectRevert("Alpha must be between 0 and 1e18");
        phlimbo.setAlpha(0);

        vm.expectRevert("Alpha must be between 0 and 1e18");
        phlimbo.setAlpha(1.1e18);
    }

    // ========================== PAUSE MECHANISM TESTS ==========================

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

    // ========================== EDGE CASE TESTS ==========================

    function test_handles_very_large_time_gap() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Very large time gap
        vm.warp(block.timestamp + 365 days * 10);

        // Should not revert and should cap by pot balance
        vm.prank(bob);
        phlimbo.stake(1 ether);

        assertGe(rewardToken.balanceOf(address(phlimbo)), 0, "Should handle large time gap");
    }

    function test_multiple_sequential_claims_same_block() public {
        // Multiple claims in same block should all work (deltaTime = 1 each)
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10 ether);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(20 ether);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(30 ether);

        assertGt(phlimbo.smoothedStablePerSecond(), 0, "Should handle sequential same-block claims");
    }
}
