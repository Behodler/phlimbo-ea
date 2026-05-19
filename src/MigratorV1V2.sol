// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IFlax.sol";
import "./interfaces/IPhlimboV2.sol";
import "./interfaces/IMigratorV1V2.sol";

/**
 * @title MigratorV1V2
 * @notice Single-purpose migrator from PhlimboEA (V1) to PhlimboV2.
 *
 *         Lifecycle, in strict order:
 *           1. Owner deploys this contract pointing at (USDC, phUSD, PhlimboV2).
 *           2. Owner calls `seedObligations(users, deposits, USDC, phUSD)` ONCE with
 *              the off-chain V1 snapshot. This locks the user set and all totals.
 *           3. Owner funds the contract:
 *                - Transfer `totalUSDC` USDC to the contract.
 *                - Mint or transfer `totalPHUSD_deposited` phUSD to the contract.
 *           4. Owner calls `settleDebt(maxIterations)` one or more times to pay V1
 *              pending rewards: USDC is TRANSFERRED, phUSD is MINTED to each user.
 *           5. Owner calls `migrateDeposits(maxIterations)` one or more times to
 *              re-stake each user's V1 deposit into PhlimboV2 on their behalf.
 *           6. After both iterators reach -1, the contract is effectively retired.
 *              The owner may `withdrawAll()` to recover any leftover balance.
 *
 *         === DEPLOYMENT-WIRING PREREQUISITES (NOT performed by this contract) ===
 *         Before invoking `settleDebt` or `migrateDeposits`, the staging script MUST
 *         carry out two owner-only wirings on the surrounding system:
 *
 *           (a) phUSD-token owner: grant THIS migrator the `canMint == true` role
 *               on the phUSD token (e.g. via Flax's `authorizedMinters` setter).
 *               Required because `settleDebt` mints pending phUSD rewards directly
 *               to each V1 user, preserving the V1 "mint on demand" semantic.
 *
 *           (b) PhlimboV2 owner: call `PhlimboV2.setMigrator(<this address>)`.
 *               Required because `migrateDeposits` calls `phlimboV2.stake(amount,
 *               user)`, which is only permitted when `msg.sender == migrator` for
 *               the cross-user path.
 *
 *         Recommended order: deploy → seed → grant phUSD mint → setMigrator on V2 →
 *         fund USDC + phUSD → settle → migrate.
 */
