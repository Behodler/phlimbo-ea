// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./IFlax.sol";
import "./interfaces/IPhlimboV3.sol";
import "./interfaces/IPhlimboHook.sol";
import {IPausable} from "lib/mutable/pauser/src/interfaces/IPausable.sol";

/**
 * @title PhlimboV3
 * @notice Staking yield farm for phUSD tokens with Linear Depletion reward distribution.
 *         V3 = verbatim copy of PhlimboV2 (which fixed the V1 depletion-rate bug and
 *         added the migrator role + hook system) plus an additive SINGLE promotional
 *         reward token subsystem:
 *
 *         1. Promo slot: a partner supplies a fixed quantity Q of their token; V3
 *            streams it linearly over an owner-set window `promoDepletionDuration`
 *            (independent of the stable `rewardToken` window), falls dormant on
 *            depletion, reactivates on owner top-up.
 *         2. Rotation without history: pause → cursor-guaranteed `batchClaim` flush
 *            over a frozen `EnumerableSet` of stakers → swap token → unpause.
 *            Two load-bearing invariants:
 *            (a) `accPromoPerShare` is NEVER reset across promotions — the flush
 *                aligns every staker's `promoDebt` to the current accumulator, so
 *                pending against the next token starts at exactly zero.
 *            (b) The flush is provably complete over a frozen staker set — set
 *                membership only mutates in `whenNotPaused` ops, and a monotone
 *                `flushCursor` makes coverage contiguous; `finalizePromotion`
 *                requires `flushCursor == _stakers.length()`.
 *         3. Pause deltas from V2: owner may pause/unpause directly (external pauser
 *            still supported); `unpause()` reverts while flushing; `pauseWithdraw`
 *            realigns ALL reward debts to the reduced amount (fixes the latent V1/V2
 *            partial-pauseWithdraw brick, forfeiting unclaimed accruals).
 *
 *         V1 (`PhlimboEA`) and V2 remain deployed; V3 coexists for migration.
 *         `pauseWithdraw` stays strictly msg.sender-only, not delegatable to migrator.
 */
