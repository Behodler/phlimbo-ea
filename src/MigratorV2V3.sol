// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IFlax.sol";
import "./interfaces/IPhlimboV2.sol";
import "./interfaces/IPhlimboV3.sol";
import "./interfaces/IMigratorV2V3.sol";

/**
 * @title MigratorV2V3
 * @notice One-time, cooperation-free, chunked migration of the PhlimboV2 user base
 *         into PhlimboV3 at the start of the first promotion. Later rotations need
 *         NO migration — each flush leaves a clean slate.
 *
 *         Mirrors MigratorV1V2's idioms (owner-seeded address list, int256 cursor
 *         terminating at -1, withdrawAll escape hatch) with one improvement:
 *         LIVE position reads from V2 instead of seeded balance snapshots. This
 *         makes the migration robust to users interacting with V2 mid-migration
 *         (V2 cannot be paused for this — its `withdraw` is `whenNotPaused`, and
 *         pausing would also block the migrator itself).
 *
 *         Per-user flow inside `migrate`:
 *           1. Read `(amount,,) = phlimboV2.userInfo(user)` LIVE; skip if zero.
 *           2. `phlimboV2.withdraw(amount, user)` — V2's migrator routing delivers
 *              the staked phUSD PLUS auto-claimed stable + freshly minted phUSD
 *              rewards to this contract (msg.sender).
 *           3. `phlimboV3.stake(amount, user)` — the user lands in V3 with
 *              `promoDebt` set against the current `accPromoPerShare`, so there is
 *              NO retroactive promo accrual.
 *           4. Forward the reward deltas (balance-diff bracketing the whole
 *              withdraw+stake block) to the user. The principal nets out of the
 *              phUSD diff (withdrawn then restaked), so the remainder is exactly
 *              the rewards. On a straggler second pass this bracketing also
 *              forwards any V3 auto-claimed rewards (incl. promo) to the user.
 *
 *         A user who stakes into V2 AFTER their index was processed simply remains
 *         in V2. Mitigation is operational: wind V2 down (owner sets APY→0, stop
 *         feeding `collectReward`), then run a second migrator pass — once a pass
 *         has completed (`migrateIterator == -1`) the owner may call `seedUsers`
 *         again with a fresh straggler list. Reseeding mid-pass is forbidden.
 *
 *         === DEPLOYMENT-WIRING PREREQUISITES (NOT performed by this contract) ===
 *         Performed by staging scripts before `migrate` can succeed:
 *
 *           (a) PhlimboV2 owner: `phlimboV2.setMigrator(<this address>)` — required
 *               so `phlimboV2.withdraw(amount, user)` may act on behalf of users.
 *           (b) PhlimboV3 owner: `phlimboV3.setMigrator(<this address>)` — required
 *               so `phlimboV3.stake(amount, user)` may act on behalf of users.
 *
 *         NO phUSD mint role is needed on this contract — V2 itself mints the
 *         pending phUSD rewards during `withdraw`.
 *
 *         Recovery note: reward forwarding uses `safeTransfer`, so a recipient that
 *         cannot receive the reward token (e.g. a blocklisted address) reverts the
 *         batch. As with MigratorV1V2, the operational escape is to exclude such
 *         addresses from the seed list (or deploy and re-wire a fresh migrator);
 *         `withdrawAll` recovers any balances stranded in this contract.
 */
