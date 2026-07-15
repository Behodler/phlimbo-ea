// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MigratorV2V3.sol";
import "../src/PhlimboV2.sol";
import "../src/PhlimboV3.sol";
import "../src/interfaces/IMigratorV2V3.sol";
import "./Mocks.sol";

/**
 * @title MigratorV2V3Test
 * @notice Full coverage for MigratorV2V3 per story 023 (plan §5/§6). Mirrors the
 *         MigratorV1V2Test conventions plus the live-read-specific scenarios:
 *
 *   1. Constructor
 *   2. seedUsers (onlyOwner, non-empty, reseed rules)
 *   3. migrate guards (not seeded, maxIterations==0, complete, wiring negatives)
 *   4. migrate iterator across multiple calls (chunked, -1 termination)
 *   5. Live-read robustness (full exit → skip; partial withdraw → reduced amount)
 *   6. Straggler second pass (post-processing V2 re-stake → reseed → second pass)
 *   7. Reward-delta forwarding exactness
 *   8. Migrated user starts with zero promo pending in V3
 *   9. Second-pass V3 auto-claim forwarding (promo included)
 *  10. withdrawAll recovery sweep
 *  11. End-to-end V2 → V3 migration
 *
 * Story 025 (audit-07 M-01) adds non-reverting reward forwarding:
 *
 *  12. Failed-forward banking: blocked stable/promo recipients bank into
 *      `unclaimable`, emit RewardForwardFailed, and the cursor always advances
 *  13. claimUnclaimable pull path (made whole after unblock; nothing-to-claim and
 *      still-blocked negatives)
 *  14. withdrawAll promo sweep + full sweep of banked `unclaimable` amounts
 *      (last-ditch trade-off: subsequent claims are unbacked)
 *  15. Audit M-01 scenario regression: frozen middle user no longer bricks the pass
 */
