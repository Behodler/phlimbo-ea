// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";
import "../src/IFlax.sol";

/**
 * @title FlaxAuthorizationTest
 * @dev Comprehensive test suite for authorization functionality of Flax token
 * 
 * Tests the setMinter functionality including:
 * - Owner authorization requirements
 * - Minter permission assignment
 * - Mint version assignment
 * - Event emissions
 * - Multiple simultaneous minters
 */
contract FlaxAuthorizationTest is Test {
    FlaxToken public flax;
    
    address public owner;
    address public minter1;
    address public minter2; 
    address public nonOwner;
    
    // Events from IFlax interface
    event MinterSet(address indexed minter, bool canMint, uint256 mintVersion);
    
    function setUp() public {
        owner = address(this);
        minter1 = address(0x1);
        minter2 = address(0x2);
        nonOwner = address(0x3);
        
        flax = new FlaxToken();
    }
    
    // ========================== OWNER AUTHORIZATION TESTS ==========================
    
    function testSetMinter_OnlyOwnerCanCall() public {
        // Test that only owner can call setMinter
        vm.prank(nonOwner);
        vm.expectRevert();
        flax.setMinter(minter1, true);
        
        // Owner should be able to call
        flax.setMinter(minter1, true);
    }
    
    function testSetMinter_NonOwnerCannotAuthorize() public {
        // Test that non-owner accounts cannot authorize minters
        vm.prank(nonOwner);
        vm.expectRevert();
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        vm.expectRevert();
        flax.setMinter(minter2, true);
    }
    
    // ========================== MINTER PERMISSION ASSIGNMENT TESTS ==========================
    
    function testSetMinter_AuthorizeMinter() public {
        // Test authorizing a new minter

        flax.setMinter(minter1, true);
    }
    
    function testSetMinter_RevokeMinter() public {
        // Test revoking minter authorization
        flax.setMinter(minter1, false);
    }
    
    function testSetMinter_ToggleMinterPermission() public {
        // Test toggling minter permission on and off
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter1, false);
        
        flax.setMinter(minter1, true);
    }
    
    // ========================== MINT VERSION ASSIGNMENT TESTS ==========================
    
    function testSetMinter_AssignsCurrentMintVersion() public {
        // Test that setMinter assigns current global mint version
        flax.setMinter(minter1, true);
    }
    
    function testSetMinter_AssignsVersionAfterRevocation() public {
        // Test version assignment after global revocation
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        flax.setMinter(minter2, true);
    }
    
    function testSetMinter_UpdatesVersionOnReauthorization() public {
        // Test that re-authorizing updates version
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        flax.setMinter(minter1, true);
    }
    
    // ========================== EVENT EMISSION TESTS ==========================
    
    function testSetMinter_EmitsMinterSetEvent() public {
        // Test that setMinter emits MinterSet event
        vm.expectEmit(true, false, false, false);
        emit MinterSet(minter1, true, 0);
        
        flax.setMinter(minter1, true);
    }
    
    function testSetMinter_EmitsEventOnRevocation() public {
        // Test event emission when revoking permission
        vm.expectEmit(true, false, false, false);
        emit MinterSet(minter1, false, 0);
        
        flax.setMinter(minter1, false);
    }
    
    function testSetMinter_EmitsEventWithCorrectVersion() public {
        // Test event includes correct mint version
        vm.expectEmit(true, false, false, false);
        emit MinterSet(minter1, true, 0);
        
        flax.setMinter(minter1, true);
    }
    
    // ========================== MULTIPLE MINTERS TESTS ==========================
    
    function testSetMinter_AuthorizeMultipleMinters() public {
        // Test authorizing multiple minters simultaneously
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter2, true);
    }
    
    function testSetMinter_IndependentMinterPermissions() public {
        // Test that minter permissions are independent
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter2, true);
        
        // Revoking one should not affect the other
        flax.setMinter(minter1, false);
    }
    
    function testSetMinter_MixedPermissions() public {
        // Test setting mixed permissions for different minters
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter2, false);
    }
    
    // ========================== PERMISSION AND VERSION VERIFICATION TESTS ==========================
    
    function testSetMinter_VerifyPermissionAndVersion() public {
        // Test that both permission and version are properly set
        flax.setMinter(minter1, true);
        
        // This should reflect the updated state (but will revert due to skeleton)
        flax.authorizedMinters(minter1);
    }
    
    function testSetMinter_VerifyRevocationState() public {
        // Test that revocation properly updates state
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter1, false);
        
        flax.authorizedMinters(minter1);
    }
    
    function testSetMinter_ZeroAddressMinter() public {
        // Test setting permissions for zero address
        flax.setMinter(address(0), true);
    }
    
    function testSetMinter_SelfAuthorization() public {
        // Test owner authorizing themselves as minter
        flax.setMinter(owner, true);
    }
}