contract MigratorV2V3 is Ownable, ReentrancyGuard, IMigratorV2V3 {
    using SafeERC20 for IERC20;
    using SafeERC20 for IFlax;

    // ========================== STATE ==========================

    IPhlimboV2 public immutable phlimboV2;
    IPhlimboV3 public immutable phlimboV3;
    IFlax public immutable phUSD;
    IERC20 public immutable rewardToken;

    /// @notice Address list for the current pass. Replaced wholesale on reseed.
    address[] public users;

    /// @notice True once seedUsers has been called at least once.
    bool public seeded;

    /// @notice Migration cursor. 0 → users.length, then -1 when the pass completes.
    int256 public migrateIterator;

    // ========================== CONSTRUCTOR ==========================

    constructor(
        address _phlimboV2,
        address _phlimboV3,
        address _phUSD,
        address _rewardToken
    ) Ownable(msg.sender) {
        require(_phlimboV2 != address(0), "Invalid phlimboV2 address");
        require(_phlimboV3 != address(0), "Invalid phlimboV3 address");
        require(_phUSD != address(0), "Invalid phUSD address");
        require(_rewardToken != address(0), "Invalid reward token address");

        phlimboV2 = IPhlimboV2(_phlimboV2);
        phlimboV3 = IPhlimboV3(_phlimboV3);
        phUSD = IFlax(_phUSD);
        rewardToken = IERC20(_rewardToken);

        // seeded and migrateIterator are zero-initialized.
    }

    // ========================== SEED ==========================

    /**
     * @inheritdoc IMigratorV2V3
     * @dev Reseedable ONLY between passes: the first call requires `!seeded`; any
     *      later call requires the previous pass to have completed
     *      (`migrateIterator == -1`). Reseeding replaces the list wholesale and
     *      resets the cursor to 0. No amounts are seeded — positions are read live.
     */
    function seedUsers(address[] calldata _users) external onlyOwner {
        require(!seeded || migrateIterator == -1, "Pass in progress");
        require(_users.length > 0, "Empty users");

        delete users;
        for (uint256 i = 0; i < _users.length; i++) {
            users.push(_users[i]);
        }

        seeded = true;
        migrateIterator = 0;

        emit Seeded(_users.length);
    }

    // ========================== MIGRATE ==========================

    /**
     * @inheritdoc IMigratorV2V3
     * @dev Live-read chunked loop over `[cursor, min(cursor + maxIterations, len))`.
     *      Skip-on-zero: a user who exited V2 (or was already migrated) is silently
     *      passed over and the cursor advances. The balance-diff bracket spans the
     *      V2 withdraw AND the V3 stake, so the principal nets out of the phUSD
     *      delta and any V3 auto-claimed rewards (second pass) are forwarded too.
     */
    function migrate(uint256 maxIterations) external nonReentrant {
        require(seeded, "Not seeded");
        require(migrateIterator >= 0, "Migration complete");
        require(maxIterations > 0, "maxIterations==0");

        // Max-approve PhlimboV3 once per call. forceApprove is idempotent-safe.
        phUSD.forceApprove(address(phlimboV3), type(uint256).max);

        // Live promo slot: bracketed only so a straggler second pass forwards a
        // user's V3 auto-claimed promo instead of stranding it here. V3 guarantees
        // promoToken is never phUSD or rewardToken. address(0) = no promotion.
        IERC20 promoToken = phlimboV3.promoToken();

        uint256 i = uint256(migrateIterator);
        uint256 end = i + maxIterations;
        uint256 len = users.length;
        if (end > len) end = len;

        for (; i < end; i++) {
            address user = users[i];

            // LIVE read — robust to mid-migration V2 exits / partial withdrawals.
            (uint256 amount,,) = phlimboV2.userInfo(user);
            if (amount == 0) continue; // exited or already migrated

            uint256 phUSDBefore = phUSD.balanceOf(address(this));
            uint256 stableBefore = rewardToken.balanceOf(address(this));
            uint256 promoBefore =
                address(promoToken) != address(0) ? promoToken.balanceOf(address(this)) : 0;

            // Wiring prerequisite (a): phlimboV2.setMigrator(this). Delivers the
            // principal + auto-claimed stable + freshly minted phUSD rewards here.
            phlimboV2.withdraw(amount, user);

            // Wiring prerequisite (b): phlimboV3.setMigrator(this). Restakes the
            // principal for the user; promoDebt is set against the current
            // accPromoPerShare → no retroactive promo accrual. Any V3 auto-claim
            // (second pass only) lands here and is included in the deltas below.
            phlimboV3.stake(amount, user);

            // The principal was received then restaked, so it nets out: the phUSD
            // delta is exactly the reward component.
            uint256 phUSDRewards = phUSD.balanceOf(address(this)) - phUSDBefore;
            uint256 stableRewards = rewardToken.balanceOf(address(this)) - stableBefore;
            uint256 promoRewards = address(promoToken) != address(0)
                ? promoToken.balanceOf(address(this)) - promoBefore
                : 0;

            if (phUSDRewards > 0) {
                IERC20(address(phUSD)).safeTransfer(user, phUSDRewards);
            }
            if (stableRewards > 0) {
                rewardToken.safeTransfer(user, stableRewards);
            }
            if (promoRewards > 0) {
                promoToken.safeTransfer(user, promoRewards);
            }

            emit UserMigrated(user, amount, phUSDRewards, stableRewards, promoRewards);
        }

        if (i == len) {
            migrateIterator = -1;
        } else {
            migrateIterator = int256(i);
        }

        emit MigrateProgress(migrateIterator, len);
    }

    // ========================== ESCAPE HATCH ==========================

    /**
     * @inheritdoc IMigratorV2V3
     * @dev Pure recovery sweep of stranded balances. Unlike MigratorV1V2, this does
     *      NOT abort the pass — live reads mean there are no balance preconditions,
     *      so the seeded list and iterator are untouched and migration can resume.
     */
    function withdrawAll() external onlyOwner {
        address ownerAddr = owner();
        uint256 phUSDBal = phUSD.balanceOf(address(this));
        uint256 rewardBal = rewardToken.balanceOf(address(this));

        if (phUSDBal > 0) {
            IERC20(address(phUSD)).safeTransfer(ownerAddr, phUSDBal);
        }
        if (rewardBal > 0) {
            rewardToken.safeTransfer(ownerAddr, rewardBal);
        }

        emit WithdrawnAll(ownerAddr, phUSDBal, rewardBal);
    }

    // ========================== VIEW ==========================

    /// @inheritdoc IMigratorV2V3
    function userCount() external view returns (uint256) {
        return users.length;
    }
}
