// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@reflax-yield-vault/src/interfaces/IYieldStrategy.sol";
import "@flax-token/src/IFlax.sol";
import "./IEYE.sol";

/**
 * @title PhlimboEA
 * @notice Staking yield farm for phUSD tokens with dynamic APY based on YieldStrategy performance
 * @dev Integrates with YieldStrategy for stable token yield and mints phUSD rewards based on APY targets
 */
contract PhlimboEA is Ownable, Pausable {
    // ========================== STATE VARIABLES ==========================

    /// @notice The yield strategy adapter for managing external vault deposits
    IYieldStrategy public yieldStrategy;

    /// @notice phUSD token - used for staking and rewards
    IFlax public phUSD;

    /// @notice External stablecoin token distributed as rewards
    IERC20 public stable;

    /// @notice Minter address used for querying YieldStrategy principal
    address public minter;

    /// @notice EYE token required for emergency pause mechanism
    IERC20 public eye;

    /// @notice Desired APY in basis points (e.g., 500 = 5%)
    uint256 public desiredAPYBps;

    /// @notice Current phUSD emission rate per second
    uint256 public phUSDPerSecond;

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

    /// @notice Amount of EYE required to pause the contract
    uint256 public constant PAUSE_EYE_COST = 1000 ether;

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

    // ========================== CONSTRUCTOR ==========================

    /**
     * @notice Initializes the Phlimbo staking contract
     * @param _yieldStrategy Address of the YieldStrategy contract
     * @param _phUSD Address of the phUSD token
     * @param _stable Address of the stable token for rewards
     * @param _minter Address used for querying YieldStrategy
     * @param _eye Address of the EYE token for pause mechanism
     */
    constructor(
        address _yieldStrategy,
        address _phUSD,
        address _stable,
        address _minter,
        address _eye
    ) Ownable(msg.sender) {
        yieldStrategy = IYieldStrategy(_yieldStrategy);
        phUSD = IFlax(_phUSD);
        stable = IERC20(_stable);
        minter = _minter;
        eye = IERC20(_eye);
        lastRewardTime = block.timestamp;
    }

    // ========================== ADMIN FUNCTIONS ==========================

    /**
     * @notice Updates the desired APY and recalculates emission rate
     * @param bps New APY in basis points
     */
    function setDesiredAPY(uint256 bps) external onlyOwner {
        _updatePool();
        desiredAPYBps = bps;
        phUSDPerSecond = _calculatePhUSDPerSecond();
    }

    /**
     * @notice Unpauses the contract (only owner)
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency function to transfer all tokens to a recipient
     * @param recipient Address to receive the tokens
     */
    function emergencyTransfer(address recipient) external onlyOwner {
        uint256 phUSDBalance = phUSD.balanceOf(address(this));
        uint256 stableBalance = stable.balanceOf(address(this));

        if (phUSDBalance > 0) {
            phUSD.transfer(recipient, phUSDBalance);
        }
        if (stableBalance > 0) {
            stable.transfer(recipient, stableBalance);
        }
    }

    // ========================== PAUSE MECHANISM ==========================

    /**
     * @notice Pauses the contract by burning EYE tokens
     * @dev Requires caller to have 1000 EYE tokens which will be burned
     */
    function pause() public {
        // Transfer EYE from caller
        eye.transferFrom(msg.sender, address(this), PAUSE_EYE_COST);

        // Burn the EYE tokens
        IEYE(address(eye)).burn(PAUSE_EYE_COST);

        // Pause the contract
        _pause();
    }

    // ========================== CORE STAKING FUNCTIONS ==========================

    /**
     * @notice Stake phUSD tokens
     * @param amount Amount of phUSD to stake
     */
    function stake(uint256 amount) external whenNotPaused {
        _updatePool();

        UserInfo storage user = userInfo[msg.sender];

        // Claim any pending rewards first
        if (user.amount > 0) {
            _claimRewards(msg.sender);
        }

        // Transfer phUSD from user
        phUSD.transferFrom(msg.sender, address(this), amount);

        // Update user info
        user.amount += amount;
        user.phUSDDebt = (user.amount * accPhUSDPerShare) / PRECISION;
        user.stableDebt = (user.amount * accStablePerShare) / PRECISION;

        // Update total staked
        totalStaked += amount;
    }

    /**
     * @notice Withdraw staked phUSD and claim rewards
     * @param amount Amount of phUSD to withdraw
     */
    function withdraw(uint256 amount) external whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Insufficient balance");

        _updatePool();

        // Claim pending rewards
        _claimRewards(msg.sender);

        // Update user info
        user.amount -= amount;
        user.phUSDDebt = (user.amount * accPhUSDPerShare) / PRECISION;
        user.stableDebt = (user.amount * accStablePerShare) / PRECISION;

        // Update total staked
        totalStaked -= amount;

        // Transfer phUSD back to user
        phUSD.transfer(msg.sender, amount);
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
     * @notice Updates pool accumulators and emission rate
     */
    function _updatePool() internal {
        if (block.timestamp <= lastRewardTime) {
            return;
        }

        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        // Harvest stable yield from YieldStrategy
        _harvestStable();

        // Calculate time elapsed
        uint256 timeElapsed = block.timestamp - lastRewardTime;

        // Update phUSD rewards
        uint256 phUSDReward = timeElapsed * phUSDPerSecond;
        accPhUSDPerShare += (phUSDReward * PRECISION) / totalStaked;

        // Recalculate emission rate based on current YieldStrategy state
        phUSDPerSecond = _calculatePhUSDPerSecond();

        lastRewardTime = block.timestamp;
    }

    /**
     * @notice Harvests stable yield from YieldStrategy
     */
    function _harvestStable() internal {
        // STUB: In red phase, this does nothing
        // Green phase will implement actual yield harvesting logic
    }

    /**
     * @notice Calculates phUSD emission rate based on APY and total principal
     * @return Emission rate in phUSD per second
     */
    function _calculatePhUSDPerSecond() internal view returns (uint256) {
        // STUB: Returns 0 in red phase
        // Green phase will query YieldStrategy for totalPrincipal and calculate emission
        return 0;
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
            // STUB: In red phase, this doesn't actually mint
            // Green phase will: phUSD.mint(user, pendingPhUSDAmount);
        }

        // Calculate pending stable
        uint256 pendingStableAmount = (userDetails.amount * accStablePerShare) / PRECISION - userDetails.stableDebt;
        if (pendingStableAmount > 0) {
            // STUB: In red phase, this doesn't actually transfer
            // Green phase will: stable.transfer(user, pendingStableAmount);
        }
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
        return (userDetails.amount * accStablePerShare) / PRECISION - userDetails.stableDebt;
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
