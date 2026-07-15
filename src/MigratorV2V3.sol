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
 *         Recovery note: the ENTIRE per-user body (live read, V2 withdraw, V3
 *         stake, reward forwarding) runs inside a try/catch'd `migrateOne`
 *         self-call, so a position that reverts anywhere in it — a stale-debt V2
 *         position that panics in `_claimRewards`, or anything unforeseen — is
 *         skipped atomically: `UserMigrationSkipped` is emitted carrying the raw
 *         revert data as its `reason`, the user's V2 position is left untouched
 *         for a later targeted pass (seeded from those events once this pass
 *         completes), and the cursor advances. Positions below V3's MINIMUM_STAKE
 *         (dust that `stake` would reject) are skipped up-front with the same
 *         event and an EMPTY reason (nothing was attempted). BEWARE: a
 *         misconfigured pass still COMPLETES — an unwired (missing setMigrator)
 *         or paused Phlimbo surfaces as a pass full of skips whose reasons decode
 *         to `Error(string)` (e.g. "Not authorized" / "Pausable: paused"); the
 *         owner MUST read the UserMigrationSkipped events after every pass before
 *         trusting it. The try/catch absorbs REVERTS, not gas
 *         exhaustion: under the 63/64 rule an out-of-gas `migrateOne` can starve
 *         the remainder of the pass — mitigated by calling `migrate` with a
 *         smaller `maxIterations`, and the owner-only `skipCurrent` is the
 *         backstop that steps the cursor past a stalling index. Within a
 *         successful iteration, reward forwarding additionally never reverts:
 *         each delta is sent with the non-reverting `_tryTransfer`; if a recipient
 *         cannot receive a token (e.g. a blocklisted address), the amount is
 *         banked into the per-user `unclaimable` mapping and `RewardForwardFailed`
 *         is emitted. Banked amounts are pulled by the affected user via the
 *         permissionless
 *         `claimUnclaimable` once they can receive again. `withdrawAll` remains a
 *         LAST-DITCH escape hatch: it sweeps this contract's ENTIRE phUSD,
 *         reward-token and (live) promo-token balances, INCLUDING amounts banked in
 *         `unclaimable`, leaving those claims unbacked. Reimbursing affected users
 *         after such a sweep is an out-of-band owner obligation — the accepted
 *         trade-off for keeping the emergency hatch unconditional and simple.
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

    /// @notice token => user => reward amount that could not be forwarded during
    ///         migrate. Banked by `_forward` when a recipient cannot receive a
    ///         token; pulled by the user via `claimUnclaimable`.
    mapping(address => mapping(address => uint256)) public unclaimable;

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
     *      passed over. Skip-on-dust: a live position below V3's MINIMUM_STAKE can
     *      never be staked into V3, so it is passed over with UserMigrationSkipped
     *      (audit-08 M-02, vector 1a). Each remaining per-user body runs as a
     *      try/catch'd `migrateOne` self-call — a reverting position (e.g. a
     *      stale-debt V2 position, vector 1b) is skipped with the same event, so
     *      the cursor ALWAYS advances.
     */
    function migrate(uint256 maxIterations) external nonReentrant {
        require(seeded, "Not seeded");
        require(migrateIterator >= 0, "Migration complete");
        require(maxIterations > 0, "maxIterations==0");

        // Max-approve PhlimboV3 once per call. forceApprove is idempotent-safe.
        phUSD.forceApprove(address(phlimboV3), type(uint256).max);

        // Cached once: MINIMUM_STAKE is a compile-time constant on PhlimboV3.
        uint256 minStake = phlimboV3.MINIMUM_STAKE();

        uint256 i = uint256(migrateIterator);
        uint256 end = i + maxIterations;
        uint256 len = users.length;
        if (end > len) end = len;

        for (; i < end; i++) {
            address user = users[i];

            // LIVE read — robust to mid-migration V2 exits / partial withdrawals.
            (uint256 amount,,) = phlimboV2.userInfo(user);
            if (amount == 0) continue; // exited or already migrated
            if (amount < minStake) {
                // Dust that phlimboV3.stake would reject ("Below minimum stake").
                // The position stays in V2 and remains the user's. Empty reason:
                // nothing was attempted.
                emit UserMigrationSkipped(user, amount, "");
                continue;
            }

            try this.migrateOne(user, amount) {
                // UserMigrated emitted inside migrateOne.
            } catch (bytes memory reason) {
                // The whole iteration reverted atomically (bracket included); the
                // user's V2 position is untouched and the cursor still advances.
                // `reason` is the raw ABI-encoded revert data — decoded off-chain
                // to tell a genuinely bad position apart from a misconfiguration
                // (e.g. "Not authorized" = missing setMigrator wiring).
                emit UserMigrationSkipped(user, amount, reason);
            }
        }

        if (i == len) {
            migrateIterator = -1;
        } else {
            migrateIterator = int256(i);
        }

        emit MigrateProgress(migrateIterator, len);
    }

    /**
     * @inheritdoc IMigratorV2V3
     * @dev Self-call ONLY — the `migrate` loop's try/catch target. A revert
     *      anywhere in here unwinds the whole iteration (bracket, withdraw, stake,
     *      forwarding together); `migrate` catches it, emits UserMigrationSkipped
     *      and advances the cursor. MUST NOT carry `nonReentrant`: OZ v5's
     *      ReentrancyGuard is a single lock shared across all guarded functions,
     *      and `migrate` already holds it when it self-calls — a guarded
     *      migrateOne would revert ReentrancyGuardReentrantCall and the catch
     *      would silently skip EVERY user. Protected by the "Only self" gate
     *      instead.
     */
    function migrateOne(address user, uint256 amount) external {
        require(msg.sender == address(this), "Only self");

        // Live promo slot: bracketed only so a straggler second pass forwards a
        // user's V3 auto-claimed promo instead of stranding it here. V3 guarantees
        // promoToken is never phUSD or rewardToken. address(0) = no promotion.
        IERC20 promoToken = phlimboV3.promoToken();

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

        // Non-reverting forwarding (audit-07 M-01): a recipient that cannot
        // receive a token banks into `unclaimable` instead of bricking the pass.
        _forward(IERC20(address(phUSD)), user, phUSDRewards);
        _forward(rewardToken, user, stableRewards);
        if (address(promoToken) != address(0)) {
            _forward(promoToken, user, promoRewards);
        }

        emit UserMigrated(user, amount, phUSDRewards, stableRewards, promoRewards);
    }

    /**
     * @inheritdoc IMigratorV2V3
     * @dev Owner backstop for a stall the try/catch cannot absorb (e.g. gas
     *      exhaustion under the 63/64 rule). Does NOT touch the skipped user's V2
     *      position. Mirrors migrate's completion semantics: -1 when the skip
     *      consumes the final index.
     */
    function skipCurrent() external onlyOwner {
        require(seeded && migrateIterator >= 0, "Nothing to skip");
        uint256 idx = uint256(migrateIterator);
        emit UserMigrationSkipped(users[idx], 0, "");
        uint256 next = idx + 1;
        migrateIterator = next == users.length ? int256(-1) : int256(next);
        emit MigrateProgress(migrateIterator, users.length);
    }

    // ========================== UNCLAIMABLE ==========================

    /**
     * @inheritdoc IMigratorV2V3
     * @dev Permissionless pull. Deliberately uses reverting `safeTransfer` — this is
     *      a user-initiated path, so reverting while the caller is still blocked is
     *      correct (non-reverting behaviour is scoped to the batch path only). The
     *      entry is zeroed BEFORE the transfer (checks-effects-interactions).
     */
    function claimUnclaimable(address token) external nonReentrant {
        uint256 amount = unclaimable[token][msg.sender];
        require(amount > 0, "Nothing to claim");
        unclaimable[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit UnclaimableClaimed(token, msg.sender, amount);
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

        // Live promo slot, mirroring migrate. address(0) = no active promotion, so
        // there is no promo leg to sweep.
        IERC20 promoToken = phlimboV3.promoToken();
        uint256 promoBal =
            address(promoToken) != address(0) ? promoToken.balanceOf(address(this)) : 0;

        if (phUSDBal > 0) {
            IERC20(address(phUSD)).safeTransfer(ownerAddr, phUSDBal);
        }
        if (rewardBal > 0) {
            rewardToken.safeTransfer(ownerAddr, rewardBal);
        }
        if (promoBal > 0) {
            promoToken.safeTransfer(ownerAddr, promoBal);
        }

        emit WithdrawnAll(ownerAddr, phUSDBal, rewardBal, promoBal);
    }

    // ========================== INTERNAL ==========================

    /**
     * @notice Non-reverting ERC20 transfer used by the migration pass: a single
     *         blocklisted or otherwise reverting recipient must not brick migrate.
     * @return success True if the transfer succeeded (call succeeded and returned
     *         either nothing or true).
     */
    function _tryTransfer(IERC20 token, address to, uint256 amount) internal returns (bool success) {
        (bool callSuccess, bytes memory returndata) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return callSuccess && (returndata.length == 0 || abi.decode(returndata, (bool)));
    }

    /**
     * @notice Forwards a reward delta to a user without ever reverting. On transfer
     *         failure the amount is banked into `unclaimable` for a later
     *         `claimUnclaimable` pull and `RewardForwardFailed` is emitted.
     */
    function _forward(IERC20 token, address user, uint256 amount) internal {
        if (amount == 0) return;
        if (_tryTransfer(token, user, amount)) return;
        unclaimable[address(token)][user] += amount;
        emit RewardForwardFailed(address(token), user, amount);
    }

    // ========================== VIEW ==========================

    /// @inheritdoc IMigratorV2V3
    function userCount() external view returns (uint256) {
        return users.length;
    }
}
