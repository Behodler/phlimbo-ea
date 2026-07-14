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
 * @notice STUB — story-023 red phase. Implementation follows in the green phase.
 */
contract MigratorV2V3 is Ownable, ReentrancyGuard, IMigratorV2V3 {
    using SafeERC20 for IERC20;
    using SafeERC20 for IFlax;

    IPhlimboV2 public immutable phlimboV2;
    IPhlimboV3 public immutable phlimboV3;
    IFlax public immutable phUSD;
    IERC20 public immutable rewardToken;

    address[] public users;
    bool public seeded;
    int256 public migrateIterator;

    constructor(
        address _phlimboV2,
        address _phlimboV3,
        address _phUSD,
        address _rewardToken
    ) Ownable(msg.sender) {
        phlimboV2 = IPhlimboV2(_phlimboV2);
        phlimboV3 = IPhlimboV3(_phlimboV3);
        phUSD = IFlax(_phUSD);
        rewardToken = IERC20(_rewardToken);
    }

    function seedUsers(address[] calldata _users) external onlyOwner {}

    function migrate(uint256 maxIterations) external nonReentrant {}

    function withdrawAll() external onlyOwner {}

    function userCount() external view returns (uint256) {
        return users.length;
    }
}
