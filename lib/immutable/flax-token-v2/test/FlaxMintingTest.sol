// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";
import "../src/IFlax.sol";

/**
 * @title FlaxMintingTest
 * @dev Comprehensive test suite for minting functionality of Flax token
 * 
 * Tests the mint functionality including:
 * - Access control (only authorized minters)
 * - Version checking against global version
 * - Balance and supply updates
 * - Event emissions
 * - Edge cases (zero amounts, zero addresses)
 */
contract FlaxMintingTest is Test {
    FlaxToken public flax;
    
    address public owner;
    address public minter1;
    address public minter2;
    address public nonMinter;
    address public recipient1;
    address public recipient2;
    
    // Events from IERC20
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    function setUp() public {
        owner = address(this);
        minter1 = address(0x1);
        minter2 = address(0x2);
        nonMinter = address(0x3);
        recipient1 = address(0x11);
        recipient2 = address(0x12);
        
        flax = new FlaxToken();
    }
    
    // ========================== ACCESS CONTROL TESTS ==========================
    
    function testMint_OnlyAuthorizedMintersCanMint() public {
        // Test that non-authorized addresses cannot mint
        vm.prank(nonMinter);
        vm.expectRevert("phUSD: caller is not authorized to mint");
        flax.mint(recipient1, 100e18);

        vm.prank(minter1);
        vm.expectRevert("phUSD: caller is not authorized to mint");
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_OwnerCannotMintUnlessAuthorized() public {
        // Test that even owner cannot mint unless explicitly authorized
        vm.expectRevert("phUSD: caller is not authorized to mint");
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_RevokedMintersCannotMint() public {
        // Test that revoked minters cannot mint
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter1, false);

        vm.prank(minter1);
        vm.expectRevert("phUSD: caller is not authorized to mint");
        flax.mint(recipient1, 100e18);
    }
    
    // ========================== VERSION CHECKING TESTS ==========================
    
    function testMint_ChecksMinterVersionAgainstGlobal() public {
        // Test that mint checks minter version against global version
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_RevertsWhenMinterVersionOutdated() public {
        // Test that mint reverts when minter version is less than global
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();

        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_WorksWhenVersionsMatch() public {
        // Test that mint works when versions match
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_NewlyAuthorizedAfterRevocationCanMint() public {
        // Test newly authorized minters can mint after global revocation
        flax.revokeAllMintPrivileges();
        
        flax.setMinter(minter2, true);
        
        vm.prank(minter2);
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_VersionCheckIgnoresPermissionFlag() public {
        // Test that version check happens regardless of permission flag
        flax.setMinter(minter1, true);
        
        flax.revokeAllMintPrivileges();
        
        // Even if still marked as canMint=true, should fail version check
        vm.prank(minter1);
        vm.expectRevert("phUSD: minter version is outdated");
        flax.mint(recipient1, 100e18);
    }
    
    // ========================== BALANCE AND SUPPLY UPDATE TESTS ==========================
    
    function testMint_IncreasesRecipientBalance() public {
        // Test that minting increases recipient balance correctly
        flax.setMinter(minter1, true);
        
        uint256 initialBalance = flax.balanceOf(recipient1);
        
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
        
        // This would check the balance increase (but skeleton reverts)
        assertEq(flax.balanceOf(recipient1), initialBalance + 100e18);
    }
    
    function testMint_IncreasesTotalSupply() public {
        // Test that minting increases total supply correctly
        flax.setMinter(minter1, true);
        
        uint256 initialSupply = flax.totalSupply();
        
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
        
        // This would check the supply increase (but skeleton reverts)
        assertEq(flax.totalSupply(), initialSupply + 100e18);
    }
    
    function testMint_MultipleMintsAccumulate() public {
        // Test that multiple mints accumulate correctly
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient1, 50e18);
        
        vm.prank(minter1);
        flax.mint(recipient1, 30e18);
        
        // Should accumulate to 80e18 total (but skeleton reverts)
        assertEq(flax.balanceOf(recipient1), 80e18);
    }
    
    function testMint_DifferentMintersCanMint() public {
        // Test that different authorized minters can mint
        flax.setMinter(minter1, true);
        
        flax.setMinter(minter2, true);
        
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
        
        vm.prank(minter2);
        flax.mint(recipient2, 200e18);
    }
    
    // ========================== EVENT EMISSION TESTS ==========================
    
    function testMint_EmitsTransferEvent() public {
        // Test that mint emits Transfer event with correct parameters
        flax.setMinter(minter1, true);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), recipient1, 100e18);
        
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
    }
    
    function testMint_EmitsTransferFromZeroAddress() public {
        // Test that Transfer event uses zero address as from
        flax.setMinter(minter1, true);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), recipient1, 50e18);
        
        vm.prank(minter1);
        flax.mint(recipient1, 50e18);
    }
    
    // ========================== EDGE CASE TESTS ==========================
    
    function testMint_ZeroAmount() public {
        // Test minting zero amount
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(recipient1, 0);
    }
    
    function testMint_ZeroAddressRecipient() public {
        // Test that minting to zero address reverts
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        vm.expectRevert();
        flax.mint(address(0), 100e18);
    }
    
    function testMint_LargeAmount() public {
        // Test minting large amounts
        flax.setMinter(minter1, true);
        
        uint256 largeAmount = type(uint256).max / 2;
        
        vm.prank(minter1);
        flax.mint(recipient1, largeAmount);
    }
    
    function testMint_SelfMinting() public {
        // Test minter minting to themselves
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(minter1, 100e18);
    }
    
    function testMint_ContractAsRecipient() public {
        // Test minting to a contract address
        flax.setMinter(minter1, true);
        
        vm.prank(minter1);
        flax.mint(address(flax), 100e18);
    }
    
    // ========================== SEQUENTIAL MINTING TESTS ==========================
    
    function testMint_SequentialMints() public {
        // Test multiple sequential mint operations
        flax.setMinter(minter1, true);
        
        vm.startPrank(minter1);
        
        flax.mint(recipient1, 10e18);
        
        flax.mint(recipient1, 20e18);
        
        flax.mint(recipient2, 30e18);
        
        vm.stopPrank();
        
        // Total supply should be 60e18 (but skeleton reverts)
        assertEq(flax.totalSupply(), 60e18);
    }
    
    function testMint_AfterOwnershipTransfer() public {
        // Test minting after ownership transfer
        flax.setMinter(minter1, true);
        
        address newOwner = address(0x99);
        flax.transferOwnership(newOwner);
        
        // Old minter should still be able to mint with current version
        vm.prank(minter1);
        flax.mint(recipient1, 100e18);
    }
}