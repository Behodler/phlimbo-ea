// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IEYE
 * @notice Interface for EYE token with burn functionality
 */
interface IEYE is IERC20 {
    /**
     * @notice Burns tokens from the caller's balance
     * @param value The amount of tokens to burn
     */
    function burn(uint256 value) external;
}
