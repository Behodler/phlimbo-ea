// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IMainRewarder
 * @notice Interface for Tokemak's MainRewarder contract that handles TOKE reward staking
 * @dev Used for staking autoDOLA vault shares to earn TOKE rewards
 */
interface IMainRewarder {
    /**
     * @notice Stake vault shares to earn TOKE rewards
     * @param account The address of the account staking
     * @param amount The amount of vault shares to stake
     */
    function stake(address account, uint256 amount) external;

    /**
     * @notice Unstake vault shares and stop earning TOKE rewards
     * @param account The address of the account unstaking
     * @param amount The amount of vault shares to unstake
     * @param claim Whether to claim pending rewards during withdrawal
     */
    function withdraw(address account, uint256 amount, bool claim) external;

    /**
     * @notice Get the reward earned by a user
     * @param account The address of the account
     * @return The amount of TOKE rewards earned
     */
    function earned(address account) external view returns (uint256);

    /**
     * @notice Claim all earned TOKE rewards
     * @param account The address of the account claiming rewards
     * @param recipient The address that will receive the claimed rewards
     * @param claimExtras Whether to claim extra rewards from linked contracts
     * @return success True if the reward claim was successful
     */
    function getReward(address account, address recipient, bool claimExtras) external returns (bool success);

    /**
     * @notice Get the staked balance of a user
     * @param account The address of the account
     * @return The amount of shares staked by the account
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Get the total supply of staked shares
     * @return The total amount of shares staked
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Get the reward token (TOKE) address
     * @return The address of the TOKE token
     */
    function rewardToken() external view returns (address);
}