// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@reflax-yield-vault/src/interfaces/IYieldStrategy.sol";
import "@flax-token/src/IFlax.sol";

/**
 * @title MockYieldStrategy
 * @notice Mock implementation of IYieldStrategy for testing
 */
contract MockYieldStrategy is IYieldStrategy {
    mapping(address => mapping(address => uint256)) private principals;
    mapping(address => mapping(address => uint256)) private totals;

    function deposit(address token, uint256 amount, address recipient) external override {
        principals[token][recipient] += amount;
        totals[token][recipient] += amount;
    }

    function withdraw(address token, uint256 amount, address recipient) external override {
        principals[token][recipient] -= amount;
        totals[token][recipient] -= amount;
    }

    function balanceOf(address token, address account) external view override returns (uint256) {
        return totals[token][account];
    }

    function principalOf(address token, address account) external view override returns (uint256) {
        return principals[token][account];
    }

    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        return totals[token][account];
    }

    function setClient(address, bool) external override {
        // No-op for testing
    }

    function emergencyWithdraw(uint256) external override {
        // No-op for testing
    }

    function totalWithdrawal(address, address) external override {
        // No-op for testing
    }

    function withdrawFrom(address token, address account, uint256 amount, address recipient) external override {
        // Withdraw from account's balance and reduce totals
        require(totals[token][account] >= amount, "Insufficient balance");
        totals[token][account] -= amount;
        // In a real implementation, tokens would be transferred to recipient
        // For testing, we just reduce the tracked balance
    }

    // Test helpers
    function setPrincipal(address token, address account, uint256 amount) external {
        principals[token][account] = amount;
    }

    function setTotal(address token, address account, uint256 amount) external {
        totals[token][account] = amount;
    }
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
