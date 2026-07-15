// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IMigratorV2V3
 * @notice Interface for MigratorV2V3 — one-time, cooperation-free, chunked migration
 *         of the PhlimboV2 user base into PhlimboV3 at the start of the first
 *         promotion. Mirrors the MigratorV1V2 idioms (owner-seeded address list,
 *         int256 cursor terminating at -1, withdrawAll escape hatch) with one
 *         improvement: LIVE position reads from V2 instead of seeded balance
 *         snapshots. Supports a straggler second pass: once a pass has completed
 *         (migrateIterator == -1) the owner may reseed a new address list.
 */
interface IMigratorV2V3 {
    // ========================== EVENTS ==========================

    /**
     * @notice Emitted whenever seedUsers (re)seeds an address list.
     * @param userCount Number of V2 users seeded for this pass.
     */
    event Seeded(uint256 userCount);

    /**
     * @notice Emitted for each user actually migrated (non-zero live V2 position).
     * @param user The migrated user.
     * @param principal Live V2 staked amount moved into V3.
     * @param phUSDRewards phUSD rewards forwarded to the user (V2 auto-claim delta,
     *        plus any V3 auto-claim delta on a straggler second pass).
     * @param stableRewards Stable-token rewards forwarded to the user.
     * @param promoRewards Promo-token rewards forwarded to the user (non-zero only
     *        on a second pass when the user already held a V3 position during an
     *        active promotion; always zero on the first pass).
     */
    event UserMigrated(
        address indexed user,
        uint256 principal,
        uint256 phUSDRewards,
        uint256 stableRewards,
        uint256 promoRewards
    );

    /**
     * @notice Emitted at the end of each migrate call.
     * @param iterator Updated migrateIterator (-1 when the pass is complete).
     * @param userCount Total size of the currently seeded address list.
     */
    event MigrateProgress(int256 iterator, uint256 userCount);

    /**
     * @notice Emitted when a reward transfer to a user fails during migrate and the
     *         amount is banked into `unclaimable` instead (the pass continues)
     * @param token The reward token whose transfer failed.
     * @param user Recipient whose transfer failed.
     * @param amount Amount banked.
     */
    event RewardForwardFailed(address indexed token, address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user's index is passed over without migrating: their
     *         live V2 position is below PhlimboV3's MINIMUM_STAKE (dust), their
     *         `migrateOne` self-call reverted (e.g. a stale-debt V2 position), or
     *         the owner stepped past them via `skipCurrent`. Informational only:
     *         the skipped user's V2 position is untouched and remains theirs — the
     *         owner handles skipped users in a later targeted pass seeded from
     *         these events.
     * @param user The user whose index was skipped.
     * @param amount The live V2 amount observed at skip time (0 for skipCurrent).
     */
    event UserMigrationSkipped(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user pulls a banked reward via claimUnclaimable.
     * @param token The reward token claimed.
     * @param user The claiming user.
     * @param amount Amount transferred.
     */
    event UnclaimableClaimed(address indexed token, address indexed user, uint256 amount);

    /**
     * @notice Emitted when withdrawAll sweeps stranded balances to the owner.
     * @param owner Owner that received the balances.
     * @param phUSDAmount Amount of phUSD transferred (may be 0).
     * @param rewardAmount Amount of reward token transferred (may be 0).
     * @param promoAmount Amount of the live promo token transferred (0 when no
     *        promotion is active or nothing is held).
     */
    event WithdrawnAll(
        address indexed owner, uint256 phUSDAmount, uint256 rewardAmount, uint256 promoAmount
    );

    // ========================== FUNCTIONS ==========================

    /**
     * @notice Seeds (or, after a completed pass, reseeds) the address list to
     *         migrate. Owner-only. No per-user amounts — positions are read live
     *         from V2 during migrate. Reverts while a pass is in progress
     *         (seeded && migrateIterator != -1).
     * @param _users V2 staker addresses (off-chain enumeration).
     */
    function seedUsers(address[] calldata _users) external;

    /**
     * @notice Migrates up to `maxIterations` users from the cursor: live-reads each
     *         user's V2 position, skips zero positions, withdraws the position from
     *         V2 (principal + auto-claimed rewards land in this contract), forwards
     *         the reward deltas to the user, and re-stakes the principal into V3 on
     *         the user's behalf.
     * @param maxIterations Maximum number of users to process in this call.
     */
    function migrate(uint256 maxIterations) external;

    /**
     * @notice Migrates a single user: V2 withdraw, V3 restake, reward-delta
     *         forwarding. NOT FOR EXTERNAL CALLERS — this function is SELF-CALL
     *         GATED (`require(msg.sender == address(this))`) and exists ONLY so
     *         `migrate` can wrap each per-user body in try/catch and skip a
     *         reverting position instead of bricking the pass. It is `external`
     *         purely because Solidity's try/catch requires an external call; any
     *         caller other than the migrator contract itself reverts "Only self".
     * @param user The seeded user to migrate.
     * @param amount The user's live V2 position, read by `migrate`.
     */
    function migrateOne(address user, uint256 amount) external;

    /**
     * @notice Owner-only backstop: advances the migration cursor past the current
     *         index WITHOUT touching that user's V2 position, emitting
     *         UserMigrationSkipped(user, 0). For use if the cursor ever stalls in
     *         a way the migrateOne try/catch cannot absorb (e.g. gas exhaustion
     *         under the 63/64 rule). Sets the iterator to -1 when the skip
     *         consumes the final index, matching migrate's completion semantics.
     */
    function skipCurrent() external;

    /**
     * @notice Permissionless pull of a reward amount that could not be forwarded to
     *         msg.sender during migrate (e.g. while blocklisted). Zeroes the entry,
     *         then transfers with reverting semantics — a caller who still cannot
     *         receive the token reverts and keeps their claim.
     * @param token The reward token to claim banked amounts of.
     */
    function claimUnclaimable(address token) external;

    /**
     * @notice Owner-only LAST-DITCH recovery sweep. Drains the contract's ENTIRE
     *         phUSD, reward-token and (live) promo-token balances to the owner —
     *         including amounts banked in `unclaimable`, whose claims become
     *         unbacked (reimbursement is then an out-of-band owner obligation).
     *         Does not touch the seeded list or iterator — with live reads there
     *         are no balance preconditions to break.
     */
    function withdrawAll() external;

    /**
     * @notice Reward amount banked for `user` in `token` after a failed forward
     *         during migrate; claimable via claimUnclaimable.
     */
    function unclaimable(address token, address user) external view returns (uint256);

    /**
     * @notice Returns the number of users in the currently seeded list.
     */
    function userCount() external view returns (uint256);
}
