// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/PhlimboV3.sol";
import "../src/interfaces/IPhlimboHook.sol";
import "./Mocks.sol";

/**
 * @title PhlimboV3Test
 * @notice Comprehensive test suite for PhlimboV3. Covers:
 *         - Self-service happy paths (msg.sender == user) parallel to V1 coverage
 *         - Migrator-pattern delegation (stake/withdraw/claim on behalf of a user)
 *         - Auth negatives (third party rejected even when migrator is set)
 *         - Hook lifecycle: unset (skip), set (called with correct args), revert
 *           propagation, clear (disable via address(0))
 *         - Bug-fix regression: rewardPerSecond is constant across stake/withdraw/claim
 *           without collectReward; only collectReward and setDepletionDuration recompute
 *         - Window-reset on second collectReward mid-depletion
 */
contract PhlimboV3Test is Test {
    // Re-declare events for use in expectEmit
    event RewardCollected(uint256 amount, uint256 newRewardBalance, uint256 newRate);
    event DepletionDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 phUSDAmount, uint256 stableAmount);
    event MigratorSet(address indexed oldMigrator, address indexed newMigrator);
    event HookSet(address indexed oldHook, address indexed newHook);
    event PromotionStarted(address indexed token, uint256 amount, uint256 duration, uint256 rate);
    event PromotionToppedUp(uint256 amount, uint256 newBalance, uint256 newRate);
    event PromoDepletionDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event PromoClaimed(address indexed user, uint256 amount);
    event FlushProgress(uint256 cursor, uint256 total);
    event PromoClaimFailed(address indexed token, address indexed user, uint256 amount);
    event UnclaimablePromoClaimed(address indexed token, address indexed user, uint256 amount);
    event PromotionFinalized(address indexed token, address indexed leftoverRecipient, uint256 leftoverAmount);
    event StableClaimFailed(address indexed user, uint256 amount);
    event UnclaimableStableClaimed(address indexed user, uint256 amount);

    PhlimboV3 public phlimbo;
    MockFlax public phUSD;
    MockStable public rewardToken;
    MockStable public partner;

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
    uint256 constant PROMO_AMOUNT = 1000 ether;
    uint256 constant PROMO_DURATION = 1_000_000; // promo's own window, != DEPLETION_DURATION

    function setUp() public {
        phUSD = new MockFlax();
        rewardToken = new MockStable();

        phlimbo = new PhlimboV3(address(phUSD), address(rewardToken), DEPLETION_DURATION);

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

        // Partner token for the promotional slot: owner (this) holds and approves it
        partner = new MockStable();
        partner.mint(owner, INITIAL_BALANCE);
        partner.approve(address(phlimbo), type(uint256).max);
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
        new PhlimboV3(address(0), address(rewardToken), DEPLETION_DURATION);

        vm.expectRevert("Invalid reward token address");
        new PhlimboV3(address(phUSD), address(0), DEPLETION_DURATION);
    }

    function test_constructor_rejects_zero_duration() public {
        vm.expectRevert("Duration must be > 0");
        new PhlimboV3(address(phUSD), address(rewardToken), 0);
    }

    // ============================================================
    // SELF-SERVICE HAPPY PATHS (msg.sender == user)
    // ============================================================

    function test_self_stake_updates_user_balance() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        (uint256 amount,,,) = phlimbo.userInfo(alice);
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
        (uint256 aliceAmount,,,) = phlimbo.userInfo(alice);
        assertEq(aliceAmount, STAKE_AMOUNT, "Alice credited");

        // Migrator paid (tokens pulled from msg.sender)
        assertEq(phUSD.balanceOf(migrator), migratorBalanceBefore - STAKE_AMOUNT, "Migrator paid");

        // Migrator's own userInfo unchanged
        (uint256 migratorAmount,,,) = phlimbo.userInfo(migrator);
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
        (uint256 aliceAmount,,,) = phlimbo.userInfo(alice);
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
        (uint256 amount,,,) = phlimbo.userInfo(alice);
        assertEq(amount, STAKE_AMOUNT);
    }

    function test_hook_unset_withdraw_succeeds() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
        (uint256 amount,,,) = phlimbo.userInfo(alice);
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
        (uint256 amount,,,) = phlimbo.userInfo(alice);
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

        (uint256 amount,,,) = phlimbo.userInfo(alice);
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
        (uint256 amount,,,) = phlimbo.userInfo(alice);
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

    // ============================================================
    // V3 PHASE 1: STAKER SET MAINTENANCE
    // ============================================================

    function test_stakers_set_adds_on_stake_and_is_idempotent() public {
        assertEq(phlimbo.stakerCount(), 0, "set starts empty");

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        assertEq(phlimbo.stakerCount(), 1, "alice added");
        assertEq(phlimbo.stakerAt(0), alice);

        // Second stake by the same user must not add a duplicate
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        assertEq(phlimbo.stakerCount(), 1, "idempotent add");

        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);
        assertEq(phlimbo.stakerCount(), 2, "bob added");
    }

    function test_stakers_set_partial_withdraw_keeps_member() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);

        assertEq(phlimbo.stakerCount(), 1, "partial withdraw keeps alice in set");
        assertEq(phlimbo.stakerAt(0), alice);
    }

    function test_stakers_set_removes_on_full_exit() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);

        assertEq(phlimbo.stakerCount(), 1, "alice removed on full exit");
        assertEq(phlimbo.stakerAt(0), bob, "bob remains");
    }

    function test_stakers_set_removes_on_dust_rule_full_exit() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Withdrawing so that 0 < remaining < MINIMUM_STAKE forces a full exit
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT - 1e14, alice);

        (uint256 amount,,,) = phlimbo.userInfo(alice);
        assertEq(amount, 0, "dust rule forced full exit");
        assertEq(phlimbo.stakerCount(), 0, "alice removed by dust-rule full exit");
    }

    // ============================================================
    // V3 PHASE 1: OWNER PAUSE/UNPAUSE
    // ============================================================

    function test_owner_can_pause_and_unpause() public {
        // owner == address(this); pauser is a separate address (0x4)
        phlimbo.pause();
        assertTrue(phlimbo.paused(), "owner paused directly");

        phlimbo.unpause();
        assertFalse(phlimbo.paused(), "owner unpaused directly");
    }

    function test_external_pauser_still_works() public {
        vm.prank(pauser);
        phlimbo.pause();
        assertTrue(phlimbo.paused());

        vm.prank(pauser);
        phlimbo.unpause();
        assertFalse(phlimbo.paused());
    }

    function test_third_party_cannot_pause_or_unpause() public {
        vm.prank(eve);
        vm.expectRevert("Only pauser or owner can pause");
        phlimbo.pause();

        phlimbo.pause();

        vm.prank(eve);
        vm.expectRevert("Only pauser or owner can unpause");
        phlimbo.unpause();
    }

    // ============================================================
    // V3 PHASE 2: startPromotion VALIDATION
    // ============================================================

    function test_startPromotion_only_owner() public {
        vm.prank(eve);
        vm.expectRevert();
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
    }

    function test_startPromotion_requires_phase_none() public {
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.expectRevert("Promo phase must be None");
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
    }

    function test_startPromotion_rejects_invalid_tokens() public {
        vm.expectRevert("Invalid promo token");
        phlimbo.startPromotion(address(0), PROMO_AMOUNT, PROMO_DURATION);

        vm.expectRevert("Invalid promo token");
        phlimbo.startPromotion(address(phUSD), PROMO_AMOUNT, PROMO_DURATION);

        vm.expectRevert("Invalid promo token");
        phlimbo.startPromotion(address(rewardToken), PROMO_AMOUNT, PROMO_DURATION);
    }

    function test_startPromotion_rejects_zero_amount_or_duration() public {
        vm.expectRevert("Amount must be greater than 0");
        phlimbo.startPromotion(address(partner), 0, PROMO_DURATION);

        vm.expectRevert("Duration must be > 0");
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, 0);
    }

    function test_startPromotion_blocked_while_paused() public {
        vm.prank(pauser);
        phlimbo.pause();

        vm.expectRevert();
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
    }

    function test_startPromotion_pulls_tokens_and_sets_state() public {
        uint256 ownerBefore = partner.balanceOf(owner);
        uint256 expectedRate = (PROMO_AMOUNT * 1e18) / PROMO_DURATION;

        vm.expectEmit(true, false, false, true);
        emit PromotionStarted(address(partner), PROMO_AMOUNT, PROMO_DURATION, expectedRate);
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        assertEq(partner.balanceOf(owner), ownerBefore - PROMO_AMOUNT, "tokens pulled from owner");
        assertEq(partner.balanceOf(address(phlimbo)), PROMO_AMOUNT);
        assertEq(address(phlimbo.promoToken()), address(partner));
        assertEq(phlimbo.promoRewardBalance(), PROMO_AMOUNT);
        assertEq(phlimbo.promoDepletionDuration(), PROMO_DURATION);
        assertEq(phlimbo.promoRewardPerSecond(), expectedRate);
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.Active));

        (address t, uint256 bal, uint256 rate, uint256 window, IPhlimboV3.PromoPhase phase, uint256 cursor) =
            phlimbo.getPromoInfo();
        assertEq(t, address(partner));
        assertEq(bal, PROMO_AMOUNT);
        assertEq(rate, expectedRate);
        assertEq(window, PROMO_DURATION);
        assertEq(uint256(phase), uint256(IPhlimboV3.PromoPhase.Active));
        assertEq(cursor, 0);
    }

    function test_startPromotion_rejects_fee_on_transfer_token() public {
        MockFeeToken feeToken = new MockFeeToken();
        feeToken.mint(owner, INITIAL_BALANCE);
        feeToken.approve(address(phlimbo), type(uint256).max);

        vm.expectRevert("Fee-on-transfer not supported");
        phlimbo.startPromotion(address(feeToken), PROMO_AMOUNT, PROMO_DURATION);
    }

    // ============================================================
    // V3 PHASE 2: PROMO ACCRUAL
    // ============================================================

    function test_promo_streams_linearly_over_own_window() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.warp(block.timestamp + PROMO_DURATION / 2);
        assertEq(phlimbo.pendingPromo(alice), PROMO_AMOUNT / 2, "half streamed at half window");

        vm.warp(block.timestamp + PROMO_DURATION / 4);
        assertEq(phlimbo.pendingPromo(alice), (PROMO_AMOUNT * 3) / 4, "3/4 streamed at 3/4 window");

        // Claim delivers the promo tokens to the user
        uint256 before = partner.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertEq(partner.balanceOf(alice) - before, (PROMO_AMOUNT * 3) / 4, "claim pays promo");
        assertEq(phlimbo.pendingPromo(alice), 0, "pending zero after claim");
    }

    function test_promo_pro_rata_split_between_stakers() public {
        // alice : bob = 1 : 3, both staked before the promo starts
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.warp(block.timestamp + PROMO_DURATION / 2);

        assertEq(phlimbo.pendingPromo(alice), PROMO_AMOUNT / 8, "alice gets 1/4 of half");
        assertEq(phlimbo.pendingPromo(bob), (PROMO_AMOUNT * 3) / 8, "bob gets 3/4 of half");
    }

    function test_promo_window_independent_of_stable_window() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Stable stream: 100 ether over DEPLETION_DURATION.
        // Promo stream: PROMO_AMOUNT over 2 * DEPLETION_DURATION.
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, 2 * DEPLETION_DURATION);

        // After one stable window: stable fully depleted, promo only half done.
        vm.warp(block.timestamp + DEPLETION_DURATION);

        assertApproxEqRel(phlimbo.pendingStable(alice), 100 ether, 0.0001e18, "stable fully streamed");
        assertApproxEqRel(phlimbo.pendingPromo(alice), PROMO_AMOUNT / 2, 0.0001e18, "promo half streamed");

        // Changing the stable window must not touch the promo rate, and vice versa
        uint256 promoRate = phlimbo.promoRewardPerSecond();
        phlimbo.setDepletionDuration(DEPLETION_DURATION / 2);
        assertEq(phlimbo.promoRewardPerSecond(), promoRate, "stable window change leaves promo rate");

        uint256 stableRate = phlimbo.rewardPerSecond();
        phlimbo.setPromoDepletionDuration(DEPLETION_DURATION);
        assertEq(phlimbo.rewardPerSecond(), stableRate, "promo window change leaves stable rate");
    }

    function test_promo_depletes_then_dormant_then_topUp_resumes() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        // Warp far past the window: distribution capped at the supplied quantity
        vm.warp(block.timestamp + PROMO_DURATION * 3);
        assertEq(phlimbo.pendingPromo(alice), PROMO_AMOUNT, "capped at Q");

        vm.prank(alice);
        phlimbo.claim(alice);
        assertEq(partner.balanceOf(alice), PROMO_AMOUNT);
        assertEq(phlimbo.promoRewardBalance(), 0, "balance depleted");

        // Dormant: time passes, nothing accrues
        vm.warp(block.timestamp + PROMO_DURATION);
        assertEq(phlimbo.pendingPromo(alice), 0, "dormant stream accrues nothing");

        // Top-up reactivates: new rate = newBalance / window
        uint256 topUp = 400 ether;
        partner.mint(owner, topUp);
        uint256 expectedRate = (topUp * 1e18) / PROMO_DURATION;
        vm.expectEmit(false, false, false, true);
        emit PromotionToppedUp(topUp, topUp, expectedRate);
        phlimbo.topUpPromotion(topUp);
        assertEq(phlimbo.promoRewardPerSecond(), expectedRate);

        vm.warp(block.timestamp + PROMO_DURATION / 4);
        assertEq(phlimbo.pendingPromo(alice), topUp / 4, "stream resumed after top-up");
    }

    function test_topUpPromotion_requires_active_and_recomputes_rate() public {
        vm.expectRevert("Promo phase must be Active");
        phlimbo.topUpPromotion(100 ether);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.prank(eve);
        vm.expectRevert();
        phlimbo.topUpPromotion(100 ether);

        // Mid-stream top-up: accrues first, then rate = remaining balance / window
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        phlimbo.topUpPromotion(100 ether);
        // Remaining ~PROMO_AMOUNT/2 + 100
        uint256 expectedBalance = PROMO_AMOUNT / 2 + 100 ether;
        assertApproxEqRel(phlimbo.promoRewardBalance(), expectedBalance, 0.0001e18);
        assertEq(
            phlimbo.promoRewardPerSecond(),
            (phlimbo.promoRewardBalance() * 1e18) / PROMO_DURATION,
            "rate recomputed over existing window"
        );
    }

    function test_setPromoDepletionDuration_accrues_then_recomputes() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.expectRevert("Duration must be > 0");
        phlimbo.setPromoDepletionDuration(0);

        vm.prank(eve);
        vm.expectRevert();
        phlimbo.setPromoDepletionDuration(PROMO_DURATION / 4);

        vm.warp(block.timestamp + PROMO_DURATION / 2);

        vm.expectEmit(false, false, false, true);
        emit PromoDepletionDurationUpdated(PROMO_DURATION, PROMO_DURATION / 4);
        phlimbo.setPromoDepletionDuration(PROMO_DURATION / 4);

        // Old-rate accrual happened first (half distributed), then recompute
        assertApproxEqRel(phlimbo.promoRewardBalance(), PROMO_AMOUNT / 2, 0.0001e18);
        assertEq(
            phlimbo.promoRewardPerSecond(),
            (phlimbo.promoRewardBalance() * 1e18) / (PROMO_DURATION / 4),
            "rate recomputed over new window"
        );
        assertEq(phlimbo.promoDepletionDuration(), PROMO_DURATION / 4);

        // Remaining half distributes over the shortened window
        vm.warp(block.timestamp + PROMO_DURATION / 4);
        assertApproxEqRel(phlimbo.pendingPromo(alice), PROMO_AMOUNT, 0.0001e18, "fully streamed");
    }

    function test_setPromoDepletionDuration_requires_active() public {
        vm.expectRevert("Promo phase must be Active");
        phlimbo.setPromoDepletionDuration(PROMO_DURATION);
    }

    function test_promo_6_decimal_partner_token() public {
        MockUSDC6 usdc = new MockUSDC6();
        uint256 q = 1000e6; // 1000 USDC in native 6 decimals
        usdc.mint(owner, q);
        usdc.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);

        phlimbo.startPromotion(address(usdc), q, PROMO_DURATION);

        vm.warp(block.timestamp + PROMO_DURATION / 2);

        // Equal stakes: each gets ~q/4 at half window, in native 6-dp units
        assertApproxEqAbs(phlimbo.pendingPromo(alice), q / 4, 2, "alice 6dp pending");
        assertApproxEqAbs(phlimbo.pendingPromo(bob), q / 4, 2, "bob 6dp pending");

        vm.prank(alice);
        phlimbo.claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), q / 4, 2, "alice paid in 6dp token");
    }

    function test_zero_slot_ops_no_promo_transfers_debts_realigned() public {
        // No promotion configured: full user surface works, no promo effects
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        vm.warp(block.timestamp + 1000);

        vm.prank(alice);
        phlimbo.claim(alice);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);

        assertEq(phlimbo.pendingPromo(alice), 0);
        (,,, uint256 promoDebt) = phlimbo.userInfo(alice);
        assertEq(promoDebt, 0, "promoDebt aligned to zero accumulator");
        assertEq(partner.balanceOf(alice), 0, "no promo tokens moved");
    }

    function test_promo_settlement_on_stake_and_withdraw() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        // Stake more mid-stream: pending promo is auto-claimed, debt realigned
        vm.warp(block.timestamp + PROMO_DURATION / 2);
        uint256 pendingAtStake = phlimbo.pendingPromo(alice);
        assertEq(pendingAtStake, PROMO_AMOUNT / 2);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        assertEq(partner.balanceOf(alice), pendingAtStake, "stake auto-claims promo");
        assertEq(phlimbo.pendingPromo(alice), 0);

        // Withdraw mid-stream: same
        vm.warp(block.timestamp + PROMO_DURATION / 4);
        uint256 pendingAtWithdraw = phlimbo.pendingPromo(alice);
        assertEq(pendingAtWithdraw, PROMO_AMOUNT / 4);

        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
        assertEq(partner.balanceOf(alice), pendingAtStake + pendingAtWithdraw, "withdraw auto-claims promo");
        assertEq(phlimbo.pendingPromo(alice), 0);
    }

    function test_migrator_claim_routes_promo_to_migrator() public {
        phlimbo.setMigrator(migrator);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        vm.prank(migrator);
        phlimbo.claim(alice);

        // V2 routing preserved: promo rewards go to the caller during delegation
        assertEq(partner.balanceOf(migrator), PROMO_AMOUNT / 2, "migrator receives promo");
        assertEq(partner.balanceOf(alice), 0, "alice receives nothing");
    }

    // ============================================================
    // V3 PHASE 3: ROTATION STATE MACHINE — PHASE TRANSITIONS
    // ============================================================

    /// @dev alice (1x) and bob (3x) staked, promo Active, half the window elapsed.
    ///      Pendings: alice = PROMO_AMOUNT/8, bob = 3*PROMO_AMOUNT/8.
    function _setupActivePromoHalfStreamed() internal {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);
    }

    function test_beginFlush_requires_active_and_owner() public {
        vm.expectRevert("Promo phase must be Active");
        phlimbo.beginFlush();

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.prank(eve);
        vm.expectRevert();
        phlimbo.beginFlush();
    }

    function test_beginFlush_pauses_and_enters_flushing() public {
        _setupActivePromoHalfStreamed();

        phlimbo.beginFlush();

        assertTrue(phlimbo.paused(), "beginFlush pauses");
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.Flushing));
        assertEq(phlimbo.flushCursor(), 0);

        // Final accrual happened: half of Q already moved out of promoRewardBalance
        assertEq(phlimbo.promoRewardBalance(), PROMO_AMOUNT / 2, "beginFlush accrues first");

        // Cannot begin again while Flushing
        vm.expectRevert("Promo phase must be Active");
        phlimbo.beginFlush();
    }

    function test_batchClaim_requires_flushing() public {
        vm.expectRevert("Promo phase must be Flushing");
        phlimbo.batchClaim(10);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        vm.expectRevert("Promo phase must be Flushing");
        phlimbo.batchClaim(10);
    }

    function test_finalizePromotion_reverts_until_cursor_complete() public {
        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();

        vm.expectRevert("Flush incomplete");
        phlimbo.finalizePromotion(owner);

        phlimbo.batchClaim(1);
        assertEq(phlimbo.flushCursor(), 1);

        vm.expectRevert("Flush incomplete");
        phlimbo.finalizePromotion(owner);

        phlimbo.batchClaim(1);
        assertEq(phlimbo.flushCursor(), 2);

        phlimbo.finalizePromotion(owner);
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.None));
    }

    function test_finalizePromotion_requires_flushing_and_owner() public {
        vm.expectRevert("Promo phase must be Flushing");
        phlimbo.finalizePromotion(owner);

        _setupActivePromoHalfStreamed();

        vm.expectRevert("Promo phase must be Flushing");
        phlimbo.finalizePromotion(owner);

        phlimbo.beginFlush();
        phlimbo.batchClaim(10);

        vm.prank(eve);
        vm.expectRevert();
        phlimbo.finalizePromotion(eve);
    }

    function test_abortFlush_returns_to_active() public {
        vm.expectRevert("Promo phase must be Flushing");
        phlimbo.abortFlush();

        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();

        // Partial flush is fine: batchClaim is just early forced claims
        phlimbo.batchClaim(1);

        vm.prank(eve);
        vm.expectRevert();
        phlimbo.abortFlush();

        phlimbo.abortFlush();
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.Active));

        phlimbo.unpause();
        assertFalse(phlimbo.paused());

        // Stream still Active on the same token/rate; users can transact again
        vm.warp(block.timestamp + PROMO_DURATION / 4);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertGt(partner.balanceOf(alice), 0, "stream continues after abort");
    }

    function test_unpause_reverts_while_flushing() public {
        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();

        vm.expectRevert("Cannot unpause while flushing");
        phlimbo.unpause();

        vm.prank(pauser);
        vm.expectRevert("Cannot unpause while flushing");
        phlimbo.unpause();

        phlimbo.batchClaim(10);
        phlimbo.finalizePromotion(owner);

        phlimbo.unpause();
        assertFalse(phlimbo.paused());
    }

    // ============================================================
    // V3 PHASE 3: CURSOR CHUNKING
    // ============================================================

    function test_batchClaim_cursor_chunking_no_gaps_no_double_pays() public {
        // Three stakers with equal stakes
        phUSD.mint(eve, INITIAL_BALANCE);
        vm.prank(eve);
        phUSD.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);
        vm.prank(eve);
        phlimbo.stake(STAKE_AMOUNT, eve);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 share = phlimbo.pendingPromo(alice); // equal stakes → equal share
        assertGt(share, 0);

        phlimbo.beginFlush();
        assertEq(phlimbo.stakerCount(), 3);

        // Chunk 1 covers two stakers
        vm.expectEmit(false, false, false, true);
        emit FlushProgress(2, 3);
        phlimbo.batchClaim(2);
        assertEq(phlimbo.flushCursor(), 2);

        // Chunk 2: maxIterations larger than remainder is clamped
        phlimbo.batchClaim(10);
        assertEq(phlimbo.flushCursor(), 3);

        assertEq(partner.balanceOf(alice), share, "alice paid exactly once");
        assertEq(partner.balanceOf(bob), share, "bob paid exactly once");
        assertEq(partner.balanceOf(eve), share, "eve paid exactly once");

        // Idempotent past the end: no double pays, cursor stays
        phlimbo.batchClaim(10);
        assertEq(phlimbo.flushCursor(), 3);
        assertEq(partner.balanceOf(alice), share, "no double pay");
    }

    function test_batchClaim_permissionless_pays_staker_directly() public {
        _setupActivePromoHalfStreamed();
        uint256 alicePending = phlimbo.pendingPromo(alice);
        uint256 bobPending = phlimbo.pendingPromo(bob);

        phlimbo.beginFlush();

        // eve — not owner, not a staker — completes the flush
        vm.prank(eve);
        phlimbo.batchClaim(10);

        assertEq(partner.balanceOf(alice), alicePending, "staker alice paid directly");
        assertEq(partner.balanceOf(bob), bobPending, "staker bob paid directly");
        assertEq(partner.balanceOf(eve), 0, "caller receives nothing");
        assertEq(phlimbo.pendingPromo(alice), 0, "debt aligned");
        assertEq(phlimbo.pendingPromo(bob), 0, "debt aligned");
    }

    // ============================================================
    // V3 PHASE 3: §2.1 CONTAMINATION REGRESSION
    // ============================================================

    function test_rotation_contamination_regression() public {
        // alice holds unclaimed token-A pending across a full rotation
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 entitlementA = phlimbo.pendingPromo(alice);
        assertEq(entitlementA, PROMO_AMOUNT / 2);

        // Full rotation: flush pays alice her exact A entitlement
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        assertEq(partner.balanceOf(alice), entitlementA, "exact A entitlement in flush");

        uint256 accAfterFlush = phlimbo.accPromoPerShare();
        assertGt(accAfterFlush, 0);

        address recipient = address(0x99);
        phlimbo.finalizePromotion(recipient);

        // Load-bearing invariant: the accumulator is NEVER reset
        assertEq(phlimbo.accPromoPerShare(), accAfterFlush, "accPromoPerShare survives finalize");

        phlimbo.unpause();

        // Promotion B on a different token
        MockStable tokenB = new MockStable();
        uint256 amountB = 600 ether;
        tokenB.mint(owner, amountB);
        tokenB.approve(address(phlimbo), type(uint256).max);
        phlimbo.startPromotion(address(tokenB), amountB, PROMO_DURATION);

        // Immediately after start: alice's pending against B is exactly zero
        assertEq(phlimbo.pendingPromo(alice), 0, "clean slate at start of B");

        vm.warp(block.timestamp + PROMO_DURATION / 4);
        assertEq(phlimbo.pendingPromo(alice), amountB / 4, "accrues only B");

        uint256 partnerBefore = partner.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim(alice);

        assertEq(tokenB.balanceOf(alice), amountB / 4, "paid in B only");
        assertEq(partner.balanceOf(alice), partnerBefore, "no token-A contamination");
    }

    // ============================================================
    // V3 PHASE 3: FAILED TRANSFER BANKING
    // ============================================================

    function test_batchClaim_failed_transfer_banks_unclaimable_and_continues() public {
        MockBlocklistToken blk = new MockBlocklistToken();
        blk.mint(owner, PROMO_AMOUNT);
        blk.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(blk), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 alicePending = phlimbo.pendingPromo(alice);
        uint256 bobPending = phlimbo.pendingPromo(bob);

        blk.setBlocked(alice, true);

        phlimbo.beginFlush();

        vm.expectEmit(true, true, false, true);
        emit PromoClaimFailed(address(blk), alice, alicePending);
        phlimbo.batchClaim(10);

        assertEq(phlimbo.flushCursor(), 2, "flush continued past failure");
        assertEq(blk.balanceOf(alice), 0, "blocked transfer did not pay");
        assertEq(blk.balanceOf(bob), bobPending, "bob still paid");
        assertEq(phlimbo.unclaimablePromoOf(address(blk), alice), alicePending, "failed amount banked per-user");
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), alicePending, "aggregate tracks the bank");
        // Debt stays aligned (§2.1) — the entitlement survives in the bank, NOT in pendingPromo.
        assertEq(phlimbo.pendingPromo(alice), 0, "debt still aligned on failure");

        // Sweep reserves the banked amount; the bank survives the rotation
        address recipient = address(0x99);
        uint256 contractBalance = blk.balanceOf(address(phlimbo));
        assertGe(contractBalance, alicePending, "banked tokens still in contract");

        phlimbo.finalizePromotion(recipient);
        assertEq(blk.balanceOf(recipient), contractBalance - alicePending, "only unencumbered balance swept");
        assertEq(blk.balanceOf(address(phlimbo)), alicePending, "banked tokens retained");
        assertEq(phlimbo.unclaimablePromoOf(address(blk), alice), alicePending, "per-user bank survives rotation");
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), alicePending, "aggregate survives rotation");
    }

    // ============================================================
    // V3 AUDIT-08 M-01: PER-USER PROMO BANK + PERMISSIONLESS PULL
    // ============================================================

    /// @dev alice (1x) + bob (3x) staked, promo on a blocklist token streamed to
    ///      half-window, alice blocked, flush run to completion (phase Flushing).
    function _bankAliceBlocked() internal returns (MockBlocklistToken blk, uint256 alicePending) {
        blk = new MockBlocklistToken();
        blk.mint(owner, PROMO_AMOUNT);
        blk.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(blk), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        alicePending = phlimbo.pendingPromo(alice);
        blk.setBlocked(alice, true);

        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
    }

    function test_claimUnclaimablePromo_after_unblock_makes_user_whole() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();

        blk.setBlocked(alice, false);

        vm.expectEmit(true, true, false, true);
        emit UnclaimablePromoClaimed(address(blk), alice, alicePending);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));

        assertEq(blk.balanceOf(alice), alicePending, "made whole");
        assertEq(phlimbo.unclaimablePromoOf(address(blk), alice), 0, "per-user entry zeroed");
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), 0, "aggregate decremented");

        // Entry zeroed → a second pull reverts.
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        phlimbo.claimUnclaimablePromo(address(blk));
    }

    /// @dev Bug-1 regression (underflow-brick guard): after a mid-flush pull the
    ///      aggregate MUST have been decremented, or finalizePromotion's sweep
    ///      would underflow and pin the contract in Flushing forever. Also proves
    ///      the pull is deliberately ungated: it succeeds while the contract is
    ///      paused for the flush (mid-flush self-rescue).
    function test_bank_pull_then_finalize_does_not_revert() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();

        // Mid-flush: contract is paused, phase Flushing. Pull must still work.
        assertTrue(phlimbo.paused(), "contract paused during flush");
        blk.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(blk.balanceOf(alice), alicePending, "self-rescued mid-flush");

        // Tokens left the contract AND the aggregate was decremented, so the
        // sweep must not underflow-revert (the audit's snippet bricked here).
        address recipient = address(0x99);
        uint256 remaining = blk.balanceOf(address(phlimbo));
        phlimbo.finalizePromotion(recipient);
        assertEq(blk.balanceOf(recipient), remaining, "full unencumbered balance swept");
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.None), "rotation completed");
    }

    /// @dev Bug-1 `= 0`-variant regression: the aggregate spans ALL users, so one
    ///      user's pull must decrement it by their amount only — zeroing it would
    ///      erase the other user's reservation and let the sweep confiscate it.
    function test_two_banked_one_pulls_other_bank_still_backed() public {
        MockBlocklistToken blk = new MockBlocklistToken();
        blk.mint(owner, PROMO_AMOUNT);
        blk.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(blk), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 alicePending = phlimbo.pendingPromo(alice);
        uint256 bobPending = phlimbo.pendingPromo(bob);
        blk.setBlocked(alice, true);
        blk.setBlocked(bob, true);

        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), alicePending + bobPending, "both banked");

        // Alice pulls; the aggregate must retain exactly bob's reservation.
        blk.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), bobPending, "decremented, not zeroed");

        // Finalize sweeps only balance − bob's bank…
        address recipient = address(0x99);
        uint256 balance = blk.balanceOf(address(phlimbo));
        phlimbo.finalizePromotion(recipient);
        assertEq(blk.balanceOf(recipient), balance - bobPending, "bob's bank reserved from sweep");
        assertEq(blk.balanceOf(address(phlimbo)), bobPending, "bob's bank fully backed");

        // …and bob remains claimable after the rotation.
        blk.setBlocked(bob, false);
        vm.prank(bob);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(blk.balanceOf(bob), bobPending, "bob made whole post-rotation");
    }

    function test_finalize_reserves_bank_and_bank_claimable_after_rotation() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();

        address recipient = address(0x99);
        uint256 balance = blk.balanceOf(address(phlimbo));
        phlimbo.finalizePromotion(recipient);

        assertEq(blk.balanceOf(recipient), balance - alicePending, "sweeps balance - banked");
        assertEq(blk.balanceOf(address(phlimbo)), alicePending, "bank retained");
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.None));
        phlimbo.unpause();

        // Retired token (promoToken == 0): the bank is still pullable.
        blk.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(blk.balanceOf(alice), alicePending, "claimable after promoPhase == None");
        assertEq(blk.balanceOf(address(phlimbo)), 0, "bank fully drained");
    }

    /// @dev Probe B2: token-wide pause — every flush transfer fails, 100% of the
    ///      distributed promo is banked, the sweep sends 0, and all stakers recover.
    function test_tokenwide_pause_banks_all_and_all_recover() public {
        MockPausableToken pausable = new MockPausableToken();
        pausable.mint(owner, PROMO_AMOUNT);
        pausable.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(pausable), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION); // full window: entire Q distributed

        pausable.setPaused(true);

        phlimbo.beginFlush();
        phlimbo.batchClaim(10);

        uint256 aliceBank = phlimbo.unclaimablePromoOf(address(pausable), alice);
        uint256 bobBank = phlimbo.unclaimablePromoOf(address(pausable), bob);
        assertEq(aliceBank + bobBank, PROMO_AMOUNT, "100% of funded promo banked");
        assertEq(phlimbo.totalUnclaimableOf(address(pausable)), PROMO_AMOUNT);

        // Sweep sends ~0 to leftoverRecipient — everything is reserved.
        address recipient = address(0x99);
        phlimbo.finalizePromotion(recipient);
        assertEq(pausable.balanceOf(recipient), 0, "nothing unencumbered to sweep");
        assertEq(pausable.balanceOf(address(phlimbo)), PROMO_AMOUNT, "entire bank retained");

        // Token recovers: every staker pulls in full.
        pausable.setPaused(false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(pausable));
        vm.prank(bob);
        phlimbo.claimUnclaimablePromo(address(pausable));
        assertEq(pausable.balanceOf(alice), aliceBank, "alice recovered");
        assertEq(pausable.balanceOf(bob), bobBank, "bob recovered");
        assertEq(phlimbo.totalUnclaimableOf(address(pausable)), 0, "aggregate drained");
    }

    function test_claimUnclaimablePromo_reverts_on_zero_balance() public {
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        phlimbo.claimUnclaimablePromo(address(partner));
    }

    function test_claimUnclaimablePromo_while_still_blocked_reverts() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();

        // Still blocked: the user-initiated pull deliberately reverts (reverting
        // safeTransfer, not _tryTransfer) and the bank is preserved.
        vm.prank(alice);
        vm.expectRevert("recipient blocked");
        phlimbo.claimUnclaimablePromo(address(blk));

        assertEq(phlimbo.unclaimablePromoOf(address(blk), alice), alicePending, "entry preserved on revert");
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), alicePending, "aggregate preserved on revert");
    }

    function test_claimUnclaimablePromo_is_permissionless_but_self_scoped() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();
        blk.setBlocked(alice, false);

        // eve (no role, no bank) cannot pull alice's entitlement…
        vm.prank(eve);
        vm.expectRevert("Nothing to claim");
        phlimbo.claimUnclaimablePromo(address(blk));

        // …while alice needs no role at all to pull her own.
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(blk.balanceOf(alice), alicePending, "owner of the bank pulls without any role");
    }

    /// @dev Bug-2 regression: banks are keyed per token — a retired token's bank
    ///      is untouched by a later promotion's accounting and its rotation sweep.
    function test_sequential_promotions_retired_token_bank_isolated() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();

        address recipient = address(0x99);
        phlimbo.finalizePromotion(recipient);
        phlimbo.unpause();

        // Promotion B on a different token; full rotation with successful payouts.
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        phlimbo.finalizePromotion(recipient);
        phlimbo.unpause();

        // B banked nothing; A's bank is untouched by B's accounting and sweep.
        assertEq(phlimbo.totalUnclaimableOf(address(partner)), 0, "token B banked nothing");
        assertEq(phlimbo.unclaimablePromoOf(address(blk), alice), alicePending, "token A bank unaffected");
        assertEq(blk.balanceOf(address(phlimbo)), alicePending, "token A bank still backed");

        blk.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(blk.balanceOf(alice), alicePending, "retired-token bank claimable after promotion B");
    }

    /// @dev abortFlush resets neither flushCursor nor the bank: a stale bank rides
    ///      into a resumed flush. Re-flushed users bank nothing further (debts
    ///      already aligned) and the finalize sweep still reserves the stale bank.
    function test_abortFlush_stale_bank_rides_into_resumed_flush() public {
        (MockBlocklistToken blk, uint256 alicePending) = _bankAliceBlocked();

        phlimbo.abortFlush();
        phlimbo.unpause();
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), alicePending, "bank not reset by abortFlush");

        // Resume the rotation: nobody banks again (pending == 0, debts aligned).
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        assertEq(phlimbo.totalUnclaimableOf(address(blk)), alicePending, "no double-bank on re-flush");

        // The sweep must not assume the bank is zero at beginFlush.
        address recipient = address(0x99);
        uint256 balance = blk.balanceOf(address(phlimbo));
        phlimbo.finalizePromotion(recipient);
        assertEq(blk.balanceOf(recipient), balance - alicePending, "stale bank reserved from sweep");

        blk.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blk));
        assertEq(blk.balanceOf(alice), alicePending, "stale bank still claimable");
    }

    /// @dev Coverage win: _tryTransfer's "returns false without reverting" branch —
    ///      a false-returning (non-reverting) transfer must bank exactly like a
    ///      reverting one, and no tokens may move.
    function test_batchClaim_false_return_transfer_banks() public {
        MockFalseReturnToken fr = new MockFalseReturnToken();
        fr.mint(owner, PROMO_AMOUNT);
        fr.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(fr), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 alicePending = phlimbo.pendingPromo(alice);
        uint256 bobPending = phlimbo.pendingPromo(bob);
        fr.setFail(alice, true);

        phlimbo.beginFlush();
        vm.expectEmit(true, true, false, true);
        emit PromoClaimFailed(address(fr), alice, alicePending);
        phlimbo.batchClaim(10);

        assertEq(fr.balanceOf(alice), 0, "false-return moved no tokens");
        assertEq(fr.balanceOf(bob), bobPending, "bob still paid");
        assertEq(phlimbo.unclaimablePromoOf(address(fr), alice), alicePending, "false-return banked");

        fr.setFail(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(fr));
        assertEq(fr.balanceOf(alice), alicePending, "recovered via pull");
    }

    // ============================================================
    // V3 PHASE 3: FINALIZE SWEEP + SLOT ZEROING
    // ============================================================

    function test_finalizePromotion_sweeps_leftover_and_zeroes_slot() public {
        _setupActivePromoHalfStreamed();

        phlimbo.beginFlush();
        phlimbo.batchClaim(10);

        // Promo cut short at half window: ~Q/2 undistributed remains in the contract
        address recipient = address(0x99);
        uint256 leftover = partner.balanceOf(address(phlimbo));
        assertEq(leftover, PROMO_AMOUNT / 2, "half of Q left over");

        uint256 accBefore = phlimbo.accPromoPerShare();

        vm.expectEmit(true, true, false, true);
        emit PromotionFinalized(address(partner), recipient, leftover);
        phlimbo.finalizePromotion(recipient);

        assertEq(partner.balanceOf(recipient), leftover, "leftover swept");
        assertEq(partner.balanceOf(address(phlimbo)), 0);
        assertEq(phlimbo.totalUnclaimableOf(address(partner)), 0, "no failures: nothing reserved from sweep");

        // Slot cleared…
        assertEq(address(phlimbo.promoToken()), address(0));
        assertEq(phlimbo.promoRewardPerSecond(), 0);
        assertEq(phlimbo.promoRewardBalance(), 0);
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.None));
        // …but the accumulator is NEVER reset
        assertEq(phlimbo.accPromoPerShare(), accBefore, "accPromoPerShare NOT reset");

        // Rotation complete: a fresh promotion can start after unpause
        phlimbo.unpause();
        partner.mint(owner, PROMO_AMOUNT);
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.Active));
    }

    function test_finalizePromotion_empty_staker_set_immediate() public {
        // No stakers: cursor 0 == length 0, finalize allowed right after beginFlush
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        phlimbo.beginFlush();

        address recipient = address(0x99);
        phlimbo.finalizePromotion(recipient);
        assertEq(partner.balanceOf(recipient), PROMO_AMOUNT, "full Q swept with no stakers");
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.None));
    }

    // ============================================================
    // V3 PHASE 3: emergencyTransfer SWEEPS PROMO TOKEN
    // ============================================================

    function test_emergencyTransfer_sweeps_promo_token() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        address recipient = address(0x99);
        phlimbo.emergencyTransfer(recipient);

        assertEq(partner.balanceOf(recipient), PROMO_AMOUNT, "promo token swept");
        assertEq(rewardToken.balanceOf(recipient), 100 ether, "reward token swept");
        assertEq(phUSD.balanceOf(recipient), STAKE_AMOUNT, "phUSD swept");
        assertEq(partner.balanceOf(address(phlimbo)), 0);
    }

    /// @dev Accepted trade-off (audit-08 M-01): emergencyTransfer sweeps the LIVE
    ///      promo token's entire balance INCLUDING per-user banked amounts —
    ///      asymmetric with finalizePromotion, which reserves the bank.
    function test_emergencyTransfer_sweeps_live_token_bank_tradeoff() public {
        MockBlocklistToken blk = new MockBlocklistToken();
        blk.mint(owner, PROMO_AMOUNT);
        blk.approve(address(phlimbo), type(uint256).max);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(blk), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        blk.setBlocked(alice, true);
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        uint256 banked = phlimbo.unclaimablePromoOf(address(blk), alice);
        assertGt(banked, 0, "alice banked");

        // Leave the flush (emergencyTransfer ends with _pause(), so it cannot run
        // while already paused); the promo slot stays live and the bank persists.
        phlimbo.abortFlush();
        phlimbo.unpause();

        // Escape hatch while the promo slot is still live: bank is swept along.
        address recipient = address(0x99);
        phlimbo.emergencyTransfer(recipient);
        assertEq(blk.balanceOf(recipient), PROMO_AMOUNT, "entire balance incl. bank swept");
        assertEq(blk.balanceOf(address(phlimbo)), 0, "nothing left backing the bank");
        // The mapping entry remains (out-of-band owner obligation to make whole).
        assertEq(phlimbo.unclaimablePromoOf(address(blk), alice), banked, "bank record persists unbacked");
    }

    // ============================================================
    // GAS SNAPSHOT SCENARIOS (documenting plan §2's gas claims)
    // ------------------------------------------------------------
    // Named so `forge snapshot` records stake/withdraw/claim costs
    // with the promo slot empty vs active vs dormant, and the
    // per-user cost of the flush. Compare lines in .gas-snapshot.
    // ============================================================

    /// @dev alice staked with stable rewards flowing; promo slot per `mode`:
    ///      0 = empty (no promotion), 1 = active, 2 = dormant (depleted, token set).
    function _setupGasScenario(uint256 mode) internal {
        vm.pauseGasMetering();
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);

        if (mode == 1) {
            phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        } else if (mode == 2) {
            phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
            vm.warp(block.timestamp + PROMO_DURATION * 2); // stream past its window
        }

        // Let every stream accrue, then settle, so all three scenarios measure the
        // op against warm, populated storage slots (accumulators, debts, balances all
        // non-zero) and freshly-aligned state. Mode 2's settle claim also depletes
        // the promo → dormant.
        vm.warp(block.timestamp + 1000);
        vm.prank(alice);
        phlimbo.claim(alice);

        // Mode 2's long warp also depleted the stable stream — refill it so every
        // scenario measures with a live stable stream and only the promo slot differs.
        if (mode == 2) {
            vm.prank(rewardDonor);
            phlimbo.collectReward(100 ether);
        }

        vm.warp(block.timestamp + 1000);
        vm.resumeGasMetering();
    }

    function test_gas_stake_promoEmpty() public {
        _setupGasScenario(0);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_gas_stake_promoActive() public {
        _setupGasScenario(1);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_gas_stake_promoDormant() public {
        _setupGasScenario(2);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
    }

    function test_gas_withdraw_promoEmpty() public {
        _setupGasScenario(0);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);
    }

    function test_gas_withdraw_promoActive() public {
        _setupGasScenario(1);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);
    }

    function test_gas_withdraw_promoDormant() public {
        _setupGasScenario(2);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT / 2, alice);
    }

    function test_gas_claim_promoEmpty() public {
        _setupGasScenario(0);
        vm.prank(alice);
        phlimbo.claim(alice);
    }

    function test_gas_claim_promoActive() public {
        _setupGasScenario(1);
        vm.prank(alice);
        phlimbo.claim(alice);
    }

    function test_gas_claim_promoDormant() public {
        _setupGasScenario(2);
        vm.prank(alice);
        phlimbo.claim(alice);
    }

    /// @dev Ten stakers flushed in one call — divide the snapshot line by 10 for the
    ///      approximate per-user flush cost (each user: pending calc + debt write +
    ///      promo transfer).
    function test_gas_batchClaim_10_stakers() public {
        vm.pauseGasMetering();
        for (uint160 i = 1; i <= 10; i++) {
            address staker = address(uint160(0x1000) + i);
            phUSD.mint(staker, STAKE_AMOUNT);
            vm.startPrank(staker);
            phUSD.approve(address(phlimbo), type(uint256).max);
            phlimbo.stake(STAKE_AMOUNT, staker);
            vm.stopPrank();
        }

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);
        phlimbo.beginFlush();
        vm.resumeGasMetering();

        phlimbo.batchClaim(10);
        assertEq(phlimbo.flushCursor(), 10);
    }
}

