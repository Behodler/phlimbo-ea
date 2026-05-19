// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MigratorV1V2.sol";
import "../src/PhlimboV2.sol";
import "../src/Phlimbo.sol";
import "../src/interfaces/IMigratorV1V2.sol";
import "./Mocks.sol";

/**
 * @title MigratorV1V2Test
 * @notice Full coverage for MigratorV1V2 per story 021 Test Plan.
 *
 * Test ordering mirrors the Test Plan in the story:
 *   1. Constructor
 *   2. seedObligations
 *   3. withdrawAll
 *   4. settleDebt balance preconditions
 *   5. settleDebt happy path
 *   6. settleDebt iterator across multiple calls
 *   7. settleDebt invariant across chunks
 *   8. migrateDeposits balance preconditions
 *   9. migrateDeposits requires V2 migrator wiring
 *  10. migrateDeposits happy path
 *  11. migrateDeposits iterator across multiple calls
 *  12. End-to-end migration scenario
 *  13. withdrawAll mid-flight
 */
contract MigratorV1V2Test is Test {
    // Re-declare events for expectEmit
    event Seeded(
        uint256 userCount,
        uint256 totalUSDC,
        uint256 totalPHUSD_deposited,
        uint256 totalPHUSD_pending
    );
    event SettleProgress(int256 iterator, uint256 remainingUSDC, uint256 remainingPHUSDPending);
    event MigrateProgress(int256 iterator, uint256 remainingDepositPHUSD);
    event WithdrawnAll(address indexed owner, uint256 usdcAmount, uint256 phUSDAmount);

    PhlimboV2 public phlimboV2;
    MockFlax public phUSD;
    MockStable public usdc;
    MigratorV1V2 public migrator;

    address public owner = address(this);
    address public alice = address(0xA1);
    address public bob = address(0xB0);
    address public carol = address(0xC0);
    address public dave = address(0xDA);
    address public eve = address(0xE5);

    uint256 constant DEPLETION_DURATION = 604800; // 1 week

    // Per-user fixtures used across most tests. Designed so two of the entries
    // exercise the skip-on-zero branch (alice has usdc=0; eve has phUSD=0).
    uint256[5] public depositFixtures = [
        uint256(100 ether),
        uint256(250 ether),
        uint256(75 ether),
        uint256(500 ether),
        uint256(180 ether)
    ];
    uint256[5] public usdcFixtures = [
        uint256(0),         // alice — skips USDC transfer
        uint256(30e6),
        uint256(12e6),
        uint256(80e6),
        uint256(5e6)
    ];
    uint256[5] public phUSDFixtures = [
        uint256(4 ether),
        uint256(8 ether),
        uint256(2 ether),
        uint256(10 ether),
        uint256(0)          // eve — skips phUSD mint
    ];

    function setUp() public {
        phUSD = new MockFlax();
        usdc = new MockStable();

        phlimboV2 = new PhlimboV2(address(phUSD), address(usdc), DEPLETION_DURATION);

        migrator = new MigratorV1V2(address(usdc), address(phUSD), address(phlimboV2));

        // Wire V2 migrator role to the migrator contract. Most tests need this;
        // the one that asserts the negative path will simply not call setMigrator
        // by deploying its own un-wired V2 inside the test body.
        phlimboV2.setMigrator(address(migrator));

        // Authorize migrator to mint phUSD (MockFlax allows anyone to mint, but we
        // still flip the flag so authorizedMinters() returns the expected info).
        phUSD.setMinter(address(migrator), true);
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

    function _arr5(uint256[5] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) out[i] = a[i];
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < a.length; i++) s += a[i];
    }

    function _seedFiveUsers() internal returns (uint256 totalUSDC, uint256 totalDep, uint256 totalPending) {
        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = _arr5(phUSDFixtures);

        migrator.seedObligations(u, d, c, p);

        totalUSDC = _sum(c);
        totalDep = _sum(d);
        totalPending = _sum(p);
    }

    function _fundMigratorExact(uint256 totalUSDC, uint256 totalDep) internal {
        usdc.mint(address(migrator), totalUSDC);
        phUSD.mint(address(migrator), totalDep);
    }

    // ============================================================
    // 1. CONSTRUCTOR
    // ============================================================

    function test_constructor_rejects_zero_usdc() public {
        vm.expectRevert("Invalid USDC address");
        new MigratorV1V2(address(0), address(phUSD), address(phlimboV2));
    }

    function test_constructor_rejects_zero_phUSD() public {
        vm.expectRevert("Invalid phUSD address");
        new MigratorV1V2(address(usdc), address(0), address(phlimboV2));
    }

    function test_constructor_rejects_zero_phlimboV2() public {
        vm.expectRevert("Invalid phlimboV2 address");
        new MigratorV1V2(address(usdc), address(phUSD), address(0));
    }

    function test_constructor_initial_state() public {
        MigratorV1V2 m = new MigratorV1V2(address(usdc), address(phUSD), address(phlimboV2));
        assertEq(m.seeded(), false, "seeded false");
        assertEq(m.settleIterator(), 0, "settleIterator 0");
        assertEq(m.migrateIterator(), 0, "migrateIterator 0");
        assertEq(m.totalUSDC(), 0, "totalUSDC 0");
        assertEq(m.totalPHUSD_deposited(), 0, "totalDep 0");
        assertEq(m.totalPHUSD_pending(), 0, "totalPending 0");
        assertEq(address(m.usdc()), address(usdc));
        assertEq(address(m.phUSD()), address(phUSD));
        assertEq(address(m.phlimboV2()), address(phlimboV2));
    }

    // ============================================================
    // 2. seedObligations
    // ============================================================

    function test_seed_non_owner_reverts() public {
        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = _arr5(phUSDFixtures);

        vm.prank(alice);
        vm.expectRevert();
        migrator.seedObligations(u, d, c, p);
    }

    function test_seed_empty_users_reverts() public {
        address[] memory u = new address[](0);
        uint256[] memory d = new uint256[](0);
        uint256[] memory c = new uint256[](0);
        uint256[] memory p = new uint256[](0);

        vm.expectRevert("Empty users");
        migrator.seedObligations(u, d, c, p);
    }

    function test_seed_length_mismatch_deposits_reverts() public {
        address[] memory u = _fiveUsers();
        uint256[] memory d = new uint256[](4); // wrong length
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = _arr5(phUSDFixtures);

        vm.expectRevert("Length mismatch");
        migrator.seedObligations(u, d, c, p);
    }

    function test_seed_length_mismatch_usdc_reverts() public {
        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = new uint256[](4); // wrong length
        uint256[] memory p = _arr5(phUSDFixtures);

        vm.expectRevert("Length mismatch");
        migrator.seedObligations(u, d, c, p);
    }

    function test_seed_length_mismatch_phUSD_reverts() public {
        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = new uint256[](4); // wrong length

        vm.expectRevert("Length mismatch");
        migrator.seedObligations(u, d, c, p);
    }

    function test_seed_happy_stores_arrays_and_totals_and_emits() public {
        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = _arr5(phUSDFixtures);

        uint256 expectedUSDC = _sum(c);
        uint256 expectedDep = _sum(d);
        uint256 expectedPending = _sum(p);

        vm.expectEmit(false, false, false, true);
        emit Seeded(5, expectedUSDC, expectedDep, expectedPending);

        migrator.seedObligations(u, d, c, p);

        assertEq(migrator.userCount(), 5);
        assertEq(migrator.seeded(), true);
        assertEq(migrator.totalUSDC(), expectedUSDC);
        assertEq(migrator.totalPHUSD_deposited(), expectedDep);
        assertEq(migrator.totalPHUSD_pending(), expectedPending);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(migrator.users(i), u[i], "users[i]");
            assertEq(migrator.deposits(i), d[i], "deposits[i]");
            assertEq(migrator.usdcOwed(i), c[i], "usdcOwed[i]");
            assertEq(migrator.phUSDOwed(i), p[i], "phUSDOwed[i]");
        }
    }

    function test_seed_second_call_reverts() public {
        _seedFiveUsers();

        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = _arr5(phUSDFixtures);

        vm.expectRevert("Already seeded");
        migrator.seedObligations(u, d, c, p);
    }

    // ============================================================
    // 3. withdrawAll
    // ============================================================

    function test_withdrawAll_non_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        migrator.withdrawAll();
    }

    function test_withdrawAll_drains_both_tokens() public {
        usdc.mint(address(migrator), 1000e6);
        phUSD.mint(address(migrator), 500 ether);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerPhusdBefore = phUSD.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnAll(owner, 1000e6, 500 ether);
        migrator.withdrawAll();

        assertEq(usdc.balanceOf(address(migrator)), 0);
        assertEq(phUSD.balanceOf(address(migrator)), 0);
        assertEq(usdc.balanceOf(owner) - ownerUsdcBefore, 1000e6);
        assertEq(phUSD.balanceOf(owner) - ownerPhusdBefore, 500 ether);
    }

    function test_withdrawAll_handles_zero_token_side() public {
        // Only USDC funded; phUSD balance is 0
        usdc.mint(address(migrator), 1000e6);

        vm.expectEmit(true, false, false, true);
        emit WithdrawnAll(owner, 1000e6, 0);
        migrator.withdrawAll();

        assertEq(usdc.balanceOf(address(migrator)), 0);
        assertEq(phUSD.balanceOf(address(migrator)), 0);
    }

    // ============================================================
    // 4. settleDebt — balance preconditions
    // ============================================================

    function test_settleDebt_before_seeding_reverts() public {
        vm.expectRevert("Not seeded");
        migrator.settleDebt(10);
    }

    function test_settleDebt_usdc_mismatch_reverts() public {
        (uint256 totalUSDC, uint256 totalDep,) = _seedFiveUsers();
        // Fund phUSD correctly but USDC short
        phUSD.mint(address(migrator), totalDep);
        usdc.mint(address(migrator), totalUSDC - 1);

        vm.expectRevert("USDC balance mismatch");
        migrator.settleDebt(10);
    }

    function test_settleDebt_phUSD_mismatch_reverts() public {
        (uint256 totalUSDC, uint256 totalDep,) = _seedFiveUsers();
        // Fund USDC correctly but phUSD short
        usdc.mint(address(migrator), totalUSDC);
        phUSD.mint(address(migrator), totalDep - 1);

        vm.expectRevert("phUSD balance mismatch");
        migrator.settleDebt(10);
    }

    // ============================================================
    // 5. settleDebt — happy path single call
    // ============================================================

    function test_settleDebt_happy_full_sweep() public {
        (uint256 totalUSDC, uint256 totalDep, uint256 totalPending) = _seedFiveUsers();
        _fundMigratorExact(totalUSDC, totalDep);

        // Pre-call: capture user balances to detect deltas
        address[] memory u = _fiveUsers();
        uint256[] memory usdcBefore = new uint256[](5);
        uint256[] memory phusdBefore = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            usdcBefore[i] = usdc.balanceOf(u[i]);
            phusdBefore[i] = phUSD.balanceOf(u[i]);
        }

        // Expect final event with iterator=-1, remaining USDC=0, remaining phUSD_pending=0
        vm.expectEmit(false, false, false, true);
        emit SettleProgress(int256(-1), 0, 0);
        migrator.settleDebt(10);

        // Each user received their owed USDC (skip-on-zero for alice)
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                usdc.balanceOf(u[i]) - usdcBefore[i],
                usdcFixtures[i],
                "user USDC delta"
            );
            assertEq(
                phUSD.balanceOf(u[i]) - phusdBefore[i],
                phUSDFixtures[i],
                "user phUSD delta"
            );
        }

        assertEq(migrator.totalUSDC(), 0, "totalUSDC drained");
        assertEq(migrator.totalPHUSD_pending(), 0, "totalPending drained");
        // totalPHUSD_deposited is unchanged by settlement
        assertEq(migrator.totalPHUSD_deposited(), totalDep, "deposit total untouched");
        assertEq(migrator.settleIterator(), int256(-1), "iterator finished");
    }

    // ============================================================
    // 6. settleDebt — iterator across multiple calls
    // ============================================================

    function test_settleDebt_iterator_chunked() public {
        (uint256 totalUSDC, uint256 totalDep,) = _seedFiveUsers();
        _fundMigratorExact(totalUSDC, totalDep);

        address[] memory u = _fiveUsers();

        // --- chunk 1: process users[0], users[1] ---
        migrator.settleDebt(2);
        assertEq(migrator.settleIterator(), int256(2), "iter==2");
        // alice and bob got their USDC/phUSD
        assertEq(usdc.balanceOf(u[0]), usdcFixtures[0]);
        assertEq(usdc.balanceOf(u[1]), usdcFixtures[1]);
        assertEq(phUSD.balanceOf(u[0]), phUSDFixtures[0]);
        assertEq(phUSD.balanceOf(u[1]), phUSDFixtures[1]);
        // carol, dave, eve untouched
        assertEq(usdc.balanceOf(u[2]), 0);
        assertEq(usdc.balanceOf(u[3]), 0);
        assertEq(usdc.balanceOf(u[4]), 0);
        assertEq(phUSD.balanceOf(u[2]), 0);
        assertEq(phUSD.balanceOf(u[3]), 0);
        assertEq(phUSD.balanceOf(u[4]), 0);

        // Totals decremented by alice+bob
        assertEq(migrator.totalUSDC(), totalUSDC - usdcFixtures[0] - usdcFixtures[1]);
        assertEq(
            migrator.totalPHUSD_pending(),
            (phUSDFixtures[0] + phUSDFixtures[1] + phUSDFixtures[2] + phUSDFixtures[3] + phUSDFixtures[4])
                - phUSDFixtures[0] - phUSDFixtures[1]
        );

        // --- chunk 2: users[2], users[3] ---
        migrator.settleDebt(2);
        assertEq(migrator.settleIterator(), int256(4), "iter==4");

        // --- chunk 3: users[4] (only one left, maxIterations=2 OK) ---
        migrator.settleDebt(2);
        assertEq(migrator.settleIterator(), int256(-1), "iter==-1");
        assertEq(migrator.totalUSDC(), 0);
        assertEq(migrator.totalPHUSD_pending(), 0);

        // --- post-completion call reverts ---
        vm.expectRevert("Settlement complete");
        migrator.settleDebt(1);
    }

    // ============================================================
    // 7. settleDebt — invariant across chunks
    // ============================================================

    function test_settleDebt_invariant_across_chunks() public {
        (uint256 totalUSDC, uint256 totalDep,) = _seedFiveUsers();
        _fundMigratorExact(totalUSDC, totalDep);

        // Invariant must hold immediately before every call.
        assertEq(usdc.balanceOf(address(migrator)), migrator.totalUSDC());
        assertEq(phUSD.balanceOf(address(migrator)), migrator.totalPHUSD_deposited());
        migrator.settleDebt(2);

        assertEq(usdc.balanceOf(address(migrator)), migrator.totalUSDC());
        assertEq(phUSD.balanceOf(address(migrator)), migrator.totalPHUSD_deposited());
        migrator.settleDebt(2);

        assertEq(usdc.balanceOf(address(migrator)), migrator.totalUSDC());
        assertEq(phUSD.balanceOf(address(migrator)), migrator.totalPHUSD_deposited());
        migrator.settleDebt(2);

        assertEq(migrator.settleIterator(), int256(-1));
        assertEq(migrator.totalUSDC(), 0);
        // phUSD migration float still held
        assertEq(phUSD.balanceOf(address(migrator)), migrator.totalPHUSD_deposited());
    }

    // ============================================================
    // 8. migrateDeposits — balance precondition
    // ============================================================

    function test_migrateDeposits_before_seeding_reverts() public {
        vm.expectRevert("Not seeded");
        migrator.migrateDeposits(10);
    }

    function test_migrateDeposits_phUSD_mismatch_reverts() public {
        (, uint256 totalDep,) = _seedFiveUsers();
        // Short fund
        phUSD.mint(address(migrator), totalDep - 1);

        vm.expectRevert("phUSD balance mismatch");
        migrator.migrateDeposits(10);
    }

    // ============================================================
    // 9. migrateDeposits — requires V2 migrator wiring
    // ============================================================

    function test_migrateDeposits_reverts_when_v2_migrator_not_wired() public {
        // Deploy a fresh V2 with no migrator role set, and a fresh migrator pointing at it.
        PhlimboV2 freshV2 = new PhlimboV2(address(phUSD), address(usdc), DEPLETION_DURATION);
        MigratorV1V2 freshMigrator = new MigratorV1V2(address(usdc), address(phUSD), address(freshV2));
        phUSD.setMinter(address(freshMigrator), true);
        // NOTE: deliberately do NOT call freshV2.setMigrator(...)

        address[] memory u = _fiveUsers();
        uint256[] memory d = _arr5(depositFixtures);
        uint256[] memory c = _arr5(usdcFixtures);
        uint256[] memory p = _arr5(phUSDFixtures);
        freshMigrator.seedObligations(u, d, c, p);

        uint256 totalDep = _sum(d);
        phUSD.mint(address(freshMigrator), totalDep);

        vm.expectRevert("Not authorized");
        freshMigrator.migrateDeposits(10);
    }

    // ============================================================
    // 10. migrateDeposits — happy path single call
    // ============================================================

    function test_migrateDeposits_happy_full_sweep() public {
        (, uint256 totalDep,) = _seedFiveUsers();
        // Migration only needs phUSD funding equal to totalPHUSD_deposited.
        phUSD.mint(address(migrator), totalDep);

        vm.expectEmit(false, false, false, true);
        emit MigrateProgress(int256(-1), 0);
        migrator.migrateDeposits(10);

        address[] memory u = _fiveUsers();
        for (uint256 i = 0; i < 5; i++) {
            (uint256 amount,,) = phlimboV2.userInfo(u[i]);
            assertEq(amount, depositFixtures[i], "v2 amount equals V1 deposit");
        }

        assertEq(phUSD.balanceOf(address(migrator)), 0, "migrator drained of phUSD");
        assertEq(migrator.totalPHUSD_deposited(), 0, "deposit total drained");
        assertEq(migrator.migrateIterator(), int256(-1), "iterator finished");
    }

    // ============================================================
    // 11. migrateDeposits — iterator across multiple calls
    // ============================================================

    function test_migrateDeposits_iterator_chunked() public {
        (, uint256 totalDep,) = _seedFiveUsers();
        phUSD.mint(address(migrator), totalDep);
        address[] memory u = _fiveUsers();

        migrator.migrateDeposits(2);
        assertEq(migrator.migrateIterator(), int256(2));
        {
            (uint256 a0,,) = phlimboV2.userInfo(u[0]);
            (uint256 a1,,) = phlimboV2.userInfo(u[1]);
            (uint256 a2,,) = phlimboV2.userInfo(u[2]);
            assertEq(a0, depositFixtures[0]);
            assertEq(a1, depositFixtures[1]);
            assertEq(a2, 0);
        }

        migrator.migrateDeposits(2);
        assertEq(migrator.migrateIterator(), int256(4));

        migrator.migrateDeposits(2);
        assertEq(migrator.migrateIterator(), int256(-1));

        vm.expectRevert("Migration complete");
        migrator.migrateDeposits(1);
    }

    // ============================================================
    // 12. End-to-end migration scenario
    // ============================================================

    function test_end_to_end_v1_to_v2_migration() public {
        // ---- Stage 1: deploy V1, have 5 users stake, accrue rewards ----
        PhlimboEA phlimboV1 = new PhlimboEA(address(phUSD), address(usdc), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimboV1), true);
        // Set a non-zero APY so phUSD rewards accrue too. Two-step API: preview, commit.
        phlimboV1.setDesiredAPY(500);
        phlimboV1.setDesiredAPY(500);

        address[] memory u = _fiveUsers();
        uint256[5] memory v1Deposits = [
            uint256(100 ether),
            uint256(250 ether),
            uint256(75 ether),
            uint256(500 ether),
            uint256(180 ether)
        ];

        for (uint256 i = 0; i < 5; i++) {
            phUSD.mint(u[i], v1Deposits[i]);
            vm.startPrank(u[i]);
            phUSD.approve(address(phlimboV1), type(uint256).max);
            phlimboV1.stake(v1Deposits[i], u[i]);
            vm.stopPrank();
        }

        // Fund the V1 reward pool so stable rewards accrue.
        address rewardDonor = address(0xD03301);
        uint256 rewardPool = 10_000e6;
        usdc.mint(rewardDonor, rewardPool);
        vm.startPrank(rewardDonor);
        usdc.approve(address(phlimboV1), type(uint256).max);
        phlimboV1.collectReward(rewardPool);
        vm.stopPrank();

        // Fast-forward to accrue rewards (half the depletion window).
        vm.warp(block.timestamp + DEPLETION_DURATION / 2);

        // ---- Stage 2: snapshot V1 state ----
        uint256[] memory snapDeposits = new uint256[](5);
        uint256[] memory snapUSDC = new uint256[](5);
        uint256[] memory snapPhUSD = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            (uint256 amount,,) = phlimboV1.userInfo(u[i]);
            snapDeposits[i] = amount;
            snapUSDC[i] = phlimboV1.pendingStable(u[i]);
            snapPhUSD[i] = phlimboV1.pendingPhUSD(u[i]);
            assertEq(snapDeposits[i], v1Deposits[i], "deposit snapshot matches");
            assertGt(snapUSDC[i], 0, "USDC accrued");
            assertGt(snapPhUSD[i], 0, "phUSD accrued");
        }

        // ---- Stage 3: deploy a fresh migrator pointed at this V2, seed it ----
        // Use the migrator from setUp() (already wired to phlimboV2 with mint
        // privileges and migrator role).
        migrator.seedObligations(u, snapDeposits, snapUSDC, snapPhUSD);

        uint256 totalUSDC = _sum(snapUSDC);
        uint256 totalDep = _sum(snapDeposits);

        // ---- Stage 4: fund migrator with USDC and phUSD ----
        usdc.mint(address(migrator), totalUSDC);
        phUSD.mint(address(migrator), totalDep);

        // Snapshot user wallet balances pre-settle (each user already holds
        // V1-staked phUSD in V1, none in wallet; usdc=0).
        uint256[] memory usdcBefore = new uint256[](5);
        uint256[] memory phusdBefore = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            usdcBefore[i] = usdc.balanceOf(u[i]);
            phusdBefore[i] = phUSD.balanceOf(u[i]);
        }

        // ---- Stage 5: settleDebt sweeps all 5 users ----
        migrator.settleDebt(100);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(usdc.balanceOf(u[i]) - usdcBefore[i], snapUSDC[i], "user got their USDC");
            assertEq(phUSD.balanceOf(u[i]) - phusdBefore[i], snapPhUSD[i], "user got their phUSD");
        }

        // ---- Stage 6: migrateDeposits re-stakes into V2 ----
        migrator.migrateDeposits(100);
        for (uint256 i = 0; i < 5; i++) {
            (uint256 v2Amount,,) = phlimboV2.userInfo(u[i]);
            (uint256 v1Amount,,) = phlimboV1.userInfo(u[i]);
            assertEq(v2Amount, v1Amount, "V2 deposit equals V1 deposit");
        }

        // ---- Stage 7: terminal state ----
        assertEq(migrator.settleIterator(), int256(-1));
        assertEq(migrator.migrateIterator(), int256(-1));
        assertEq(migrator.totalUSDC(), 0);
        assertEq(migrator.totalPHUSD_pending(), 0);
        assertEq(migrator.totalPHUSD_deposited(), 0);
        assertEq(usdc.balanceOf(address(migrator)), 0);
        assertEq(phUSD.balanceOf(address(migrator)), 0);
    }

    // ============================================================
    // 13. withdrawAll mid-flight
    // ============================================================

    function test_withdrawAll_mid_flight_breaks_settle() public {
        (uint256 totalUSDC, uint256 totalDep,) = _seedFiveUsers();
        _fundMigratorExact(totalUSDC, totalDep);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerPhusdBefore = phUSD.balanceOf(owner);

        migrator.withdrawAll();

        assertEq(usdc.balanceOf(owner) - ownerUsdcBefore, totalUSDC);
        assertEq(phUSD.balanceOf(owner) - ownerPhusdBefore, totalDep);
        assertEq(usdc.balanceOf(address(migrator)), 0);
        assertEq(phUSD.balanceOf(address(migrator)), 0);

        // Subsequent settle reverts on the balance invariant.
        vm.expectRevert("USDC balance mismatch");
        migrator.settleDebt(1);
    }
}
