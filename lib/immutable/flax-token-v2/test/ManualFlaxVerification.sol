// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";

contract ManualFlaxVerification is Test {
    FlaxToken public flax;
    address public owner;
    address public minter;
    address public user;
    
    function setUp() public {
        owner = address(this);
        minter = address(0x1);
        user = address(0x2);
        flax = new FlaxToken();
    }
    
    function testBasicWorkflow() public {
        // Initial state
        assertEq(flax.name(), "Phoenix USD");
        assertEq(flax.symbol(), "phUSD");
        assertEq(flax.decimals(), 18);
        assertEq(flax.totalSupply(), 0);
        assertEq(flax.mintVersion(), 0);
        
        // Authorize minter
        flax.setMinter(minter, true);
        
        // Check minter info
        IFlax.MinterInfo memory info = flax.authorizedMinters(minter);
        assertTrue(info.canMint);
        assertEq(info.mintVersion, 0);
        
        // Minter can mint
        vm.prank(minter);
        flax.mint(user, 1000e18);
        
        // Verify balances
        assertEq(flax.balanceOf(user), 1000e18);
        assertEq(flax.totalSupply(), 1000e18);
        
        // User can transfer
        vm.prank(user);
        flax.transfer(address(0x3), 100e18);
        assertEq(flax.balanceOf(user), 900e18);
        assertEq(flax.balanceOf(address(0x3)), 100e18);
        
        console.log("All basic functionality works correctly!");
    }
    
    function testRevocation() public {
        // Authorize minter
        flax.setMinter(minter, true);
        
        // Minter can mint
        vm.prank(minter);
        flax.mint(user, 500e18);
        assertEq(flax.balanceOf(user), 500e18);
        
        // Revoke all privileges
        flax.revokeAllMintPrivileges();
        assertEq(flax.mintVersion(), 1);
        
        // Old minter should no longer be able to mint
        vm.prank(minter);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(user, 500e18);
        
        // Re-authorize minter
        flax.setMinter(minter, true);
        
        // Should be able to mint again
        vm.prank(minter);
        flax.mint(user, 300e18);
        assertEq(flax.balanceOf(user), 800e18);
        
        console.log("Revocation system works correctly!");
    }
}