/**
 * @title PhlimboV3StableBankTest
 * @notice audit-09 M-01 stable leg. Wires a MockBlocklistToken as the STABLE
 *         `rewardToken` (no other test does this) and proves the self-service paths
 *         (withdraw/stake/claim) no longer freeze a blocklisted staker's principal:
 *         the failing stable transfer is banked into `unclaimableStableOf` and pulled
 *         later via `claimUnclaimableStable`.
 */
contract PhlimboV3StableBankTest is Test {
    event StableClaimFailed(address indexed user, uint256 amount);
    event UnclaimableStableClaimed(address indexed user, uint256 amount);

    PhlimboV3 public phlimbo;
    MockFlax public phUSD;
    MockBlocklistToken public stable;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public migrator = address(0x5);
    address public rewardDonor = address(0x3);

    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant DEPLETION_DURATION = 604800;

    function setUp() public {
        phUSD = new MockFlax();
        stable = new MockBlocklistToken();
        phlimbo = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, 10000 ether);
        phUSD.mint(bob, 10000 ether);
        phUSD.mint(migrator, 10000 ether);

        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(migrator);
        phUSD.approve(address(phlimbo), type(uint256).max);

        stable.mint(rewardDonor, 100000 ether);
        vm.prank(rewardDonor);
        stable.approve(address(phlimbo), type(uint256).max);
    }

    function _fundStable(uint256 amount) internal {
        vm.prank(rewardDonor);
        phlimbo.collectReward(amount);
    }

    // --- Core fix: blocked staker withdraws principal successfully, stable banked ---
    function test_blockedStable_withdraw_succeeds_and_banks() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);
        uint256 pending = phlimbo.pendingStable(alice);
        assertGt(pending, 0, "alice should have accrued stable");

        stable.setBlocked(alice, true);

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.expectEmit(true, false, false, true);
        emit StableClaimFailed(alice, pending);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);

        assertEq(phUSD.balanceOf(alice), balBefore + STAKE_AMOUNT, "principal returned");
        assertEq(phlimbo.unclaimableStableOf(alice), pending, "stable banked");
        assertEq(phlimbo.totalUnclaimableStable(), pending, "aggregate banked");
        assertEq(phlimbo.pendingStable(alice), 0, "pending realigned to 0");
    }

    function test_blockedStable_claim_succeeds_and_banks() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);
        stable.setBlocked(alice, true);
        uint256 pending = phlimbo.pendingStable(alice);

        vm.prank(alice);
        phlimbo.claim(alice);

        assertEq(phlimbo.unclaimableStableOf(alice), pending, "stable banked");
        assertEq(phlimbo.pendingStable(alice), 0, "pending realigned");
    }

    function test_blockedStable_stake_succeeds_and_banks() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);
        stable.setBlocked(alice, true);
        uint256 pending = phlimbo.pendingStable(alice);

        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        assertEq(phlimbo.unclaimableStableOf(alice), pending, "stable banked on stake");
    }

    // --- No-redistribution regression (Nuance 1) ---
    function test_bankedStable_notRedistributed_toCostaker() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);

        uint256 bobPendingBefore = phlimbo.pendingStable(bob);
        assertGt(bobPendingBefore, 0, "bob accrued");

        stable.setBlocked(alice, true);
        vm.prank(alice);
        phlimbo.claim(alice);

        // Banked stable must NOT be redistributed into bob's accrual.
        assertEq(phlimbo.pendingStable(bob), bobPendingBefore, "co-staker pending unchanged");
    }

    // --- Stable pull round-trip ---
    function test_claimUnclaimableStable_roundTrip() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);
        stable.setBlocked(alice, true);
        vm.prank(alice);
        phlimbo.claim(alice);
        uint256 banked = phlimbo.unclaimableStableOf(alice);
        assertGt(banked, 0, "banked");

        // Reverts while still blocked.
        vm.prank(alice);
        vm.expectRevert("recipient blocked");
        phlimbo.claimUnclaimableStable();

        // Unblock and pull.
        stable.setBlocked(alice, false);
        vm.expectEmit(true, false, false, true);
        emit UnclaimableStableClaimed(alice, banked);
        vm.prank(alice);
        phlimbo.claimUnclaimableStable();

        assertEq(stable.balanceOf(alice), banked, "paid in full");
        assertEq(phlimbo.unclaimableStableOf(alice), 0, "bank cleared");
        assertEq(phlimbo.totalUnclaimableStable(), 0, "aggregate cleared");

        // Reverts on zero balance.
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        phlimbo.claimUnclaimableStable();
    }

    function test_claimUnclaimableStable_ungatedByPause() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);
        stable.setBlocked(alice, true);
        vm.prank(alice);
        phlimbo.claim(alice);
        uint256 banked = phlimbo.unclaimableStableOf(alice);
        stable.setBlocked(alice, false);

        // Pause the contract; the self-rescue pull must still work.
        phlimbo.pause();
        vm.prank(alice);
        phlimbo.claimUnclaimableStable();
        assertEq(stable.balanceOf(alice), banked, "pull works while paused");
    }

    // --- Migrator delegation recovery path ---
    function test_migrator_claim_routesToMigrator_unsticksBlockedUser() public {
        phlimbo.setMigrator(migrator);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        _fundStable(1000 ether);
        vm.warp(block.timestamp + 100000);
        stable.setBlocked(alice, true);

        uint256 pending = phlimbo.pendingStable(alice);
        // Migrator (unblocked) claims on behalf of the blocked user; stable lands with migrator.
        vm.prank(migrator);
        phlimbo.claim(alice);
        assertEq(stable.balanceOf(migrator), pending, "stable routed to migrator");
        assertEq(phlimbo.totalUnclaimableStable(), 0, "nothing banked (migrator unblocked)");
        assertEq(phlimbo.pendingStable(alice), 0, "blocked user's debt realigned");

        // Alice's subsequent self-service withdraw no longer touches the stable leg.
        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);
        assertEq(phUSD.balanceOf(alice), balBefore + STAKE_AMOUNT, "principal freed");
    }
}

