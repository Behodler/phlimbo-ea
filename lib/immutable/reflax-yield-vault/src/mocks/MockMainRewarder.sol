// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./MockERC20.sol";

/**
 * @title MockMainRewarder
 * @notice Mock implementation of Tokemak's MainRewarder contract for testing
 * @dev Simulates the external Tokemak staking contract that handles TOKE rewards
 */
contract MockMainRewarder {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _rewards;
    uint256 private _totalSupply;
    address private _rewardToken;

    constructor(address rewardTokenAddr) {
        _rewardToken = rewardTokenAddr;
    }

    function stake(address user, uint256 amount) external {
        _balances[user] += amount;
        _totalSupply += amount;
    }

    function withdraw(address user, uint256 amount, bool claim) external {
        require(_balances[user] >= amount, "Insufficient staked balance");
        _balances[user] -= amount;
        _totalSupply -= amount;

        // If claim is true, also claim pending rewards
        if (claim && _rewards[user] > 0) {
            uint256 reward = _rewards[user];
            _rewards[user] = 0;
            MockERC20(_rewardToken).transfer(user, reward);
        }
    }

    function earned(address user) external view returns (uint256) {
        return _rewards[user];
    }

    function getReward(address account, address recipient, bool claimExtras) external returns (bool) {
        uint256 reward = _rewards[account];
        _rewards[account] = 0;
        if (reward > 0) {
            MockERC20(_rewardToken).transfer(recipient, reward);
        }
        // claimExtras is a parameter for future extensibility, currently just a placeholder
        return true;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }

    // Test helper to simulate earning rewards
    function simulateRewards(address user, uint256 amount) external {
        _rewards[user] += amount;
        MockERC20(_rewardToken).mint(address(this), amount);
    }
}
