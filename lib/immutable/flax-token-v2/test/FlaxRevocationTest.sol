// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";
import "../src/IFlax.sol";

/**
 * @title FlaxRevocationTest
 * @dev Comprehensive test suite for privilege revocation functionality of Flax token
 * 
 * Tests the revokeAllMintPrivileges functionality including:
 * - Access control (only owner can revoke)
 * - Global mint version increment
 * - Making all existing minters unable to mint
 * - Event emissions
 * - Newly authorized minters after revocation
 * - Multiple sequential revocations
 */
contract FlaxRevocationTest is Test {
    FlaxToken public flax;
    
    address public owner;
    address public minter1;
    address public minter2;
    address public minter3;
    address public nonOwner;
    address public recipient;
    
    // Events from IFlax interface
    event MintPrivilegesRevoked(uint256 newMintVersion);
    event MinterSet(address indexed minter, bool canMint, uint256 mintVersion);
    
    function setUp() public {
        owner = address(this);
        minter1 = address(0x1);
        minter2 = address(0x2);
        minter3 = address(0x3);
        nonOwner = address(0x4);
        recipient = address(0x11);
        
        flax = new FlaxToken();
    }
    
    // ========================== ACCESS CONTROL TESTS ==========================
    
    function testRevokeAllMintPrivileges_OnlyOwnerCanCall() public {
        // Test that only owner can call revokeAllMintPrivileges
        vm.prank(nonOwner);
        vm.expectRevert();
        flax.revokeAllMintPrivileges();
        
        // Owner should be able to call
        flax.revokeAllMintPrivileges();
    }
    
    function testRevokeAllMintPrivileges_MintersCannotRevoke() public {
        // Test that minters cannot revoke privileges
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        vm.expectRevert();
        flax.revokeAllMintPrivileges();
    }
    
    function testRevokeAllMintPrivileges_NonOwnerCannotRevoke() public {
        // Test various non-owner accounts cannot revoke
        vm.prank(nonOwner);
        vm.expectRevert();
        flax.revokeAllMintPrivileges();
        
        vm.prank(minter1);
        vm.expectRevert();
        flax.revokeAllMintPrivileges();
        
        vm.prank(address(0x99));
        vm.expectRevert();
        flax.revokeAllMintPrivileges();
    }
    
    // ========================== MINT VERSION INCREMENT TESTS ==========================
    
    function testRevokeAllMintPrivileges_IncrementsGlobalVersion() public {
        // Test that revocation increments global mint version
        uint256 initialVersion = flax.mintVersion();
        
        flax.revokeAllMintPrivileges();
        
        // Should increment from 0 to 1 (but skeleton doesn't implement)
        assertEq(flax.mintVersion(), initialVersion + 1);
    }
    
    function testRevokeAllMintPrivileges_MultipleRevocationsIncrement() public {
        // Test that multiple revocations increment version correctly
        uint256 initialVersion = flax.mintVersion();
        
        flax.revokeAllMintPrivileges();
        
        flax.revokeAllMintPrivileges();
        
        flax.revokeAllMintPrivileges();
        
        // Should increment by 3 (but skeleton doesn't implement)
        assertEq(flax.mintVersion(), initialVersion + 3);
    }
    
    function testRevokeAllMintPrivileges_VersionIncrementIsSequential() public {
        // Test that version increments are sequential
        flax.revokeAllMintPrivileges();
        
        assertEq(flax.mintVersion(), 1);
        
        flax.revokeAllMintPrivileges();
        
        assertEq(flax.mintVersion(), 2);
    }
    
    // ========================== EXISTING MINTERS REVOCATION TESTS ==========================
    
    function testRevokeAllMintPrivileges_DisablesExistingMinters() public {
        // Test that existing minters become unable to mint after revocation
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter2, true);
        
        flax.revokeAllMintPrivileges();
        
        // Both minters should now be unable to mint
        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient, 100e18);

        vm.prank(minter2);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient, 100e18);
    }
    
    function testRevokeAllMintPrivileges_AffectsAllMinters() public {
        // Test that revocation affects all existing minters
        address[] memory minters = new address[](3);
        minters[0] = minter1;
        minters[1] = minter2;
        minters[2] = minter3;
        
        // Authorize all minters
        for (uint i = 0; i < minters.length; i++) {
                flax.setMinter(minters[i], true);
        }
        
        flax.revokeAllMintPrivileges();
        
        // All should be unable to mint
        for (uint i = 0; i < minters.length; i++) {
            vm.prank(minters[i]);
            vm.expectRevert("phUSD: minter version is outdated");
                flax.mint(recipient, 100e18);
        }
    }
    
    function testRevokeAllMintPrivileges_EvenWithPermissionFlag() public {
        // Test that revocation works even if permission flag is still true
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        // Even if canMint flag is still true, version mismatch should prevent minting
        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient, 100e18);
    }
    
    // ========================== EVENT EMISSION TESTS ==========================
    
    function testRevokeAllMintPrivileges_EmitsRevocationEvent() public {
        // Test that revocation emits MintPrivilegesRevoked event
        vm.expectEmit(false, false, false, true);
        emit MintPrivilegesRevoked(1);
        
        flax.revokeAllMintPrivileges();
    }
    
    function testRevokeAllMintPrivileges_EmitsEventWithCorrectVersion() public {
        // Test that event includes correct new version
        vm.expectEmit(false, false, false, true);
        emit MintPrivilegesRevoked(1);
        
        flax.revokeAllMintPrivileges();
        
        vm.expectEmit(false, false, false, true);
        emit MintPrivilegesRevoked(2);
        
        flax.revokeAllMintPrivileges();
    }
    
    // ========================== NEWLY AUTHORIZED MINTERS TESTS ==========================
    
    function testRevokeAllMintPrivileges_NewlyAuthorizedCanMint() public {
        // Test that newly authorized minters can mint after revocation
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        flax.setMinter(minter2, true);
        
        // New minter should be able to mint
        vm.prank(minter2);
        flax.mint(recipient, 100e18);
    }
    
    function testRevokeAllMintPrivileges_ReauthorizationWorks() public {
        // Test that re-authorizing old minters works after revocation
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        flax.setMinter(minter1, true);
        
        // Re-authorized minter should be able to mint
        vm.prank(minter1);
        flax.mint(recipient, 100e18);
    }
    
    function testRevokeAllMintPrivileges_NewVersionAssignedToNewMinters() public {
        // Test that newly authorized minters get current version
        flax.revokeAllMintPrivileges();
        
        flax.setMinter(minter1, true);
        
        // Should get version 1 (but skeleton doesn't implement)
        IFlax.MinterInfo memory info = flax.authorizedMinters(minter1);
        assertEq(info.mintVersion, 1);
    }
    
    // ========================== EDGE CASE TESTS ==========================
    
    function testRevokeAllMintPrivileges_WithoutAnyMinters() public {
        // Test revocation when no minters are authorized
        flax.revokeAllMintPrivileges();
        
        // Should still increment version
        assertEq(flax.mintVersion(), 1);
    }
    
    function testRevokeAllMintPrivileges_AfterOwnershipTransfer() public {
        // Test revocation after ownership transfer
        flax.setMinter(minter1, true);
        
        address newOwner = address(0x99);
        flax.transferOwnership(newOwner);
        
        // Old owner should not be able to revoke
        vm.expectRevert();
        flax.revokeAllMintPrivileges();
        
        // New owner should be able to revoke
        vm.prank(newOwner);
        flax.revokeAllMintPrivileges();
    }
    
    function testRevokeAllMintPrivileges_ImmediateReauthorization() public {
        // Test immediate re-authorization after revocation
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        // Immediately re-authorize same minter
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient, 100e18);
    }
    
    function testRevokeAllMintPrivileges_MultipleSequentialRevocations() public {
        // Test behavior with multiple sequential revocations
        flax.setMinter(minter1, true);
        
        for (uint i = 0; i < 5; i++) {
                flax.revokeAllMintPrivileges();
        }
        
        // Version should be 5
        assertEq(flax.mintVersion(), 5);
        
        // Minter should still be unable to mint
        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient, 100e18);
    }
    
    // ========================== COMBINED WORKFLOW TESTS ==========================
    
    function testRevokeAllMintPrivileges_CompleteWorkflow() public {
        // Test complete workflow: authorize -> mint -> revoke -> can't mint -> reauthorize -> can mint
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient, 100e18);
        
        flax.revokeAllMintPrivileges();

        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient, 100e18);
        
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient, 100e18);
    }
}