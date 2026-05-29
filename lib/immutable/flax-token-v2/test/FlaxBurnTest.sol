// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FlaxToken.sol";
import "../src/IFlax.sol";

/**
 * @title FlaxBurnTest
 * @dev Comprehensive test suite for burn functionality of Flax token
 *
 * Tests the burn function which works like transferFrom but burns instead of transfers:
 * - Allowance-based burning
 * - Allowance decrements
 * - Total supply decreases
 * - Balance decreases
 * - Insufficient allowance reverts
 * - Edge cases and error conditions
 */
contract FlaxBurnTest is Test {
    FlaxToken public flax;

    address public owner;
    address public minter;
    address public holder;
    address public burner;
    address public user1;

    // Events from IERC20
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        owner = address(this);
        minter = address(0x1);
        holder = address(0x11);
        burner = address(0x22);
        user1 = address(0x33);

        flax = new FlaxToken();

        // Setup: authorize minter and mint initial tokens to holder
        flax.setMinter(minter, true);
        vm.prank(minter);
        flax.mint(holder, 1000e18);
    }

    // ========================== BASIC BURN FUNCTIONALITY TESTS ==========================

    function testBurnWithAllowanceWorks() public {
        // Arrange: holder approves burner to burn 100 tokens
        vm.prank(holder);
        flax.approve(burner, 100e18);

        uint256 holderBalanceBefore = flax.balanceOf(holder);
        uint256 totalSupplyBefore = flax.totalSupply();

        // Act: burner burns 100 tokens from holder
        vm.prank(burner);
        flax.burn(holder, 100e18);

        // Assert: balance and total supply decreased
        assertEq(flax.balanceOf(holder), holderBalanceBefore - 100e18);
        assertEq(flax.totalSupply(), totalSupplyBefore - 100e18);
    }

    function testBurnDecrementsAllowance() public {
        // Arrange: holder approves burner to burn 100 tokens
        vm.prank(holder);
        flax.approve(burner, 100e18);

        uint256 allowanceBefore = flax.allowance(holder, burner);

        // Act: burner burns 50 tokens from holder
        vm.prank(burner);
        flax.burn(holder, 50e18);

        // Assert: allowance decreased by burned amount
        assertEq(flax.allowance(holder, burner), allowanceBefore - 50e18);
        assertEq(flax.allowance(holder, burner), 50e18);
    }

    function testBurnEmitsTransferEvent() public {
        // Arrange: holder approves burner to burn 100 tokens
        vm.prank(holder);
        flax.approve(burner, 100e18);

        // Assert: expect Transfer event to zero address (burn)
        vm.expectEmit(true, true, false, true);
        emit Transfer(holder, address(0), 100e18);

        // Act: burner burns 100 tokens from holder
        vm.prank(burner);
        flax.burn(holder, 100e18);
    }

    function testBurnZeroAmountWorks() public {
        // Arrange: holder approves burner
        vm.prank(holder);
        flax.approve(burner, 100e18);

        uint256 holderBalanceBefore = flax.balanceOf(holder);
        uint256 totalSupplyBefore = flax.totalSupply();
        uint256 allowanceBefore = flax.allowance(holder, burner);

        // Act: burner burns 0 tokens (should succeed but do nothing)
        vm.prank(burner);
        flax.burn(holder, 0);

        // Assert: nothing changed
        assertEq(flax.balanceOf(holder), holderBalanceBefore);
        assertEq(flax.totalSupply(), totalSupplyBefore);
        assertEq(flax.allowance(holder, burner), allowanceBefore);
    }

    // ========================== ALLOWANCE PATTERN TESTS ==========================

    function testBurnFailsWithInsufficientAllowance() public {
        // Arrange: holder approves burner for only 50 tokens
        vm.prank(holder);
        flax.approve(burner, 50e18);

        // Assert: expect revert when trying to burn more than allowance
        vm.prank(burner);
        vm.expectRevert();
        flax.burn(holder, 100e18);
    }

    function testBurnFailsWithNoAllowance() public {
        // Arrange: no approval given

        // Assert: expect revert when trying to burn without allowance
        vm.prank(burner);
        vm.expectRevert();
        flax.burn(holder, 1e18);
    }

    function testBurnWorksWithExactAllowance() public {
        // Arrange: holder approves burner for exact amount
        vm.prank(holder);
        flax.approve(burner, 100e18);

        // Act: burner burns exact allowance amount
        vm.prank(burner);
        flax.burn(holder, 100e18);

        // Assert: allowance is now 0
        assertEq(flax.allowance(holder, burner), 0);
    }

    function testBurnWorksWithInfiniteAllowance() public {
        // Arrange: holder approves burner with max uint256 (infinite)
        vm.prank(holder);
        flax.approve(burner, type(uint256).max);

        uint256 allowanceBefore = flax.allowance(holder, burner);

        // Act: burner burns some tokens
        vm.prank(burner);
        flax.burn(holder, 100e18);

        // Assert: infinite allowance remains unchanged
        assertEq(flax.allowance(holder, burner), allowanceBefore);
        assertEq(flax.allowance(holder, burner), type(uint256).max);
    }

    function testMultipleBurnsDecrementAllowanceCorrectly() public {
        // Arrange: holder approves burner for 300 tokens
        vm.prank(holder);
        flax.approve(burner, 300e18);

        // Act: burner burns in multiple transactions
        vm.prank(burner);
        flax.burn(holder, 100e18);

        assertEq(flax.allowance(holder, burner), 200e18);

        vm.prank(burner);
        flax.burn(holder, 50e18);

        assertEq(flax.allowance(holder, burner), 150e18);

        vm.prank(burner);
        flax.burn(holder, 150e18);

        // Assert: all allowance used up
        assertEq(flax.allowance(holder, burner), 0);
    }

    // ========================== BALANCE AND SUPPLY TESTS ==========================

    function testBurnDecreasesHolderBalance() public {
        // Arrange
        uint256 initialBalance = flax.balanceOf(holder);
        vm.prank(holder);
        flax.approve(burner, 250e18);

        // Act: burn tokens
        vm.prank(burner);
        flax.burn(holder, 250e18);

        // Assert: balance decreased by burned amount
        assertEq(flax.balanceOf(holder), initialBalance - 250e18);
        assertEq(flax.balanceOf(holder), 750e18);
    }

    function testBurnDecreasesTotalSupply() public {
        // Arrange
        uint256 initialSupply = flax.totalSupply();
        vm.prank(holder);
        flax.approve(burner, 300e18);

        // Act: burn tokens
        vm.prank(burner);
        flax.burn(holder, 300e18);

        // Assert: total supply decreased by burned amount
        assertEq(flax.totalSupply(), initialSupply - 300e18);
        assertEq(flax.totalSupply(), 700e18);
    }

    function testBurnAllTokensWorks() public {
        // Arrange: approve and burn all tokens
        uint256 totalBalance = flax.balanceOf(holder);
        vm.prank(holder);
        flax.approve(burner, totalBalance);

        // Act: burn all tokens
        vm.prank(burner);
        flax.burn(holder, totalBalance);

        // Assert: balance and supply are 0
        assertEq(flax.balanceOf(holder), 0);
        assertEq(flax.totalSupply(), 0);
    }

    function testBurnFailsWithInsufficientBalance() public {
        // Arrange: holder has 1000 tokens, approve burner for 2000
        vm.prank(holder);
        flax.approve(burner, 2000e18);

        // Assert: should revert when trying to burn more than balance
        vm.prank(burner);
        vm.expectRevert();
        flax.burn(holder, 1500e18);
    }

    // ========================== INTEGRATION TESTS ==========================

    function testBurnAfterTransferFrom() public {
        // Arrange: test that burn works after transferFrom
        vm.prank(holder);
        flax.approve(user1, 500e18);

        // Act: user1 transfers some tokens to themselves
        vm.prank(user1);
        flax.transferFrom(holder, user1, 200e18);

        // Now user1 has tokens, approve burner and burn from user1
        vm.prank(user1);
        flax.approve(burner, 100e18);

        vm.prank(burner);
        flax.burn(user1, 100e18);

        // Assert: user1 balance is correct
        assertEq(flax.balanceOf(user1), 100e18);
        assertEq(flax.totalSupply(), 900e18);
    }

    function testHolderCanBurnOwnTokens() public {
        // Arrange: holder approves themselves
        vm.prank(holder);
        flax.approve(holder, 100e18);

        uint256 balanceBefore = flax.balanceOf(holder);

        // Act: holder burns their own tokens
        vm.prank(holder);
        flax.burn(holder, 100e18);

        // Assert: balance decreased
        assertEq(flax.balanceOf(holder), balanceBefore - 100e18);
    }

    // ========================== EDGE CASES ==========================

    function testBurnFromZeroAddressFails() public {
        // Assert: burning from zero address should revert
        vm.expectRevert();
        flax.burn(address(0), 100e18);
    }

    function testMultipleApproversCanBurnFromSameHolder() public {
        // Arrange: holder approves multiple burners
        address burner2 = address(0x44);

        vm.prank(holder);
        flax.approve(burner, 200e18);

        vm.prank(holder);
        flax.approve(burner2, 300e18);

        // Act: both burners burn tokens
        vm.prank(burner);
        flax.burn(holder, 100e18);

        vm.prank(burner2);
        flax.burn(holder, 150e18);

        // Assert: total burned is 250, holder has 750 left
        assertEq(flax.balanceOf(holder), 750e18);
        assertEq(flax.totalSupply(), 750e18);
    }
}