contract MigratorV1V2 is Ownable, ReentrancyGuard, IMigratorV1V2 {
    using SafeERC20 for IERC20;
    using SafeERC20 for IFlax;

    // ========================== STATE ==========================

    IERC20 public immutable usdc;
    IFlax public immutable phUSD;
    IPhlimboV2 public immutable phlimboV2;

    // Seeded once via seedObligations; not modified thereafter.
    address[] public users;
    uint256[] public deposits;
    uint256[] public usdcOwed;
    uint256[] public phUSDOwed;

    /// @notice Remaining USDC obligations. Decremented as `settleDebt` pays.
    uint256 public totalUSDC;

    /// @notice phUSD migration float — sum of deposits. Decremented as
    ///         `migrateDeposits` re-stakes into V2. Unchanged by `settleDebt`
    ///         (phUSD rewards are minted, not transferred from this contract).
    uint256 public totalPHUSD_deposited;

    /// @notice Remaining pending phUSD rewards. Decremented as `settleDebt`
    ///         mints to each user.
    uint256 public totalPHUSD_pending;

    /// @notice One-shot guard for seedObligations.
    bool public seeded;

    /// @notice Settlement iterator. 0 → users.length, then -1 when complete.
    int256 public settleIterator;

    /// @notice Migration iterator. 0 → users.length, then -1 when complete.
    int256 public migrateIterator;

    // ========================== CONSTRUCTOR ==========================

    constructor(address _usdc, address _phUSD, address _phlimboV2) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_phUSD != address(0), "Invalid phUSD address");
        require(_phlimboV2 != address(0), "Invalid phlimboV2 address");

        usdc = IERC20(_usdc);
        phUSD = IFlax(_phUSD);
        phlimboV2 = IPhlimboV2(_phlimboV2);

        // settleIterator, migrateIterator, totals, seeded are all zero-initialized.
    }

    // ========================== SEED ==========================

    /**
     * @inheritdoc IMigratorV1V2
     * @dev One-shot; reverts if `seeded` is already true. Validates non-empty users
     *      and equal length of all four arrays. Copies arrays into storage and
     *      precomputes the three totals.
     */
    function seedObligations(
        address[] calldata _users,
        uint256[] calldata _deposits,
        uint256[] calldata _usdc,
        uint256[] calldata _phUSD
    ) external onlyOwner {
        require(!seeded, "Already seeded");
        require(_users.length > 0, "Empty users");
        require(
            _deposits.length == _users.length &&
                _usdc.length == _users.length &&
                _phUSD.length == _users.length,
            "Length mismatch"
        );

        uint256 sumUSDC;
        uint256 sumDep;
        uint256 sumPending;

        for (uint256 i = 0; i < _users.length; i++) {
            users.push(_users[i]);
            deposits.push(_deposits[i]);
            usdcOwed.push(_usdc[i]);
            phUSDOwed.push(_phUSD[i]);

            sumUSDC += _usdc[i];
            sumDep += _deposits[i];
            sumPending += _phUSD[i];
        }

        totalUSDC = sumUSDC;
        totalPHUSD_deposited = sumDep;
        totalPHUSD_pending = sumPending;
        seeded = true;

        emit Seeded(_users.length, sumUSDC, sumDep, sumPending);
    }

    // ========================== SETTLE ==========================

    /**
     * @inheritdoc IMigratorV1V2
     * @dev Pays pending V1 rewards: transfers `usdcOwed[i]` USDC and mints
     *      `phUSDOwed[i]` phUSD to `users[i]`. Skip-on-zero is honored to keep
     *      gas low when a user has only one reward type pending.
     *
     *      Both balance preconditions are strict equalities. Strict `==` catches
     *      operator over-funding mistakes — the recovery is `withdrawAll`.
     */
    function settleDebt(uint256 maxIterations) external nonReentrant {
        require(seeded, "Not seeded");
        require(settleIterator >= 0, "Settlement complete");
        require(maxIterations > 0, "maxIterations==0");
        require(usdc.balanceOf(address(this)) == totalUSDC, "USDC balance mismatch");
        require(
            phUSD.balanceOf(address(this)) == totalPHUSD_deposited,
            "phUSD balance mismatch"
        );

        uint256 i = uint256(settleIterator);
        uint256 end = i + maxIterations;
        uint256 len = users.length;
        if (end > len) end = len;

        for (; i < end; i++) {
            uint256 usdcAmt = usdcOwed[i];
            uint256 phusdAmt = phUSDOwed[i];

            if (usdcAmt > 0) {
                usdc.safeTransfer(users[i], usdcAmt);
                totalUSDC -= usdcAmt;
            }
            if (phusdAmt > 0) {
                // Mint authority prerequisite: phUSD-token owner must grant this
                // migrator the canMint role before this line can execute.
                phUSD.mint(users[i], phusdAmt);
                totalPHUSD_pending -= phusdAmt;
            }
        }

        if (i == len) {
            settleIterator = -1;
        } else {
            settleIterator = int256(i);
        }

        emit SettleProgress(settleIterator, totalUSDC, totalPHUSD_pending);
    }

    // ========================== MIGRATE ==========================

    /**
     * @inheritdoc IMigratorV1V2
     * @dev Calls `phlimboV2.stake(deposits[i], users[i])` for each user in the
     *      batch. Skip-on-zero: a deposit of 0 is silently passed over (and the
     *      iterator advances). Per-call max approval keeps the loop body cheap.
     */
    function migrateDeposits(uint256 maxIterations) external nonReentrant {
        require(seeded, "Not seeded");
        require(migrateIterator >= 0, "Migration complete");
        require(maxIterations > 0, "maxIterations==0");
        require(
            phUSD.balanceOf(address(this)) == totalPHUSD_deposited,
            "phUSD balance mismatch"
        );

        // Max-approve PhlimboV2 once per call. forceApprove is safe even if a
        // non-zero allowance is already in place (idempotent).
        phUSD.forceApprove(address(phlimboV2), type(uint256).max);

        uint256 i = uint256(migrateIterator);
        uint256 end = i + maxIterations;
        uint256 len = users.length;
        if (end > len) end = len;

        for (; i < end; i++) {
            uint256 dep = deposits[i];
            if (dep > 0) {
                // V2 migrator-role prerequisite: PhlimboV2.setMigrator(this) must
                // have been called by the V2 owner before this line — otherwise
                // V2 reverts with "Not authorized".
                phlimboV2.stake(dep, users[i]);
                totalPHUSD_deposited -= dep;
            }
        }

        if (i == len) {
            migrateIterator = -1;
        } else {
            migrateIterator = int256(i);
        }

        emit MigrateProgress(migrateIterator, totalPHUSD_deposited);
    }

    // ========================== ESCAPE HATCH ==========================

    /**
     * @inheritdoc IMigratorV1V2
     * @dev Does NOT touch the seeded arrays, totals, or iterators. Calling this
     *      mid-migration is an abort signal: the next settle/migrate call will
     *      revert on the balance precondition.
     */
    function withdrawAll() external onlyOwner {
        address ownerAddr = owner();
        uint256 usdcBal = usdc.balanceOf(address(this));
        uint256 phUSDBal = phUSD.balanceOf(address(this));

        if (usdcBal > 0) {
            usdc.safeTransfer(ownerAddr, usdcBal);
        }
        if (phUSDBal > 0) {
            IERC20(address(phUSD)).safeTransfer(ownerAddr, phUSDBal);
        }

        emit WithdrawnAll(ownerAddr, usdcBal, phUSDBal);
    }

    // ========================== VIEW ==========================

    /// @inheritdoc IMigratorV1V2
    function userCount() external view returns (uint256) {
        return users.length;
    }
}
