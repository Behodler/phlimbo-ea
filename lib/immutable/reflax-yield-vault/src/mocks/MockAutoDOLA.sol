// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./MockERC20.sol";

/**
 * @title MockAutoDOLA
 * @notice Mock implementation of Tokemak's AutoDOLA ERC4626 vault for testing
 * @dev Simulates the external Tokemak vault that AutoDolaYieldStrategy deposits into
 */
contract MockAutoDOLA is MockERC20 {
    uint256 private _totalAssets;
    address private _asset;
    address private _rewarder;

    // Slippage simulation
    bool private _slippageEnabled;
    uint256 private _slippageReturnAmount;

    constructor(address asset_, address rewarder_) MockERC20("AutoDOLA", "autoDOLA", 18) {
        _totalAssets = 0; // Start with no assets - shares will be minted on first deposit
        _asset = asset_;
        _rewarder = rewarder_;
        _slippageEnabled = false;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _mint(receiver, shares);
        _totalAssets += assets;

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(balanceOf(owner) >= shares, "Insufficient shares");

        assets = convertToAssets(shares);
        _burn(owner, shares);
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(balanceOf(owner) >= shares, "Insufficient shares");

        _burn(owner, shares);
        _totalAssets -= assets;

        // Handle slippage simulation if enabled
        uint256 transferAmount = _slippageEnabled ? _slippageReturnAmount : assets;
        MockERC20(_asset).transfer(receiver, transferAmount);
        return transferAmount; // Return actual transferred amount (not shares)
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalAssets == 0) return assets;
        return (assets * totalSupply()) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * _totalAssets) / supply;
    }

    function asset() public view returns (address) {
        return _asset;
    }

    function rewarder() external view returns (address) {
        return _rewarder;
    }

    // Simulate yield growth
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
    }

    // Enable/disable slippage simulation for testing
    function setSlippageSimulation(bool enabled, uint256 returnAmount) external {
        _slippageEnabled = enabled;
        _slippageReturnAmount = returnAmount;
    }
}
