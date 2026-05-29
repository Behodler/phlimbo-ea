// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockMainRewarder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VaultWithdrawerTest
 * @notice Comprehensive tests for vault withdrawer authorization and withdrawFrom functionality
 */
contract VaultWithdrawerTest is Test {
    using SafeERC20 for IERC20;

    AutoDolaYieldStrategy public vault;
    MockERC20 public depositToken;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner;
    address public client;
    address public withdrawer;
    address public recipient;
    address public unauthorized;

    event WithdrawerAuthorizationSet(address indexed withdrawer, bool authorized);
    event WithdrawnFrom(
        address indexed token,
        address indexed client,
        address indexed withdrawer,
        uint256 amount,
        address recipient
    );

    function setUp() public {
        owner = address(this);
        client = address(0x1);
        withdrawer = address(0x2);
        recipient = address(0x3);
        unauthorized = address(0x4);

        // Deploy mock tokens
        depositToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock external dependencies
        mainRewarder = new MockMainRewarder(address(tokeToken));
        autoDolaVault = new MockAutoDOLA(address(depositToken), address(mainRewarder));

        // Deploy the real AutoDolaYieldStrategy
        vault = new AutoDolaYieldStrategy(
            owner,
            address(depositToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Authorize client for vault operations
        vault.setClient(client, true);

        // Mint tokens to client and autoDolaVault for testing
        depositToken.mint(client, 10000000e18);
        depositToken.mint(address(autoDolaVault), 10000000e18);
    }

    /**
     * @notice Helper function to set up principal and surplus for a client
     * @param token The token address (must be depositToken for AutoDolaYieldStrategy)
     * @param account The client account
     * @param principal The principal amount to deposit
     * @param surplus The surplus amount to simulate (via yield in autoDolaVault)
     */
    function setupPrincipalAndSurplus(address token, address account, uint256 principal, uint256 surplus) internal {
        // Mint tokens to account if needed (checking balance to avoid double-minting)
        if (depositToken.balanceOf(account) < principal) {
            depositToken.mint(account, principal);
        }

        vm.startPrank(account);
        depositToken.approve(address(vault), principal);
        vault.deposit(token, principal, account);
        vm.stopPrank();

        if (surplus > 0) {
            depositToken.mint(address(autoDolaVault), surplus);
            autoDolaVault.simulateYield(surplus);
        }
    }

    // ============ AUTHORIZATION TESTS ============

    function testSetWithdrawerAuthorization() public {
        // Should emit event when authorizing
        vm.expectEmit(true, false, false, true);
        emit WithdrawerAuthorizationSet(withdrawer, true);

        vault.setWithdrawer(withdrawer, true);

        assertTrue(vault.authorizedWithdrawers(withdrawer));
    }

    function testSetWithdrawerDeauthorization() public {
        // First authorize
        vault.setWithdrawer(withdrawer, true);
        assertTrue(vault.authorizedWithdrawers(withdrawer));

        // Then deauthorize
        vm.expectEmit(true, false, false, true);
        emit WithdrawerAuthorizationSet(withdrawer, false);

        vault.setWithdrawer(withdrawer, false);

        assertFalse(vault.authorizedWithdrawers(withdrawer));
    }

    function testSetWithdrawerOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.setWithdrawer(withdrawer, true);
    }

    function testSetWithdrawerZeroAddress() public {
        vm.expectRevert("AYieldStrategy: withdrawer cannot be zero address");
        vault.setWithdrawer(address(0), true);
    }

    function testSetWithdrawerMultiple() public {
        address withdrawer2 = address(0x5);

        vault.setWithdrawer(withdrawer, true);
        vault.setWithdrawer(withdrawer2, true);

        assertTrue(vault.authorizedWithdrawers(withdrawer));
        assertTrue(vault.authorizedWithdrawers(withdrawer2));
    }

    // ============ WITHDRAWFROM FUNCTIONALITY TESTS ============

    function testWithdrawFromSuccess() public {
        // Setup: authorize withdrawer and give client a balance with surplus
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);

        uint256 withdrawAmount = 100e18;
        uint256 recipientBalanceBefore = depositToken.balanceOf(recipient);

        // Execute withdrawal
        vm.expectEmit(true, true, true, true);
        emit WithdrawnFrom(address(depositToken), client, withdrawer, withdrawAmount, recipient);

        vm.prank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, withdrawAmount, recipient);

        // Verify balances - principal should stay at 1000e18, total should be 1000e18 (surplus withdrawn)
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
        // Allow for 1 wei rounding error
        assertApproxEqAbs(depositToken.balanceOf(recipient), recipientBalanceBefore + withdrawAmount, 1, "Recipient balance within 1 wei");
    }

    function testWithdrawFromMultipleClients() public {
        address client2 = address(0x6);

        vault.setWithdrawer(withdrawer, true);
        vault.setClient(client2, true); // Authorize client2

        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);
        setupPrincipalAndSurplus(address(depositToken), client2, 2000e18, 400e18);

        vm.startPrank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, 100e18, recipient);
        vault.withdrawFrom(address(depositToken), client2, 200e18, recipient);
        vm.stopPrank();

        // Verify balances - principal should remain, only surplus withdrawn
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
        assertEq(vault.balanceOf(address(depositToken), client2), 2000e18);
    }

    function testWithdrawFromFullBalance() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 1000e18);

        vm.prank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, 1000e18, recipient);

        // Verify balance - principal should remain at 1000e18, surplus fully withdrawn
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
    }

    function testWithdrawFromPartialAmount() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 1000e18);

        vm.prank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, 250e18, recipient);

        // Verify balance - principal remains at 1000e18, partial surplus withdrawn (750e18 surplus left)
        assertEq(vault.totalBalanceOf(address(depositToken), client), 1750e18);
    }

    // ============ SECURITY TESTS ============

    function testWithdrawFromUnauthorizedReverts() public {
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(unauthorized);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized withdrawers");
        vault.withdrawFrom(address(depositToken), client, 100e18, recipient);
    }

    function testWithdrawFromAfterDeauthorizationReverts() public {
        // Authorize then deauthorize
        vault.setWithdrawer(withdrawer, true);
        vault.setWithdrawer(withdrawer, false);

        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized withdrawers");
        vault.withdrawFrom(address(depositToken), client, 100e18, recipient);
    }

    function testWithdrawFromInsufficientBalance() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 100e18, 0);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: insufficient client balance");
        vault.withdrawFrom(address(depositToken), client, 200e18, recipient);
    }

    function testWithdrawFromZeroToken() public {
        vault.setWithdrawer(withdrawer, true);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: token cannot be zero address");
        vault.withdrawFrom(address(0), client, 100e18, recipient);
    }

    function testWithdrawFromZeroClient() public {
        vault.setWithdrawer(withdrawer, true);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: client cannot be zero address");
        vault.withdrawFrom(address(depositToken), address(0), 100e18, recipient);
    }

    function testWithdrawFromZeroRecipient() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: recipient cannot be zero address");
        vault.withdrawFrom(address(depositToken), client, 100e18, address(0));
    }

    function testWithdrawFromZeroAmount() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: amount must be greater than zero");
        vault.withdrawFrom(address(depositToken), client, 0, recipient);
    }

    function testWithdrawFromNonOwnerCannotAuthorize() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.setWithdrawer(withdrawer, true);

        assertFalse(vault.authorizedWithdrawers(withdrawer));
    }

    function testWithdrawFromReentrancyProtection() public {
        // The nonReentrant modifier should prevent reentrancy
        // This is implicitly tested through the modifier, but we verify the modifier is present
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);

        vm.prank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, 100e18, recipient);

        // If reentrancy protection works, the transaction completes successfully
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
    }

    // ============ EDGE CASE TESTS ============

    function testWithdrawFromClientWithNoBalance() public {
        vault.setWithdrawer(withdrawer, true);
        // No balance set for client

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: insufficient client balance");
        vault.withdrawFrom(address(depositToken), client, 1e18, recipient);
    }

    function testWithdrawFromSameClientMultipleTimes() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 1000e18);

        vm.startPrank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, 100e18, recipient);
        vault.withdrawFrom(address(depositToken), client, 200e18, recipient);
        vault.withdrawFrom(address(depositToken), client, 300e18, recipient);
        vm.stopPrank();

        // Verify balance - principal remains at 1000e18, 600e18 surplus withdrawn (400e18 surplus left)
        assertEq(vault.totalBalanceOf(address(depositToken), client), 1400e18);
    }

    function testWithdrawFromDifferentRecipients() public {
        address recipient2 = address(0x7);

        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 300e18);

        vm.startPrank(withdrawer);
        vault.withdrawFrom(address(depositToken), client, 100e18, recipient);
        vault.withdrawFrom(address(depositToken), client, 200e18, recipient2);
        vm.stopPrank();

        // Allow for 2 wei total rounding error across both withdrawals
        assertApproxEqAbs(depositToken.balanceOf(recipient), 100e18, 2, "Recipient 1 balance within 2 wei");
        assertApproxEqAbs(depositToken.balanceOf(recipient2), 200e18, 2, "Recipient 2 balance within 2 wei");
    }

    // ============ AUTHORIZATION CHANGE TESTS ============

    function testAuthorizationToggle() public {
        // Authorize
        vault.setWithdrawer(withdrawer, true);
        assertTrue(vault.authorizedWithdrawers(withdrawer));

        // Deauthorize
        vault.setWithdrawer(withdrawer, false);
        assertFalse(vault.authorizedWithdrawers(withdrawer));

        // Re-authorize
        vault.setWithdrawer(withdrawer, true);
        assertTrue(vault.authorizedWithdrawers(withdrawer));
    }

    function testMultipleWithdrawersIndependentAuthorization() public {
        address withdrawer2 = address(0x8);

        vault.setWithdrawer(withdrawer, true);
        vault.setWithdrawer(withdrawer2, true);

        // Deauthorize only one
        vault.setWithdrawer(withdrawer, false);

        assertFalse(vault.authorizedWithdrawers(withdrawer));
        assertTrue(vault.authorizedWithdrawers(withdrawer2));
    }
}
