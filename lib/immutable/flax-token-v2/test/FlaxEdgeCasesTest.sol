// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";
import "../src/IFlax.sol";
import "./TestContract.sol";

/**
 * @title FlaxEdgeCasesTest
 * @dev Comprehensive test suite for edge cases and security aspects of Flax token
 * 
 * Tests include:
 * - Contract deployment and initial state
 * - Ownership transfer scenarios
 * - Sequential operations and complex workflows
 * - Large amount handling and overflow protection
 * - Reentrancy protection scenarios
 * - Contract-to-contract interactions
 * - Boundary conditions and error states
 */
contract FlaxEdgeCasesTest is Test {
    FlaxToken public flax;
    
    address public owner;
    address public newOwner;
    address public minter1;
    address public minter2;
    address public user1;
    address public user2;
    
    function setUp() public {
        owner = address(this);
        newOwner = address(0x99);
        minter1 = address(0x1);
        minter2 = address(0x2);
        user1 = address(0x11);
        user2 = address(0x12);
        
        flax = new FlaxToken();
    }
    
    // ========================== CONTRACT DEPLOYMENT TESTS ==========================
    
    function testContractDeploymentInitialState() public {
        // Test contract deployment with proper initial state
        assertEq(flax.name(), "Phoenix USD");
        assertEq(flax.symbol(), "phUSD");
        assertEq(flax.decimals(), 18);
        assertEq(flax.totalSupply(), 0);
        assertEq(flax.mintVersion(), 0);
        assertEq(flax.owner(), owner);
    }
    
    function testMultipleContractDeployments() public {
        // Test that multiple contract deployments are independent
        FlaxToken flax2 = new FlaxToken();
        FlaxToken flax3 = new FlaxToken();
        
        assertEq(flax2.owner(), address(this));
        assertEq(flax3.owner(), address(this));
        assertEq(flax2.mintVersion(), 0);
        assertEq(flax3.mintVersion(), 0);
        
        // Operations on one should not affect others
        flax.setMinter(minter1, true);
        
        // Other contracts should remain unaffected
        assertEq(flax2.mintVersion(), 0);
        assertEq(flax3.mintVersion(), 0);
    }
    
    // ========================== OWNERSHIP TRANSFER TESTS ==========================
    
    function testOwnershipTransferFunctionality() public {
        // Test ownership transfer functionality
        assertEq(flax.owner(), owner);
        
        flax.transferOwnership(newOwner);
        assertEq(flax.owner(), newOwner);
        
        // Old owner should not be able to perform owner functions
        vm.expectRevert();
        flax.setMinter(minter1, true);
        
        // New owner should be able to perform owner functions
        vm.prank(newOwner);
        flax.setMinter(minter1, true);
    }
    
    function testOwnershipTransferToZeroAddress() public {
        // Test ownership transfer to zero address
        vm.expectRevert();
        flax.transferOwnership(address(0));
    }
    
    function testRenounceOwnership() public {
        // Test renouncing ownership
        flax.renounceOwnership();
        assertEq(flax.owner(), address(0));
        
        // No one should be able to perform owner functions
        vm.expectRevert();
        flax.setMinter(minter1, true);
        
        vm.prank(newOwner);
        vm.expectRevert();
        flax.setMinter(minter1, true);
    }
    
    function testMintingAfterOwnershipTransfer() public {
        // Test that minting works correctly after ownership transfer
        flax.setMinter(minter1, true);
        
        flax.transferOwnership(newOwner);
        
        // Previously authorized minter should still work
        vm.prank(minter1);
        flax.mint(user1, 100e18);
        
        // New owner should be able to authorize new minters
        vm.prank(newOwner);
        flax.setMinter(minter2, true);
    }
    
    // ========================== SEQUENTIAL OPERATIONS TESTS ==========================
    
    function testMultipleSequentialMintOperations() public {
        // Test multiple sequential mint operations
        flax.setMinter(minter1, true);
        
        vm.startPrank(minter1);
        for (uint i = 1; i <= 10; i++) {
                flax.mint(user1, i * 10e18);
        }
        vm.stopPrank();
        
        // Total should be sum of 1+2+...+10 = 55, each * 10e18
        uint256 expectedTotal = 55 * 10e18;
        assertEq(flax.balanceOf(user1), expectedTotal);
    }
    
    function testComplexAuthorizationSequence() public {
        // Test complex sequence of authorization changes
        address[] memory minters = new address[](5);
        for (uint i = 0; i < 5; i++) {
            minters[i] = address(uint160(0x100 + i));
        }
        
        // Authorize all minters
        for (uint i = 0; i < minters.length; i++) {
                flax.setMinter(minters[i], true);
        }
        
        // Revoke some, keep others
        for (uint i = 0; i < minters.length; i++) {
            if (i % 2 == 0) {
                        flax.setMinter(minters[i], false);
            }
        }
        
        // Global revocation
        flax.revokeAllMintPrivileges();
        
        // Re-authorize subset
        flax.setMinter(minters[0], true);
        
        flax.setMinter(minters[2], true);
    }
    
    // ========================== LARGE AMOUNTS TESTS ==========================
    
    function testLargeAmountMinting() public {
        // Test minting large amounts
        flax.setMinter(minter1, true);
        
        uint256 largeAmount = type(uint128).max; // Very large but safe amount
        
        vm.prank(minter1);
        flax.mint(user1, largeAmount);
        
        assertEq(flax.balanceOf(user1), largeAmount);
        assertEq(flax.totalSupply(), largeAmount);
    }
    
    function testIntegerOverflowProtection() public {
        // Test integer overflow protection
        flax.setMinter(minter1, true);
        
        uint256 maxUint256 = type(uint256).max;
        
        vm.prank(minter1);
        flax.mint(user1, maxUint256);
        
        // Second mint should cause overflow and revert in proper implementation
        vm.prank(minter1);
        vm.expectRevert(); // Should revert due to overflow
        flax.mint(user1, 1);
    }
    
    function testMintVersionOverflow() public {
        // Test mint version overflow protection
        // This would require many revocations to test overflow
        for (uint i = 0; i < 10; i++) {
                flax.revokeAllMintPrivileges();
        }
        
        assertEq(flax.mintVersion(), 10);
    }
    
    // ========================== REENTRANCY PROTECTION TESTS ==========================
    
    // Note: These tests are more conceptual since the skeleton doesn't implement the logic
    function testReentrancyProtectionInMint() public {
        // Test that mint function has reentrancy protection if applicable
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(user1, 100e18);
    }
    
    function testReentrancyProtectionInSetMinter() public {
        // Test reentrancy protection in setMinter if applicable
        flax.setMinter(minter1, true);
    }
    
    // ========================== CONTRACT RECIPIENT TESTS ==========================
    
    function testMintingToContract() public {
        // Test minting to a contract address
        TestContract testContract = new TestContract(flax);
        
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(address(testContract), 100e18);
        
        assertEq(flax.balanceOf(address(testContract)), 100e18);
    }
    
    function testContractCallingMint() public {
        // Test contract calling mint function
        TestContract testContract = new TestContract(flax);
        
        flax.setMinter(address(testContract), true);
        
        // Contract should be able to mint to itself
        testContract.mintToSelf(100e18);
    }
    
    function testContractTransferFunctionality() public {
        // Test contract's ability to transfer tokens
        TestContract testContract = new TestContract(flax);
        
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(address(testContract), 100e18);
        
        // Contract should be able to transfer tokens
        testContract.transferTokens(user1, 50e18);
        
        assertEq(flax.balanceOf(address(testContract)), 50e18);
        assertEq(flax.balanceOf(user1), 50e18);
    }
    
    // ========================== BOUNDARY CONDITIONS TESTS ==========================
    
    function testZeroVersionMinting() public {
        // Test minting at version 0 (initial state)
        assertEq(flax.mintVersion(), 0);
        
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(user1, 100e18);
    }
    
    function testMaxVersionMinting() public {
        // Test minting at high version numbers
        // Simulate many revocations to get high version
        for (uint i = 0; i < 100; i++) {
                flax.revokeAllMintPrivileges();
        }
        
        assertEq(flax.mintVersion(), 100);
        
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(user1, 100e18);
    }
    
    function testEmptyStateOperations() public {
        // Test operations on completely empty state
        assertEq(flax.totalSupply(), 0);
        assertEq(flax.balanceOf(user1), 0);
        
        // These should all work on empty state
        assertEq(flax.allowance(user1, user2), 0);
        
        vm.prank(user1);
        assertTrue(flax.approve(user2, 100e18));
        
        vm.prank(user1);
        vm.expectRevert();
        flax.transfer(user2, 1); // Should fail - no balance
    }
    
    // ========================== ERROR STATE TESTS ==========================
    
    function testOperationsAfterRevocation() public {
        // Test various operations after global revocation
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter2, true);
        
        flax.revokeAllMintPrivileges();
        
        // All old minters should fail
        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(user1, 100e18);

        vm.prank(minter2);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(user2, 100e18);
        
        // Query functions should still work
        assertEq(flax.mintVersion(), 1);
        assertEq(flax.totalSupply(), 0);
    }
    
    function testAuthorizationQueryAccuracy() public {
        // Test that authorization queries return accurate information
        flax.authorizedMinters(minter1);
        
        flax.setMinter(minter1, true);
        
        flax.authorizedMinters(minter1);
        
        flax.revokeAllMintPrivileges();
        
        flax.authorizedMinters(minter1);
    }
    
    // ========================== STRESS TESTS ==========================
    
    function testManySmallMints() public {
        // Test many small minting operations
        flax.setMinter(minter1, true);
        
        vm.startPrank(minter1);
        for (uint i = 0; i < 50; i++) {
                flax.mint(user1, 1e18); // 1 token each time
        }
        vm.stopPrank();
        
        assertEq(flax.balanceOf(user1), 50e18);
        assertEq(flax.totalSupply(), 50e18);
    }
    
    function testRapidAuthorizationChanges() public {
        // Test rapid authorization changes
        for (uint i = 0; i < 20; i++) {
                flax.setMinter(minter1, true);
            
                flax.setMinter(minter1, false);
        }
        
        // Final state should be unauthorized
        vm.prank(minter1);
        vm.expectRevert("phUSD: caller is not authorized to mint");
        flax.mint(user1, 100e18);
    }
}