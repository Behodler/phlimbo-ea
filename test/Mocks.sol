// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/IFlax.sol";

/**
 * @title MockYieldAccumulator
 * @notice Mock implementation of yield accumulator for testing
 */
contract MockYieldAccumulator {
    // Mock implementation - can be used to test collectReward calls
}

/**
 * @title MockFlax
 * @notice Mock implementation of IFlax for testing
 */
contract MockFlax is ERC20 {
    mapping(address => bool) public minters;

    constructor() ERC20("Mock Flax", "mFLX") {}

    function setMinter(address minter, bool canMint) external {
        minters[minter] = canMint;
    }

    function mint(address recipient, uint256 amount) external {
        // Allow anyone to mint for testing purposes
        _mint(recipient, amount);
    }

    function burn(address holder, uint256 amount) external {
        _burn(holder, amount);
    }

    function authorizedMinters(address minter) external view returns (IFlax.MinterInfo memory) {
        return IFlax.MinterInfo({canMint: minters[minter], mintVersion: 1});
    }

    function mintVersion() external pure returns (uint256) {
        return 1;
    }

    function revokeAllMintPrivileges() external {
        // No-op for testing
    }
}

/**
 * @title MockStable
 * @notice Mock stablecoin token for testing
 */
contract MockStable is ERC20 {
    constructor() ERC20("Mock Stable", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