/**
 * @title PhlimboV3PromoBankSelfServiceTest
 * @notice audit-09 M-01 promo leg. Uses a plain stable `rewardToken` and a
 *         MockBlocklistToken as the PROMO token, proving the self-service paths bank
 *         a failed promo transfer into the EXISTING `unclaimablePromoOf` bank
 *         (story 027 infra, credited to the beneficiary) — distinct from the
 *         `batchClaim`-path tests above — and that the bank survives a finalize.
 */
contract PhlimboV3PromoBankSelfServiceTest is Test {
    event PromoClaimFailed(address indexed token, address indexed user, uint256 amount);

    PhlimboV3 public phlimbo;
    MockFlax public phUSD;
    MockStable public stable;
    MockBlocklistToken public blkPromo;

    address public owner = address(this);
    address public alice = address(0x1);
    address public migrator = address(0x5);
    address public rewardDonor = address(0x3);

    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant DEPLETION_DURATION = 604800;
    uint256 constant PROMO_AMOUNT = 1000 ether;
    uint256 constant PROMO_DURATION = 1_000_000;

    function setUp() public {
        phUSD = new MockFlax();
        stable = new MockStable();
        phlimbo = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, 10000 ether);
        phUSD.mint(migrator, 10000 ether);
        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(migrator);
        phUSD.approve(address(phlimbo), type(uint256).max);

        blkPromo = new MockBlocklistToken();
        blkPromo.mint(owner, 10 * PROMO_AMOUNT);
        blkPromo.approve(address(phlimbo), type(uint256).max);
    }

    function test_blockedPromo_withdraw_banks_and_pull() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        phlimbo.startPromotion(address(blkPromo), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + 10000);
        uint256 pending = phlimbo.pendingPromo(alice);
        assertGt(pending, 0, "alice accrued promo");
        blkPromo.setBlocked(alice, true);

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit PromoClaimFailed(address(blkPromo), alice, pending);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice);

        assertEq(phUSD.balanceOf(alice), balBefore + STAKE_AMOUNT, "principal returned");
        assertEq(phlimbo.unclaimablePromoOf(address(blkPromo), alice), pending, "promo banked");
        assertEq(phlimbo.totalUnclaimableOf(address(blkPromo)), pending, "aggregate banked");
        assertEq(phlimbo.pendingPromo(alice), 0, "pending realigned");

        blkPromo.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blkPromo));
        assertEq(blkPromo.balanceOf(alice), pending, "made whole");
    }

    function test_blockedPromo_claim_banks() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        phlimbo.startPromotion(address(blkPromo), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + 10000);
        blkPromo.setBlocked(alice, true);
        uint256 pending = phlimbo.pendingPromo(alice);

        vm.prank(alice);
        phlimbo.claim(alice);

        assertEq(phlimbo.unclaimablePromoOf(address(blkPromo), alice), pending, "promo banked on claim");
    }

    function test_promo_bankedViaClaimRewards_survivesFinalize() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        phlimbo.startPromotion(address(blkPromo), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + 10000);
        blkPromo.setBlocked(alice, true);

        // Self-service claim banks promo via _claimRewards (Active phase).
        vm.prank(alice);
        phlimbo.claim(alice);
        uint256 banked = phlimbo.unclaimablePromoOf(address(blkPromo), alice);
        assertGt(banked, 0, "banked via _claimRewards");

        // Owner rotates the promo slot.
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        phlimbo.finalizePromotion(owner);
        phlimbo.unpause();

        // Bank survived rotation (reserved from the sweep); pull after unblock.
        assertEq(phlimbo.unclaimablePromoOf(address(blkPromo), alice), banked, "bank survived finalize");
        blkPromo.setBlocked(alice, false);
        vm.prank(alice);
        phlimbo.claimUnclaimablePromo(address(blkPromo));
        assertEq(blkPromo.balanceOf(alice), banked, "pullable after rotation");
    }

    function test_migrator_claim_routesPromoToMigrator() public {
        phlimbo.setMigrator(migrator);
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        phlimbo.startPromotion(address(blkPromo), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + 10000);
        blkPromo.setBlocked(alice, true);

        uint256 pending = phlimbo.pendingPromo(alice);
        vm.prank(migrator);
        phlimbo.claim(alice);

        assertEq(blkPromo.balanceOf(migrator), pending, "promo routed to migrator");
        assertEq(phlimbo.totalUnclaimableOf(address(blkPromo)), 0, "nothing banked (migrator unblocked)");
        assertEq(phlimbo.pendingPromo(alice), 0, "blocked user debt realigned");
    }
}