contract PhlimboV3 is Ownable, Pausable, ReentrancyGuard, IPhlimboV3, IPausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========================== STATE VARIABLES ==========================

    /// @notice phUSD token - used for staking and rewards
    IFlax public phUSD;

    /// @notice External stablecoin token distributed as rewards (received from yield-accumulator)
    IERC20 public rewardToken;

    /// @notice Address authorized to pause the contract
    address public override pauser;

    /// @notice Desired APY in basis points (e.g., 500 = 5%)
    uint256 public desiredAPYBps;

    /// @notice Current phUSD emission rate per second
    uint256 public phUSDPerSecond;

    // Two-step APY setting state
    /// @notice Proposed APY value awaiting confirmation
    uint256 public pendingAPYBps;

    /// @notice Block when APY was proposed
    uint256 public pendingAPYBlockNumber;

    /// @notice Whether a set operation is pending confirmation
    bool public apySetInProgress;

    /// @notice Total undistributed reward tokens (not yet accrued to stakers)
    uint256 public rewardBalance;

    /// @notice Target time window to fully distribute rewards (e.g., 604800 = 1 week)
    uint256 public depletionDuration;

    /// @notice Current reward rate per second (scaled by PRECISION)
    uint256 public rewardPerSecond;

    /// @notice Timestamp of last reward update
    uint256 public lastRewardTime;

    /// @notice Accumulated phUSD rewards per share (scaled by PRECISION)
    uint256 public accPhUSDPerShare;

    /// @notice Accumulated stable rewards per share (scaled by PRECISION)
    uint256 public accStablePerShare;

    /// @notice Total amount of phUSD staked in the contract
    uint256 public totalStaked;

    /// @notice Address allowed to act on behalf of any user via stake/withdraw/claim.
    /// @dev Initialized to address(0) — role disabled until owner calls `setMigrator`.
    address public migrator;

    /// @notice Optional hook contract invoked after stake/withdraw/claim.
    /// @dev Initialized to address(0) — no hook. Guarded with `if (address(hook) != address(0))`.
    IPhlimboHook public hook;

    // ---------- Promotional slot (single) ----------

    /// @notice Current promotional partner token. address(0) = no promotion.
    IERC20 public promoToken;

    /// @notice Undistributed promo tokens (not yet accrued to stakers)
    uint256 public promoRewardBalance;

    /// @notice Promo stream's OWN depletion window, independent of `depletionDuration`
    uint256 public promoDepletionDuration;

    /// @notice Current promo reward rate per second (scaled by PRECISION)
    uint256 public promoRewardPerSecond;

    /// @notice Accumulated promo rewards per share (scaled by PRECISION).
    /// @dev NEVER reset across promotions — the flush aligns every staker's
    ///      `promoDebt` to this accumulator instead. Zeroing it while debts are
    ///      non-zero would underflow `amount * acc - debt`.
    uint256 public accPromoPerShare;

    /// @notice Enumerable set of every address with a non-zero staked amount.
    /// @dev Membership mutates only inside `whenNotPaused` ops, so the set is
    ///      frozen while paused/flushing (EnumerableSet.remove is swap-and-pop —
    ///      a mid-flush removal could silently skip a member).
    EnumerableSet.AddressSet private _stakers;

    /// @notice Rotation state machine phase
    PromoPhase public promoPhase;

    /// @notice Monotone cursor into `_stakers` during a flush (chunked-iterator idiom)
    uint256 public flushCursor;

    /// @notice Promo tokens whose transfer to a user failed during flush (banked
    ///         for out-of-band handling; swept at finalizePromotion)
    uint256 public unclaimablePromo;

    // ========================== CONSTANTS ==========================

    /// @notice Precision multiplier for reward calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Seconds in a year for APY calculations
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Minimum stake amount to prevent first depositor attack (0.001 phUSD)
    uint256 public constant MINIMUM_STAKE = 1e15;

    // ========================== STRUCTS ==========================

    /**
     * @notice Tracks user staking information
     */
    struct UserInfo {
        uint256 amount;
        uint256 phUSDDebt;
        uint256 stableDebt;
        uint256 promoDebt;
    }

    // ========================== MAPPINGS ==========================

    /// @notice Mapping of user address to their staking information
    mapping(address => UserInfo) public userInfo;

    // ========================== EVENTS ==========================
    // Note: Staked/Withdrawn/RewardsClaimed/EmergencyWithdrawal/MigratorSet/HookSet
    // are declared in IPhlimboV3.

    /// @notice Emitted when rewards are collected from yield-accumulator
    event RewardCollected(uint256 amount, uint256 newRewardBalance, uint256 newRate);

    /// @notice Emitted when reward rate is updated
    event RateUpdated(uint256 newRate, uint256 newBalance);

    /// @notice Emitted when depletion duration is updated
    event DepletionDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when an APY change is proposed (preview step)
    event IntendedSetAPY(uint256 indexed proposedAPY, uint256 blockNumber, address indexed proposer);

    /// @notice Emitted when an APY change is confirmed (commit step)
    event DesiredAPYUpdated(uint256 oldAPY, uint256 newAPY);

    // ========================== CONSTRUCTOR ==========================

    /**
     * @notice Initializes the PhlimboV3 staking contract
     * @param _phUSD Address of the phUSD token
     * @param _rewardToken Address of the stable token for rewards
     * @param _depletionDuration Target time window to distribute rewards
     */
    constructor(
        address _phUSD,
        address _rewardToken,
        uint256 _depletionDuration
    ) Ownable(msg.sender) {
        require(_phUSD != address(0), "Invalid phUSD address");
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_depletionDuration > 0, "Duration must be > 0");

        phUSD = IFlax(_phUSD);
        rewardToken = IERC20(_rewardToken);
        depletionDuration = _depletionDuration;
        lastRewardTime = block.timestamp;
        rewardBalance = 0;
        rewardPerSecond = 0;

        // Per "Hook gas pattern" decision in story Concerns: hook starts at address(0)
        // and is checked with `if (address(hook) != address(0))` at each call site.
        // No default hook contract is instantiated.
        // migrator and hook are already zero-initialized — explicit comment for clarity.
    }

    // ========================== ADMIN FUNCTIONS ==========================

    /**
     * @notice Two-step APY setting: preview then commit
     */
    function setDesiredAPY(uint256 bps) external onlyOwner {
        bool isPreview = !apySetInProgress ||
                        block.number > pendingAPYBlockNumber + 100 ||
                        bps != pendingAPYBps;

        if (isPreview) {
            emit IntendedSetAPY(bps, block.number, msg.sender);
            pendingAPYBps = bps;
            pendingAPYBlockNumber = block.number;
            apySetInProgress = true;
        } else {
            _updatePool();
            uint256 oldAPY = desiredAPYBps;
            desiredAPYBps = bps;
            _updatePhUSDEmissionRate();
            emit DesiredAPYUpdated(oldAPY, bps);
            apySetInProgress = false;
        }
    }

    /**
     * @notice Sets the depletion duration for reward distribution
     * @dev Recomputes rate after window change — kept from V1 per planning Concerns.
     */
    function setDepletionDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0, "Duration must be > 0");

        // Accrue pending rewards with old rate before changing duration
        _updatePool();

        uint256 oldDuration = depletionDuration;
        depletionDuration = _duration;

        // Recalculate rate with new duration. This recompute stays in V2 because the
        // window has explicitly changed; the bug fix only removes the recompute from
        // _updatePool() (which fires on every user interaction).
        rewardPerSecond = (rewardBalance * PRECISION) / depletionDuration;

        emit DepletionDurationUpdated(oldDuration, _duration);
    }

    /**
     * @notice Unpauses the contract
     * @dev V3: owner may unpause directly in addition to the external pauser.
     */
    function unpause() public override {
        require(msg.sender == pauser || msg.sender == owner(), "Only pauser or owner can unpause");
        _unpause();
    }

    /**
     * @notice Sets the address authorized to pause the contract
     */
    function setPauser(address _pauser) external onlyOwner {
        pauser = _pauser;
    }

    /**
     * @notice Sets the migrator address authorized to act on behalf of any user.
     * @dev Accepts address(0) to disable the migrator role.
     */
    function setMigrator(address _migrator) external onlyOwner {
        address oldMigrator = migrator;
        migrator = _migrator;
        emit MigratorSet(oldMigrator, _migrator);
    }

    /**
     * @notice Sets the hook contract invoked after stake/withdraw/claim.
     * @dev Accepts address(0) to disable the hook.
     */
    function setHook(address _hook) external onlyOwner {
        address oldHook = address(hook);
        hook = IPhlimboHook(_hook);
        emit HookSet(oldHook, _hook);
    }

    /**
     * @notice Emergency function to transfer all tokens to a recipient
     */
    function emergencyTransfer(address recipient) external onlyOwner {
        uint256 phUSDBalance = phUSD.balanceOf(address(this));
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));

        if (phUSDBalance > 0) {
            IERC20(address(phUSD)).safeTransfer(recipient, phUSDBalance);
        }
        if (rewardTokenBalance > 0) {
            rewardToken.safeTransfer(recipient, rewardTokenBalance);
        }

        _pause();
    }

    // ========================== PROMO LIFECYCLE (OWNER) ==========================

    /**
     * @notice Starts a new promotion: pulls `amount` of `token` from the owner and
     *         streams it linearly over `duration`. Phase None → Active.
     * @dev Fee-on-transfer/rebasing tokens are rejected by policy; the balance-delta
     *      check is the belt-and-braces guard. `_updatePool()` runs first so the promo
     *      stream cannot retroactively accrue over time before the promotion existed.
     */
    function startPromotion(address token, uint256 amount, uint256 duration) external onlyOwner whenNotPaused {
        require(promoPhase == PromoPhase.None, "Promo phase must be None");
        require(
            token != address(0) && token != address(phUSD) && token != address(rewardToken),
            "Invalid promo token"
        );
        require(amount > 0, "Amount must be greater than 0");
        require(duration > 0, "Duration must be > 0");

        // Advance shared lastRewardTime before the promo slot exists so the new
        // stream starts accruing strictly from now.
        _updatePool();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(
            IERC20(token).balanceOf(address(this)) - balanceBefore == amount,
            "Fee-on-transfer not supported"
        );

        promoToken = IERC20(token);
        promoRewardBalance = amount;
        promoDepletionDuration = duration;
        promoRewardPerSecond = (amount * PRECISION) / duration;
        promoPhase = PromoPhase.Active;

        emit PromotionStarted(token, amount, duration, promoRewardPerSecond);
    }

    /**
     * @notice Adds `amount` of the current promo token and recomputes the rate over
     *         the existing window (canonical recompute site, mirrors collectReward).
     *         Reactivates a dormant stream. Requires phase Active.
     */
    function topUpPromotion(uint256 amount) external onlyOwner {
        require(promoPhase == PromoPhase.Active, "Promo phase must be Active");
        require(amount > 0, "Amount must be greater than 0");

        // Accrue at the old rate before changing balance/rate.
        _updatePool();

        uint256 balanceBefore = promoToken.balanceOf(address(this));
        promoToken.safeTransferFrom(msg.sender, address(this), amount);
        require(
            promoToken.balanceOf(address(this)) - balanceBefore == amount,
            "Fee-on-transfer not supported"
        );

        promoRewardBalance += amount;
        promoRewardPerSecond = (promoRewardBalance * PRECISION) / promoDepletionDuration;

        emit PromotionToppedUp(amount, promoRewardBalance, promoRewardPerSecond);
    }

    /**
     * @notice Changes the promo depletion window and recomputes the rate over the
     *         remaining balance (mirrors setDepletionDuration). Requires phase Active.
     */
    function setPromoDepletionDuration(uint256 duration) external onlyOwner {
        require(promoPhase == PromoPhase.Active, "Promo phase must be Active");
        require(duration > 0, "Duration must be > 0");

        // Accrue at the old rate over the old window first.
        _updatePool();

        uint256 oldDuration = promoDepletionDuration;
        promoDepletionDuration = duration;
        promoRewardPerSecond = (promoRewardBalance * PRECISION) / duration;

        emit PromoDepletionDurationUpdated(oldDuration, duration);
    }

    // ========================== PAUSE MECHANISM ==========================

    /**
     * @notice Pauses the contract
     * @dev V3: owner may pause directly in addition to the external pauser.
     */
    function pause() public override {
        require(msg.sender == pauser || msg.sender == owner(), "Only pauser or owner can pause");
        _pause();
    }

    /**
     * @notice Allows users to withdraw their staked phUSD when contract is paused
     * @dev Emergency exit mechanism — strictly msg.sender-only. NOT delegatable to
     *      migrator. Does NOT claim rewards or update pool. Does NOT invoke any hook.
     *
     *      V3 deltas from V2:
     *      - Realigns ALL reward debts (phUSDDebt/stableDebt/promoDebt) to the
     *        reduced amount, forfeiting unclaimed accruals. This fixes the latent
     *        V1/V2 defect where a partial pauseWithdraw left debts computed against
     *        the old, larger amount, so `amount * acc - debt` underflowed and
     *        bricked the user's position after unpause.
     *      - Does NOT touch `_stakers` membership: the set only mutates in
     *        `whenNotPaused` ops, keeping it frozen during a flush. A user who
     *        fully exits here is visited by the flush with pending == 0 (harmless).
     */
    function pauseWithdraw(uint256 amount) external whenPaused {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Insufficient balance");
        require(amount > 0, "Amount must be greater than 0");

        user.amount -= amount;
        totalStaked -= amount;

        user.phUSDDebt = (user.amount * accPhUSDPerShare) / PRECISION;
        user.stableDebt = (user.amount * accStablePerShare) / PRECISION;
        user.promoDebt = (user.amount * accPromoPerShare) / PRECISION;

        IERC20(address(phUSD)).safeTransfer(msg.sender, amount);

        emit EmergencyWithdrawal(msg.sender, amount);
    }

    // ========================== REWARD COLLECTION ==========================

    /**
     * @notice Collects rewards and updates linear depletion rate
     */
    function collectReward(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Update pool FIRST to accrue pending rewards before adding new balance
        _updatePool();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        rewardBalance += amount;

        // Recalculate rate based on new balance — this is the canonical recompute site.
        rewardPerSecond = (rewardBalance * PRECISION) / depletionDuration;

        emit RewardCollected(amount, rewardBalance, rewardPerSecond);
    }

    // ========================== CORE STAKING FUNCTIONS ==========================

    /**
     * @notice Stake phUSD tokens on behalf of `user`
     * @dev Auth: msg.sender == user || msg.sender == migrator. Tokens are pulled from
     *      msg.sender via safeTransferFrom. The position is credited to `user`.
     *      Any auto-claimed rewards go to msg.sender (not `user`) — consistent with
     *      withdraw/claim routing during migrator delegation.
     */
    function stake(uint256 amount, address user) external whenNotPaused nonReentrant {
        require(amount >= MINIMUM_STAKE, "Below minimum stake");
        require(user != address(0), "Invalid user");
        require(msg.sender == user || msg.sender == migrator, "Not authorized");

        _updatePool();

        UserInfo storage userDetails = userInfo[user];

        // Claim any pending rewards first. Route auto-claim to msg.sender so the
        // migrator path is consistent: rewards always go to the caller during
        // delegation. Self-service paths (msg.sender == user) end up routing to the
        // user themselves, which matches V1.
        if (userDetails.amount > 0) {
            _claimRewards(user, msg.sender);
        }

        // Transfer phUSD from msg.sender (caller always pays)
        IERC20(address(phUSD)).safeTransferFrom(msg.sender, address(this), amount);

        userDetails.amount += amount;
        userDetails.phUSDDebt = (userDetails.amount * accPhUSDPerShare) / PRECISION;
        userDetails.stableDebt = (userDetails.amount * accStablePerShare) / PRECISION;
        userDetails.promoDebt = (userDetails.amount * accPromoPerShare) / PRECISION;

        totalStaked += amount;

        // Idempotent: `amount >= MINIMUM_STAKE` is guaranteed above, so membership
        // in `_stakers` ⟺ userInfo.amount > 0 (V2 dust rule preserves this on exit).
        _stakers.add(user);

        _updatePhUSDEmissionRate();

        emit Staked(user, amount);

        if (address(hook) != address(0)) {
            hook.onDeposit(msg.sender, user, amount);
        }
    }

    /**
     * @notice Withdraw staked phUSD and auto-claim rewards on behalf of `user`
     * @dev Auth: msg.sender == user || msg.sender == migrator. Withdrawn tokens AND
     *      any auto-claimed rewards are sent to msg.sender.
     */
    function withdraw(uint256 amount, address user) external whenNotPaused nonReentrant {
        require(user != address(0), "Invalid user");
        require(msg.sender == user || msg.sender == migrator, "Not authorized");

        UserInfo storage userDetails = userInfo[user];
        require(userDetails.amount >= amount, "Insufficient balance");

        _updatePool();

        // Route auto-claim to msg.sender (caller) — consistent with stake/claim.
        _claimRewards(user, msg.sender);

        uint256 remaining = userDetails.amount - amount;

        // Prevent dust: if remaining would be > 0 but < MINIMUM_STAKE, force full withdrawal
        uint256 actualWithdrawAmount = amount;
        if (remaining > 0 && remaining < MINIMUM_STAKE) {
            actualWithdrawAmount = userDetails.amount;
            remaining = 0;
        }

        userDetails.amount = remaining;
        userDetails.phUSDDebt = (userDetails.amount * accPhUSDPerShare) / PRECISION;
        userDetails.stableDebt = (userDetails.amount * accStablePerShare) / PRECISION;
        userDetails.promoDebt = (userDetails.amount * accPromoPerShare) / PRECISION;

        totalStaked -= actualWithdrawAmount;

        // Full exit (including dust-rule forced full exit) leaves the staker set.
        if (remaining == 0) {
            _stakers.remove(user);
        }

        // Transfer phUSD to msg.sender (caller). When the migrator calls on behalf
        // of a user, the migrator wallet receives the tokens.
        IERC20(address(phUSD)).safeTransfer(msg.sender, actualWithdrawAmount);

        _updatePhUSDEmissionRate();

        emit Withdrawn(user, actualWithdrawAmount);

        if (address(hook) != address(0)) {
            hook.onWithdraw(msg.sender, user, actualWithdrawAmount);
        }
    }

    /**
     * @notice Claim pending rewards on behalf of `user` without withdrawing stake
     * @dev Auth: msg.sender == user || msg.sender == migrator. Rewards go to msg.sender.
     */
    function claim(address user) external whenNotPaused nonReentrant {
        require(user != address(0), "Invalid user");
        require(msg.sender == user || msg.sender == migrator, "Not authorized");

        _updatePool();

        // Snapshot claimable amounts BEFORE _claimRewards updates user.debt internally,
        // so we can pass exact amounts to the hook.
        UserInfo storage userDetails = userInfo[user];
        uint256 pendingPhUSDAmount;
        uint256 pendingRewardAmount;
        if (userDetails.amount > 0) {
            pendingPhUSDAmount = (userDetails.amount * accPhUSDPerShare) / PRECISION - userDetails.phUSDDebt;
            pendingRewardAmount = (userDetails.amount * accStablePerShare) / PRECISION - userDetails.stableDebt;
        }

        // Route rewards to msg.sender (caller).
        _claimRewards(user, msg.sender);

        userDetails.phUSDDebt = (userDetails.amount * accPhUSDPerShare) / PRECISION;
        userDetails.stableDebt = (userDetails.amount * accStablePerShare) / PRECISION;
        userDetails.promoDebt = (userDetails.amount * accPromoPerShare) / PRECISION;

        if (address(hook) != address(0)) {
            hook.onClaim(msg.sender, user, pendingPhUSDAmount, pendingRewardAmount);
        }
    }

    // ========================== INTERNAL FUNCTIONS ==========================

    /**
     * @notice Updates pool accumulators based on linear depletion reward rate
     * @dev V2 FIX: does NOT recompute rewardPerSecond here. The recompute lives in
     *      collectReward() and setDepletionDuration() only, so the depletion window
     *      does not silently reset on every user interaction.
     */
    function _updatePool() internal {
        if (block.timestamp <= lastRewardTime) {
            return;
        }

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - lastRewardTime;

        uint256 potentialReward = (rewardPerSecond * timeElapsed) / PRECISION;

        // Cap distribution by rewardBalance to prevent over-distribution
        uint256 toDistribute = potentialReward > rewardBalance ? rewardBalance : potentialReward;

        if (toDistribute > 0) {
            accStablePerShare += (toDistribute * PRECISION) / totalStaked;

            // Decrease rewardBalance by distributed amount
            rewardBalance -= toDistribute;

            // NOTE: V1 used to recompute `rewardPerSecond` here. V2 deliberately does
            // not — that was the bug. Rate is recomputed only in collectReward() and
            // setDepletionDuration().
        }

        // Update phUSD rewards (if phUSDPerSecond is set)
        if (phUSDPerSecond > 0) {
            uint256 phUSDReward = timeElapsed * phUSDPerSecond;
            accPhUSDPerShare += (phUSDReward * PRECISION) / totalStaked;
        }

        // Promo stream: capped linear depletion on the promo's OWN window, mirroring
        // the stable block on separate variables. Skipped when no promotion is set.
        // Rate is NEVER recomputed here (recompute lives only in topUpPromotion and
        // setPromoDepletionDuration — the V2 bug-fix discipline).
        if (address(promoToken) != address(0)) {
            uint256 potentialPromo = (promoRewardPerSecond * timeElapsed) / PRECISION;
            uint256 promoToDistribute =
                potentialPromo > promoRewardBalance ? promoRewardBalance : potentialPromo;

            if (promoToDistribute > 0) {
                accPromoPerShare += (promoToDistribute * PRECISION) / totalStaked;
                promoRewardBalance -= promoToDistribute;
            }
        }

        lastRewardTime = block.timestamp;
    }

    /**
     * @notice Claims pending rewards for `user`, sending them to `beneficiary`.
     * @dev V1 always sent rewards to `user`. In V2 the beneficiary is the caller
     *      (msg.sender) so migrator-delegated calls land rewards in the migrator
     *      wallet. For self-service (caller == user) beneficiary collapses to the
     *      user themselves and behavior matches V1.
     */
    function _claimRewards(address user, address beneficiary) internal {
        UserInfo storage userDetails = userInfo[user];

        if (userDetails.amount == 0) {
            return;
        }

        uint256 pendingPhUSDAmount = (userDetails.amount * accPhUSDPerShare) / PRECISION - userDetails.phUSDDebt;
        if (pendingPhUSDAmount > 0) {
            phUSD.mint(beneficiary, pendingPhUSDAmount);
        }

        uint256 pendingRewardAmount = (userDetails.amount * accStablePerShare) / PRECISION - userDetails.stableDebt;
        if (pendingRewardAmount > 0) {
            rewardToken.safeTransfer(beneficiary, pendingRewardAmount);
        }

        if (pendingPhUSDAmount > 0 || pendingRewardAmount > 0) {
            // Indexed by `user` (whose accrued rewards were drained), matching V1 semantics.
            emit RewardsClaimed(user, pendingPhUSDAmount, pendingRewardAmount);
        }

        // Promo settlement: pay pending promo when a promotion slot is set. When the
        // slot is empty (promoToken == 0), all debts were aligned by the last flush,
        // so pending is zero by construction and only the callers' debt realignment
        // runs. Same beneficiary routing as phUSD/stable (caller during delegation).
        if (address(promoToken) != address(0)) {
            uint256 pendingPromoAmount =
                (userDetails.amount * accPromoPerShare) / PRECISION - userDetails.promoDebt;
            if (pendingPromoAmount > 0) {
                promoToken.safeTransfer(beneficiary, pendingPromoAmount);
                emit PromoClaimed(user, pendingPromoAmount);
            }
        }
    }

    /**
     * @notice Updates phUSD emission rate based on total staked and desired APY
     */
    function _updatePhUSDEmissionRate() internal {
        if (totalStaked == 0) {
            phUSDPerSecond = 0;
            return;
        }

        phUSDPerSecond = (totalStaked * desiredAPYBps) / 10000 / SECONDS_PER_YEAR;
    }

    // ========================== VIEW FUNCTIONS ==========================

    /**
     * @notice Returns pending phUSD rewards for a user
     */
    function pendingPhUSD(address user) external view returns (uint256) {
        UserInfo storage userDetails = userInfo[user];
        uint256 _accPhUSDPerShare = accPhUSDPerShare;

        if (block.timestamp > lastRewardTime && totalStaked != 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 phUSDReward = timeElapsed * phUSDPerSecond;
            _accPhUSDPerShare += (phUSDReward * PRECISION) / totalStaked;
        }

        return (userDetails.amount * _accPhUSDPerShare) / PRECISION - userDetails.phUSDDebt;
    }

    /**
     * @notice Returns pending stable rewards for a user
     */
    function pendingStable(address user) external view returns (uint256) {
        UserInfo storage userDetails = userInfo[user];
        uint256 _accStablePerShare = accStablePerShare;

        if (block.timestamp > lastRewardTime && totalStaked != 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 potentialReward = (rewardPerSecond * timeElapsed) / PRECISION;

            uint256 toDistribute = potentialReward > rewardBalance ? rewardBalance : potentialReward;

            if (toDistribute > 0) {
                _accStablePerShare += (toDistribute * PRECISION) / totalStaked;
            }
        }

        return (userDetails.amount * _accStablePerShare) / PRECISION - userDetails.stableDebt;
    }

    /**
     * @notice Returns pending promo rewards for a user
     */
    function pendingPromo(address user) external view returns (uint256) {
        UserInfo storage userDetails = userInfo[user];
        uint256 _accPromoPerShare = accPromoPerShare;

        if (address(promoToken) != address(0) && block.timestamp > lastRewardTime && totalStaked != 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 potentialPromo = (promoRewardPerSecond * timeElapsed) / PRECISION;

            uint256 promoToDistribute =
                potentialPromo > promoRewardBalance ? promoRewardBalance : potentialPromo;

            if (promoToDistribute > 0) {
                _accPromoPerShare += (promoToDistribute * PRECISION) / totalStaked;
            }
        }

        return (userDetails.amount * _accPromoPerShare) / PRECISION - userDetails.promoDebt;
    }

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
    ) {
        return (
            address(promoToken),
            promoRewardBalance,
            promoRewardPerSecond,
            promoDepletionDuration,
            promoPhase,
            flushCursor
        );
    }

    /**
     * @notice Number of addresses currently in the staker set
     */
    function stakerCount() external view returns (uint256) {
        return _stakers.length();
    }

    /**
     * @notice Staker address at `index` in the staker set
     */
    function stakerAt(uint256 index) external view returns (address) {
        return _stakers.at(index);
    }

    /**
     * @notice Returns current pool information
     */
    function getPoolInfo() external view returns (
        uint256 _totalStaked,
        uint256 _accPhUSDPerShare,
        uint256 _accStablePerShare,
        uint256 _phUSDPerSecond,
        uint256 _lastRewardTime
    ) {
        return (
            totalStaked,
            accPhUSDPerShare,
            accStablePerShare,
            phUSDPerSecond,
            lastRewardTime
        );
    }

    /**
     * @notice Returns information about pending APY setting operation
     */
    function getPendingAPYInfo() external view returns (
        uint256 _pendingAPYBps,
        uint256 _pendingAPYBlockNumber,
        bool _apySetInProgress
    ) {
        return (
            pendingAPYBps,
            pendingAPYBlockNumber,
            apySetInProgress
        );
    }
}
