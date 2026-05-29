// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IAutoDOLA
 * @notice Interface for Tokemak's AutoDola vault contract
 * @dev Extends ERC4626 standard for yield-bearing vault functionality
 */
interface IAutoDOLA is IERC4626 {
    /**
     * @notice Returns the MainRewarder contract address for TOKE rewards
     * @return The address of the MainRewarder contract
     */
    function rewarder() external view returns (address);

    /**
     * @notice Returns information about the underlying asset and vault
     * @return asset The underlying DOLA token address
     * @return symbol The vault symbol
     * @return name The vault name
     */
    function getVaultInfo() external view returns (
        address asset,
        string memory symbol,
        string memory name
    );
}