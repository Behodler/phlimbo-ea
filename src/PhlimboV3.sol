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
 *                requires `flushCursor == _stakers.length()`. `accPromoPerShare`
 *                itself is frozen during `Flushing` by `_updatePool`'s phase gate
 *                (NOT by the pause — `collectReward` and the owner setters are
 *                not `whenNotPaused`), so aligned debts stay aligned.
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
    ///      non-zero would underflow `amount * acc - debt`. Frozen while
    ///      `promoPhase == Flushing` (via `_updatePool`'s phase gate), keeping
    ///      `batchClaim`'s debt alignment valid for the whole flush window.
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

    /// @notice token => user => promo amount banked when a flush transfer to that
    ///         user failed (audit-08 M-01). Pulled permissionlessly via
    ///         `claimUnclaimablePromo`; reserved from the `finalizePromotion` sweep.
    ///         Keyed by token because the promo slot rotates — a retired token's
    ///         bank survives into later promotions.
    mapping(address => mapping(address => uint256)) public unclaimablePromoOf;

    /// @notice token => total promo still banked and unclaimed across all users.
    ///         Incremented alongside `unclaimablePromoOf` in `batchClaim`,
    ///         decremented by exactly the pulled amount in `claimUnclaimablePromo`
    ///         (never zeroed wholesale — it spans all users), and reserved from the
    ///         `finalizePromotion` sweep so banked entitlements are never swept.
    mapping(address => uint256) public totalUnclaimableOf;

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
    constructor(address _phUSD, address _rewardToken, uint256 _depletionDuration) Ownable(msg.sender) {
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
        bool isPreview = !apySetInProgress || block.number > pendingAPYBlockNumber + 100 || bps != pendingAPYBps;

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
     *      Reverts while a flush is in progress — the only exits from Flushing are
     *      finalizePromotion or abortFlush, so no path exists where users transact
     *      against a half-rotated promo slot.
     */
    function unpause() public override {
        require(msg.sender == pauser || msg.sender == owner(), "Only pauser or owner can unpause");
        require(promoPhase != PromoPhase.Flushing, "Cannot unpause while flushing");
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
     * @dev V3: also sweeps the promo token when a promotion slot is set.
     *
     *      Trade-off (audit-08 M-01): this sweeps the LIVE promo token's entire
     *      balance, INCLUDING any per-user banked amounts (`unclaimablePromoOf`) —
     *      an accepted escape-hatch trade-off mirroring `MigratorV2V3.withdrawAll`;
     *      making users whole after such a sweep is an out-of-band owner
     *      obligation. Note the asymmetry with `finalizePromotion`, which is a
     *      routine lifecycle step and must NOT sweep the bank. A RETIRED token's
     *      bank (promoToken == address(0) for it) is unreachable here and stays
     *      pullable via `claimUnclaimablePromo`.
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
        if (address(promoToken) != address(0)) {
            uint256 promoBalance = promoToken.balanceOf(address(this));
            if (promoBalance > 0) {
                promoToken.safeTransfer(recipient, promoBalance);
            }
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
        require(token != address(0) && token != address(phUSD) && token != address(rewardToken), "Invalid promo token");
        require(amount > 0, "Amount must be greater than 0");
        require(duration > 0, "Duration must be > 0");

        // Advance shared lastRewardTime before the promo slot exists so the new
        // stream starts accruing strictly from now.
        _updatePool();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(token).balanceOf(address(this)) - balanceBefore == amount, "Fee-on-transfer not supported");

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
        require(promoToken.balanceOf(address(this)) - balanceBefore == amount, "Fee-on-transfer not supported");

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

    // ========================== PROMO ROTATION (FLUSH) ==========================

    /**
     * @notice Begins the rotation flush: final promo accrual up to now, then pause.
     *         Phase Active → Flushing.
     * @dev Pausing blocks all whenNotPaused ops, so from this point every user's
     *      amount (except pauseWithdraw, which realigns debts) and the
     *      staker set are frozen. accPromoPerShare is frozen NOT by the pause but
     *      by _updatePool's Flushing phase gate — collectReward and the owner
     *      setters reach _updatePool while paused. `_pause()` reverts if already
     *      paused — a flush cannot be started over an unrelated pause.
     */
    function beginFlush() external onlyOwner {
        require(promoPhase == PromoPhase.Active, "Promo phase must be Active");

        _updatePool();
        _pause();

        flushCursor = 0;
        promoPhase = PromoPhase.Flushing;
    }

    /**
     * @notice Processes up to `maxIterations` stakers from the flush cursor: pays each
     *         staker's pending promo TO THE STAKER DIRECTLY (forced claim — beneficiary
     *         is the user, unlike the V2 caller-routing of ordinary claims) and aligns
     *         their promoDebt to the current accumulator.
     * @dev Permissionless: recipients and amounts are fixed by state, so anyone may
     *      help complete a flush. Failed transfers (e.g. blocklisted recipients) are
     *      banked per-user into `unclaimablePromoOf[token][staker]` (audit-08 M-01)
     *      for later pull via `claimUnclaimablePromo` — the flush must never brick.
     *      Touches ONLY promo state; stable/phUSD pendings are untouched.
     */
    function batchClaim(uint256 maxIterations) external nonReentrant {
        require(promoPhase == PromoPhase.Flushing, "Promo phase must be Flushing");

        uint256 len = _stakers.length();
        uint256 cursor = flushCursor;
        uint256 end = cursor + maxIterations;
        if (end > len) {
            end = len;
        }

        for (; cursor < end; cursor++) {
            address staker = _stakers.at(cursor);
            UserInfo storage userDetails = userInfo[staker];

            uint256 pending = (userDetails.amount * accPromoPerShare) / PRECISION - userDetails.promoDebt;

            // Align the debt unconditionally: the next promotion continues on the
            // same accumulator, so every debt must sit exactly at it (§2.1).
            userDetails.promoDebt = (userDetails.amount * accPromoPerShare) / PRECISION;

            if (pending > 0) {
                if (_tryTransfer(promoToken, staker, pending)) {
                    emit PromoClaimed(staker, pending);
                } else {
                    // Per-user bank (audit-08 M-01): the debt is already aligned
                    // above, so without this record the entitlement would be erased
                    // (pendingPromo reads 0 forever). Banked amounts are reserved
                    // from the finalizePromotion sweep and recovered via the
                    // permissionless claimUnclaimablePromo pull.
                    unclaimablePromoOf[address(promoToken)][staker] += pending;
                    totalUnclaimableOf[address(promoToken)] += pending;
                    emit PromoClaimFailed(address(promoToken), staker, pending);
                }
            }
        }

        flushCursor = cursor;
        emit FlushProgress(cursor, len);
    }

    /**
     * @notice Finalizes the rotation: requires full cursor coverage of the frozen
     *         staker set. Sweeps only the UNENCUMBERED promo token balance
     *         (undistributed remainder + rounding dust + pauseWithdraw forfeits) to
     *         `leftoverRecipient`; per-user banked amounts (`totalUnclaimableOf`)
     *         are reserved and survive the rotation (audit-08 M-01).
     *         Phase Flushing → None; owner then unpauses.
     * @dev `accPromoPerShare` is deliberately NOT reset (§2.1): all debts were aligned
     *      to it by the flush, so pending against the next token starts at exactly
     *      zero. Zeroing it while debts are non-zero would underflow amount*acc − debt.
     *
     *      Forfeit-sweep vs bank-retain (audit-08 M-01): `pauseWithdraw` forfeits
     *      realign the debt with NOTHING banked — those tokens are legitimately
     *      swept here as leftover. Failed flush transfers, by contrast, are banked
     *      per-user in `batchClaim` and reserved from this sweep via
     *      `totalUnclaimableOf`; they belong to users, not to `leftoverRecipient`.
     *
     *      The subtraction saturates deliberately: even under accounting drift this
     *      function must never revert — stranding some leftover is preferable to
     *      pinning the contract in `Flushing` forever.
     */
    function finalizePromotion(address leftoverRecipient) external onlyOwner {
        require(promoPhase == PromoPhase.Flushing, "Promo phase must be Flushing");
        require(flushCursor == _stakers.length(), "Flush incomplete");
        require(leftoverRecipient != address(0), "Invalid recipient");

        IERC20 retiredToken = promoToken;
        uint256 banked = totalUnclaimableOf[address(retiredToken)];
        uint256 balance = retiredToken.balanceOf(address(this));
        uint256 leftover = balance > banked ? balance - banked : 0;
        if (leftover > 0) {
            retiredToken.safeTransfer(leftoverRecipient, leftover);
        }

        promoToken = IERC20(address(0));
        promoRewardPerSecond = 0;
        promoRewardBalance = 0;
        // NOTE: totalUnclaimableOf / unclaimablePromoOf are deliberately NOT cleared
        // — the bank survives the rotation and remains pullable (audit-08 M-01).
        promoPhase = PromoPhase.None;

        emit PromotionFinalized(address(retiredToken), leftoverRecipient, leftover);
    }

    /**
     * @notice Aborts an in-progress flush, returning to Active; owner may then unpause.
     * @dev Always safe: batchClaim is just early forced claims with debts correctly
     *      aligned, so a partial flush leaves fully consistent state.
     */
    function abortFlush() external onlyOwner {
        require(promoPhase == PromoPhase.Flushing, "Promo phase must be Flushing");
        promoPhase = PromoPhase.Active;
    }

    // ========================== PROMO BANK (PERMISSIONLESS PULL) ==========================

    /**
     * @notice Pulls the caller's banked promo for `token` — the amount recorded when
     *         a flush transfer to them failed (audit-08 M-01). Permissionless and
     *         callable at any time, including for tokens retired by rotation.
     * @dev Deliberately NOT `whenNotPaused`: `beginFlush` pauses the contract, so a
     *      gate would lock a blocked-then-unblocked staker out of self-rescue for
     *      the whole flush window. Matches `MigratorV2V3.claimUnclaimable` and the
     *      deliberately-ungated `batchClaim`. Uses a reverting `safeTransfer` (not
     *      `_tryTransfer`): a user-initiated pull that fails while the caller is
     *      still blocked SHOULD revert, leaving the bank intact. Both state writes
     *      precede the transfer (checks-effects-interactions); `totalUnclaimableOf`
     *      is decremented by exactly `amount` — it spans all users, so it must never
     *      be zeroed on a single user's claim.
     * @param token The promo token (live or retired) whose bank is being pulled
     */
    function claimUnclaimablePromo(address token) external nonReentrant {
        uint256 amount = unclaimablePromoOf[token][msg.sender];
        require(amount > 0, "Nothing to claim");
        unclaimablePromoOf[token][msg.sender] = 0;
        totalUnclaimableOf[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit UnclaimablePromoClaimed(token, msg.sender, amount);
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
        //
        // Phase gate (audit-07 H-01): the accumulator freeze during Flushing is an
        // ACCRUAL property, not a pause property, so it is enforced here at the
        // accrual site rather than with `whenNotPaused` on the callers. Three paths
        // reach _updatePool while paused — permissionless collectReward, plus the
        // owner setters setDesiredAPY (commit branch) and setDepletionDuration —
        // and any of them would otherwise advance accPromoPerShare after batchClaim
        // has aligned every promoDebt, minting phantom pending that survives
        // finalizePromotion and is claimable against the NEXT promo's token (§2.1).
        // Gating here closes all three paths at once and is future-proof against
        // new call sites. beginFlush's own final accrual is unaffected: it calls
        // _updatePool while promoPhase is still Active.
        if (address(promoToken) != address(0) && promoPhase != PromoPhase.Flushing) {
            uint256 potentialPromo = (promoRewardPerSecond * timeElapsed) / PRECISION;
            uint256 promoToDistribute = potentialPromo > promoRewardBalance ? promoRewardBalance : potentialPromo;

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
            uint256 pendingPromoAmount = (userDetails.amount * accPromoPerShare) / PRECISION - userDetails.promoDebt;
            if (pendingPromoAmount > 0) {
                promoToken.safeTransfer(beneficiary, pendingPromoAmount);
                emit PromoClaimed(user, pendingPromoAmount);
            }
        }
    }

    /**
     * @notice Non-reverting ERC20 transfer used by the flush: a single blocklisted or
     *         otherwise reverting recipient must not brick batchClaim.
     * @return success True if the transfer succeeded (call succeeded and returned
     *         either nothing or true).
     */
    function _tryTransfer(IERC20 token, address to, uint256 amount) internal returns (bool success) {
        (bool callSuccess, bytes memory returndata) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return callSuccess && (returndata.length == 0 || abi.decode(returndata, (bool)));
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
     * @dev Returns 0 for users whose flush transfer failed and was banked — BY
     *      DESIGN (audit-08 M-01): `batchClaim` aligns `promoDebt` unconditionally
     *      (§2.1 cross-promotion non-contamination requires it), so banked recovery
     *      is surfaced via `unclaimablePromoOf` / `totalUnclaimableOf`, never here.
     *      Do NOT "fix" this by un-aligning the debt.
     */
    function pendingPromo(address user) external view returns (uint256) {
        UserInfo storage userDetails = userInfo[user];
        uint256 _accPromoPerShare = accPromoPerShare;

        // Mirrors _updatePool's phase gate (audit-07 H-01): during Flushing the
        // accumulator is frozen, so the view must not project accrual either.
        if (
            address(promoToken) != address(0) && promoPhase != PromoPhase.Flushing && block.timestamp > lastRewardTime
                && totalStaked != 0
        ) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 potentialPromo = (promoRewardPerSecond * timeElapsed) / PRECISION;

            uint256 promoToDistribute = potentialPromo > promoRewardBalance ? promoRewardBalance : potentialPromo;

            if (promoToDistribute > 0) {
                _accPromoPerShare += (promoToDistribute * PRECISION) / totalStaked;
            }
        }

        return (userDetails.amount * _accPromoPerShare) / PRECISION - userDetails.promoDebt;
    }

    /**
     * @notice Returns current promotional slot information
     */
    function getPromoInfo()
        external
        view
        returns (
            address _promoToken,
            uint256 _promoRewardBalance,
            uint256 _promoRewardPerSecond,
            uint256 _promoDepletionDuration,
            PromoPhase _promoPhase,
            uint256 _flushCursor
        )
    {
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
    function getPoolInfo()
        external
        view
        returns (
            uint256 _totalStaked,
            uint256 _accPhUSDPerShare,
            uint256 _accStablePerShare,
            uint256 _phUSDPerSecond,
            uint256 _lastRewardTime
        )
    {
        return (totalStaked, accPhUSDPerShare, accStablePerShare, phUSDPerSecond, lastRewardTime);
    }

    /**
     * @notice Returns information about pending APY setting operation
     */
    function getPendingAPYInfo()
        external
        view
        returns (uint256 _pendingAPYBps, uint256 _pendingAPYBlockNumber, bool _apySetInProgress)
    {
        return (pendingAPYBps, pendingAPYBlockNumber, apySetInProgress);
    }
}
