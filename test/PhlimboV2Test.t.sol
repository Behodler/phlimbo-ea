// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/PhlimboV2.sol";
import "../src/interfaces/IPhlimboHook.sol";
import "./Mocks.sol";

/**
 * @title PhlimboV2Test
 * @notice Comprehensive test suite for PhlimboV2. Covers:
 *         - Self-service happy paths (msg.sender == user) parallel to V1 coverage
 *         - Migrator-pattern delegation (stake/withdraw/claim on behalf of a user)
 *         - Auth negatives (third party rejected even when migrator is set)
 *         - Hook lifecycle: unset (skip), set (called with correct args), revert
 *           propagation, clear (disable via address(0))
 *         - Bug-fix regression: rewardPerSecond is constant across stake/withdraw/claim
 *           without collectReward; only collectReward and setDepletionDuration recompute
 *         - Window-reset on second collectReward mid-depletion
 */
contract PhlimboV2Test is Test {
    // Re-declare events for use in expectEmit
    event RewardCollected(uint256 amount, uint256 newRewardBalance, uint256 newRate);
    event DepletionDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event EmergencyWithdrawal(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 phUSDAmount, uint256 stableAmount);
    event MigratorSet(address indexed oldMigrator, address indexed newMigrator);
    event HookSet(address indexed oldHook, address indexed newHook);

    PhlimboV2 public phlimbo;
    MockFlax public phUSD;
    MockStable public rewardToken;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public rewardDonor = address(0x3);
    address public pauser = address(0x4);
    address public migrator = address(0x5);
    address public eve = address(0x6); // unauthorized third party

    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant DEPLETION_DURATION = 604800; // 1 week

    function setUp() public {
        phUSD = new MockFlax();
        rewardToken = new MockStable();

        phlimbo = new PhlimboV2(
            address(phUSD),
            address(rewardToken),
            DEPLETION_DURATION
        );

        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, INITIAL_BALANCE);
        phUSD.mint(bob, INITIAL_BALANCE);
        phUSD.mint(migrator, INITIAL_BALANCE);
        rewardToken.mint(rewardDonor, INITIAL_BALANCE);

        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(migrator);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(rewardDonor);
        rewardToken.approve(address(phlimbo), type(uint256).max);

        phlimbo.setPauser(pauser);
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    function test_constructor_initial_state() public {
        assertEq(address(phlimbo.phUSD()), address(phUSD));
        assertEq(address(phlimbo.rewardToken()), address(rewardToken));
        assertEq(phlimbo.depletionDuration(), DEPLETION_DURATION);
        assertEq(phlimbo.rewardBalance(), 0);
        assertEq(phlimbo.rewardPerSecond(), 0);
        assertEq(phlimbo.migrator(), address(0), "migrator starts as address(0)");
        assertEq(address(phlimbo.hook()), address(0), "hook starts as address(0)");
    }

    function test_constructor_rejects_zero_addresses() public {
        vm.expectRevert("Invalid phUSD address");
        new PhlimboV2(address(0), address(rewardToken), DEPLETION_DURATION);

        vm.expectRevert("Invalid reward token address");
        new PhlimboV2(address(phUSD), address(0), DEPLETION_DURATION);
    }

    function test_constructor_rejects_zero_duration() public {
        vm.expectRevert("Duration must be > 0");
        new PhlimboV2(address(phUSD), address(rewardToken), 0);
    }

    // ============================================================
    // SELF-SERVICE HAPPY PATHS (msg.sender == user)
    // ============================================================

    function test_self_stake_updates_user_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT);
        assertEq(phlimbo.totalStaked(), STAKE_AMOUNT);
    }

    function test_self_stake_transfers_tokens_from_msg_sender() public {
        uint256 balanceBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        assertEq(phUSD.balanceOf(alice), balanceBefore - STAKE_AMOUNT);
        assertEq(phUSD.balanceOf(address(phlimbo)), STAKE_AMOUNT);
    }

    function test_self_withdraw_returns_tokens_to_msg_sender() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        uint256 balanceBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
        assertEq(phUSD.balanceOf(alice) - balanceBefore, STAKE_AMOUNT);
    }

    function test_self_claim_routes_rewards_to_msg_sender() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + 100);

        uint256 stableBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertGt(rewardToken.balanceOf(alice), stableBefore, "Alice should receive stable rewards");
    }

    function test_self_stake_below_minimum_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Below minimum stake");
        phlimbo.stake(1, alice);
    }

    function test_self_stake_rejects_zero_user() public {
        vm.prank(alice);
        vm.expectRevert("Invalid user");
        phlimbo.stake(STAKE_AMOUNT, address(0));
    }

    function test_self_withdraw_rejects_zero_user() public {
        vm.prank(alice);
        vm.expectRevert("Invalid user");
        phlimbo.withdraw(STAKE_AMOUNT, address(0));
    }

    function test_self_claim_rejects_zero_user() public {
        vm.prank(alice);
        vm.expectRevert("Invalid user");
        phlimbo.claim(address(0));
    }

    function test_self_withdraw_exceeds_balance_reverts() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(alice);
        vm.expectRevert("Insufficient balance");
        phlimbo.withdraw(STAKE_AMOUNT + 1, alice);
    }

    function test_collectReward_increases_balance_and_rate() public {
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        assertEq(phlimbo.rewardBalance(), 100 ether);
        assertEq(phlimbo.rewardPerSecond(), (100 ether * 1e18) / DEPLETION_DURATION);
    }

    function test_setDepletionDuration_recomputes_rate() public {
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        uint256 rateBefore = phlimbo.rewardPerSecond();
        uint256 newDuration = DEPLETION_DURATION / 2;
        phlimbo.setDepletionDuration(newDuration);
        uint256 rateAfter = phlimbo.rewardPerSecond();

        // Rate doubles when duration halves.
        assertApproxEqRel(rateAfter, rateBefore * 2, 0.001e18);
    }

    // ============================================================
    // MIGRATOR PATTERN
    // ============================================================

    function test_setMigrator_only_owner() public {
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setMigrator(migrator);
    }

    function test_setMigrator_emits_event() public {
        vm.expectEmit(true, true, false, false);
        emit MigratorSet(address(0), migrator);
        phlimbo.setMigrator(migrator);
        assertEq(phlimbo.migrator(), migrator);
    }

    function test_setMigrator_accepts_zero_to_disable() public {
        phlimbo.setMigrator(migrator);
        phlimbo.setMigrator(address(0));
        assertEq(phlimbo.migrator(), address(0));
    }

    function test_migrator_stake_on_behalf_of_alice() public {
        phlimbo.setMigrator(migrator);

        uint256 migratorBalanceBefore = phUSD.balanceOf(migrator);

        vm.prank(migrator);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Alice's userInfo.amount credited
        (uint256 aliceAmount,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, STAKE_AMOUNT, "Alice credited");

        // Migrator paid (tokens pulled from msg.sender)
        assertEq(phUSD.balanceOf(migrator), migratorBalanceBefore - STAKE_AMOUNT, "Migrator paid");

        // Migrator's own userInfo unchanged
        (uint256 migratorAmount,,) = phlimbo.userInfo(migrator);
        assertEq(migratorAmount, 0, "Migrator has no position");
    }

    function test_migrator_withdraw_routes_tokens_to_migrator() public {
        phlimbo.setMigrator(migrator);

        // Alice stakes self-service
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        uint256 migratorBalanceBefore = phUSD.balanceOf(migrator);
        uint256 aliceBalanceBefore = phUSD.balanceOf(alice);

        vm.prank(migrator);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);

        // Migrator gained the withdrawn tokens
        assertEq(phUSD.balanceOf(migrator) - migratorBalanceBefore, STAKE_AMOUNT / 2);
        // Alice's wallet untouched (her stake was debited internally)
        assertEq(phUSD.balanceOf(alice), aliceBalanceBefore);
        // Alice's user.amount decreased
        (uint256 aliceAmount,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, STAKE_AMOUNT / 2);
    }

    function test_migrator_claim_routes_rewards_to_migrator() public {
        phlimbo.setMigrator(migrator);

        // Alice stakes self-service
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Collect some rewards
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        // Set a non-zero APY so phUSD also accrues
        phlimbo.setDesiredAPY(500);
        phlimbo.setDesiredAPY(500); // commit (within 100 blocks, same value)

        vm.warp(block.timestamp + 1000);

        uint256 migratorStableBefore = rewardToken.balanceOf(migrator);
        uint256 migratorPhUSDBefore = phUSD.balanceOf(migrator);
        uint256 aliceStableBefore = rewardToken.balanceOf(alice);
        uint256 alicePhUSDBefore = phUSD.balanceOf(alice);

        vm.prank(migrator);
        phlimbo.claim(alice);

        // Migrator received both reward streams
        assertGt(rewardToken.balanceOf(migrator), migratorStableBefore, "Migrator stable");
        assertGt(phUSD.balanceOf(migrator), migratorPhUSDBefore, "Migrator phUSD");

        // Alice received neither
        assertEq(rewardToken.balanceOf(alice), aliceStableBefore, "Alice stable unchanged");
        assertEq(phUSD.balanceOf(alice), alicePhUSDBefore, "Alice phUSD unchanged");
    }

    // ============================================================
    // AUTH NEGATIVES
    // ============================================================

    function test_third_party_cannot_stake_on_behalf_before_migrator_set() public {
        vm.prank(eve);
        vm.expectRevert("Not authorized");
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_third_party_cannot_stake_on_behalf_after_migrator_set() public {
        phlimbo.setMigrator(migrator);
        // eve is not the migrator and not the user
        vm.prank(eve);
        vm.expectRevert("Not authorized");
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_third_party_cannot_withdraw_on_behalf() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.setMigrator(migrator);

        vm.prank(eve);
        vm.expectRevert("Not authorized");
        phlimbo.withdraw(STAKE_AMOUNT, alice);
    }

    function test_third_party_cannot_claim_on_behalf() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.setMigrator(migrator);

        vm.prank(eve);
        vm.expectRevert("Not authorized");
        phlimbo.claim(alice);
    }

    function test_migrator_cannot_pauseWithdraw_on_behalf() public {
        // Even when migrator is set, pauseWithdraw remains strictly msg.sender-only:
        // it has no `user` param at all, so the migrator can only pause-withdraw
        // their own balance. This test asserts the migrator cannot drain alice via
        // pauseWithdraw.
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.setMigrator(migrator);

        vm.prank(pauser);
        phlimbo.pause();

        // Migrator's own balance is 0, so pauseWithdraw reverts on insufficient balance.
        // (Cannot delegate.)
        vm.prank(migrator);
        vm.expectRevert("Insufficient balance");
        phlimbo.pauseWithdraw(1 ether);

        // Alice's balance untouched
        (uint256 aliceAmount,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, STAKE_AMOUNT);
    }

    function test_migrator_zero_does_not_authorize_random_caller() public {
        // migrator starts as address(0); msg.sender is never address(0), so the
        // `msg.sender == migrator` branch can never match while migrator is unset.
        vm.prank(eve);
        vm.expectRevert("Not authorized");
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    // ============================================================
    // HOOK SYSTEM
    // ============================================================

    function test_hook_unset_stake_succeeds() public {
        // Default state: hook is address(0). Stake/withdraw/claim must work.
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT);
    }

    function test_hook_unset_withdraw_succeeds() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0);
    }

    function test_hook_unset_claim_succeeds() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        phlimbo.claim(alice);
    }

    function test_setHook_only_owner() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        vm.prank(alice);
        vm.expectRevert();
        phlimbo.setHook(address(mock));
    }

    function test_setHook_emits_event() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        vm.expectEmit(true, true, false, false);
        emit HookSet(address(0), address(mock));
        phlimbo.setHook(address(mock));
        assertEq(address(phlimbo.hook()), address(mock));
    }

    function test_hook_onDeposit_self_service_args() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        phlimbo.setHook(address(mock));

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        assertEq(mock.depositCount(), 1);
        MockPhlimboHook.Call memory c = mock.lastCall();
        assertEq(c.caller, alice);
        assertEq(c.user, alice);
        assertEq(c.amount, STAKE_AMOUNT);
        assertEq(c.kind, "deposit");
    }

    function test_hook_onDeposit_migrator_args() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        phlimbo.setHook(address(mock));
        phlimbo.setMigrator(migrator);

        vm.prank(migrator);
        phlimbo.stake(STAKE_AMOUNT, alice);

        MockPhlimboHook.Call memory c = mock.lastCall();
        assertEq(c.caller, migrator, "caller should be migrator");
        assertEq(c.user, alice, "user should be alice");
        assertEq(c.amount, STAKE_AMOUNT);
    }

    function test_hook_onWithdraw_args() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        phlimbo.setHook(address(mock));

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);

        // Mock recorded both deposit and withdraw
        assertEq(mock.depositCount(), 1);
        assertEq(mock.withdrawCount(), 1);
        MockPhlimboHook.Call memory c = mock.lastCall();
        assertEq(c.kind, "withdraw");
        assertEq(c.caller, alice);
        assertEq(c.user, alice);
        assertEq(c.amount, STAKE_AMOUNT / 2);
    }

    function test_hook_onClaim_args() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        phlimbo.setHook(address(mock));

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + 1000);

        uint256 expectedStable = phlimbo.pendingStable(alice);

        vm.prank(alice);
        phlimbo.claim(alice);

        MockPhlimboHook.Call memory c = mock.lastCall();
        assertEq(c.kind, "claim");
        assertEq(c.caller, alice);
        assertEq(c.user, alice);
        // pendingStable() was a snapshot before the claim mutated state, and the
        // hook receives the same snapshot value. Allow a small absolute tolerance
        // since _updatePool inside claim() advances state slightly. (For our test
        // timing, expected and observed should match exactly.)
        assertEq(c.stableAmount, expectedStable, "hook stable arg matches snapshot");
    }

    function test_hook_revert_propagates_on_stake() public {
        RevertingPhlimboHook bad = new RevertingPhlimboHook("hook reverted");
        phlimbo.setHook(address(bad));

        vm.prank(alice);
        vm.expectRevert("hook reverted");
        phlimbo.stake(STAKE_AMOUNT, alice);

        // State must be rolled back: alice not staked
        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0, "state rolled back on revert");
        assertEq(phlimbo.totalStaked(), 0);
    }

    function test_hook_revert_propagates_on_withdraw() public {
        // First stake successfully (no hook yet)
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        RevertingPhlimboHook bad = new RevertingPhlimboHook("withdraw blocked");
        phlimbo.setHook(address(bad));

        vm.prank(alice);
        vm.expectRevert("withdraw blocked");
        phlimbo.withdraw(STAKE_AMOUNT, alice);

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT, "state preserved on revert");
    }

    function test_hook_revert_propagates_on_claim() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        vm.warp(block.timestamp + 100);

        RevertingPhlimboHook bad = new RevertingPhlimboHook("claim blocked");
        phlimbo.setHook(address(bad));

        vm.prank(alice);
        vm.expectRevert("claim blocked");
        phlimbo.claim(alice);
    }

    function test_setHook_zero_disables() public {
        MockPhlimboHook mock = new MockPhlimboHook();
        phlimbo.setHook(address(mock));

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        assertEq(mock.depositCount(), 1, "hook was active");

        // Disable hook
        phlimbo.setHook(address(0));
        assertEq(address(phlimbo.hook()), address(0));

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Mock state unchanged — hook was not invoked
        assertEq(mock.depositCount(), 1, "hook NOT called after disable");
    }

    // ============================================================
    // BUG-FIX REGRESSION: depletion rate constant without collectReward
    // ============================================================

    function test_rate_constant_across_stake_withdraw_claim() public {
        // Alice stakes
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Bob stakes (we'll use bob for the touching interactions)
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);

        // Collect rewards — this sets the initial rate
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        uint256 initialRate = phlimbo.rewardPerSecond();
        assertGt(initialRate, 0);

        // Now perform a series of interactions WITHOUT calling collectReward.
        // In V1, every interaction would re-derive rewardPerSecond from
        // (shrinking rewardBalance) / depletionDuration, effectively resetting
        // the depletion window each time. V2 must keep rewardPerSecond constant.

        vm.warp(block.timestamp + 100);
        vm.prank(bob);
        phlimbo.claim(bob);
        assertEq(phlimbo.rewardPerSecond(), initialRate, "rate constant after claim 1");

        vm.warp(block.timestamp + 200);
        vm.prank(bob);
        phlimbo.stake(10 ether, bob);
        assertEq(phlimbo.rewardPerSecond(), initialRate, "rate constant after stake");

        vm.warp(block.timestamp + 300);
        vm.prank(bob);
        phlimbo.withdraw(10 ether, bob);
        assertEq(phlimbo.rewardPerSecond(), initialRate, "rate constant after withdraw");

        vm.warp(block.timestamp + 500);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertEq(phlimbo.rewardPerSecond(), initialRate, "rate constant after second claim");

        // Sanity: rewardBalance HAS decreased (rewards were distributed), even though
        // rate stayed constant.
        assertLt(phlimbo.rewardBalance(), 100 ether, "rewardBalance decreased");
    }

    function test_rate_only_recomputes_on_collectReward_or_setDepletionDuration() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        uint256 rate1 = phlimbo.rewardPerSecond();

        // Touch many user-facing fns — rate stays.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertEq(phlimbo.rewardPerSecond(), rate1);

        // collectReward DOES recompute
        rewardToken.mint(rewardDonor, 50 ether);
        vm.prank(rewardDonor);
        phlimbo.collectReward(50 ether);
        uint256 rate2 = phlimbo.rewardPerSecond();
        // Rate changed: new balance is (remaining + 50)/duration
        assertTrue(rate2 != rate1, "collectReward recomputes rate");

        // setDepletionDuration DOES recompute
        phlimbo.setDepletionDuration(DEPLETION_DURATION * 2);
        uint256 rate3 = phlimbo.rewardPerSecond();
        assertTrue(rate3 != rate2, "setDepletionDuration recomputes rate");
    }

    function test_window_reset_on_second_collectReward() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // First collection: 100 ether
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        // Wait half the depletion window — half should be distributed
        vm.warp(block.timestamp + DEPLETION_DURATION / 2);

        // Touch the pool to accrue (this should NOT change the rate in V2)
        uint256 rateBeforeCollect = phlimbo.rewardPerSecond();

        // Second collection: 50 ether mid-depletion
        rewardToken.mint(rewardDonor, 50 ether);
        vm.prank(rewardDonor);
        phlimbo.collectReward(50 ether);

        uint256 newRate = phlimbo.rewardPerSecond();
        uint256 newBalance = phlimbo.rewardBalance();

        // newRate should equal newBalance / depletionDuration (window restarts now)
        uint256 expectedRate = (newBalance * 1e18) / DEPLETION_DURATION;
        assertEq(newRate, expectedRate, "rate = newBalance / depletionDuration");

        // newRate should also differ from rateBeforeCollect (proof the recompute fired)
        assertTrue(newRate != rateBeforeCollect, "rate changed after collectReward");

        // The new balance should be approx (50 ether un-distributed half) + 50 ether
        // = ~100 ether (with rounding). Loose check.
        assertApproxEqRel(newBalance, 100 ether, 0.01e18, "balance ~= remaining + new");
    }

    // ============================================================
    // ADDITIONAL V1-PARALLEL COVERAGE
    // ============================================================

    function test_two_stakers_split_rewards_proportionally() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);

        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        vm.warp(block.timestamp + DEPLETION_DURATION);

        uint256 pendingAlice = phlimbo.pendingStable(alice);
        uint256 pendingBob = phlimbo.pendingStable(bob);

        // Equal stakes → equal rewards
        assertApproxEqRel(pendingAlice, pendingBob, 0.001e18);
        // Combined should be ~100 ether
        assertApproxEqRel(pendingAlice + pendingBob, 100 ether, 0.001e18);
    }

    function test_emergencyTransfer_pauses_contract() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        address treasury = address(0x999);
        phlimbo.emergencyTransfer(treasury);

        assertTrue(phlimbo.paused());
        assertEq(phUSD.balanceOf(treasury), STAKE_AMOUNT);
    }

    function test_pauseWithdraw_self_service() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        phlimbo.pauseWithdraw(STAKE_AMOUNT);

        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0);
        assertEq(phUSD.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_pause_blocks_stake() public {
        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_pause_blocks_withdraw() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.withdraw(STAKE_AMOUNT, alice);
    }

    function test_pause_blocks_claim() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(pauser);
        phlimbo.pause();

        vm.prank(alice);
        vm.expectRevert();
        phlimbo.claim(alice);
    }

    function test_dust_prevention_forces_full_withdraw() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Try to leave less than MINIMUM_STAKE
        uint256 leaveDust = STAKE_AMOUNT - 1e14; // remaining would be 0.0001 phUSD
        uint256 balanceBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        phlimbo.withdraw(leaveDust, alice);

        // Full balance withdrawn
        assertEq(phUSD.balanceOf(alice), balanceBefore + STAKE_AMOUNT);
        (uint256 amount,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0);
    }

    function test_balance_cannot_go_negative() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);

        // Warp far past depletion window
        vm.warp(block.timestamp + DEPLETION_DURATION * 10);

        vm.prank(alice);
        phlimbo.claim(alice);

        // Cap should kick in: rewardBalance not negative (would have underflowed otherwise)
        assertEq(phlimbo.rewardBalance(), 0);
    }

    function test_collectReward_event() public {
        vm.expectEmit(false, false, false, false);
        emit RewardCollected(0, 0, 0);
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
    }

    function test_Staked_event() public {
        vm.expectEmit(true, false, false, true);
        emit Staked(alice, STAKE_AMOUNT);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_Withdrawn_event() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, STAKE_AMOUNT);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
    }

    function test_migrator_withdraw_emits_event_indexed_by_user() public {
        phlimbo.setMigrator(migrator);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // The event indexes by `user` (alice), not msg.sender (migrator),
        // matching V1 semantics.
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, STAKE_AMOUNT);
        vm.prank(migrator);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
    }
}
