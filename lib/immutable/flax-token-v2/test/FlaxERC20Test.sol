// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";
import "../src/IFlax.sol";

/**
 * @title FlaxERC20Test
 * @dev Comprehensive test suite for ERC20 integration of Flax token
 * 
 * Tests the ERC20 functionality including:
 * - Initial token properties (name, symbol, decimals, supply)
 * - Transfer functionality after minting
 * - Approval and transferFrom functionality
 * - Balance and supply queries
 * - Integration with minting system
 */
contract FlaxERC20Test is Test {
    FlaxToken public flax;
    
    address public owner;
    address public minter;
    address public user1;
    address public user2;
    address public user3;
    
    // Events from IERC20
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    function setUp() public {
        owner = address(this);
        minter = address(0x1);
        user1 = address(0x11);
        user2 = address(0x12);
        user3 = address(0x13);
        
        flax = new FlaxToken();
    }
    
    // ========================== INITIAL TOKEN PROPERTIES TESTS ==========================
    
    function testInitialSupplyIsZero() public {
        // Test that initial supply is zero
        assertEq(flax.totalSupply(), 0);
    }
    
    function testNameReturnsFlax() public {
        // Test that name returns "Phoenix USD"
        assertEq(flax.name(), "Phoenix USD");
    }
    
    function testSymbolReturnsFLX() public {
        // Test that symbol returns "phUSD"
        assertEq(flax.symbol(), "phUSD");
    }
    
    function testDecimalsReturns18() public {
        // Test that decimals returns 18 (default ERC20)
        assertEq(flax.decimals(), 18);
    }
    
    function testInitialBalancesAreZero() public {
        // Test that all initial balances are zero
        assertEq(flax.balanceOf(user1), 0);
        assertEq(flax.balanceOf(user2), 0);
        assertEq(flax.balanceOf(owner), 0);
        assertEq(flax.balanceOf(minter), 0);
    }
    
    // ========================== TRANSFER FUNCTIONALITY TESTS ==========================
    
    function testTransferWorksAfterMinting() public {
        // Test that transfer works after tokens are minted
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        // Transfer should work after minting (but skeleton doesn't implement minting)
        vm.prank(user1);
        assertTrue(flax.transfer(user2, 100e18));
        
        assertEq(flax.balanceOf(user1), 900e18);
        assertEq(flax.balanceOf(user2), 100e18);
    }
    
    function testTransferEmitsEvent() public {
        // Test that transfer emits Transfer event
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, 100e18);
        
        vm.prank(user1);
        flax.transfer(user2, 100e18);
    }
    
    function testTransferFailsWithInsufficientBalance() public {
        // Test that transfer fails with insufficient balance
        vm.prank(user1);
        vm.expectRevert();
        flax.transfer(user2, 100e18);
    }
    
    function testTransferToSelf() public {
        // Test transfer to self
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        vm.prank(user1);
        assertTrue(flax.transfer(user1, 100e18));
        
        assertEq(flax.balanceOf(user1), 1000e18); // Should remain the same
    }
    
    // ========================== APPROVAL AND TRANSFERFROM TESTS ==========================
    
    function testApproveWorks() public {
        // Test that approve functionality works
        vm.prank(user1);
        assertTrue(flax.approve(user2, 500e18));
        
        assertEq(flax.allowance(user1, user2), 500e18);
    }
    
    function testApproveEmitsEvent() public {
        // Test that approve emits Approval event
        vm.expectEmit(true, true, false, true);
        emit Approval(user1, user2, 500e18);
        
        vm.prank(user1);
        flax.approve(user2, 500e18);
    }
    
    function testTransferFromWorksAfterMinting() public {
        // Test that transferFrom works after minting and approval
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        vm.prank(user1);
        flax.approve(user2, 300e18);
        
        vm.prank(user2);
        assertTrue(flax.transferFrom(user1, user3, 200e18));
        
        assertEq(flax.balanceOf(user1), 800e18);
        assertEq(flax.balanceOf(user3), 200e18);
        assertEq(flax.allowance(user1, user2), 100e18);
    }
    
    function testTransferFromEmitsEvent() public {
        // Test that transferFrom emits Transfer event
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        vm.prank(user1);
        flax.approve(user2, 300e18);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user3, 200e18);
        
        vm.prank(user2);
        flax.transferFrom(user1, user3, 200e18);
    }
    
    function testTransferFromFailsWithInsufficientAllowance() public {
        // Test that transferFrom fails with insufficient allowance
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        vm.prank(user1);
        flax.approve(user2, 100e18);
        
        vm.prank(user2);
        vm.expectRevert();
        flax.transferFrom(user1, user3, 200e18);
    }
    
    function testTransferFromFailsWithInsufficientBalance() public {
        // Test that transferFrom fails with insufficient balance
        vm.prank(user1);
        flax.approve(user2, 1000e18);
        
        vm.prank(user2);
        vm.expectRevert();
        flax.transferFrom(user1, user3, 500e18);
    }
    
    // ========================== BALANCE AND SUPPLY QUERIES TESTS ==========================
    
    function testBalanceOfReturnsCorrectValues() public {
        // Test that balanceOf returns correct values
        assertEq(flax.balanceOf(user1), 0);
        
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 500e18);
        
        assertEq(flax.balanceOf(user1), 500e18);
        
        vm.prank(minter);
        flax.mint(user1, 300e18);
        
        assertEq(flax.balanceOf(user1), 800e18);
    }
    
    function testTotalSupplyUpdatesWithMinting() public {
        // Test that total supply updates correctly with minting
        assertEq(flax.totalSupply(), 0);
        
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        assertEq(flax.totalSupply(), 1000e18);
        
        vm.prank(minter);
        flax.mint(user2, 500e18);
        
        assertEq(flax.totalSupply(), 1500e18);
    }
    
    function testTotalSupplyUnchangedByTransfers() public {
        // Test that total supply unchanged by transfers
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        uint256 supplyBeforeTransfer = flax.totalSupply();
        
        vm.prank(user1);
        flax.transfer(user2, 400e18);
        
        assertEq(flax.totalSupply(), supplyBeforeTransfer);
    }
    
    // ========================== INTEGRATION WITH MINTING SYSTEM TESTS ==========================
    
    function testERC20AfterMintingWorkflow() public {
        // Test complete ERC20 workflow after minting
        flax.setMinter(minter, true);
        
        // Mint tokens
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        // Transfer some tokens
        vm.prank(user1);
        flax.transfer(user2, 300e18);
        
        // Approve and transferFrom
        vm.prank(user2);
        flax.approve(user3, 100e18);
        
        vm.prank(user3);
        flax.transferFrom(user2, user1, 50e18);
        
        // Check final balances
        assertEq(flax.balanceOf(user1), 750e18); // 1000 - 300 + 50
        assertEq(flax.balanceOf(user2), 250e18); // 300 - 50
        assertEq(flax.balanceOf(user3), 0);
        assertEq(flax.totalSupply(), 1000e18);
    }
    
    function testERC20AfterRevocationAndReauthorization() public {
        // Test ERC20 functionality after privilege revocation and reauthorization
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        // Revoke privileges
        flax.revokeAllMintPrivileges();
        
        // Existing tokens should still be transferable
        vm.prank(user1);
        flax.transfer(user2, 200e18);
        
        assertEq(flax.balanceOf(user1), 800e18);
        assertEq(flax.balanceOf(user2), 200e18);
        
        // Re-authorize and mint more
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user3, 500e18);
        
        assertEq(flax.totalSupply(), 1500e18);
    }
    
    function testERC20WithMultipleMinters() public {
        // Test ERC20 functionality with multiple minters
        address minter2 = address(0x2);
        
        flax.setMinter(minter, true);
        
        flax.setMinter(minter2, true);
        
        // Both minters mint tokens
        vm.prank(minter);
        flax.mint(user1, 600e18);
        
        vm.prank(minter2);
        flax.mint(user2, 400e18);
        
        // Standard ERC20 operations should work
        vm.prank(user1);
        flax.transfer(user3, 100e18);
        
        vm.prank(user2);
        flax.approve(user3, 200e18);
        
        vm.prank(user3);
        flax.transferFrom(user2, user1, 150e18);
        
        assertEq(flax.balanceOf(user1), 650e18); // 600 - 100 + 150
        assertEq(flax.balanceOf(user2), 250e18); // 400 - 150
        assertEq(flax.balanceOf(user3), 100e18); // 100 from transfer
        assertEq(flax.totalSupply(), 1000e18);
    }
    
    // ========================== EDGE CASES TESTS ==========================
    
    function testZeroValueTransfer() public {
        // Test zero value transfer
        vm.prank(user1);
        assertTrue(flax.transfer(user2, 0));
        
        assertEq(flax.balanceOf(user1), 0);
        assertEq(flax.balanceOf(user2), 0);
    }
    
    function testZeroValueApproval() public {
        // Test zero value approval
        vm.prank(user1);
        assertTrue(flax.approve(user2, 0));
        
        assertEq(flax.allowance(user1, user2), 0);
    }
    
    function testMaxValueOperations() public {
        // Test operations with maximum values
        flax.setMinter(minter, true);
        
        uint256 maxAmount = type(uint256).max / 2;
        
        vm.prank(minter);
        flax.mint(user1, maxAmount);
        
        vm.prank(user1);
        assertTrue(flax.approve(user2, type(uint256).max));
        
        assertEq(flax.allowance(user1, user2), type(uint256).max);
    }
    
    function testTransferToZeroAddress() public {
        // Test transfer to zero address (should revert in proper implementation)
        flax.setMinter(minter, true);
        
        vm.prank(minter);
        flax.mint(user1, 1000e18);
        
        vm.prank(user1);
        // This should revert in proper implementation
        vm.expectRevert();
        flax.transfer(address(0), 100e18);
    }
}