/**
 * @title PhlimboV3PhUSDMintBankTest
 * @notice audit-09 V3-M-05 / V3-L-14 phUSD mint leg. Uses a MockRevertingMintFlax as
 *         the phUSD stake+reward token so the `_claimRewards` mint can be forced to
 *         revert (models PhlimboV3 losing mint authority). Proves the self-service
 *         paths (claim/withdraw) no longer freeze a staker's principal: the failing
 *         mint is banked into `unclaimablePhUSDOf` and RE-MINTED later via
 *         `claimUnclaimablePhUSD`. Mirrors PhlimboV3StableBankTest.
 */
contract PhlimboV3PhUSDMintBankTest is Test {
    event PhUSDMintFailed(address indexed beneficiary, uint256 amount);
    event UnclaimablePhUSDClaimed(address indexed user, uint256 amount);

    PhlimboV3 public phlimbo;
    MockRevertingMintFlax public phUSD;
    MockStable public stable;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public migrator = address(0x5);
    address public rewardDonor = address(0x3);

    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant DEPLETION_DURATION = 604800;

    function setUp() public {
        phUSD = new MockRevertingMintFlax();
        stable = new MockStable();
        phlimbo = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, 10000 ether);
        phUSD.mint(bob, 10000 ether);
        phUSD.mint(migrator, 10000 ether);

        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(migrator);
        phUSD.approve(address(phlimbo), type(uint256).max);

        stable.mint(rewardDonor, 100000 ether);
        vm.prank(rewardDonor);
        stable.approve(address(phlimbo), type(uint256).max);

        // Non-zero APY so phUSD rewards accrue (two-step: preview then commit).
        phlimbo.setDesiredAPY(500);
        phlimbo.setDesiredAPY(500);
    }

    // --- Core fix: claim succeeds and banks when the phUSD mint reverts ---
    function test_revertingMint_claim_succeeds_and_banks() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.warp(block.timestamp + 100000);

        uint256 pending = phlimbo.pendingPhUSD(alice);
        assertGt(pending, 0, "alice should have accrued phUSD");

        // PhlimboV3 loses mint authority.
        phUSD.setMintReverts(true);

        vm.expectEmit(true, false, false, true);
        emit PhUSDMintFailed(alice, pending);
        vm.prank(alice);
        phlimbo.claim(alice); // must NOT revert

        assertEq(phlimbo.unclaimablePhUSDOf(alice), pending, "phUSD banked");
        assertEq(phlimbo.totalUnclaimablePhUSD(), pending, "aggregate banked");
        assertEq(phlimbo.pendingPhUSD(alice), 0, "pending realigned to 0");
    }

    // --- Principal path stays live: withdraw returns stake even when mint reverts ---
    function test_revertingMint_withdraw_returns_principal_and_banks() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.warp(block.timestamp + 100000);

        uint256 pending = phlimbo.pendingPhUSD(alice);
        assertGt(pending, 0, "alice accrued phUSD");
        phUSD.setMintReverts(true);

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        phlimbo.withdraw(STAKE_AMOUNT, alice); // principal transfer, mint banked

        // Principal returned (transfer, not mint) even though the reward mint failed.
        assertEq(phUSD.balanceOf(alice), balBefore + STAKE_AMOUNT, "principal returned");
        assertEq(phlimbo.unclaimablePhUSDOf(alice), pending, "phUSD reward banked");
        assertEq(phlimbo.totalUnclaimablePhUSD(), pending, "aggregate banked");
    }

    // --- Pull re-mints the exact banked amount once authority is restored ---
    function test_claimUnclaimablePhUSD_roundTrip() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.warp(block.timestamp + 100000);
        phUSD.setMintReverts(true);
        vm.prank(alice);
        phlimbo.claim(alice);

        uint256 banked = phlimbo.unclaimablePhUSDOf(alice);
        assertGt(banked, 0, "banked");

        // Reverts while mint authority is still missing (bank intact).
        vm.prank(alice);
        vm.expectRevert("mint not authorized");
        phlimbo.claimUnclaimablePhUSD();
        assertEq(phlimbo.unclaimablePhUSDOf(alice), banked, "bank intact after failed pull");

        // Restore authority and pull — re-mints exactly the banked amount.
        phUSD.setMintReverts(false);
        uint256 balBefore = phUSD.balanceOf(alice);
        vm.expectEmit(true, false, false, true);
        emit UnclaimablePhUSDClaimed(alice, banked);
        vm.prank(alice);
        phlimbo.claimUnclaimablePhUSD();

        assertEq(phUSD.balanceOf(alice), balBefore + banked, "re-minted in full");
        assertEq(phlimbo.unclaimablePhUSDOf(alice), 0, "bank cleared");
        assertEq(phlimbo.totalUnclaimablePhUSD(), 0, "aggregate cleared");

        // Reverts on zero balance.
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        phlimbo.claimUnclaimablePhUSD();
    }

    // --- Self-rescue pull is not pause-gated ---
    function test_claimUnclaimablePhUSD_ungatedByPause() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.warp(block.timestamp + 100000);
        phUSD.setMintReverts(true);
        vm.prank(alice);
        phlimbo.claim(alice);
        uint256 banked = phlimbo.unclaimablePhUSDOf(alice);
        phUSD.setMintReverts(false);

        // Pause the contract; the self-rescue pull must still work.
        phlimbo.pause();
        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claimUnclaimablePhUSD();
        assertEq(phUSD.balanceOf(alice), balBefore + banked, "pull works while paused");
    }

    // --- Banked phUSD must not leak into a co-staker's accrual ---
    function test_bankedPhUSD_notRedistributed_toCostaker() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);
        vm.warp(block.timestamp + 100000);

        uint256 bobPendingBefore = phlimbo.pendingPhUSD(bob);
        assertGt(bobPendingBefore, 0, "bob accrued");

        phUSD.setMintReverts(true);
        vm.prank(alice);
        phlimbo.claim(alice);

        // Alice's banked phUSD is minted independently, so bob's accrual is untouched.
        assertEq(phlimbo.pendingPhUSD(bob), bobPendingBefore, "co-staker pending unchanged");
    }
}
