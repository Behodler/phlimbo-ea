// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockMainRewarder.sol";
import "../src/AYieldStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VaultSecurityTest
 * @notice Comprehensive test suite for Vault contract security features
 * @dev Tests all access control mechanisms, owner functions, and security edge cases
 * @dev Uses AutoDolaYieldStrategy (real implementation) with mocked external dependencies
 */
contract VaultSecurityTest is Test {
    AutoDolaYieldStrategy public vault;
    MockERC20 public token;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public bondingCurve = makeAddr("bondingCurve");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        // Deploy mock tokens
        token = new MockERC20("Test Token", "TEST", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock external dependencies
        mainRewarder = new MockMainRewarder(address(tokeToken));
        autoDolaVault = new MockAutoDOLA(address(token), address(mainRewarder));

        // Deploy the real AutoDolaYieldStrategy
        vault = new AutoDolaYieldStrategy(
            owner,
            address(token),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Setup initial tokens
        token.mint(user1, 1000000 * 1e18);
        token.mint(user2, 1000000 * 1e18);
        token.mint(attacker, 1000000 * 1e18);
        token.mint(bondingCurve, 10000000 * 1e18); // Give tokens to bonding curve for tests
        token.mint(address(autoDolaVault), 10000000 * 1e18); // For autoDOLA mock

        // Set bonding curve address as authorized client
        vm.prank(owner);
        vault.setClient(bondingCurve, true);

        // Give bonding curve approval for its own tokens
        vm.prank(bondingCurve);
        token.approve(address(vault), type(uint256).max);
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Helper to set up a specific principal and surplus scenario
     * @dev Deposits principal amount and simulates yield to create surplus
     * @param principalAmount The amount to deposit as principal
     * @param surplusAmount The additional yield to simulate
     */
    function setupPrincipalAndSurplus(uint256 principalAmount, uint256 surplusAmount) internal {
        // Deposit principal
        vm.startPrank(bondingCurve);
        token.approve(address(vault), principalAmount);
        vault.deposit(address(token), principalAmount, bondingCurve);
        vm.stopPrank();

        // Simulate yield by minting tokens to the autoDOLA vault
        if (surplusAmount > 0) {
            token.mint(address(autoDolaVault), surplusAmount);
        }
    }
    
    // ============ BONDING CURVE ACCESS CONTROL TESTS ============
    
    function testOnlyBondingCurveCanDeposit() public {
        // Arrange
        uint256 amount = 1000 * 1e18;
        
        // Act & Assert - Only bonding curve can deposit
        vm.prank(bondingCurve);
        vault.deposit(address(token), amount, bondingCurve); // Deposit to bonding curve itself
        
        // Verify deposit worked
        assertEq(vault.balanceOf(address(token), bondingCurve), amount);
    }
    
    function testUnauthorizedDepositReverts() public {
        // Arrange
        uint256 amount = 1000 * 1e18;
        vm.prank(user1);
        token.approve(address(vault), amount);
        
        // Act & Assert - User cannot deposit directly
        vm.prank(user1);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.deposit(address(token), amount, user1);
        
        // Act & Assert - Attacker cannot deposit
        vm.prank(attacker);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.deposit(address(token), amount, user1);
        
        // Act & Assert - Owner cannot deposit (unless they are also authorized client)
        vm.prank(owner);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.deposit(address(token), amount, user1);
    }
    
    function testOnlyBondingCurveCanWithdraw() public {
        // Arrange - First deposit some tokens
        uint256 depositAmount = 1000 * 1e18;
        uint256 bondingCurveInitialBalance = token.balanceOf(bondingCurve);

        vm.prank(bondingCurve);
        vault.deposit(address(token), depositAmount, bondingCurve); // Deposit to bonding curve itself

        // Act & Assert - Only bonding curve can withdraw
        uint256 withdrawAmount = 500 * 1e18;
        vm.prank(bondingCurve);
        vault.withdraw(address(token), withdrawAmount, bondingCurve);

        // Verify withdrawal worked
        assertEq(vault.balanceOf(address(token), bondingCurve), depositAmount - withdrawAmount);
        assertEq(token.balanceOf(bondingCurve), bondingCurveInitialBalance - depositAmount + withdrawAmount);
    }
    
    function testUnauthorizedWithdrawReverts() public {
        // Arrange - First deposit some tokens
        uint256 depositAmount = 1000 * 1e18;
        
        vm.prank(bondingCurve);
        vault.deposit(address(token), depositAmount, bondingCurve);
        
        uint256 withdrawAmount = 500 * 1e18;
        
        // Act & Assert - User cannot withdraw directly
        vm.prank(user1);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.withdraw(address(token), withdrawAmount, user1);
        
        // Act & Assert - Attacker cannot withdraw
        vm.prank(attacker);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.withdraw(address(token), withdrawAmount, attacker);
        
        // Act & Assert - Owner cannot withdraw (unless they are also bonding curve)
        vm.prank(owner);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.withdraw(address(token), withdrawAmount, owner);
    }
    
    // ============ OWNER ACCESS CONTROL TESTS ============
    
    function testOnlyOwnerCanSetClient() public {
        address newClient = makeAddr("newClient");
        
        // Act & Assert - Owner can set client authorization
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.ClientAuthorizationSet(newClient, true);
        vault.setClient(newClient, true);
        
        // Verify change
        assertTrue(vault.authorizedClients(newClient));
    }
    
    function testUnauthorizedSetClientReverts() public {
        address newClient = makeAddr("newClient");
        
        // Act & Assert - User cannot set client authorization
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vault.setClient(newClient, true);
        
        // Act & Assert - Attacker cannot set client authorization
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setClient(newClient, true);
        
        // Act & Assert - Bonding curve itself cannot change the setting
        vm.prank(bondingCurve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bondingCurve));
        vault.setClient(newClient, true);
        
        // Verify no change occurred for new client
        assertFalse(vault.authorizedClients(newClient));
        // Original client should still be authorized
        assertTrue(vault.authorizedClients(bondingCurve));
    }
    
    function testOnlyOwnerCanEmergencyWithdraw() public {
        // First deposit some tokens so there are shares to withdraw
        uint256 depositAmount = 1000 * 1e18;
        vm.prank(bondingCurve);
        vault.deposit(address(token), depositAmount, bondingCurve);

        uint256 amount = 100 * 1e18;

        // Act & Assert - Owner can call emergency withdraw
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.EmergencyWithdraw(owner, amount);
        vault.emergencyWithdraw(amount);
    }
    
    function testUnauthorizedEmergencyWithdrawReverts() public {
        uint256 amount = 100 * 1e18;
        
        // Act & Assert - User cannot emergency withdraw
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vault.emergencyWithdraw(amount);
        
        // Act & Assert - Attacker cannot emergency withdraw
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.emergencyWithdraw(amount);
        
        // Act & Assert - Bonding curve cannot emergency withdraw
        vm.prank(bondingCurve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bondingCurve));
        vault.emergencyWithdraw(amount);
    }
    
    // ============ INPUT VALIDATION TESTS ============
    
    function testSetClientZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert("AYieldStrategy: client cannot be zero address");
        vault.setClient(address(0), true);
    }
    
    function testEmergencyWithdrawZeroAmountReverts() public {
        vm.prank(owner);
        vm.expectRevert("AYieldStrategy: amount must be greater than zero");
        vault.emergencyWithdraw(0);
    }
    
    function testDepositValidation() public {
        uint256 amount = 1000 * 1e18;

        vm.startPrank(bondingCurve);

        // Zero amount should revert
        vm.expectRevert("AutoDolaYieldStrategy: amount must be greater than zero");
        vault.deposit(address(token), 0, user1);

        // Zero recipient address should revert
        vm.expectRevert("AutoDolaYieldStrategy: recipient cannot be zero address");
        vault.deposit(address(token), amount, address(0));

        vm.stopPrank();
    }

    function testWithdrawValidation() public {
        // First deposit some tokens
        uint256 depositAmount = 1000 * 1e18;

        vm.prank(bondingCurve);
        vault.deposit(address(token), depositAmount, bondingCurve);

        vm.startPrank(bondingCurve);

        // Zero amount should revert
        vm.expectRevert("AutoDolaYieldStrategy: amount must be greater than zero");
        vault.withdraw(address(token), 0, user1);

        // Zero recipient address should revert
        vm.expectRevert("AutoDolaYieldStrategy: recipient cannot be zero address");
        vault.withdraw(address(token), 500 * 1e18, address(0));

        vm.stopPrank();
    }
    
    // ============ EDGE CASE AND INTEGRATION TESTS ============
    
    function testClientAuthorizationCanBeChanged() public {
        address newClient = makeAddr("newClient");

        // Setup initial deposit with old client
        uint256 amount = 1000 * 1e18;

        vm.prank(bondingCurve);
        vault.deposit(address(token), amount, bondingCurve);

        // Change client authorization - deauthorize old, authorize new
        vm.prank(owner);
        vault.setClient(bondingCurve, false);
        vm.prank(owner);
        vault.setClient(newClient, true);

        // Give new client tokens and approval
        token.mint(newClient, 1000000 * 1e18);
        vm.prank(newClient);
        token.approve(address(vault), type(uint256).max);

        // Old client should no longer work for new deposits
        vm.prank(bondingCurve);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.deposit(address(token), 100 * 1e18, bondingCurve);

        // New client should work for new deposits
        vm.prank(newClient);
        vault.deposit(address(token), 100 * 1e18, newClient);

        // Verify state
        assertEq(vault.balanceOf(address(token), bondingCurve), amount); // Old balance unchanged
        assertEq(vault.balanceOf(address(token), newClient), 100 * 1e18); // New deposit
    }
    
    function testOwnershipTransferMaintainsAccessControl() public {
        address newOwner = makeAddr("newOwner");
        
        // Transfer ownership
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        
        // Old owner should no longer be able to set client authorization
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setClient(makeAddr("anotherClient"), true);
        
        // New owner should be able to set client authorization
        address anotherClient = makeAddr("anotherClient");
        vm.prank(newOwner);
        vault.setClient(anotherClient, true);
        
        assertTrue(vault.authorizedClients(anotherClient));
    }
    
    // Note: testMultipleTokensAccessControl removed - AutoDolaYieldStrategy is bound to a single token
    // Multi-token support is not part of the AutoDolaYieldStrategy design
    
    // ============ EVENTS TESTING ============
    
    function testClientAuthorizationSetEventEmission() public {
        address newClient = makeAddr("newClient");
        
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.ClientAuthorizationSet(newClient, true);
        vault.setClient(newClient, true);
    }
    
    function testEmergencyWithdrawEventEmission() public {
        // First deposit some tokens so there are shares to withdraw
        uint256 depositAmount = 1000 * 1e18;
        vm.prank(bondingCurve);
        vault.deposit(address(token), depositAmount, bondingCurve);

        uint256 amount = 100 * 1e18;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.EmergencyWithdraw(owner, amount);
        vault.emergencyWithdraw(amount);
    }
    
    // ============ INTEGRATION WITH EXISTING FUNCTIONALITY ============
    
    function testSecurityDoesNotBreakNormalOperations() public {
        uint256 amount = 1000 * 1e18;
        uint256 bondingCurveInitialBalance = token.balanceOf(bondingCurve);

        // Bonding curve deposits (approval already set in setUp)
        vm.prank(bondingCurve);
        vault.deposit(address(token), amount, bondingCurve);

        assertEq(vault.balanceOf(address(token), bondingCurve), amount);

        // Bonding curve withdraws
        uint256 withdrawAmount = 600 * 1e18;
        vm.prank(bondingCurve);
        vault.withdraw(address(token), withdrawAmount, bondingCurve);

        assertEq(vault.balanceOf(address(token), bondingCurve), amount - withdrawAmount);
        assertEq(token.balanceOf(bondingCurve), bondingCurveInitialBalance - amount + withdrawAmount);
    }

    // ============ MULTIPLE CLIENT AUTHORIZATION TESTS ============
    
    function testMultipleClientsCanBeAuthorized() public {
        address client1 = makeAddr("client1");
        address client2 = makeAddr("client2");
        address client3 = makeAddr("client3");
        
        // Authorize multiple clients
        vm.prank(owner);
        vault.setClient(client1, true);
        vm.prank(owner);
        vault.setClient(client2, true);
        vm.prank(owner);
        vault.setClient(client3, true);
        
        // Verify all are authorized
        assertTrue(vault.authorizedClients(client1));
        assertTrue(vault.authorizedClients(client2));
        assertTrue(vault.authorizedClients(client3));
        assertTrue(vault.authorizedClients(bondingCurve)); // Original should still be authorized
    }
    
    function testMultipleClientsCanDepositAndWithdraw() public {
        address client1 = makeAddr("client1");
        address client2 = makeAddr("client2");
        uint256 amount = 500 * 1e18;
        
        // Authorize additional clients
        vm.prank(owner);
        vault.setClient(client1, true);
        vm.prank(owner);
        vault.setClient(client2, true);
        
        // Give clients tokens and approvals
        token.mint(client1, 1000000 * 1e18);
        token.mint(client2, 1000000 * 1e18);
        vm.prank(client1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(client2);
        token.approve(address(vault), type(uint256).max);
        
        // All clients should be able to deposit
        vm.prank(bondingCurve);
        vault.deposit(address(token), amount, bondingCurve);
        vm.prank(client1);
        vault.deposit(address(token), amount, client1);
        vm.prank(client2);
        vault.deposit(address(token), amount, client2);
        
        // Verify balances
        assertEq(vault.balanceOf(address(token), bondingCurve), amount);
        assertEq(vault.balanceOf(address(token), client1), amount);
        assertEq(vault.balanceOf(address(token), client2), amount);
        
        // All clients should be able to withdraw their own deposits
        vm.prank(bondingCurve);
        vault.withdraw(address(token), amount / 2, bondingCurve);
        vm.prank(client1);
        vault.withdraw(address(token), amount / 2, client1);
        vm.prank(client2);
        vault.withdraw(address(token), amount / 2, client2);

        // Verify remaining balances
        assertEq(vault.balanceOf(address(token), bondingCurve), amount - amount / 2);
        assertEq(vault.balanceOf(address(token), client1), amount - amount / 2);
        assertEq(vault.balanceOf(address(token), client2), amount - amount / 2);
    }
    
    function testClientAuthorizationCanBeRevoked() public {
        address client1 = makeAddr("client1");
        uint256 amount = 500 * 1e18;
        
        // Authorize client
        vm.prank(owner);
        vault.setClient(client1, true);
        assertTrue(vault.authorizedClients(client1));
        
        // Give client tokens and approval
        token.mint(client1, 1000000 * 1e18);
        vm.prank(client1);
        token.approve(address(vault), type(uint256).max);
        
        // Client can deposit
        vm.prank(client1);
        vault.deposit(address(token), amount, client1);
        assertEq(vault.balanceOf(address(token), client1), amount);
        
        // Revoke authorization
        vm.prank(owner);
        vault.setClient(client1, false);
        assertFalse(vault.authorizedClients(client1));
        
        // Client should no longer be able to deposit
        vm.prank(client1);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.deposit(address(token), amount, client1);
        
        // Client should no longer be able to withdraw
        vm.prank(client1);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.withdraw(address(token), amount, client1);
    }
    
    function testUnauthorizedClientCannotDepositOrWithdraw() public {
        address unauthorizedClient = makeAddr("unauthorizedClient");
        uint256 amount = 500 * 1e18;
        
        // Give client tokens and approval
        token.mint(unauthorizedClient, 1000000 * 1e18);
        vm.prank(unauthorizedClient);
        token.approve(address(vault), type(uint256).max);
        
        // Unauthorized client cannot deposit
        vm.prank(unauthorizedClient);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.deposit(address(token), amount, unauthorizedClient);
        
        // Unauthorized client cannot withdraw
        vm.prank(unauthorizedClient);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vault.withdraw(address(token), amount, unauthorizedClient);
        
        // Verify client is not authorized
        assertFalse(vault.authorizedClients(unauthorizedClient));
    }
    
    function testMultipleClientAuthorizationEvents() public {
        address client1 = makeAddr("client1");
        address client2 = makeAddr("client2");
        
        // Test authorization events
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.ClientAuthorizationSet(client1, true);
        vault.setClient(client1, true);
        
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.ClientAuthorizationSet(client2, true);
        vault.setClient(client2, true);
        
        // Test revocation events
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.ClientAuthorizationSet(client1, false);
        vault.setClient(client1, false);
        
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AYieldStrategy.ClientAuthorizationSet(client2, false);
        vault.setClient(client2, false);
    }
}