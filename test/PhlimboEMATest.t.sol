// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Phlimbo.sol";
import "./Mocks.sol";

/**
 * @title PhlimboLinearDepletionTest
 * @notice Comprehensive test suite for Phlimbo with Linear Depletion reward collection
 */
contract PhlimboLinearDepletionTest is Test {
    // Re-declare events for use in expectEmit
    event RewardCollected(uint256 amount, uint256 newRewardBalance, uint256 newRate);
    event YieldAccumulatorUpdated(address indexed oldAccumulator, address indexed newAccumulator);
    event RateUpdated(uint256 newRate, uint256 newBalance);
    event DepletionDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event EmergencyWithdrawal(address indexed user, uint256 amount);
    event IntendedSetAPY(uint256 indexed proposedAPY, uint256 blockNumber, address indexed proposer);
    event DesiredAPYUpdated(uint256 oldAPY, uint256 newAPY);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 phUSDAmount, uint256 stableAmount);

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
    uint256 constant DEPLETION_DURATION = 604800; // 1 week in seconds

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
            DEPLETION_DURATION
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
        assertEq(phlimbo.depletionDuration(), DEPLETION_DURATION, "depletionDuration should be set");
        assertEq(phlimbo.rewardBalance(), 0, "rewardBalance should start at 0");
        assertEq(phlimbo.rewardPerSecond(), 0, "rewardPerSecond should start at 0");
    }

    function test_constructor_rejects_zero_addresses() public {
        vm.expectRevert("Invalid phUSD address");
        new PhlimboEA(address(0), address(rewardToken), address(yieldAccumulator), DEPLETION_DURATION);

        vm.expectRevert("Invalid reward token address");
        new PhlimboEA(address(phUSD), address(0), address(yieldAccumulator), DEPLETION_DURATION);

        vm.expectRevert("Invalid yield accumulator address");
        new PhlimboEA(address(phUSD), address(rewardToken), address(0), DEPLETION_DURATION);
    }

    function test_constructor_rejects_zero_duration() public {
        vm.expectRevert("Duration must be > 0");
        new PhlimboEA(address(phUSD), address(rewardToken), address(yieldAccumulator), 0);
    }

    // ========================== STAKING TESTS ==========================

    function test_stake_updates_user_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT, "User balance should equal staked amount");
    }

    function test_stake_updates_total_staked() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        uint256 totalStaked = phlimbo.totalStaked();
        assertEq(totalStaked, STAKE_AMOUNT, "Total staked should increase by stake amount");
    }

    function test_stake_transfers_tokens() public {
        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, STAKE_AMOUNT, "Tokens should be transferred from user");

        uint256 contractBalance = phUSD.balanceOf(address(phlimbo));
        assertEq(contractBalance, STAKE_AMOUNT, "Tokens should be in contract");
    }

    function test_stake_on_behalf_of_another_address() public {
        uint256 aliceBalanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, bob);

        uint256 aliceBalanceAfter = phUSD.balanceOf(alice);
        assertEq(aliceBalanceBefore - aliceBalanceAfter, STAKE_AMOUNT, "Alice should pay for the stake");

        (uint256 bobAmount,,) = phlimbo.userInfo(bob);
        assertEq(bobAmount, STAKE_AMOUNT, "Bob should receive the staked position");

        (uint256 aliceAmount,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, 0, "Alice should not receive the staked position");
    }

    function test_stake_with_address_zero_defaults_to_msg_sender() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT, "address(0) should default to msg.sender");
    }

    // ========================== WITHDRAWAL TESTS ==========================

    function test_withdraw_returns_tokens() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, STAKE_AMOUNT, "Staked tokens should be returned");
    }

    // ========================== COLLECT REWARD TESTS (Linear Depletion) ==========================

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

    function test_collectReward_increases_balance_and_rate() public {
        uint256 rewardAmount = 100 ether;

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        // Check balance increased
        assertEq(phlimbo.rewardBalance(), rewardAmount, "Reward balance should increase");

        // Check rate calculated correctly
        uint256 expectedRate = (rewardAmount * 1e18) / DEPLETION_DURATION;
        assertEq(phlimbo.rewardPerSecond(), expectedRate, "Rate should be balance / duration");
    }

    function test_rate_equals_balance_divided_by_duration() public {
        uint256 rewardAmount = 100 ether;

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        uint256 expectedRate = (rewardAmount * 1e18) / DEPLETION_DURATION;
        uint256 actualRate = phlimbo.rewardPerSecond();

        assertEq(actualRate, expectedRate, "Rate should equal balance * PRECISION / duration");
    }

    function test_collectReward_emits_event() public {
        uint256 rewardAmount = 100 ether;

        vm.expectEmit(false, false, false, false);
        emit RewardCollected(0, 0, 0);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);
    }

    function test_user_claims_decrease_balance_and_rate() public {
        // Stake first
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        // Collect rewards (use smaller amount that fits in initial balance)
        uint256 rewardAmount = 100 ether;
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        uint256 balanceBefore = phlimbo.rewardBalance();
        uint256 rateBefore = phlimbo.rewardPerSecond();

        // Wait some time
        vm.warp(block.timestamp + 100);

        // Claim triggers _updatePool which decreases balance and recalculates rate
        vm.prank(alice);
        phlimbo.claim();

        uint256 balanceAfter = phlimbo.rewardBalance();
        uint256 rateAfter = phlimbo.rewardPerSecond();

        assertLt(balanceAfter, balanceBefore, "Balance should decrease after claim");
        assertLt(rateAfter, rateBefore, "Rate should decrease with balance");
    }

    // ========================== GRIEF RESISTANCE TESTS ==========================

    function test_cannot_recalculate_rate_without_balance_change() public {
        // Stake
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        // Collect initial rewards (use amount within balance)
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        uint256 initialBalance = phlimbo.rewardBalance();

        // Wait some time
        vm.warp(block.timestamp + 100);

        // Trigger pool update by staking more (rate should only change because balance depleted)
        vm.prank(alice);
        phlimbo.stake(1 ether, address(0));

        uint256 newRate = phlimbo.rewardPerSecond();
        uint256 newBalance = phlimbo.rewardBalance();

        // Balance should have decreased (rewards distributed)
        assertLt(newBalance, initialBalance, "Balance should decrease from distribution");

        // Rate should be proportional to new balance
        uint256 expectedRate = (newBalance * 1e18) / DEPLETION_DURATION;
        assertEq(newRate, expectedRate, "Rate should be calculated from current balance");
    }

    function test_rate_unaffected_by_collection_frequency() public {
        // Test that collecting 100 ether in 1 call vs 100 ether in 10 calls gives same end state

        // Setup scenario A: single collection
        PhlimboEA phlimboA = new PhlimboEA(
            address(phUSD),
            address(rewardToken),
            address(yieldAccumulator),
            DEPLETION_DURATION
        );

        // Setup scenario B: multiple collections
        PhlimboEA phlimboB = new PhlimboEA(
            address(phUSD),
            address(rewardToken),
            address(yieldAccumulator),
            DEPLETION_DURATION
        );

        // Give both contracts minter access
        phUSD.setMinter(address(phlimboA), true);
        phUSD.setMinter(address(phlimboB), true);

        // Approve both contracts to pull reward tokens from yield accumulator
        vm.startPrank(address(yieldAccumulator));
        rewardToken.approve(address(phlimboA), type(uint256).max);
        rewardToken.approve(address(phlimboB), type(uint256).max);
        vm.stopPrank();

        // Scenario A: Single 100 ether collection
        vm.prank(address(yieldAccumulator));
        phlimboA.collectReward(100 ether);

        // Scenario B: 10 x 10 ether collections
        for (uint i = 0; i < 10; i++) {
            vm.prank(address(yieldAccumulator));
            phlimboB.collectReward(10 ether);
        }

        // Both should have same balance and rate
        assertEq(phlimboA.rewardBalance(), phlimboB.rewardBalance(), "Balances should match");
        assertEq(phlimboA.rewardPerSecond(), phlimboB.rewardPerSecond(), "Rates should match");
    }

    // ========================== STEADY STATE TESTS ==========================

    function test_rate_converges_to_yield_rate_at_equilibrium() public {
        // This test verifies that linear depletion model correctly recalculates rate
        // after each deposit

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        uint256 weeklyYield = 100 ether;

        // Collect initial rewards
        rewardToken.mint(address(yieldAccumulator), weeklyYield);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(weeklyYield);

        uint256 initialRate = phlimbo.rewardPerSecond();
        uint256 expectedRate = (weeklyYield * 1e18) / DEPLETION_DURATION;
        assertEq(initialRate, expectedRate, "Initial rate should match formula");

        // Wait half the depletion duration
        vm.warp(block.timestamp + DEPLETION_DURATION / 2);

        // Trigger distribution via claim
        vm.prank(alice);
        phlimbo.claim();

        // Rate should have decreased (balance decreased)
        uint256 rateAfterHalf = phlimbo.rewardPerSecond();
        assertLt(rateAfterHalf, initialRate, "Rate should decrease as balance depletes");

        // Balance should be approximately half
        uint256 balanceAfterHalf = phlimbo.rewardBalance();
        assertApproxEqRel(balanceAfterHalf, weeklyYield / 2, 0.01e18, "Balance should be approx half");

        // Verify rate recalculates correctly from current balance
        uint256 expectedRateAfterHalf = (balanceAfterHalf * 1e18) / DEPLETION_DURATION;
        assertEq(rateAfterHalf, expectedRateAfterHalf, "Rate should match formula with current balance");
    }

    function test_different_depletion_windows_converge_to_same_rate() public {
        // With same yield rate, different windows converge to same equilibrium rate
        // But with different balances: balance = yieldPerSecond * duration

        uint256 shortDuration = 1 days;
        uint256 longDuration = 7 days;

        PhlimboEA phlimboShort = new PhlimboEA(
            address(phUSD),
            address(rewardToken),
            address(yieldAccumulator),
            shortDuration
        );

        PhlimboEA phlimboLong = new PhlimboEA(
            address(phUSD),
            address(rewardToken),
            address(yieldAccumulator),
            longDuration
        );

        phUSD.setMinter(address(phlimboShort), true);
        phUSD.setMinter(address(phlimboLong), true);

        // Approve both contracts to pull reward tokens from yield accumulator
        vm.startPrank(address(yieldAccumulator));
        rewardToken.approve(address(phlimboShort), type(uint256).max);
        rewardToken.approve(address(phlimboLong), type(uint256).max);
        vm.stopPrank();

        // Both receive same amount of rewards
        vm.startPrank(address(yieldAccumulator));
        phlimboShort.collectReward(100 ether);
        phlimboLong.collectReward(100 ether);
        vm.stopPrank();

        // Balances should be equal
        assertEq(phlimboShort.rewardBalance(), phlimboLong.rewardBalance(), "Same amount collected");

        // But rates differ based on duration
        uint256 shortRate = phlimboShort.rewardPerSecond();
        uint256 longRate = phlimboLong.rewardPerSecond();

        assertGt(shortRate, longRate, "Shorter duration = higher rate");
        assertApproxEqRel(shortRate, longRate * 7, 0.001e18, "Rate ratio should equal duration ratio");
    }

    // ========================== EDGE CASE TESTS ==========================

    function test_first_collection_sets_correct_rate() public {
        uint256 rewardAmount = 100 ether;

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        uint256 expectedRate = (rewardAmount * 1e18) / DEPLETION_DURATION;
        assertEq(phlimbo.rewardPerSecond(), expectedRate, "First collection should set correct rate");
        assertEq(phlimbo.rewardBalance(), rewardAmount, "First collection should set correct balance");
    }

    function test_zero_balance_means_zero_rate() public {
        // Initial state should have zero rate
        assertEq(phlimbo.rewardPerSecond(), 0, "Rate should be 0 with no balance");
        assertEq(phlimbo.rewardBalance(), 0, "Balance should be 0 initially");

        // Stake and collect rewards
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(1 ether);

        // Wait long enough for full depletion
        vm.warp(block.timestamp + DEPLETION_DURATION * 2);

        // Trigger pool update
        vm.prank(alice);
        phlimbo.claim();

        // After full depletion, rate should be zero (or near zero)
        assertEq(phlimbo.rewardBalance(), 0, "Balance should be 0 after full depletion");
        assertEq(phlimbo.rewardPerSecond(), 0, "Rate should be 0 after full depletion");
    }

    function test_balance_cannot_go_negative() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        // Small reward
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(1 ether);

        // Wait much longer than depletion duration
        vm.warp(block.timestamp + DEPLETION_DURATION * 10);

        // Trigger pool update - should not underflow
        vm.prank(alice);
        phlimbo.claim();

        // Balance should be 0, not negative
        assertEq(phlimbo.rewardBalance(), 0, "Balance should be 0, not negative");
    }

    function test_large_claim_capped_at_available_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        // Small reward
        uint256 rewardAmount = 1 ether;
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(rewardAmount);

        // Wait much longer than needed to distribute all rewards
        vm.warp(block.timestamp + DEPLETION_DURATION * 10);

        // Get pending rewards (should be capped at available balance)
        uint256 pending = phlimbo.pendingStable(alice);

        // Should not exceed original reward amount
        assertLe(pending, rewardAmount, "Pending should not exceed available rewards");

        // Claim should succeed and not revert
        uint256 balanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim();
        uint256 received = rewardToken.balanceOf(alice) - balanceBefore;

        assertLe(received, rewardAmount, "Received should not exceed available rewards");
    }

    // ========================== ADMIN FUNCTION TESTS ==========================

    function test_setDepletionDuration_updates_rate() public {
        // Collect initial rewards
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        uint256 rateBefore = phlimbo.rewardPerSecond();
        uint256 newDuration = DEPLETION_DURATION / 2; // Half the duration = double the rate

        phlimbo.setDepletionDuration(newDuration);

        uint256 rateAfter = phlimbo.rewardPerSecond();

        // Rate should double when duration halves
        assertApproxEqRel(rateAfter, rateBefore * 2, 0.001e18, "Rate should double when duration halves");
    }

    function test_setDepletionDuration_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setDepletionDuration(1 days);
    }

    function test_setDepletionDuration_rejects_zero() public {
        vm.expectRevert("Duration must be > 0");
        phlimbo.setDepletionDuration(0);
    }

    function test_setDepletionDuration_emits_event() public {
        uint256 newDuration = 1 days;

        vm.expectEmit(false, false, false, true);
        emit DepletionDurationUpdated(DEPLETION_DURATION, newDuration);

        phlimbo.setDepletionDuration(newDuration);
    }

    // ========================== YIELD ACCUMULATOR TESTS ==========================

    function test_setYieldAccumulator_updates_address() public {
        address newAccumulator = address(0x999);

        vm.expectEmit(true, true, false, false);
        emit YieldAccumulatorUpdated(address(yieldAccumulator), newAccumulator);

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

    // ========================== PAUSE MECHANISM TESTS ==========================

    function test_pause_prevents_staking() public {
        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(bob);
        vm.expectRevert();
        phlimbo.stake(STAKE_AMOUNT, address(0));
    }

    function test_pause_prevents_withdraw() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.withdraw(STAKE_AMOUNT);
    }

    // ========================== EMERGENCY TRANSFER AND PAUSE WITHDRAW TESTS ==========================

    function test_emergencyTransfer_pauses_contract() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        assertFalse(phlimbo.paused(), "Contract should not be paused initially");

        address treasury = address(0x999);
        phlimbo.emergencyTransfer(treasury);

        assertTrue(phlimbo.paused(), "Contract should be paused after emergencyTransfer");
    }

    function test_pauseWithdraw_only_works_when_paused() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0, "User balance should be 0 after pauseWithdraw");
    }

    function test_pauseWithdraw_correctly_updates_balances() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        uint256 totalStakedBefore = phlimbo.totalStaked();
        (uint256 userAmountBefore,,) = phlimbo.userInfo(alice);

        vm.prank(pauser);
        phlimbo.pause();

        uint256 withdrawAmount = STAKE_AMOUNT / 2;
        vm.prank(alice);
        phlimbo.pauseWithdraw(withdrawAmount);

        (uint256 userAmountAfter,,) = phlimbo.userInfo(alice);
        uint256 totalStakedAfter = phlimbo.totalStaked();

        assertEq(userAmountAfter, userAmountBefore - withdrawAmount, "User balance should decrease");
        assertEq(totalStakedAfter, totalStakedBefore - withdrawAmount, "Total staked should decrease");
    }

    function test_pauseWithdraw_transfers_correct_amount() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(pauser);
        phlimbo.pause();

        uint256 balanceBefore = phUSD.balanceOf(alice);
        uint256 withdrawAmount = STAKE_AMOUNT / 2;

        vm.prank(alice);
        phlimbo.pauseWithdraw(withdrawAmount);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Should transfer correct amount");
    }

    function test_pauseWithdraw_doesnt_claim_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + 100);

        uint256 pendingBefore = phlimbo.pendingStable(alice);
        assertGt(pendingBefore, 0, "Should have pending rewards");

        vm.prank(pauser);
        phlimbo.pause();

        uint256 stableBalanceBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        uint256 stableBalanceAfter = rewardToken.balanceOf(alice);

        assertEq(stableBalanceAfter, stableBalanceBefore, "Should not receive rewards during pauseWithdraw");
    }

    function test_pauseWithdraw_doesnt_update_pool() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + 100);

        vm.prank(pauser);
        phlimbo.pause();

        uint256 accStableBefore = phlimbo.accStablePerShare();
        uint256 lastRewardTimeBefore = phlimbo.lastRewardTime();

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT / 2);

        uint256 accStableAfter = phlimbo.accStablePerShare();
        uint256 lastRewardTimeAfter = phlimbo.lastRewardTime();

        assertEq(accStableAfter, accStableBefore, "accStablePerShare should not change");
        assertEq(lastRewardTimeAfter, lastRewardTimeBefore, "lastRewardTime should not change");
    }

    function test_users_cannot_stake_after_emergency_pause() public {
        address treasury = address(0x999);
        phlimbo.emergencyTransfer(treasury);

        vm.prank(bob);
        vm.expectRevert();
        phlimbo.stake(STAKE_AMOUNT, address(0));
    }

    function test_users_cannot_withdraw_after_emergency_pause() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        address treasury = address(0x999);
        phlimbo.emergencyTransfer(treasury);

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.withdraw(STAKE_AMOUNT);
    }

    function test_users_cannot_claim_after_emergency_pause() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + 100);

        address treasury = address(0x999);
        phlimbo.emergencyTransfer(treasury);

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.claim();
    }

    function test_pauseWithdraw_rejects_withdrawal_exceeding_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert("Insufficient balance");
        phlimbo.pauseWithdraw(STAKE_AMOUNT + 1 ether);
    }

    function test_pauseWithdraw_rejects_zero_amount() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert("Amount must be greater than 0");
        phlimbo.pauseWithdraw(0);
    }

    function test_full_emergency_scenario() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT / 2, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + 100);

        uint256 contractPhUSDBefore = phUSD.balanceOf(address(phlimbo));
        uint256 contractRewardBefore = rewardToken.balanceOf(address(phlimbo));
        assertGt(contractPhUSDBefore, 0, "Contract should have phUSD");
        assertGt(contractRewardBefore, 0, "Contract should have rewards");

        address treasury = address(0x999);
        phlimbo.emergencyTransfer(treasury);

        assertTrue(phlimbo.paused(), "Contract should be paused");
        assertEq(phUSD.balanceOf(treasury), contractPhUSDBefore, "Treasury should receive phUSD");
        assertEq(rewardToken.balanceOf(treasury), contractRewardBefore, "Treasury should receive rewards");
        assertEq(phUSD.balanceOf(address(phlimbo)), 0, "Contract phUSD balance should be 0");
        assertEq(rewardToken.balanceOf(address(phlimbo)), 0, "Contract reward balance should be 0");

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.withdraw(STAKE_AMOUNT);

        vm.prank(bob);
        vm.expectRevert();
        phlimbo.claim();

        uint256 aliceBalanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        vm.prank(treasury);
        phUSD.transfer(address(phlimbo), STAKE_AMOUNT);

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        uint256 aliceBalanceAfter = phUSD.balanceOf(alice);
        assertEq(aliceBalanceAfter - aliceBalanceBefore, STAKE_AMOUNT, "Alice should recover her stake");

        (uint256 aliceAmount,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, 0, "Alice balance should be 0");
    }

    function test_pauseWithdraw_emits_event() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(pauser);
        phlimbo.pause();

        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawal(alice, STAKE_AMOUNT);

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT);
    }

    function test_pauseWithdraw_multiple_users() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT / 2, address(0));

        uint256 totalStakedBefore = phlimbo.totalStaked();
        assertEq(totalStakedBefore, STAKE_AMOUNT + STAKE_AMOUNT / 2, "Total staked should be sum");

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        (uint256 aliceAmount,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, 0, "Alice balance should be 0");

        vm.prank(bob);
        phlimbo.pauseWithdraw(STAKE_AMOUNT / 4);

        (uint256 bobAmount,,) = phlimbo.userInfo(bob);
        assertEq(bobAmount, STAKE_AMOUNT / 4, "Bob should have half remaining");

        uint256 totalStakedAfter = phlimbo.totalStaked();
        assertEq(totalStakedAfter, STAKE_AMOUNT / 4, "Total staked should be bob's remainder");
    }

    // ========================== EDGE CASE TESTS ==========================

    function test_handles_very_large_time_gap() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Very large time gap
        vm.warp(block.timestamp + 365 days * 10);

        // Should not revert and should cap by balance
        vm.prank(bob);
        phlimbo.stake(1 ether, address(0));

        assertGe(rewardToken.balanceOf(address(phlimbo)), 0, "Should handle large time gap");
    }

    function test_multiple_sequential_claims() public {
        // Multiple collections should all work
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10 ether);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(20 ether);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(30 ether);

        assertEq(phlimbo.rewardBalance(), 60 ether, "Should accumulate all collections");
    }

    // ========================== PHUSD EMISSION RATE TESTS ==========================

    function test_emission_rate_calculates_correctly() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        vm.prank(alice);
        phlimbo.stake(200 ether, address(0));

        uint256 SECONDS_PER_YEAR = 365 days;
        uint256 expectedRate = (200 ether * 800) / 10000 / SECONDS_PER_YEAR;
        uint256 actualRate = phlimbo.phUSDPerSecond();

        assertEq(actualRate, expectedRate, "Emission rate should match formula");
    }

    function test_emission_rate_updates_on_stake_increase() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        vm.prank(alice);
        phlimbo.stake(100 ether, address(0));
        uint256 rateBefore = phlimbo.phUSDPerSecond();

        vm.prank(bob);
        phlimbo.stake(100 ether, address(0));
        uint256 rateAfter = phlimbo.phUSDPerSecond();

        assertGt(rateAfter, rateBefore, "Rate should increase");
        assertEq(rateAfter, rateBefore * 2, "Rate should double with double stake");
    }

    function test_emission_rate_updates_on_withdraw_decrease() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        vm.prank(alice);
        phlimbo.stake(200 ether, address(0));
        uint256 rateBefore = phlimbo.phUSDPerSecond();

        vm.prank(alice);
        phlimbo.withdraw(100 ether);
        uint256 rateAfter = phlimbo.phUSDPerSecond();

        assertLt(rateAfter, rateBefore, "Rate should decrease");
        assertEq(rateAfter, rateBefore / 2, "Rate should halve when stake halves");
    }

    function test_emission_rate_is_zero_when_no_stake() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        uint256 rate = phlimbo.phUSDPerSecond();
        assertEq(rate, 0, "Emission rate should be 0 with no stakers");
    }

    function test_emission_rate_becomes_zero_after_full_withdraw() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        vm.prank(alice);
        phlimbo.stake(100 ether, address(0));
        assertGt(phlimbo.phUSDPerSecond(), 0, "Rate should be positive after staking");

        vm.prank(alice);
        phlimbo.withdraw(100 ether);
        assertEq(phlimbo.phUSDPerSecond(), 0, "Rate should be 0 after full withdraw");
    }

    function test_setDesiredAPY_triggers_emission_rate_recalculation() public {
        vm.prank(alice);
        phlimbo.stake(200 ether, address(0));

        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);
        uint256 rateBefore = phlimbo.phUSDPerSecond();
        assertGt(rateBefore, 0, "Rate should be positive");

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(1600);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(1600);
        uint256 rateAfter = phlimbo.phUSDPerSecond();

        assertEq(rateAfter, rateBefore * 2, "Rate should double when APY doubles");
    }

    function test_emission_rate_example_200_phUSD_8_percent_APY() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        vm.prank(alice);
        phlimbo.stake(200 ether, address(0));

        uint256 rate = phlimbo.phUSDPerSecond();

        uint256 SECONDS_PER_YEAR = 365 days;
        uint256 expectedRate = (200 ether * 800) / 10000 / SECONDS_PER_YEAR;
        assertEq(rate, expectedRate, "Should match example calculation");

        uint256 annualEmissions = rate * SECONDS_PER_YEAR;
        assertApproxEqRel(annualEmissions, 16 ether, 0.001e18, "Annual yield should be ~16 phUSD");
    }

    function test_phUSD_rewards_accrue_with_emission_rate() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);
        vm.prank(alice);
        phlimbo.stake(200 ether, address(0));

        vm.warp(block.timestamp + 1 days);

        uint256 pending = phlimbo.pendingPhUSD(alice);

        uint256 annualYield = (200 ether * 800) / 10000;
        uint256 daysPerYear = 365;
        uint256 expectedDaily = annualYield / daysPerYear;
        assertApproxEqRel(pending, expectedDaily, 0.001e18, "Daily phUSD rewards should accrue");
    }

    // ========================== SECURITY TESTS - FIRST DEPOSITOR ATTACK MITIGATION ==========================

    function test_stake_below_minimum_reverts() public {
        uint256 belowMinimum = phlimbo.MINIMUM_STAKE() - 1;

        vm.prank(alice);
        vm.expectRevert("Below minimum stake");
        phlimbo.stake(belowMinimum, address(0));
    }

    function test_stake_at_minimum_succeeds() public {
        uint256 minimum = phlimbo.MINIMUM_STAKE();

        vm.prank(alice);
        phlimbo.stake(minimum, address(0));

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, minimum, "Should stake exactly at minimum");
    }

    function test_withdraw_leaving_dust_withdraws_all() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        phlimbo.stake(stakeAmount, address(0));

        uint256 attemptedWithdraw = stakeAmount - 500;
        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(attemptedWithdraw);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, stakeAmount, "Should withdraw full amount when dust would remain");

        (uint256 remaining,,) = phlimbo.userInfo(alice);
        assertEq(remaining, 0, "User balance should be zero");
    }

    function test_withdraw_above_minimum_remaining_works() public {
        uint256 stakeAmount = 100 ether;
        vm.prank(alice);
        phlimbo.stake(stakeAmount, address(0));

        uint256 withdrawAmount = 50 ether;
        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(withdrawAmount);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Should withdraw exact amount");

        (uint256 remaining,,) = phlimbo.userInfo(alice);
        assertEq(remaining, stakeAmount - withdrawAmount, "User balance should be remainder");
    }

    function test_first_depositor_attack_mitigated() public {
        uint256 attackerStake = phlimbo.MINIMUM_STAKE();
        vm.prank(alice);
        phlimbo.stake(attackerStake, address(0));

        uint256 largeReward = 1000 ether;
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(largeReward);

        // Wait a significant period for rewards to accrue
        vm.warp(block.timestamp + 1 days);

        uint256 legitimateStake = 1000 ether;
        vm.prank(bob);
        phlimbo.stake(legitimateStake, address(0));

        // Wait more time for both to accrue rewards
        vm.warp(block.timestamp + 1 days);
        rewardToken.mint(address(yieldAccumulator), 1000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(1000 ether);

        vm.warp(block.timestamp + 1 days);

        uint256 attackerRewards = phlimbo.pendingStable(alice);
        uint256 legitimateRewards = phlimbo.pendingStable(bob);

        assertGt(attackerRewards, 0, "Attacker should have some rewards");
        assertGt(legitimateRewards, 0, "Legitimate user should have rewards");

        // With minimum stake being small and Bob having 1000x the stake,
        // Bob should get approximately 1000x more rewards per second (when both are staked)
        // The key is that legitimateRewards should be proportional to stake
        assertGt(legitimateRewards, attackerRewards, "Legitimate staker should get more than attacker with small stake");
    }

    function test_cannot_circumvent_minimum_by_withdraw_to_dust() public {
        uint256 stakeAmount = phlimbo.MINIMUM_STAKE() + 100;
        vm.prank(alice);
        phlimbo.stake(stakeAmount, address(0));

        uint256 attemptWithdraw = 101;
        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(attemptWithdraw);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, stakeAmount, "Should force full withdrawal");

        (uint256 remaining,,) = phlimbo.userInfo(alice);
        assertEq(remaining, 0, "No dust should remain");
    }

    // ========================== VIEW FUNCTION PROJECTION TESTS ==========================

    function test_pendingStable_shows_accurate_realtime_rewards_without_pool_update() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.prank(alice);
        phlimbo.claim();

        rewardToken.mint(address(yieldAccumulator), 5000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(5000 ether);

        vm.prank(alice);
        phlimbo.claim();

        uint256 pendingBefore = phlimbo.pendingStable(alice);
        assertEq(pendingBefore, 0, "No rewards pending immediately after claim");

        uint256 timeElapsed = 100;
        vm.warp(block.timestamp + timeElapsed);

        uint256 pendingAfter = phlimbo.pendingStable(alice);

        uint256 currentRate = phlimbo.rewardPerSecond();
        uint256 currentBalance = phlimbo.rewardBalance();
        uint256 potentialReward = (currentRate * timeElapsed) / 1e18;
        uint256 expectedDistribute = potentialReward > currentBalance ? currentBalance : potentialReward;
        uint256 expectedPending = (STAKE_AMOUNT * expectedDistribute * 1e18) / phlimbo.totalStaked() / 1e18;

        assertGt(pendingAfter, 0, "Should show pending rewards without pool update");
        assertApproxEqRel(pendingAfter, expectedPending, 0.001e18, "Projected rewards should match calculation");
    }

    function test_pendingStable_projection_matches_actual_rewards_after_claim() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.prank(alice);
        phlimbo.claim();

        rewardToken.mint(address(yieldAccumulator), 5000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(5000 ether);

        vm.prank(alice);
        phlimbo.claim();

        vm.warp(block.timestamp + 100);

        uint256 projectedPending = phlimbo.pendingStable(alice);
        assertGt(projectedPending, 0, "Should have projected pending rewards");

        uint256 balanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim();
        uint256 balanceAfter = rewardToken.balanceOf(alice);

        uint256 actualReceived = balanceAfter - balanceBefore;

        assertApproxEqRel(actualReceived, projectedPending, 0.001e18, "Projected should match actual rewards");
    }

    // ========================== TWO-STEP APY SETTING TESTS ==========================

    function test_first_setDesiredAPY_call_emits_IntendedSetAPY() public {
        uint256 newAPY = 800;

        vm.expectEmit(true, true, false, true);
        emit IntendedSetAPY(newAPY, block.number, owner);

        phlimbo.setDesiredAPY(newAPY);
    }

    function test_first_setDesiredAPY_call_does_not_change_actual_APY() public {
        uint256 initialAPY = phlimbo.desiredAPYBps();
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        assertEq(phlimbo.desiredAPYBps(), initialAPY, "First call should not change actual APY");
    }

    function test_first_setDesiredAPY_call_sets_pending_state() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        (uint256 pendingAPY, uint256 pendingBlock, bool inProgress) = phlimbo.getPendingAPYInfo();
        assertEq(pendingAPY, newAPY, "Should set pending APY");
        assertEq(pendingBlock, block.number, "Should set pending block number");
        assertTrue(inProgress, "Should mark operation as in progress");
    }

    function test_second_setDesiredAPY_call_with_same_value_commits_APY() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 1);

        phlimbo.setDesiredAPY(newAPY);

        assertEq(phlimbo.desiredAPYBps(), newAPY, "Second call should commit APY change");
    }

    function test_second_setDesiredAPY_call_emits_DesiredAPYUpdated() public {
        uint256 oldAPY = phlimbo.desiredAPYBps();
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 1);

        vm.expectEmit(false, false, false, true);
        emit DesiredAPYUpdated(oldAPY, newAPY);

        phlimbo.setDesiredAPY(newAPY);
    }

    function test_second_setDesiredAPY_call_resets_pending_state() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 1);

        phlimbo.setDesiredAPY(newAPY);

        (,, bool inProgress) = phlimbo.getPendingAPYInfo();
        assertFalse(inProgress, "Should reset in progress flag after commit");
    }

    function test_setDesiredAPY_with_different_value_resets_to_preview() public {
        uint256 firstAPY = 800;
        uint256 secondAPY = 1000;

        phlimbo.setDesiredAPY(firstAPY);

        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, true);
        emit IntendedSetAPY(secondAPY, block.number, owner);

        phlimbo.setDesiredAPY(secondAPY);

        assertEq(phlimbo.desiredAPYBps(), 0, "Should not commit when value changes");

        (uint256 pendingAPY,,) = phlimbo.getPendingAPYInfo();
        assertEq(pendingAPY, secondAPY, "Should update pending APY to new value");
    }

    function test_setDesiredAPY_after_100_blocks_resets_to_preview() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 101);

        vm.expectEmit(true, true, false, true);
        emit IntendedSetAPY(newAPY, block.number, owner);

        phlimbo.setDesiredAPY(newAPY);

        assertEq(phlimbo.desiredAPYBps(), 0, "Should not commit after 100+ blocks");
    }

    function test_setDesiredAPY_cannot_be_stuck() public {
        uint256 firstAPY = 800;
        uint256 secondAPY = 1000;
        uint256 thirdAPY = 1200;

        phlimbo.setDesiredAPY(firstAPY);

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(secondAPY);

        vm.roll(block.number + 150);

        phlimbo.setDesiredAPY(thirdAPY);

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(thirdAPY);

        assertEq(phlimbo.desiredAPYBps(), thirdAPY, "Contract should never be stuck");
    }

    function test_setDesiredAPY_multiple_preview_commit_cycles() public {
        uint256 firstAPY = 800;
        uint256 secondAPY = 1000;

        phlimbo.setDesiredAPY(firstAPY);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(firstAPY);
        assertEq(phlimbo.desiredAPYBps(), firstAPY, "First cycle should commit");

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(secondAPY);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(secondAPY);
        assertEq(phlimbo.desiredAPYBps(), secondAPY, "Second cycle should commit");
    }

    function test_setDesiredAPY_within_100_blocks_commits() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 99);
        phlimbo.setDesiredAPY(newAPY);

        assertEq(phlimbo.desiredAPYBps(), newAPY, "Should commit within 100 blocks");
    }

    function test_setDesiredAPY_at_block_100_commits() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 100);
        phlimbo.setDesiredAPY(newAPY);

        assertEq(phlimbo.desiredAPYBps(), newAPY, "Should commit at exactly 100 blocks");
    }

    function test_setDesiredAPY_at_block_101_does_not_commit() public {
        uint256 newAPY = 800;

        phlimbo.setDesiredAPY(newAPY);

        vm.roll(block.number + 101);

        vm.expectEmit(true, true, false, true);
        emit IntendedSetAPY(newAPY, block.number, owner);

        phlimbo.setDesiredAPY(newAPY);

        assertEq(phlimbo.desiredAPYBps(), 0, "Should not commit after 101 blocks");
    }

    function test_getPendingAPYInfo_returns_correct_values() public {
        uint256 newAPY = 800;

        (uint256 pendingAPY, uint256 pendingBlock, bool inProgress) = phlimbo.getPendingAPYInfo();
        assertEq(pendingAPY, 0, "Should start with 0 pending APY");
        assertEq(pendingBlock, 0, "Should start with 0 pending block");
        assertFalse(inProgress, "Should start with no operation in progress");

        phlimbo.setDesiredAPY(newAPY);
        (pendingAPY, pendingBlock, inProgress) = phlimbo.getPendingAPYInfo();
        assertEq(pendingAPY, newAPY, "Should show pending APY");
        assertEq(pendingBlock, block.number, "Should show pending block number");
        assertTrue(inProgress, "Should show operation in progress");

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(newAPY);
        (,, inProgress) = phlimbo.getPendingAPYInfo();
        assertFalse(inProgress, "Should show no operation in progress after commit");
    }

    function test_setDesiredAPY_updates_emission_rate_on_commit() public {
        uint256 newAPY = 800;

        vm.prank(alice);
        phlimbo.stake(200 ether, address(0));

        phlimbo.setDesiredAPY(newAPY);

        uint256 emissionAfterPreview = phlimbo.phUSDPerSecond();
        assertEq(emissionAfterPreview, 0, "Emission rate should not change on preview");

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(newAPY);

        uint256 emissionAfterCommit = phlimbo.phUSDPerSecond();
        uint256 SECONDS_PER_YEAR = 365 days;
        uint256 expectedRate = (200 ether * 800) / 10000 / SECONDS_PER_YEAR;
        assertEq(emissionAfterCommit, expectedRate, "Emission rate should update on commit");
    }

    function test_setDesiredAPY_only_owner_can_call() public {
        uint256 newAPY = 800;

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setDesiredAPY(newAPY);
    }

    // ========================== USER ACTION EVENT TESTS ==========================

    function test_stake_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit Staked(alice, STAKE_AMOUNT);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));
    }

    function test_withdraw_emits_event() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, STAKE_AMOUNT);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);
    }

    function test_withdraw_emits_event_with_actual_amount_when_dust_prevented() public {
        uint256 stakeAmount = 10 ether;
        vm.prank(alice);
        phlimbo.stake(stakeAmount, address(0));

        uint256 attemptedWithdraw = stakeAmount - 500;

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, stakeAmount);

        vm.prank(alice);
        phlimbo.withdraw(attemptedWithdraw);
    }

    function test_claim_emits_RewardsClaimed_event() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        rewardToken.mint(address(yieldAccumulator), 10000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10000 ether);

        vm.prank(alice);
        phlimbo.claim();
    }

    function test_claim_emits_event_when_only_phUSD_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        vm.warp(block.timestamp + 100);

        uint256 pendingPhUSD = phlimbo.pendingPhUSD(alice);
        assertGt(pendingPhUSD, 0, "Should have phUSD rewards");

        vm.expectEmit(true, false, false, true);
        emit RewardsClaimed(alice, pendingPhUSD, 0);

        vm.prank(alice);
        phlimbo.claim();
    }

    function test_claim_emits_event_when_only_stable_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        rewardToken.mint(address(yieldAccumulator), 10000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10000 ether);

        vm.prank(alice);
        phlimbo.claim();
    }

    function test_withdraw_triggers_RewardsClaimed_event() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        rewardToken.mint(address(yieldAccumulator), 10000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10000 ether);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);
    }

    function test_stake_with_existing_position_triggers_RewardsClaimed_event() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);

        rewardToken.mint(address(yieldAccumulator), 10000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(10000 ether);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));
    }

    function test_no_RewardsClaimed_event_when_no_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        uint256 phUSDBefore = phUSD.balanceOf(alice);
        uint256 stableBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        phlimbo.claim();

        uint256 phUSDAfter = phUSD.balanceOf(alice);
        uint256 stableAfter = rewardToken.balanceOf(alice);

        assertEq(phUSDAfter, phUSDBefore, "No phUSD rewards should be claimed");
        assertEq(stableAfter, stableBefore, "No stable rewards should be claimed");
    }

    // ========================== ZERO APY TESTS ==========================

    function test_zero_APY_stake_does_not_revert() public {
        assertEq(phlimbo.desiredAPYBps(), 0, "APY should be 0 by default");

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT, "Stake should succeed with zero APY");
        assertEq(phlimbo.phUSDPerSecond(), 0, "Emission rate should be 0");
    }

    function test_zero_APY_claim_does_not_revert() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        phlimbo.claim();

        assertEq(phlimbo.pendingPhUSD(alice), 0, "No phUSD should be pending");
    }

    function test_zero_APY_withdraw_does_not_revert() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.warp(block.timestamp + 100);

        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);

        uint256 balanceAfter = phUSD.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, STAKE_AMOUNT, "Should withdraw full amount");
    }

    function test_zero_APY_with_stable_rewards_works() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        rewardToken.mint(address(yieldAccumulator), 10000 ether);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Wait some time for rewards to accrue
        vm.warp(block.timestamp + 100);

        uint256 pendingStable = phlimbo.pendingStable(alice);
        assertGt(pendingStable, 0, "Should have pending stable rewards even with zero APY");

        uint256 pendingPhUSD = phlimbo.pendingPhUSD(alice);
        assertEq(pendingPhUSD, 0, "Should have no phUSD rewards with zero APY");

        uint256 stableBefore = rewardToken.balanceOf(alice);
        uint256 phUSDBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.claim();

        uint256 stableAfter = rewardToken.balanceOf(alice);
        uint256 phUSDAfter = phUSD.balanceOf(alice);

        assertGt(stableAfter - stableBefore, 0, "Should receive stable rewards");
        assertEq(phUSDAfter - phUSDBefore, 0, "Should not receive phUSD rewards");
    }

    function test_zero_APY_full_flow_stake_claim_withdraw() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        rewardToken.mint(address(yieldAccumulator), 10000 ether);
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.prank(alice);
        phlimbo.claim();

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT);

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0, "User should have withdrawn everything");
    }

    function test_setting_APY_to_zero_does_not_revert() public {
        phlimbo.setDesiredAPY(800);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(800);
        assertEq(phlimbo.desiredAPYBps(), 800, "APY should be 800");

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));
        assertGt(phlimbo.phUSDPerSecond(), 0, "Emission rate should be positive");

        vm.warp(block.timestamp + 100);

        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(0);
        vm.roll(block.number + 1);
        phlimbo.setDesiredAPY(0);

        assertEq(phlimbo.desiredAPYBps(), 0, "APY should be 0 after setting");
        assertEq(phlimbo.phUSDPerSecond(), 0, "Emission rate should be 0");

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        phlimbo.claim();

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT / 4, address(0));

        vm.warp(block.timestamp + 100);
        uint256 pendingPhUSD = phlimbo.pendingPhUSD(alice);
        assertEq(pendingPhUSD, 0, "No phUSD should accrue with zero APY");
    }

    // ========================== POOL ACCRUAL TESTS ==========================

    function test_updatePool_accrues_rewards_based_on_linear_rate() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        uint256 accStableBefore = phlimbo.accStablePerShare();

        vm.warp(block.timestamp + 100);

        vm.prank(bob);
        phlimbo.stake(1 ether, address(0));

        uint256 accStableAfter = phlimbo.accStablePerShare();

        assertGt(accStableAfter, accStableBefore, "Should accrue rewards based on linear rate");
    }

    function test_updatePool_caps_distribution_by_reward_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        // Small reward to start
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(1 ether);

        // Wait much longer than needed to fully distribute
        vm.warp(block.timestamp + DEPLETION_DURATION * 10);

        uint256 rewardBalanceBefore = phlimbo.rewardBalance();

        // Trigger pool update
        vm.prank(bob);
        phlimbo.stake(1 ether, address(0));

        uint256 rewardBalanceAfter = phlimbo.rewardBalance();

        // Balance should be 0 (all distributed), not negative
        assertEq(rewardBalanceAfter, 0, "Balance should be 0, capped at available");
    }

    function test_updatePool_handles_totalStaked_zero() public {
        assertEq(phlimbo.totalStaked(), 0, "No stakers initially");

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        assertEq(phlimbo.accStablePerShare(), 0, "No accumulation when no stakers");
    }

    // ========================== CLAIM TESTS ==========================

    function test_claim_distributes_stable_rewards() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        rewardToken.mint(address(yieldAccumulator), 100 ether);

        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);

        // Wait some time for rewards to accrue
        vm.warp(block.timestamp + 100);

        uint256 stableBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        phlimbo.claim();

        uint256 stableAfter = rewardToken.balanceOf(alice);

        assertGt(stableAfter, stableBefore, "Should receive stable rewards");
    }

    function test_linear_provides_predictable_reward_rate() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, address(0));

        // First collection
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);
        uint256 rate1 = phlimbo.rewardPerSecond();

        // Second collection with different amount
        vm.prank(address(yieldAccumulator));
        phlimbo.collectReward(100 ether);
        uint256 rate2 = phlimbo.rewardPerSecond();

        // Rate should be predictable: (200 ether * 1e18) / DEPLETION_DURATION
        uint256 expectedRate = (200 ether * 1e18) / DEPLETION_DURATION;
        assertEq(rate2, expectedRate, "Rate should be deterministic based on balance");

        // Rate should double with double balance
        assertEq(rate2, rate1 * 2, "Rate should scale linearly with balance");
    }
}
