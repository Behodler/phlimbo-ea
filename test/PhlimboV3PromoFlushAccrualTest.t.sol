// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/PhlimboV3.sol";
import "../src/interfaces/IPhlimboV3.sol";
import "./Mocks.sol";

/**
 * @title PhlimboV3PromoFlushAccrualTest
 * @notice Regression suite for audit-07 H-01: during the promo Flushing phase,
 *         `accPromoPerShare` must be FROZEN. Three call paths reach `_updatePool()`
 *         while the contract is paused — permissionless `collectReward`, and the
 *         owner-only `setDesiredAPY` (commit branch) and `setDepletionDuration` —
 *         and before the fix each of them advanced the promo accumulator after
 *         `batchClaim` had already aligned every staker's `promoDebt`. The gap became
 *         phantom pending promo that survived `finalizePromotion` and was claimable
 *         against the NEXT promotion's token (theft), or bricked claims outright when
 *         it exceeded the next promo's funded pool (ERC20InsufficientBalance DoS).
 *
 *         Ported from the auditor's PoC (PromoFlushAccrualPoC.t.sol) with assertions
 *         rewritten to express the FIXED behaviour, plus guards against over-gating:
 *         beginFlush's own final accrual, the stable/phUSD streams during Flushing,
 *         and accrual resumption after abortFlush must all keep working.
 */
