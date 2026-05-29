// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../src/FlaxToken.sol";

/**
 * @title TestContract
 * @dev Simple contract to test contract-to-contract interactions with FlaxToken
 */
contract TestContract {
    FlaxToken public flaxToken;
    
    constructor(FlaxToken _flaxToken) {
        flaxToken = _flaxToken;
    }
    
    function mintToSelf(uint256 amount) external {
        flaxToken.mint(address(this), amount);
    }
    
    function transferTokens(address to, uint256 amount) external {
        flaxToken.transfer(to, amount);
    }
}