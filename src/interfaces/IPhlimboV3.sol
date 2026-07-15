// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../IFlax.sol";
import "./IPhlimboHook.sol";

/**
 * @title IPhlimboV3
 * @notice Interface for the PhlimboV3 staking yield farm contract.
 * @dev Mirrors `IPhlimboV2` plus the V3 promotional reward token subsystem:
 *      - Single promo slot: owner-funded fixed quantity streamed linearly over its
 *        own depletion window; dormant on depletion; reactivated by top-up.
 *      - Rotation state machine: None → Active (startPromotion) → Flushing
 *        (beginFlush) → None (finalizePromotion), with abortFlush: Flushing → Active.
 *      - Staker enumeration (`stakerCount`/`stakerAt`) backing the flush.
 *      - Owner may pause/unpause directly in addition to the external pauser.
 */
interface IPhlimboV3 {
    // ========================== TYPES ==========================

    /// @notice Rotation state machine phase for the promotional slot
    enum PromoPhase {
        None,
        Active,
        Flushing
    }
    // ========================== EVENTS ==========================

    /**
     * @notice Emitted when a user makes an emergency withdrawal while contract is paused
     * @param user Address of the user withdrawing
     * @param amount Amount of phUSD withdrawn
     */
    event EmergencyWithdrawal(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user stakes phUSD
     * @param user Address of the user staking
     * @param amount Amount of phUSD staked
     */
    event Staked(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user withdraws staked phUSD
     * @param user Address of the user withdrawing
     * @param amount Amount of phUSD withdrawn
     */
    event Withdrawn(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a user claims rewards
     * @param user Address of the user claiming rewards
     * @param phUSDAmount Amount of phUSD rewards claimed
     * @param stableAmount Amount of stable token rewards claimed
     */
    event RewardsClaimed(address indexed user, uint256 phUSDAmount, uint256 stableAmount);

    /**
     * @notice Emitted when the migrator role is changed
     * @param oldMigrator Previous migrator address (address(0) if none)
     * @param newMigrator New migrator address (address(0) disables the role)
     */
    event MigratorSet(address indexed oldMigrator, address indexed newMigrator);

    /**
     * @notice Emitted when the hook contract is changed
     * @param oldHook Previous hook address (address(0) if none)
     * @param newHook New hook address (address(0) disables the hook)
     */
    event HookSet(address indexed oldHook, address indexed newHook);

    // ========================== PROMO EVENTS ==========================

    /**
     * @notice Emitted when a new promotion is started
     * @param token Partner token being streamed
     * @param amount Quantity supplied
     * @param duration Promo depletion window in seconds
     * @param rate Resulting promoRewardPerSecond (scaled by PRECISION)
     */
    event PromotionStarted(address indexed token, uint256 amount, uint256 duration, uint256 rate);

    /**
     * @notice Emitted when the active promotion is topped up
     * @param amount Quantity added
     * @param newBalance New undistributed promo balance
     * @param newRate Recomputed promoRewardPerSecond
     */
    event PromotionToppedUp(uint256 amount, uint256 newBalance, uint256 newRate);

    /**
     * @notice Emitted when the promo depletion window is changed
     */
    event PromoDepletionDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /**
     * @notice Emitted when promo rewards are paid to a user (settlement or flush)
     * @param user Address whose accrued promo rewards were drained
     * @param amount Amount of promo tokens paid
     */
    event PromoClaimed(address indexed user, uint256 amount);

    /**
     * @notice Emitted after each batchClaim chunk
     * @param cursor New flush cursor position
     * @param total Total staker set size being flushed
     */
    event FlushProgress(uint256 cursor, uint256 total);

    /**
     * @notice Emitted when a promo transfer to a user fails during the flush and the
     *         amount is banked into `unclaimablePromo` instead (flush continues)
     * @param user Recipient whose transfer failed
     * @param amount Amount banked
     */
    event PromoClaimFailed(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a promotion is finalized and the slot cleared
     * @param token The promo token that was retired
     * @param leftoverRecipient Recipient of the leftover sweep
     * @param leftoverAmount Amount swept (undistributed remainder + rounding dust + unclaimablePromo)
     */
    event PromotionFinalized(address indexed token, address indexed leftoverRecipient, uint256 leftoverAmount);

    // ========================== PROMO LIFECYCLE (OWNER) ==========================

    /**
     * @notice Starts a new promotion: pulls `amount` of `token` from the owner and
     *         streams it linearly over `duration`. Requires phase None.
     * @param token Partner token (not zero / phUSD / rewardToken; standard ERC20 only)
     * @param amount Fixed quantity to stream
     * @param duration Promo depletion window in seconds
     */
    function startPromotion(address token, uint256 amount, uint256 duration) external;

    /**
     * @notice Adds `amount` of the current promo token and recomputes the rate over
     *         the existing window. Reactivates a dormant stream. Requires phase Active.
     */
    function topUpPromotion(uint256 amount) external;

    /**
     * @notice Changes the promo depletion window and recomputes the rate.
     *         Requires phase Active.
     */
    function setPromoDepletionDuration(uint256 duration) external;

    // ========================== PROMO ROTATION (FLUSH) ==========================

    /**
     * @notice Begins the rotation flush: final promo accrual, pause, cursor reset.
     *         Phase Active → Flushing. Owner only.
     */
    function beginFlush() external;

    /**
     * @notice Processes up to `maxIterations` stakers from the flush cursor: pays each
     *         staker's pending promo TO THE STAKER DIRECTLY and aligns their promoDebt
     *         to the current accumulator. Permissionless — recipients and amounts are
     *         fixed by state. Requires phase Flushing. Failed transfers are banked
     *         into `unclaimablePromo` (flush continues).
     */
    function batchClaim(uint256 maxIterations) external;

    /**
     * @notice Finalizes the rotation: requires the flush cursor to have covered the
     *         entire staker set. Sweeps the remaining promo token balance (leftover +
     *         rounding dust + unclaimablePromo) to `leftoverRecipient` and clears the
     *         slot (promoToken/rate/balance zeroed; accPromoPerShare NEVER reset).
     *         Phase Flushing → None. Owner only.
     */
    function finalizePromotion(address leftoverRecipient) external;

    /**
     * @notice Aborts an in-progress flush, returning to Active. Always safe: batchClaim
     *         is just early forced claims with debts correctly aligned. Owner only.
     */
    function abortFlush() external;

    // ========================== PROMO VIEWS ==========================

    /**
     * @notice Returns pending promo rewards for a user
     */
    function pendingPromo(address user) external view returns (uint256);

    /**
     * @notice Returns current promotional slot information
     */
    function getPromoInfo() external view returns (
        address _promoToken,
        uint256 _promoRewardBalance,
        uint256 _promoRewardPerSecond,
        uint256 _promoDepletionDuration,
        PromoPhase _promoPhase,
        uint256 _flushCursor
    );

    // ========================== ADMIN FUNCTIONS ==========================

    /**
     * @notice Updates the desired APY and recalculates emission rate
     * @param bps New APY in basis points
     */
    function setDesiredAPY(uint256 bps) external;

    /**
     * @notice Sets the depletion duration for reward distribution
     * @param _duration New depletion duration in seconds
     */
    function setDepletionDuration(uint256 _duration) external;

    /**
     * @notice Sets the address authorized to pause the contract
     * @param _pauser Address to authorize for pausing (can be zero address to disable pausing)
     */
    function setPauser(address _pauser) external;

    /**
     * @notice Sets the migrator address authorized to act on behalf of any user
     * @param _migrator New migrator address (address(0) disables the role)
     */
    function setMigrator(address _migrator) external;

    /**
     * @notice Sets the hook contract invoked after stake/withdraw/claim
     * @param _hook New hook address (address(0) disables the hook)
     */
    function setHook(address _hook) external;

    /**
     * @notice Emergency function to transfer all tokens to a recipient
     * @param recipient Address to receive the tokens
     */
    function emergencyTransfer(address recipient) external;

    /**
     * @notice Allows users to withdraw their staked phUSD when contract is paused
     * @dev Emergency exit mechanism - does NOT claim rewards or update pool. Strictly
     *      msg.sender-only; migrator cannot delegate this call.
     * @param amount Amount of phUSD to withdraw
     */
    function pauseWithdraw(uint256 amount) external;

    // ========================== REWARD COLLECTION ==========================

    /**
     * @notice Collects rewards and updates linear depletion rate
     * @dev Anyone with approved tokens can contribute rewards
     * @param amount Amount of reward tokens to collect
     */
    function collectReward(uint256 amount) external;

    // ========================== CORE STAKING FUNCTIONS ==========================

    /**
     * @notice Stake phUSD tokens on behalf of `user`
     * @dev Auth: `msg.sender == user || msg.sender == migrator`. Tokens are pulled from
     *      msg.sender. The staked position is credited to `user`.
     * @param amount Amount of phUSD to stake
     * @param user Address to receive the staked position
     */
    function stake(uint256 amount, address user) external;

    /**
     * @notice Withdraw staked phUSD and auto-claim rewards on behalf of `user`
     * @dev Auth: `msg.sender == user || msg.sender == migrator`. Withdrawn tokens and any
     *      auto-claimed rewards are sent to msg.sender (the caller), enabling the migrator
     *      to extract a user's V2 stake.
     * @param amount Amount of phUSD to withdraw
     * @param user Address whose stake is debited
     */
    function withdraw(uint256 amount, address user) external;

    /**
     * @notice Claim pending rewards on behalf of `user` without withdrawing stake
     * @dev Auth: `msg.sender == user || msg.sender == migrator`. Rewards (phUSD + stable)
     *      are sent to msg.sender.
     * @param user Address whose accrued rewards are drained
     */
    function claim(address user) external;

    // ========================== VIEW FUNCTIONS ==========================

    /**
     * @notice Returns pending phUSD rewards for a user
     * @param user Address to check
     * @return Pending phUSD amount
     */
    function pendingPhUSD(address user) external view returns (uint256);

    /**
     * @notice Returns pending stable rewards for a user
     * @param user Address to check
     * @return Pending stable amount
     */
    function pendingStable(address user) external view returns (uint256);

    /**
     * @notice Returns current pool information
     */
    function getPoolInfo() external view returns (
        uint256 _totalStaked,
        uint256 _accPhUSDPerShare,
        uint256 _accStablePerShare,
        uint256 _phUSDPerSecond,
        uint256 _lastRewardTime
    );

    // ========================== STATE VARIABLE GETTERS ==========================

    function phUSD() external view returns (IFlax);
    function rewardToken() external view returns (IERC20);
    function desiredAPYBps() external view returns (uint256);
    function phUSDPerSecond() external view returns (uint256);
    function rewardBalance() external view returns (uint256);
    function depletionDuration() external view returns (uint256);
    function rewardPerSecond() external view returns (uint256);
    function lastRewardTime() external view returns (uint256);
    function accPhUSDPerShare() external view returns (uint256);
    function accStablePerShare() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function migrator() external view returns (address);
    function hook() external view returns (IPhlimboHook);
    function PRECISION() external view returns (uint256);
    function SECONDS_PER_YEAR() external view returns (uint256);
    function MINIMUM_STAKE() external view returns (uint256);
    function userInfo(address user)
        external
        view
        returns (uint256 amount, uint256 phUSDDebt, uint256 stableDebt, uint256 promoDebt);
    function promoToken() external view returns (IERC20);
    function promoRewardBalance() external view returns (uint256);
    function promoDepletionDuration() external view returns (uint256);
    function promoRewardPerSecond() external view returns (uint256);
    function accPromoPerShare() external view returns (uint256);
    function promoPhase() external view returns (PromoPhase);
    function flushCursor() external view returns (uint256);
    function unclaimablePromo() external view returns (uint256);

    // ========================== STAKER ENUMERATION ==========================

    /**
     * @notice Number of addresses currently in the staker set
     */
    function stakerCount() external view returns (uint256);

    /**
     * @notice Staker address at `index` in the staker set
     * @param index Index into the enumerable staker set
     */
    function stakerAt(uint256 index) external view returns (address);
}