contract MigratorV2V3Test is Test {
    // Re-declare events for expectEmit
    event Seeded(uint256 userCount);
    event UserMigrated(
        address indexed user,
        uint256 principal,
        uint256 phUSDRewards,
        uint256 stableRewards,
        uint256 promoRewards
    );
    event MigrateProgress(int256 iterator, uint256 userCount);
    event RewardForwardFailed(address indexed token, address indexed user, uint256 amount);
    event UnclaimableClaimed(address indexed token, address indexed user, uint256 amount);
    event WithdrawnAll(
        address indexed owner, uint256 phUSDAmount, uint256 rewardAmount, uint256 promoAmount
    );

    PhlimboV2 public phlimboV2;
    PhlimboV3 public phlimboV3;
    MockFlax public phUSD;
    MockStable public stable;
    MockStable public promoTok;
    MigratorV2V3 public migrator;

    address public owner = address(this);
    address public alice = address(0xA1);
    address public bob = address(0xB0);
    address public carol = address(0xC0);
    address public dave = address(0xDA);
    address public eve = address(0xE5);
    address public frank = address(0xF0); // pre-existing direct V3 staker
    address public rewardDonor = address(0xD03301);

    uint256 constant DEPLETION_DURATION = 604800; // 1 week
    uint256 constant PROMO_DURATION = 1_000_000;
    uint256 constant PROMO_AMOUNT = 1000 ether;
    uint256 constant STABLE_REWARD_POOL = 10_000 ether;

    uint256[5] public depositFixtures = [
        uint256(100 ether),
        uint256(250 ether),
        uint256(75 ether),
        uint256(500 ether),
        uint256(180 ether)
    ];

    function setUp() public {
        phUSD = new MockFlax();
        stable = new MockStable();
        promoTok = new MockStable();

        phlimboV2 = new PhlimboV2(address(phUSD), address(stable), DEPLETION_DURATION);
        phlimboV3 = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);

        migrator = new MigratorV2V3(
            address(phlimboV2),
            address(phlimboV3),
            address(phUSD),
            address(stable)
        );

        // Wiring prerequisites (staging-script actions in production):
        phlimboV2.setMigrator(address(migrator));
        phlimboV3.setMigrator(address(migrator));

        // Non-zero V2 phUSD APY so phUSD rewards accrue (two-step: preview, commit).
        phlimboV2.setDesiredAPY(500);
        phlimboV2.setDesiredAPY(500);
    }

    // ---------- helpers ----------

    function _fiveUsers() internal view returns (address[] memory users) {
        users = new address[](5);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        users[3] = dave;
        users[4] = eve;
    }

    function _oneUser(address u) internal pure returns (address[] memory users) {
        users = new address[](1);
        users[0] = u;
    }

    function _stakeInV2(address user, uint256 amount) internal {
        phUSD.mint(user, amount);
        vm.startPrank(user);
        phUSD.approve(address(phlimboV2), type(uint256).max);
        phlimboV2.stake(amount, user);
        vm.stopPrank();
    }

    function _stakeFiveInV2() internal {
        address[] memory u = _fiveUsers();
        for (uint256 i = 0; i < 5; i++) {
            _stakeInV2(u[i], depositFixtures[i]);
        }
    }

    function _fundV2StableRewards() internal {
        stable.mint(rewardDonor, STABLE_REWARD_POOL);
        vm.startPrank(rewardDonor);
        stable.approve(address(phlimboV2), type(uint256).max);
        phlimboV2.collectReward(STABLE_REWARD_POOL);
        vm.stopPrank();
    }

    /// @dev Frank stakes directly into V3, then the owner starts a promotion.
    function _startV3PromotionWithFrank() internal {
        phUSD.mint(frank, 100 ether);
        vm.startPrank(frank);
        phUSD.approve(address(phlimboV3), type(uint256).max);
        phlimboV3.stake(100 ether, frank);
        vm.stopPrank();

        promoTok.mint(owner, PROMO_AMOUNT);
        promoTok.approve(address(phlimboV3), PROMO_AMOUNT);
        phlimboV3.startPromotion(address(promoTok), PROMO_AMOUNT, PROMO_DURATION);
    }

    function _v2Amount(address user) internal view returns (uint256 amount) {
        (amount,,) = phlimboV2.userInfo(user);
    }

    function _v3Amount(address user) internal view returns (uint256 amount) {
        (amount,,,) = phlimboV3.userInfo(user);
    }

    // ============================================================
    // 1. CONSTRUCTOR
    // ============================================================

    function test_constructor_rejects_zero_phlimboV2() public {
        vm.expectRevert("Invalid phlimboV2 address");
        new MigratorV2V3(address(0), address(phlimboV3), address(phUSD), address(stable));
    }

    function test_constructor_rejects_zero_phlimboV3() public {
        vm.expectRevert("Invalid phlimboV3 address");
        new MigratorV2V3(address(phlimboV2), address(0), address(phUSD), address(stable));
    }

    function test_constructor_rejects_zero_phUSD() public {
        vm.expectRevert("Invalid phUSD address");
        new MigratorV2V3(address(phlimboV2), address(phlimboV3), address(0), address(stable));
    }

    function test_constructor_rejects_zero_rewardToken() public {
        vm.expectRevert("Invalid reward token address");
        new MigratorV2V3(address(phlimboV2), address(phlimboV3), address(phUSD), address(0));
    }

    function test_constructor_initial_state() public {
        MigratorV2V3 m = new MigratorV2V3(
            address(phlimboV2), address(phlimboV3), address(phUSD), address(stable)
        );
        assertEq(m.seeded(), false, "seeded false");
        assertEq(m.migrateIterator(), 0, "migrateIterator 0");
        assertEq(m.userCount(), 0, "userCount 0");
        assertEq(address(m.phlimboV2()), address(phlimboV2));
        assertEq(address(m.phlimboV3()), address(phlimboV3));
        assertEq(address(m.phUSD()), address(phUSD));
        assertEq(address(m.rewardToken()), address(stable));
    }

    // ============================================================
    // 2. seedUsers
    // ============================================================

    function test_seed_non_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        migrator.seedUsers(_fiveUsers());
    }

    function test_seed_empty_users_reverts() public {
        address[] memory u = new address[](0);
        vm.expectRevert("Empty users");
        migrator.seedUsers(u);
    }

    function test_seed_happy_stores_users_and_emits() public {
        address[] memory u = _fiveUsers();

        vm.expectEmit(false, false, false, true);
        emit Seeded(5);
        migrator.seedUsers(u);

        assertEq(migrator.userCount(), 5);
        assertEq(migrator.seeded(), true);
        assertEq(migrator.migrateIterator(), 0);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(migrator.users(i), u[i], "users[i]");
        }
    }

    function test_seed_mid_pass_reverts() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());

        // Immediately after seeding: pass in progress (iterator == 0, not -1).
        vm.expectRevert("Pass in progress");
        migrator.seedUsers(_fiveUsers());

        // Partially through the pass: still forbidden.
        migrator.migrate(2);
        assertEq(migrator.migrateIterator(), int256(2));
        vm.expectRevert("Pass in progress");
        migrator.seedUsers(_fiveUsers());
    }

    function test_seed_after_complete_pass_resets_list_and_iterator() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());
        migrator.migrate(10);
        assertEq(migrator.migrateIterator(), int256(-1), "first pass complete");

        vm.expectEmit(false, false, false, true);
        emit Seeded(1);
        migrator.seedUsers(_oneUser(frank));

        assertEq(migrator.userCount(), 1, "list replaced");
        assertEq(migrator.users(0), frank);
        assertEq(migrator.migrateIterator(), 0, "iterator reset");
        assertEq(migrator.seeded(), true);
    }

    // ============================================================
    // 3. migrate — guards
    // ============================================================

    function test_migrate_before_seed_reverts() public {
        vm.expectRevert("Not seeded");
        migrator.migrate(10);
    }

    function test_migrate_zero_maxIterations_reverts() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());
        vm.expectRevert("maxIterations==0");
        migrator.migrate(0);
    }

    function test_migrate_after_complete_reverts() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());
        migrator.migrate(10);
        assertEq(migrator.migrateIterator(), int256(-1));

        vm.expectRevert("Migration complete");
        migrator.migrate(1);
    }

    function test_migrate_reverts_when_v3_migrator_not_wired() public {
        PhlimboV2 freshV2 = new PhlimboV2(address(phUSD), address(stable), DEPLETION_DURATION);
        PhlimboV3 freshV3 = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        MigratorV2V3 freshMigrator = new MigratorV2V3(
            address(freshV2), address(freshV3), address(phUSD), address(stable)
        );
        freshV2.setMigrator(address(freshMigrator));
        // NOTE: deliberately do NOT call freshV3.setMigrator(...)

        phUSD.mint(alice, 100 ether);
        vm.startPrank(alice);
        phUSD.approve(address(freshV2), type(uint256).max);
        freshV2.stake(100 ether, alice);
        vm.stopPrank();

        freshMigrator.seedUsers(_oneUser(alice));
        vm.expectRevert("Not authorized");
        freshMigrator.migrate(1);
    }

    function test_migrate_reverts_when_v2_migrator_not_wired() public {
        PhlimboV2 freshV2 = new PhlimboV2(address(phUSD), address(stable), DEPLETION_DURATION);
        PhlimboV3 freshV3 = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        MigratorV2V3 freshMigrator = new MigratorV2V3(
            address(freshV2), address(freshV3), address(phUSD), address(stable)
        );
        freshV3.setMigrator(address(freshMigrator));
        // NOTE: deliberately do NOT call freshV2.setMigrator(...)

        phUSD.mint(alice, 100 ether);
        vm.startPrank(alice);
        phUSD.approve(address(freshV2), type(uint256).max);
        freshV2.stake(100 ether, alice);
        vm.stopPrank();

        freshMigrator.seedUsers(_oneUser(alice));
        vm.expectRevert("Not authorized");
        freshMigrator.migrate(1);
    }

    // ============================================================
    // 4. migrate — iterator across multiple calls
    // ============================================================

    function test_migrate_iterator_chunked() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());
        address[] memory u = _fiveUsers();

        // No time has passed since staking → zero rewards, deterministic event.
        vm.expectEmit(true, false, false, true);
        emit UserMigrated(alice, depositFixtures[0], 0, 0, 0);
        vm.expectEmit(false, false, false, true);
        emit MigrateProgress(int256(2), 5);
        migrator.migrate(2);

        assertEq(migrator.migrateIterator(), int256(2));
        assertEq(_v3Amount(u[0]), depositFixtures[0], "alice in V3");
        assertEq(_v3Amount(u[1]), depositFixtures[1], "bob in V3");
        assertEq(_v3Amount(u[2]), 0, "carol not yet");
        assertEq(_v2Amount(u[0]), 0, "alice out of V2");
        assertEq(_v2Amount(u[1]), 0, "bob out of V2");
        assertEq(_v2Amount(u[2]), depositFixtures[2], "carol still in V2");

        migrator.migrate(2);
        assertEq(migrator.migrateIterator(), int256(4));

        vm.expectEmit(false, false, false, true);
        emit MigrateProgress(int256(-1), 5);
        migrator.migrate(2);
        assertEq(migrator.migrateIterator(), int256(-1));

        for (uint256 i = 0; i < 5; i++) {
            assertEq(_v3Amount(u[i]), depositFixtures[i], "all migrated to V3");
            assertEq(_v2Amount(u[i]), 0, "all out of V2");
        }

        vm.expectRevert("Migration complete");
        migrator.migrate(1);
    }

    // ============================================================
    // 5. Live-read robustness
    // ============================================================

    function test_migrate_skips_user_who_fully_exited_v2() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());

        // Bob fully exits V2 after seeding, before his index is processed.
        vm.prank(bob);
        phlimboV2.withdraw(depositFixtures[1], bob);
        assertEq(_v2Amount(bob), 0);
        uint256 bobWalletBefore = phUSD.balanceOf(bob);

        // No revert; bob is skipped (live amount == 0); everyone else migrates.
        migrator.migrate(10);
        assertEq(migrator.migrateIterator(), int256(-1));

        assertEq(_v3Amount(bob), 0, "bob not in V3");
        assertEq(phUSD.balanceOf(bob), bobWalletBefore, "bob's wallet untouched");
        assertEq(_v3Amount(alice), depositFixtures[0]);
        assertEq(_v3Amount(carol), depositFixtures[2]);
        assertEq(_v3Amount(dave), depositFixtures[3]);
        assertEq(_v3Amount(eve), depositFixtures[4]);
    }

    function test_migrate_partial_v2_withdraw_migrates_reduced_amount() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());

        // Bob withdraws 100 of his 250 after seeding — live read must migrate 150.
        vm.prank(bob);
        phlimboV2.withdraw(100 ether, bob);
        assertEq(_v2Amount(bob), 150 ether);

        migrator.migrate(10);

        assertEq(_v3Amount(bob), 150 ether, "reduced live amount migrated");
        assertEq(_v2Amount(bob), 0, "bob fully out of V2");
        // No over-migration: total V3 stake equals sum of live amounts.
        assertEq(
            phlimboV3.totalStaked(),
            depositFixtures[0] + 150 ether + depositFixtures[2] + depositFixtures[3] + depositFixtures[4]
        );
    }

    // ============================================================
    // 6. Straggler second pass
    // ============================================================

    function test_straggler_second_pass_picks_up_restaker() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());
        migrator.migrate(10);
        assertEq(migrator.migrateIterator(), int256(-1));

        // Bob stakes MORE into V2 after his index was processed → remains in V2.
        _stakeInV2(bob, 50 ether);
        assertEq(_v2Amount(bob), 50 ether, "straggler remains in V2");
        assertEq(_v3Amount(bob), depositFixtures[1], "first-pass stake in V3");

        // Second seeded pass picks him up.
        migrator.seedUsers(_oneUser(bob));
        migrator.migrate(10);
        assertEq(migrator.migrateIterator(), int256(-1), "second pass complete");

        assertEq(_v2Amount(bob), 0, "straggler out of V2");
        assertEq(_v3Amount(bob), depositFixtures[1] + 50 ether, "V3 position topped up");
    }

    // ============================================================
    // 7. Reward-delta forwarding exactness
    // ============================================================

    function test_reward_delta_forwarding_exactness() public {
        _stakeFiveInV2();
        _fundV2StableRewards();
        vm.warp(block.timestamp + DEPLETION_DURATION / 2);

        address[] memory u = _fiveUsers();
        migrator.seedUsers(u);

        // Snapshot live pendings at migration time (same timestamp as migrate).
        uint256[] memory pendPhUSD = new uint256[](5);
        uint256[] memory pendStable = new uint256[](5);
        uint256[] memory phusdBefore = new uint256[](5);
        uint256[] memory stableBefore = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            pendPhUSD[i] = phlimboV2.pendingPhUSD(u[i]);
            pendStable[i] = phlimboV2.pendingStable(u[i]);
            assertGt(pendPhUSD[i], 0, "phUSD accrued");
            assertGt(pendStable[i], 0, "stable accrued");
            phusdBefore[i] = phUSD.balanceOf(u[i]);
            stableBefore[i] = stable.balanceOf(u[i]);
        }

        migrator.migrate(10);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                phUSD.balanceOf(u[i]) - phusdBefore[i],
                pendPhUSD[i],
                "exact phUSD rewards forwarded"
            );
            assertEq(
                stable.balanceOf(u[i]) - stableBefore[i],
                pendStable[i],
                "exact stable rewards forwarded"
            );
            assertEq(_v3Amount(u[i]), depositFixtures[i], "principal lands in V3");
        }

        // Nothing sticks to the migrator.
        assertEq(phUSD.balanceOf(address(migrator)), 0, "migrator holds no phUSD");
        assertEq(stable.balanceOf(address(migrator)), 0, "migrator holds no stable");
    }

    // ============================================================
    // 8. Migrated user starts with zero promo pending
    // ============================================================

    function test_migrated_user_has_zero_promo_pending() public {
        _stakeFiveInV2();
        _startV3PromotionWithFrank();

        // Promo accrues to frank (the only V3 staker) for a day before migration.
        vm.warp(block.timestamp + 1 days);
        assertGt(phlimboV3.pendingPromo(frank), 0, "promo accrued pre-migration");

        migrator.seedUsers(_oneUser(alice));
        migrator.migrate(1);

        // Alice's promoDebt was set against the current accPromoPerShare:
        // no retroactive promo accrual.
        assertEq(_v3Amount(alice), depositFixtures[0], "alice staked in V3");
        assertEq(phlimboV3.pendingPromo(alice), 0, "zero promo pending post-stake");
        assertGt(phlimboV3.pendingPromo(frank), 0, "frank's accrual untouched");

        // Promo accrues for alice only from now on.
        vm.warp(block.timestamp + 1 days);
        assertGt(phlimboV3.pendingPromo(alice), 0, "accrues from migration onward");
    }

    // ============================================================
    // 9. Second-pass V3 auto-claim forwarding (incl. promo)
    // ============================================================

    function test_second_pass_forwards_v3_autoclaimed_promo_to_user() public {
        _stakeFiveInV2();
        _startV3PromotionWithFrank();

        // First pass migrates everyone into V3 during the active promotion.
        migrator.seedUsers(_fiveUsers());
        migrator.migrate(10);

        // Promo accrues to bob's V3 position; meanwhile bob re-stakes into V2.
        vm.warp(block.timestamp + 1 days);
        _stakeInV2(bob, 50 ether);

        uint256 bobPendingPromo = phlimboV3.pendingPromo(bob);
        assertGt(bobPendingPromo, 0, "bob accrued promo in V3");
        uint256 bobPromoBefore = promoTok.balanceOf(bob);

        // Second pass: v3.stake auto-claims bob's V3 promo to the migrator, which
        // must forward it to bob rather than strand it.
        migrator.seedUsers(_oneUser(bob));
        migrator.migrate(1);

        assertEq(
            promoTok.balanceOf(bob) - bobPromoBefore,
            bobPendingPromo,
            "V3 auto-claimed promo forwarded to bob"
        );
        assertEq(promoTok.balanceOf(address(migrator)), 0, "no promo stranded");
        assertEq(_v3Amount(bob), depositFixtures[1] + 50 ether);
    }

    // ============================================================
    // 10. withdrawAll recovery sweep
    // ============================================================

    function test_withdrawAll_non_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        migrator.withdrawAll();
    }

    function test_withdrawAll_sweeps_stranded_balances() public {
        // Simulate stranded balances (e.g. tokens sent directly to the migrator).
        phUSD.mint(address(migrator), 100 ether);
        stable.mint(address(migrator), 50 ether);

        uint256 ownerPhusdBefore = phUSD.balanceOf(owner);
        uint256 ownerStableBefore = stable.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnAll(owner, 100 ether, 50 ether, 0);
        migrator.withdrawAll();

        assertEq(phUSD.balanceOf(address(migrator)), 0);
        assertEq(stable.balanceOf(address(migrator)), 0);
        assertEq(phUSD.balanceOf(owner) - ownerPhusdBefore, 100 ether);
        assertEq(stable.balanceOf(owner) - ownerStableBefore, 50 ether);
    }

    function test_withdrawAll_does_not_touch_iterator_or_seed() public {
        _stakeFiveInV2();
        migrator.seedUsers(_fiveUsers());
        migrator.migrate(2);

        phUSD.mint(address(migrator), 1 ether);
        migrator.withdrawAll();

        // Live reads mean withdrawAll is a pure recovery sweep — the pass resumes.
        assertEq(migrator.migrateIterator(), int256(2), "iterator untouched");
        assertEq(migrator.seeded(), true, "seed untouched");
        migrator.migrate(10);
        assertEq(migrator.migrateIterator(), int256(-1), "pass completes after sweep");
    }

    function test_withdrawAll_handles_zero_balances() public {
        vm.expectEmit(true, false, false, true);
        emit WithdrawnAll(owner, 0, 0, 0);
        migrator.withdrawAll();
    }

    // ============================================================
    // 11. End-to-end V2 → V3 migration
    // ============================================================

    function test_end_to_end_v2_to_v3_migration() public {
        // ---- Stage 1: V2 population with accrued stable + phUSD rewards ----
        _stakeFiveInV2();
        _fundV2StableRewards();

        // ---- Stage 2: first promotion begins on V3 (frank already staked) ----
        _startV3PromotionWithFrank();

        // ---- Stage 3: time passes; both farms accrue ----
        vm.warp(block.timestamp + DEPLETION_DURATION / 2);

        address[] memory u = _fiveUsers();
        uint256[] memory pendPhUSD = new uint256[](5);
        uint256[] memory pendStable = new uint256[](5);
        uint256[] memory phusdBefore = new uint256[](5);
        uint256[] memory stableBefore = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            pendPhUSD[i] = phlimboV2.pendingPhUSD(u[i]);
            pendStable[i] = phlimboV2.pendingStable(u[i]);
            phusdBefore[i] = phUSD.balanceOf(u[i]);
            stableBefore[i] = stable.balanceOf(u[i]);
        }

        // ---- Stage 4: seed and migrate in chunks ----
        migrator.seedUsers(u);
        migrator.migrate(2);
        assertEq(migrator.migrateIterator(), int256(2));
        migrator.migrate(2);
        assertEq(migrator.migrateIterator(), int256(4));
        migrator.migrate(2);
        assertEq(migrator.migrateIterator(), int256(-1));

        // ---- Stage 5: verify terminal state ----
        for (uint256 i = 0; i < 5; i++) {
            assertEq(_v2Amount(u[i]), 0, "out of V2");
            assertEq(_v3Amount(u[i]), depositFixtures[i], "principal in V3");
            assertEq(phUSD.balanceOf(u[i]) - phusdBefore[i], pendPhUSD[i], "phUSD forwarded");
            assertEq(stable.balanceOf(u[i]) - stableBefore[i], pendStable[i], "stable forwarded");
            assertEq(phlimboV3.pendingPromo(u[i]), 0, "no retroactive promo");
        }

        assertEq(phlimboV2.totalStaked(), 0, "V2 emptied");
        assertEq(
            phlimboV3.totalStaked(),
            depositFixtures[0] + depositFixtures[1] + depositFixtures[2]
                + depositFixtures[3] + depositFixtures[4] + 100 ether,
            "V3 holds all principals plus frank"
        );
        assertEq(phUSD.balanceOf(address(migrator)), 0, "migrator drained of phUSD");
        assertEq(stable.balanceOf(address(migrator)), 0, "migrator drained of stable");
        assertGt(phlimboV3.pendingPromo(frank), 0, "frank's promo accrual intact");
    }

    // ============================================================
    // 12-15. Non-reverting reward forwarding (story 025, audit-07 M-01)
    // ============================================================

    MockBlocklistToken public blkStable;
    PhlimboV2 public blkV2;
    PhlimboV3 public blkV3;
    MigratorV2V3 public blkMigrator;

    /// @dev Fresh V2/V3/migrator stack whose STABLE reward token is a
    ///      MockBlocklistToken, with five staked users and accrued stable +
    ///      phUSD rewards (half the depletion window elapsed).
    function _setupBlocklistStableStack() internal {
        blkStable = new MockBlocklistToken();
        blkV2 = new PhlimboV2(address(phUSD), address(blkStable), DEPLETION_DURATION);
        blkV3 = new PhlimboV3(address(phUSD), address(blkStable), DEPLETION_DURATION);
        blkMigrator = new MigratorV2V3(
            address(blkV2), address(blkV3), address(phUSD), address(blkStable)
        );
        blkV2.setMigrator(address(blkMigrator));
        blkV3.setMigrator(address(blkMigrator));
        blkV2.setDesiredAPY(500);
        blkV2.setDesiredAPY(500);

        address[] memory u = _fiveUsers();
        for (uint256 i = 0; i < 5; i++) {
            phUSD.mint(u[i], depositFixtures[i]);
            vm.startPrank(u[i]);
            phUSD.approve(address(blkV2), type(uint256).max);
            blkV2.stake(depositFixtures[i], u[i]);
            vm.stopPrank();
        }

        blkStable.mint(rewardDonor, STABLE_REWARD_POOL);
        vm.startPrank(rewardDonor);
        blkStable.approve(address(blkV2), type(uint256).max);
        blkV2.collectReward(STABLE_REWARD_POOL);
        vm.stopPrank();

        vm.warp(block.timestamp + DEPLETION_DURATION / 2);
    }

    function _blkV2Amount(address user) internal view returns (uint256 amount) {
        (amount,,) = blkV2.userInfo(user);
    }

    function _blkV3Amount(address user) internal view returns (uint256 amount) {
        (amount,,,) = blkV3.userInfo(user);
    }

    /// @dev Seeds all five, banks carol's stable rewards (blocked mid-list), runs
    ///      the full pass, and returns carol's banked amount.
    function _bankCarolStable() internal returns (uint256 carolPending) {
        _setupBlocklistStableStack();
        blkMigrator.seedUsers(_fiveUsers());
        carolPending = blkV2.pendingStable(carol);
        assertGt(carolPending, 0, "carol accrued stable");
        blkStable.setBlocked(carol, true);
        blkMigrator.migrate(10);
        assertEq(
            blkMigrator.unclaimable(address(blkStable), carol), carolPending, "banked"
        );
    }

    function test_migrate_failed_stable_transfer_banks_unclaimable_and_advances() public {
        _setupBlocklistStableStack();
        address[] memory u = _fiveUsers();
        blkMigrator.seedUsers(u);

        uint256 carolPending = blkV2.pendingStable(carol);
        assertGt(carolPending, 0, "carol accrued stable");
        uint256 bobPending = blkV2.pendingStable(bob);

        blkStable.setBlocked(carol, true);

        vm.expectEmit(true, true, false, true);
        emit RewardForwardFailed(address(blkStable), carol, carolPending);
        blkMigrator.migrate(10);

        assertEq(blkMigrator.migrateIterator(), int256(-1), "cursor advanced to completion");
        assertEq(blkStable.balanceOf(carol), 0, "blocked transfer did not pay");
        assertEq(blkStable.balanceOf(bob), bobPending, "bob still paid");
        assertEq(
            blkMigrator.unclaimable(address(blkStable), carol),
            carolPending,
            "failed amount banked"
        );
        assertEq(
            blkStable.balanceOf(address(blkMigrator)),
            carolPending,
            "banked tokens held by migrator"
        );
        for (uint256 i = 0; i < 5; i++) {
            assertEq(_blkV2Amount(u[i]), 0, "everyone out of V2");
            assertEq(_blkV3Amount(u[i]), depositFixtures[i], "everyone landed in V3");
        }
    }

    function test_migrate_failed_promo_transfer_banks_and_does_not_brick() public {
        _stakeFiveInV2();

        // Promotion on V3 funded with a blocklist promo token; frank stakes direct.
        MockBlocklistToken blkPromo = new MockBlocklistToken();
        phUSD.mint(frank, 100 ether);
        vm.startPrank(frank);
        phUSD.approve(address(phlimboV3), type(uint256).max);
        phlimboV3.stake(100 ether, frank);
        vm.stopPrank();
        blkPromo.mint(owner, PROMO_AMOUNT);
        blkPromo.approve(address(phlimboV3), PROMO_AMOUNT);
        phlimboV3.startPromotion(address(blkPromo), PROMO_AMOUNT, PROMO_DURATION);

        // First pass lands everyone in V3 during the active promotion.
        migrator.seedUsers(_fiveUsers());
        migrator.migrate(10);

        // Bob accrues V3 promo, re-stakes into V2, then gets blocklisted.
        vm.warp(block.timestamp + 1 days);
        _stakeInV2(bob, 50 ether);
        uint256 bobPendingPromo = phlimboV3.pendingPromo(bob);
        assertGt(bobPendingPromo, 0, "bob accrued promo in V3");
        blkPromo.setBlocked(bob, true);

        // Second pass: V3 auto-claimed promo cannot reach bob → banked, not bricked.
        migrator.seedUsers(_oneUser(bob));
        vm.expectEmit(true, true, false, true);
        emit RewardForwardFailed(address(blkPromo), bob, bobPendingPromo);
        migrator.migrate(1);

        assertEq(migrator.migrateIterator(), int256(-1), "pass completed");
        assertEq(blkPromo.balanceOf(bob), 0, "blocked promo not paid");
        assertEq(
            migrator.unclaimable(address(blkPromo), bob), bobPendingPromo, "promo banked"
        );
        assertEq(
            blkPromo.balanceOf(address(migrator)),
            bobPendingPromo,
            "banked promo held by migrator"
        );
        assertEq(_v3Amount(bob), depositFixtures[1] + 50 ether, "principal restaked");
    }

    function test_claimUnclaimable_after_unblock_makes_user_whole() public {
        uint256 carolPending = _bankCarolStable();

        blkStable.setBlocked(carol, false);

        vm.expectEmit(true, true, false, true);
        emit UnclaimableClaimed(address(blkStable), carol, carolPending);
        vm.prank(carol);
        blkMigrator.claimUnclaimable(address(blkStable));

        assertEq(blkStable.balanceOf(carol), carolPending, "made whole");
        assertEq(blkMigrator.unclaimable(address(blkStable), carol), 0, "entry zeroed");

        // Entry zeroed → a second pull reverts.
        vm.prank(carol);
        vm.expectRevert("Nothing to claim");
        blkMigrator.claimUnclaimable(address(blkStable));
    }

    function test_claimUnclaimable_nothing_to_claim_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        migrator.claimUnclaimable(address(stable));
    }

    function test_claimUnclaimable_while_still_blocked_reverts() public {
        uint256 carolPending = _bankCarolStable();

        // Still blocked: the user-initiated pull deliberately reverts.
        vm.prank(carol);
        vm.expectRevert("recipient blocked");
        blkMigrator.claimUnclaimable(address(blkStable));

        assertEq(
            blkMigrator.unclaimable(address(blkStable), carol),
            carolPending,
            "entry preserved on revert"
        );
    }

    function test_withdrawAll_sweeps_promo_when_promotion_active() public {
        _startV3PromotionWithFrank();

        phUSD.mint(address(migrator), 100 ether);
        stable.mint(address(migrator), 50 ether);
        promoTok.mint(address(migrator), 25 ether);

        uint256 ownerPromoBefore = promoTok.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnAll(owner, 100 ether, 50 ether, 25 ether);
        migrator.withdrawAll();

        assertEq(promoTok.balanceOf(address(migrator)), 0, "promo swept");
        assertEq(promoTok.balanceOf(owner) - ownerPromoBefore, 25 ether, "owner got promo");
    }

    function test_withdrawAll_sweeps_banked_unclaimable_and_claim_reverts() public {
        uint256 carolPending = _bankCarolStable();

        uint256 migratorBal = blkStable.balanceOf(address(blkMigrator));
        assertGe(migratorBal, carolPending, "banked tokens still in contract");
        uint256 ownerBefore = blkStable.balanceOf(owner);

        // Last-ditch hatch: FULL sweep, including carol's banked amount.
        blkMigrator.withdrawAll();

        assertEq(blkStable.balanceOf(address(blkMigrator)), 0, "everything swept");
        assertEq(
            blkStable.balanceOf(owner) - ownerBefore,
            migratorBal,
            "owner received full balance incl. banked"
        );
        assertEq(
            blkMigrator.unclaimable(address(blkStable), carol),
            carolPending,
            "entry persists but is now unbacked"
        );

        // Even unblocked, the claim reverts for want of balance — the accepted
        // trade-off; reimbursement becomes an out-of-band owner obligation.
        blkStable.setBlocked(carol, false);
        vm.prank(carol);
        vm.expectRevert();
        blkMigrator.claimUnclaimable(address(blkStable));
    }

    function test_audit_m01_frozen_middle_user_does_not_brick_pass() public {
        _setupBlocklistStableStack();
        address[] memory u = _fiveUsers();
        blkMigrator.seedUsers(u);

        // Carol (index 2, mid-list) is frozen by the stable token's blocklist.
        blkStable.setBlocked(carol, true);

        // Chunked exactly as an operator would drive it: pre-fix, the chunk
        // containing carol reverted forever and pinned the cursor at 2.
        blkMigrator.migrate(2);
        assertEq(blkMigrator.migrateIterator(), int256(2));
        blkMigrator.migrate(2);
        assertEq(blkMigrator.migrateIterator(), int256(4), "cursor stepped past frozen carol");
        blkMigrator.migrate(2);
        assertEq(blkMigrator.migrateIterator(), int256(-1), "pass completed");

        for (uint256 i = 0; i < 5; i++) {
            assertEq(_blkV2Amount(u[i]), 0, "all out of V2");
            assertEq(_blkV3Amount(u[i]), depositFixtures[i], "all landed in V3");
        }
        assertGt(
            blkMigrator.unclaimable(address(blkStable), carol),
            0,
            "carol's stable rewards banked, not lost"
        );
    }
}
