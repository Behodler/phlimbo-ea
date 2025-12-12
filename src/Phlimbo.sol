// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IFlax.sol";
import "./interfaces/IPhlimbo.sol";

/**
 * @title PhlimboEA
 * @notice Staking yield farm for phUSD tokens with EMA-smoothed reward distribution
 * @dev Receives rewards from yield-accumulator contract and distributes them smoothly using EMA algorithm
 */
contract PhlimboEA is Ownable, Pausable, IPhlimbo {
    using SafeERC20 for IERC20;

    // ========================== STATE VARIABLES ==========================

    /// @notice phUSD token - used for staking and rewards
    IFlax public phUSD;

    /// @notice External stablecoin token distributed as rewards (received from yield-accumulator)
    IERC20 public rewardToken;

    /// @notice Address of the yield accumulator contract authorized to call collectReward
    address public yieldAccumulator;

    /// @notice Address authorized to pause the contract
    address public pauser;

    /// @notice Desired APY in basis points (e.g., 500 = 5%)
    uint256 public desiredAPYBps;

    /// @notice Current phUSD emission rate per second
    uint256 public phUSDPerSecond;

    /// @notice Timestamp of last reward collection from yield-accumulator
    uint256 public lastClaimTimestamp;

    /// @notice EMA-smoothed stable reward rate per second (scaled by PRECISION)
    uint256 public smoothedStablePerSecond;

    /// @notice EMA alpha parameter for smoothing (scaled by PRECISION, e.g., 0.1e18 = 10% weight on new rate)
    uint256 public alpha;

    /// @notice Timestamp of last reward update
    uint256 public lastRewardTime;

    /// @notice Accumulated phUSD rewards per share (scaled by PRECISION)
    uint256 public accPhUSDPerShare;

    /// @notice Accumulated stable rewards per share (scaled by PRECISION)
    uint256 public accStablePerShare;

    /// @notice Total amount of phUSD staked in the contract
    uint256 public totalStaked;

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
     * @param amount The amount of phUSD staked by the user
     * @param phUSDDebt The reward debt for phUSD rewards
     * @param stableDebt The reward debt for stable rewards
     */
    struct UserInfo {
        uint256 amount;
        uint256 phUSDDebt;
        uint256 stableDebt;
    }

    // ========================== MAPPINGS ==========================

    /// @notice Mapping of user address to their staking information
    mapping(address => UserInfo) public userInfo;

    // ========================== EVENTS ==========================

    /// @notice Emitted when rewards are collected from yield-accumulator
    event RewardCollected(uint256 amount, uint256 instantRate, uint256 newSmoothedRate);

    /// @notice Emitted when yield accumulator address is updated
    event YieldAccumulatorUpdated(address indexed oldAccumulator, address indexed newAccumulator);

    /// @notice Emitted when alpha parameter is updated
    event AlphaUpdated(uint256 oldAlpha, uint256 newAlpha);

    // ========================== CONSTRUCTOR ==========================

    /**
     * @notice Initializes the Phlimbo staking contract
     * @param _phUSD Address of the phUSD token
     * @param _rewardToken Address of the stable token for rewards (received from yield-accumulator)
     * @param _yieldAccumulator Address of the yield accumulator contract
     * @param _alpha EMA alpha parameter (scaled by 1e18, e.g., 0.1e18 = 10%)
     */
    constructor(
        address _phUSD,
        address _rewardToken,
        address _yieldAccumulator,
        uint256 _alpha
    ) Ownable(msg.sender) {
        require(_phUSD != address(0), "Invalid phUSD address");
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_yieldAccumulator != address(0), "Invalid yield accumulator address");
        require(_alpha > 0 && _alpha <= PRECISION, "Alpha must be between 0 and 1e18");

        phUSD = IFlax(_phUSD);
        rewardToken = IERC20(_rewardToken);
        yieldAccumulator = _yieldAccumulator;
        alpha = _alpha;
        lastRewardTime = block.timestamp;
        lastClaimTimestamp = 0; // Initialize to 0 to allow first claim
        smoothedStablePerSecond = 0; // Will converge after first few claims
    }

    // ========================== ADMIN FUNCTIONS ==========================

    /**
     * @notice Updates the desired APY and recalculates emission rate
     * @param bps New APY in basis points
     */
    function setDesiredAPY(uint256 bps) external onlyOwner {
        _updatePool();
        desiredAPYBps = bps;
        _updatePhUSDEmissionRate();
    }

    /**
     * @notice Sets the yield accumulator address
     * @param _yieldAccumulator New yield accumulator address
     */
    function setYieldAccumulator(address _yieldAccumulator) external onlyOwner {
        require(_yieldAccumulator != address(0), "Invalid address");
        address oldAccumulator = yieldAccumulator;
        yieldAccumulator = _yieldAccumulator;
        emit YieldAccumulatorUpdated(oldAccumulator, _yieldAccumulator);
    }

    /**
     * @notice Sets the EMA alpha parameter
     * @param _alpha New alpha value (scaled by 1e18)
     */
    function setAlpha(uint256 _alpha) external onlyOwner {
        require(_alpha > 0 && _alpha <= PRECISION, "Alpha must be between 0 and 1e18");
        uint256 oldAlpha = alpha;
        alpha = _alpha;
        emit AlphaUpdated(oldAlpha, _alpha);
    }

    /**
     * @notice Unpauses the contract (only owner)
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @notice Sets the address authorized to pause the contract
     * @param _pauser Address to authorize for pausing (can be zero address to disable pausing)
     */
    function setPauser(address _pauser) external onlyOwner {
        pauser = _pauser;
    }

    /**
     * @notice Emergency function to transfer all tokens to a recipient
     * @param recipient Address to receive the tokens
     */
    function emergencyTransfer(address recipient) external onlyOwner {
        uint256 phUSDBalance = phUSD.balanceOf(address(this));
        uint256 rewardBalance = rewardToken.balanceOf(address(this));

        if (phUSDBalance > 0) {
            IERC20(address(phUSD)).safeTransfer(recipient, phUSDBalance);
        }
        if (rewardBalance > 0) {
            rewardToken.safeTransfer(recipient, rewardBalance);
        }
    }

    // ========================== PAUSE MECHANISM ==========================

    /**
     * @notice Pauses the contract
     * @dev Can only be called by the designated pauser address
     */
    function pause() public {
        require(msg.sender == pauser, "Only pauser can pause");
        _pause();
    }

    // ========================== REWARD COLLECTION ==========================

    /**
     * @notice Collects rewards from yield-accumulator and updates EMA-smoothed rate
     * @dev Can only be called by the yield accumulator contract
     * @param amount Amount of reward tokens to collect
     */
    function collectReward(uint256 amount) external {
        require(msg.sender == yieldAccumulator, "Only yield accumulator can call");
        require(amount > 0, "Amount must be greater than 0");
        require(block.timestamp > lastClaimTimestamp, "Cannot claim in same block");

        // Pull tokens from yield-accumulator
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate time delta since last claim
        uint256 deltaTime = block.timestamp - lastClaimTimestamp;

        // Calculate instant rate with 1e18 precision
        uint256 instantRate = (amount * PRECISION) / deltaTime;

        // Update smoothed rate using EMA formula
        // smoothedStablePerSecond = (alpha * instantRate + (1e18 - alpha) * smoothedStablePerSecond) / 1e18
        if (smoothedStablePerSecond == 0) {
            // First claim - initialize with instant rate
            smoothedStablePerSecond = instantRate;
        } else {
            uint256 alphaWeight = (alpha * instantRate) / PRECISION;
            uint256 historyWeight = ((PRECISION - alpha) * smoothedStablePerSecond) / PRECISION;
            smoothedStablePerSecond = alphaWeight + historyWeight;
        }

        // Update last claim timestamp
        lastClaimTimestamp = block.timestamp;

        // Update pool to accrue rewards based on new rate
        _updatePool();

        emit RewardCollected(amount, instantRate, smoothedStablePerSecond);
    }

    // ========================== CORE STAKING FUNCTIONS ==========================

    /**
     * @notice Stake phUSD tokens
     * @param amount Amount of phUSD to stake
     */
    function stake(uint256 amount) external whenNotPaused {
        require(amount >= MINIMUM_STAKE, "Below minimum stake");

        _updatePool();

        UserInfo storage user = userInfo[msg.sender];

        // Claim any pending rewards first
        if (user.amount > 0) {
            _claimRewards(msg.sender);
        }

        // Transfer phUSD from user
        IERC20(address(phUSD)).safeTransferFrom(msg.sender, address(this), amount);

        // Update user info
        user.amount += amount;
        user.phUSDDebt = (user.amount * accPhUSDPerShare) / PRECISION;
        user.stableDebt = (user.amount * accStablePerShare) / PRECISION;

        // Update total staked
        totalStaked += amount;

        // Update phUSD emission rate based on new total staked
        _updatePhUSDEmissionRate();
    }

    /**
     * @notice Withdraw staked phUSD and claim rewards
     * @param amount Amount of phUSD to withdraw
     */
    function withdraw(uint256 amount) external whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Insufficient balance");

        _updatePool();

        // Claim pending rewards (uses original user.amount before adjustment)
        _claimRewards(msg.sender);

        // Calculate remaining balance after withdrawal
        uint256 remaining = user.amount - amount;

        // Prevent dust: if remaining would be > 0 but < MINIMUM_STAKE, force full withdrawal
        uint256 actualWithdrawAmount = amount;
        if (remaining > 0 && remaining < MINIMUM_STAKE) {
            actualWithdrawAmount = user.amount;
            remaining = 0;
        }

        // Update user info
        user.amount = remaining;
        user.phUSDDebt = (user.amount * accPhUSDPerShare) / PRECISION;
        user.stableDebt = (user.amount * accStablePerShare) / PRECISION;

        // Update total staked
        totalStaked -= actualWithdrawAmount;

        // Transfer phUSD back to user
        IERC20(address(phUSD)).safeTransfer(msg.sender, actualWithdrawAmount);

        // Update phUSD emission rate based on new total staked
        _updatePhUSDEmissionRate();
    }

    /**
     * @notice Claim pending rewards without withdrawing stake
     */
    function claim() external whenNotPaused {
        _updatePool();
        _claimRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        user.phUSDDebt = (user.amount * accPhUSDPerShare) / PRECISION;
        user.stableDebt = (user.amount * accStablePerShare) / PRECISION;
    }

    // ========================== INTERNAL FUNCTIONS ==========================

    /**
     * @notice Updates pool accumulators based on EMA-smoothed reward rate
     * @dev Accrues stable rewards based on smoothedStablePerSecond, capped by actual pot balance
     */
    function _updatePool() internal {
        if (block.timestamp <= lastRewardTime) {
            return;
        }

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        // Calculate time elapsed since last update
        uint256 timeElapsed = block.timestamp - lastRewardTime;

        // Calculate potential stable reward based on smoothed rate
        uint256 potentialReward = (smoothedStablePerSecond * timeElapsed) / PRECISION;

        // Get current pot balance (reward tokens in contract)
        uint256 potBalance = rewardToken.balanceOf(address(this));

        // If rewardToken is the same as phUSD (staked token), subtract staked amount
        if (address(rewardToken) == address(phUSD)) {
            if (potBalance > totalStaked) {
                potBalance -= totalStaked;
            } else {
                potBalance = 0;
            }
        }

        // Cap distribution by actual pot balance to prevent over-distribution
        uint256 toDistribute = potentialReward > potBalance ? potBalance : potentialReward;

        // Update accumulated stable per share
        if (toDistribute > 0) {
            accStablePerShare += (toDistribute * PRECISION) / totalStaked;
        }

        // Update phUSD rewards (if phUSDPerSecond is set)
        if (phUSDPerSecond > 0) {
            uint256 phUSDReward = timeElapsed * phUSDPerSecond;
            accPhUSDPerShare += (phUSDReward * PRECISION) / totalStaked;
        }

        lastRewardTime = block.timestamp;
    }

    /**
     * @notice Claims pending rewards for a user
     * @param user Address of the user
     */
    function _claimRewards(address user) internal {
        UserInfo storage userDetails = userInfo[user];

        if (userDetails.amount == 0) {
            return;
        }

        // Calculate pending phUSD
        uint256 pendingPhUSDAmount = (userDetails.amount * accPhUSDPerShare) / PRECISION - userDetails.phUSDDebt;
        if (pendingPhUSDAmount > 0) {
            phUSD.mint(user, pendingPhUSDAmount);
        }

        // Calculate pending reward tokens (stable)
        uint256 pendingRewardAmount = (userDetails.amount * accStablePerShare) / PRECISION - userDetails.stableDebt;
        if (pendingRewardAmount > 0) {
            rewardToken.safeTransfer(user, pendingRewardAmount);
        }
    }

    /**
     * @notice Updates phUSD emission rate based on total staked and desired APY
     * @dev Formula: phUSDPerSecond = (totalStaked * desiredAPYBps) / 10000 / SECONDS_PER_YEAR
     */
    function _updatePhUSDEmissionRate() internal {
        if (totalStaked == 0) {
            phUSDPerSecond = 0;
            return;
        }

        // Calculate phUSD emission rate
        // phUSDPerSecond = (totalStaked * desiredAPYBps) / 10000 / SECONDS_PER_YEAR
        phUSDPerSecond = (totalStaked * desiredAPYBps) / 10000 / SECONDS_PER_YEAR;
    }

    // ========================== VIEW FUNCTIONS ==========================

    /**
     * @notice Returns pending phUSD rewards for a user
     * @param user Address to check
     * @return Pending phUSD amount
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
     * @param user Address to check
     * @return Pending stable amount
     */
    function pendingStable(address user) external view returns (uint256) {
        UserInfo storage userDetails = userInfo[user];
        uint256 _accStablePerShare = accStablePerShare;

        if (block.timestamp > lastRewardTime && totalStaked != 0) {
            uint256 timeElapsed = block.timestamp - lastRewardTime;
            uint256 potentialReward = (smoothedStablePerSecond * timeElapsed) / PRECISION;

            // Get pot balance and cap distribution
            uint256 potBalance = rewardToken.balanceOf(address(this));

            // Cap by available balance
            uint256 toDistribute = potentialReward > potBalance ? potBalance : potentialReward;

            if (toDistribute > 0) {
                _accStablePerShare += (toDistribute * PRECISION) / totalStaked;
            }
        }

        return (userDetails.amount * _accStablePerShare) / PRECISION - userDetails.stableDebt;
    }

    /**
     * @notice Returns current pool information
     * @return _totalStaked Total staked amount
     * @return _accPhUSDPerShare Accumulated phUSD per share
     * @return _accStablePerShare Accumulated stable per share
     * @return _phUSDPerSecond Current emission rate
     * @return _lastRewardTime Last update time
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
}