contract PhlimboV3PromoFlushAccrualTest is Test {
    PhlimboV3 public phlimbo;
    MockFlax public phUSD;
    MockStable public rewardToken;
    MockStable public partner;
    MockStable public partner2;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public rewardDonor = address(0x3);
    address public leftoverRecipient = address(0x1EF7);

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
        rewardToken.mint(rewardDonor, INITIAL_BALANCE);

        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(rewardDonor);
        rewardToken.approve(address(phlimbo), type(uint256).max);

        // Partner tokens for the promotional slot: owner (this) holds and approves
        partner = new MockStable();
        partner.mint(owner, INITIAL_BALANCE);
        partner.approve(address(phlimbo), type(uint256).max);
        partner2 = new MockStable();
        partner2.mint(owner, INITIAL_BALANCE);
        partner2.approve(address(phlimbo), type(uint256).max);
    }

    /// @dev alice (1x) and bob (3x) staked, promo Active, half the window elapsed.
    function _setupActivePromoHalfStreamed() internal {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT * 3, bob);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);
    }

    // ============================================================
    // V3 H-01 REGRESSION: PORTED PoC SCENARIOS (FIXED BEHAVIOUR)
    // ============================================================

    /// @dev PoC scenario 1, fixed: a permissionless collectReward during the flush
    ///      window must NOT advance accPromoPerShare, so no phantom pending survives
    ///      the rotation and the next promotion starts at exactly zero for everyone.
    function test_collectReward_during_flush_keeps_pending_zero_across_rotation() public {
        // Alice stakes; a promotion streams promo to her for half the window.
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        // Rotation: pause + flush + align debts.
        phlimbo.beginFlush();
        phlimbo.batchClaim(10); // flushCursor == stakerCount; alice.promoDebt aligned

        assertEq(phlimbo.pendingPromo(alice), 0, "debt aligned at flush -> zero pending");
        uint256 accAfterFlush = phlimbo.accPromoPerShare();
        assertGt(accAfterFlush, 0, "half the window accrued before the flush");

        // Permissionless collectReward DURING Flushing runs _updatePool. promoToken
        // is still set, but the phase gate must freeze the promo accumulator.
        vm.warp(block.timestamp + 3 days);
        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);

        assertEq(
            phlimbo.accPromoPerShare(), accAfterFlush, "accPromoPerShare frozen during Flushing despite collectReward"
        );

        // Finalize the rotation -> phase None, promoToken cleared; owner unpauses.
        phlimbo.finalizePromotion(leftoverRecipient);
        phlimbo.unpause();
        assertEq(uint256(phlimbo.promoPhase()), uint256(IPhlimboV3.PromoPhase.None), "phase None");

        // FIXED: no phantom pending while phase == None.
        assertEq(phlimbo.pendingPromo(alice), 0, "no phantom promo pending after rotation");

        // The NEXT promotion starts at exactly zero for alice: nothing claimable
        // against the brand-new token with zero stake time in promo #2.
        phlimbo.startPromotion(address(partner2), 500 ether, PROMO_DURATION);
        assertEq(phlimbo.pendingPromo(alice), 0, "new promo is zero-based");

        uint256 aliceP2Before = partner2.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertEq(partner2.balanceOf(alice), aliceP2Before, "nothing claimable at t=0 of promo #2");
    }

    /// @dev PoC scenario 2, fixed: even when the entire promo window elapses during
    ///      the flush, no over-credit accumulates, so a legitimate claim against the
    ///      next promotion SUCCEEDS (previously ERC20InsufficientBalance).
    function test_flush_accrual_cannot_overcredit_next_promo_pool() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);

        // Enough time for the whole promo to accrue — if the gate were missing.
        vm.warp(block.timestamp + 30 days);
        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);

        phlimbo.finalizePromotion(leftoverRecipient);
        phlimbo.unpause();

        // New promotion of the SAME token, identical size.
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 4);

        // Alice's credit is exactly her legitimate quarter-window share, never more
        // than the pool holds, and her claim SUCCEEDS.
        uint256 pending = phlimbo.pendingPromo(alice);
        assertEq(pending, PROMO_AMOUNT / 4, "exactly the legitimate quarter-window share");
        assertLe(pending, partner.balanceOf(address(phlimbo)), "never credited beyond pool");

        uint256 aliceBefore = partner.balanceOf(alice);
        vm.prank(alice);
        phlimbo.claim(alice);
        assertEq(partner.balanceOf(alice) - aliceBefore, pending, "legitimate claim succeeds");
    }

    // ============================================================
    // V3 H-01 REGRESSION: EACH _updatePool PATH REACHABLE WHILE FLUSHING
    // ============================================================

    function test_collectReward_during_flushing_does_not_advance_accPromoPerShare() public {
        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();

        uint256 accAtFlush = phlimbo.accPromoPerShare();
        uint256 promoBalanceAtFlush = phlimbo.promoRewardBalance();

        vm.warp(block.timestamp + 1 days);
        vm.prank(rewardDonor);
        phlimbo.collectReward(10 ether);

        assertEq(phlimbo.accPromoPerShare(), accAtFlush, "promo accumulator frozen");
        assertEq(phlimbo.promoRewardBalance(), promoBalanceAtFlush, "promo balance untouched");
        assertEq(phlimbo.lastRewardTime(), block.timestamp, "clock still advances");
    }

    function test_setDesiredAPY_during_flushing_does_not_advance_accPromoPerShare() public {
        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();

        uint256 accAtFlush = phlimbo.accPromoPerShare();

        vm.warp(block.timestamp + 1 days);
        // Two-step: preview then commit — the commit branch calls _updatePool.
        phlimbo.setDesiredAPY(500);
        phlimbo.setDesiredAPY(500);
        assertEq(phlimbo.desiredAPYBps(), 500, "APY commit went through");

        assertEq(phlimbo.accPromoPerShare(), accAtFlush, "promo accumulator frozen");
    }

    function test_setDepletionDuration_during_flushing_does_not_advance_accPromoPerShare() public {
        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();

        uint256 accAtFlush = phlimbo.accPromoPerShare();

        vm.warp(block.timestamp + 1 days);
        phlimbo.setDepletionDuration(DEPLETION_DURATION * 2);
        assertEq(phlimbo.depletionDuration(), DEPLETION_DURATION * 2, "duration change went through");

        assertEq(phlimbo.accPromoPerShare(), accAtFlush, "promo accumulator frozen");
    }

    // ============================================================
    // V3 H-01 REGRESSION: OVER-GATING GUARDS
    // ============================================================

    /// @dev beginFlush calls _updatePool while promoPhase is still Active — the gate
    ///      must permit this intended FINAL accrual.
    function test_beginFlush_final_accrual_still_works() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        assertEq(phlimbo.accPromoPerShare(), 0, "no trigger yet");

        phlimbo.beginFlush();

        assertGt(phlimbo.accPromoPerShare(), 0, "beginFlush's own final accrual happened");
        assertEq(phlimbo.promoRewardBalance(), PROMO_AMOUNT / 2, "half the window accrued");
        assertEq(phlimbo.pendingPromo(alice), PROMO_AMOUNT / 2, "alice's entitlement intact");
    }

    /// @dev The gate must be promo-only: the stable and phUSD streams keep accruing
    ///      during Flushing (their freeze semantics are pause-based, not phase-based).
    function test_stable_and_phusd_streams_still_accrue_during_flushing() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        // Seed the stable stream and a non-zero phUSD emission rate.
        vm.prank(rewardDonor);
        phlimbo.collectReward(100 ether);
        phlimbo.setDesiredAPY(500); // preview
        phlimbo.setDesiredAPY(500); // commit

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        phlimbo.beginFlush();

        uint256 accStableAtFlush = phlimbo.accStablePerShare();
        uint256 accPhUSDAtFlush = phlimbo.accPhUSDPerShare();
        uint256 accPromoAtFlush = phlimbo.accPromoPerShare();

        vm.warp(block.timestamp + 1 days);
        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);

        assertGt(phlimbo.accStablePerShare(), accStableAtFlush, "stable stream still accrues");
        assertGt(phlimbo.accPhUSDPerShare(), accPhUSDAtFlush, "phUSD stream still accrues");
        assertEq(phlimbo.accPromoPerShare(), accPromoAtFlush, "only promo is frozen");
        assertEq(phlimbo.lastRewardTime(), block.timestamp, "clock still advances");
    }

    /// @dev abortFlush returns the phase to Active: promo accrual must RESUME from
    ///      that point (the flush window itself stays skipped — the clock advanced).
    function test_accrual_resumes_after_abortFlush() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        phlimbo.beginFlush();

        uint256 accAtFlush = phlimbo.accPromoPerShare();

        // Advance the clock DURING the flush: promo stays frozen.
        vm.warp(block.timestamp + 2 days);
        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);
        assertEq(phlimbo.accPromoPerShare(), accAtFlush, "frozen during flush");

        phlimbo.abortFlush();
        phlimbo.unpause();

        // A quarter window after the abort: exactly that slice accrues, no back-pay
        // for the flush window (the undistributed remainder stays in promoRewardBalance).
        vm.warp(block.timestamp + PROMO_DURATION / 4);
        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);

        assertGt(phlimbo.accPromoPerShare(), accAtFlush, "accrual resumed after abortFlush");
        assertEq(phlimbo.pendingPromo(alice), PROMO_AMOUNT / 4, "exactly the post-abort slice");
        assertEq(
            phlimbo.promoRewardBalance(),
            PROMO_AMOUNT - PROMO_AMOUNT / 4,
            "flush-window slice undistributed, not back-paid"
        );
    }

    /// @dev pendingPromo mirrors _updatePool's math; the view must carry the same
    ///      phase gate or it over-reports during Flushing relative to what
    ///      _updatePool would actually write.
    function test_pendingPromo_consistent_with_updatePool_during_flushing() public {
        _setupActivePromoHalfStreamed();
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);

        assertEq(phlimbo.pendingPromo(alice), 0, "aligned at flush");

        vm.warp(block.timestamp + 3 days);

        // View before any state write...
        uint256 viewPending = phlimbo.pendingPromo(alice);
        assertEq(viewPending, 0, "view reports frozen accumulator during Flushing");

        // ...must match what _updatePool actually writes.
        vm.prank(rewardDonor);
        phlimbo.collectReward(1 ether);
        assertEq(phlimbo.pendingPromo(alice), viewPending, "view consistent with _updatePool");
    }
}
