// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/SurplusWithdrawer.sol";
import "../src/SurplusTracker.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockMainRewarder.sol";

/**
 * @title SurplusWithdrawerTest
 * @notice Comprehensive unit tests for SurplusWithdrawer contract
 * @dev Uses AutoDolaYieldStrategy (real implementation) with mocked external dependencies
 */
contract SurplusWithdrawerTest is Test {
    SurplusWithdrawer public withdrawer;
    SurplusTracker public tracker;
    AutoDolaYieldStrategy public vault;
    MockERC20 public token;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner;
    address public client;
    address public recipient;
    address public nonOwner;

    event ConfigurationUpdated(
        address indexed token,
        address indexed vault,
        address indexed yieldStrategy,
        address client
    );

    event SurplusWithdrawn(
        address indexed vault,
        address indexed token,
        address indexed client,
        uint256 percentage,
        uint256 amount,
        address recipient
    );

    function setUp() public {
        owner = address(this);
        client = address(0x1);
        recipient = address(0x2);
        nonOwner = address(0x3);

        // Deploy tracker
        tracker = new SurplusTracker();

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

        // Deploy withdrawer
        withdrawer = new SurplusWithdrawer(address(tracker), owner);

        // Setup vault
        vault.setClient(client, true);
        vault.setWithdrawer(address(withdrawer), true);

        // Configure withdrawer with token, vault, yieldStrategy, and client
        withdrawer.configure(address(token), address(vault), address(vault), client);

        // Mint tokens to client and autoDolaVault for testing
        token.mint(client, 10000e18);
        token.mint(address(autoDolaVault), 10000e18); // For autoDOLA mock
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
        vm.startPrank(client);
        token.approve(address(vault), principalAmount);
        vault.deposit(address(token), principalAmount, client);
        vm.stopPrank();

        // Simulate yield if surplus is needed
        if (surplusAmount > 0) {
            autoDolaVault.simulateYield(surplusAmount);
        }
    }

    // ============ CONSTRUCTOR TESTS ============

    function testConstructorWithValidInputs() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);
        assertEq(address(newWithdrawer.surplusTracker()), address(tracker), "Tracker should be set");
        assertEq(newWithdrawer.owner(), owner, "Owner should be set");
    }

    function testConstructorRevertsWithZeroTracker() public {
        vm.expectRevert("SurplusWithdrawer: tracker cannot be zero address");
        new SurplusWithdrawer(address(0), owner);
    }

    function testConstructorRevertsWithZeroOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new SurplusWithdrawer(address(tracker), address(0));
    }

    // ============ CONFIGURATION TESTS ============

    function testConfigureWithValidInputs() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit ConfigurationUpdated(address(token), address(vault), address(vault), client);

        newWithdrawer.configure(address(token), address(vault), address(vault), client);

        assertEq(newWithdrawer.token(), address(token), "Token should be set");
        assertEq(newWithdrawer.vault(), address(vault), "Vault should be set");
        assertEq(newWithdrawer.yieldStrategy(), address(vault), "YieldStrategy should be set");
        assertEq(newWithdrawer.client(), client, "Client should be set");
    }

    function testConfigureRevertsWithZeroToken() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        vm.expectRevert("SurplusWithdrawer: token cannot be zero address");
        newWithdrawer.configure(address(0), address(vault), address(vault), client);
    }

    function testConfigureRevertsWithZeroVault() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        vm.expectRevert("SurplusWithdrawer: vault cannot be zero address");
        newWithdrawer.configure(address(token), address(0), address(vault), client);
    }

    function testConfigureRevertsWithZeroYieldStrategy() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        vm.expectRevert("SurplusWithdrawer: yieldStrategy cannot be zero address");
        newWithdrawer.configure(address(token), address(vault), address(0), client);
    }

    function testConfigureRevertsWithZeroClient() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        vm.expectRevert("SurplusWithdrawer: client cannot be zero address");
        newWithdrawer.configure(address(token), address(vault), address(vault), address(0));
    }

    function testConfigureRevertsWhenCalledByNonOwner() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        newWithdrawer.configure(address(token), address(vault), address(vault), client);
        vm.stopPrank();
    }

    function testConfigureCanBeUpdated() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        // Initial configuration
        newWithdrawer.configure(address(token), address(vault), address(vault), client);
        assertEq(newWithdrawer.token(), address(token), "Token should be set initially");

        // Create new token, vault, and client
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        MockERC20 newTokeToken = new MockERC20("TOKE2", "TOKE2", 18);
        MockMainRewarder newRewarder = new MockMainRewarder(address(newTokeToken));
        MockAutoDOLA newAutoDolaVault = new MockAutoDOLA(address(newToken), address(newRewarder));
        AutoDolaYieldStrategy newVault = new AutoDolaYieldStrategy(
            owner,
            address(newToken),
            address(newTokeToken),
            address(newAutoDolaVault),
            address(newRewarder)
        );
        address newClient = address(0x99);

        // Update configuration
        vm.expectEmit(true, true, true, true);
        emit ConfigurationUpdated(address(newToken), address(newVault), address(newVault), newClient);

        newWithdrawer.configure(address(newToken), address(newVault), address(newVault), newClient);

        assertEq(newWithdrawer.token(), address(newToken), "Token should be updated");
        assertEq(newWithdrawer.vault(), address(newVault), "Vault should be updated");
        assertEq(newWithdrawer.yieldStrategy(), address(newVault), "YieldStrategy should be updated");
        assertEq(newWithdrawer.client(), newClient, "Client should be updated");
    }

    // ============ UNCONFIGURED STATE TESTS ============

    function testWithdrawSurplusPercentRevertsWhenNotConfigured() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);

        // Try to withdraw without configuration
        vm.expectRevert("SurplusWithdrawer: not configured - token is zero address");
        newWithdrawer.withdrawSurplusPercent(50, recipient);
    }

    // ============ PERCENTAGE VALIDATION TESTS ============

    function testWithdrawSurplusPercentRevertsWithZeroPercentage() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Try to withdraw 0%
        vm.expectRevert("SurplusWithdrawer: percentage must be between 1 and 100");
        withdrawer.withdrawSurplusPercent(0, recipient);
    }

    function testWithdrawSurplusPercentRevertsWithPercentageOver100() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Try to withdraw 101%
        vm.expectRevert("SurplusWithdrawer: percentage must be between 1 and 100");
        withdrawer.withdrawSurplusPercent(101, recipient);
    }

    function testWithdrawSurplusPercentRevertsWithPercentage200() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Try to withdraw 200%
        vm.expectRevert("SurplusWithdrawer: percentage must be between 1 and 100");
        withdrawer.withdrawSurplusPercent(200, recipient);
    }

    function testWithdrawSurplusPercentAllowsPercentage1() public {
        // Setup: Client has principal of 900 and surplus of 100 (total 1000)
        setupPrincipalAndSurplus(900e18, 100e18);

        // Withdraw 1% (boundary test)
        uint256 amount = withdrawer.withdrawSurplusPercent(1, recipient);

        // 1% of 100 = 1
        assertEq(amount, 1e18, "Should withdraw 1% of surplus");
        assertEq(token.balanceOf(recipient), 1e18, "Recipient should receive 1 token");
    }

    function testWithdrawSurplusPercentAllowsPercentage100() public {
        // Setup: Client has principal of 900 and surplus of 100 (total 1000)
        setupPrincipalAndSurplus(900e18, 100e18);

        // Withdraw 100% (boundary test)
        uint256 amount = withdrawer.withdrawSurplusPercent(100, recipient);

        // 100% of 100 = 100
        assertEq(amount, 100e18, "Should withdraw 100% of surplus");
        assertEq(token.balanceOf(recipient), 100e18, "Recipient should receive 100 tokens");
    }

    // ============ PERCENTAGE CALCULATION TESTS ============

    function testWithdrawSurplusPercent50Percent() public {
        // Setup: Client has principal of 800 and surplus of 200 (total 1000)
        setupPrincipalAndSurplus(800e18, 200e18);

        // Withdraw 50%
        uint256 amount = withdrawer.withdrawSurplusPercent(50, recipient);

        // 50% of 200 = 100
        assertEq(amount, 100e18, "Should withdraw 50% of surplus");
        assertEq(token.balanceOf(recipient), 100e18, "Recipient should receive 100 tokens");
    }

    function testWithdrawSurplusPercent25Percent() public {
        // Setup: Client has principal of 600 and surplus of 400 (total 1000)
        setupPrincipalAndSurplus(600e18, 400e18);

        // Withdraw 25%
        uint256 amount = withdrawer.withdrawSurplusPercent(25, recipient);

        // 25% of 400 = 100
        assertEq(amount, 100e18, "Should withdraw 25% of surplus");
        assertEq(token.balanceOf(recipient), 100e18, "Recipient should receive 100 tokens");
    }

    function testWithdrawSurplusPercent75Percent() public {
        // Setup: Client has principal of 600 and surplus of 400 (total 1000)
        setupPrincipalAndSurplus(600e18, 400e18);

        // Withdraw 75%
        uint256 amount = withdrawer.withdrawSurplusPercent(75, recipient);

        // 75% of 400 = 300
        assertEq(amount, 300e18, "Should withdraw 75% of surplus");
        assertEq(token.balanceOf(recipient), 300e18, "Recipient should receive 300 tokens");
    }

    function testWithdrawSurplusPercentWithLargeSurplus() public {
        // Setup: Client has principal of 5000 and surplus of 5000 (total 10000)
        setupPrincipalAndSurplus(5000e18, 5000e18);

        // Withdraw 30%
        uint256 amount = withdrawer.withdrawSurplusPercent(30, recipient);

        // 30% of 5000 = 1500
        assertEq(amount, 1500e18, "Should withdraw 30% of surplus");
        assertEq(token.balanceOf(recipient), 1500e18, "Recipient should receive 1500 tokens");
    }

    function testWithdrawSurplusPercentWithSmallSurplus() public {
        // Setup: Client has principal of 100 and surplus of 10 (total 110)
        setupPrincipalAndSurplus(100e18, 10e18);

        // Withdraw 50%
        uint256 amount = withdrawer.withdrawSurplusPercent(50, recipient);

        // 50% of 10 = 5
        assertEq(amount, 5e18, "Should withdraw 50% of surplus");
        // Use approximate equality to allow for 1 wei rounding error
        assertApproxEqAbs(token.balanceOf(recipient), 5e18, 1, "Recipient should receive 5 tokens (within 1 wei)");
    }

    // ============ INPUT VALIDATION TESTS ============

    function testWithdrawSurplusPercentRevertsWithZeroRecipient() public {
        // Setup: Client has principal of 900 and surplus of 100
        setupPrincipalAndSurplus(900e18, 100e18);

        vm.expectRevert("SurplusWithdrawer: recipient cannot be zero address");
        withdrawer.withdrawSurplusPercent(50, address(0));
    }

    function testWithdrawSurplusPercentRevertsWithNoSurplus() public {
        // Setup: Client has 1000 tokens in vault and principal is also 1000 (no surplus)
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Principal matches vault balance (no surplus)
        // Note: MockVault already sets principal = balance on deposit, so no need to set separately

        vm.expectRevert("SurplusWithdrawer: no surplus to withdraw");
        withdrawer.withdrawSurplusPercent(50, recipient);
    }

    // ============ ACCESS CONTROL TESTS ============

    function testWithdrawSurplusPercentRevertsWhenCalledByNonOwner() public {
        // Setup: Client has principal of 900 and surplus of 100
        setupPrincipalAndSurplus(900e18, 100e18);

        // Try to withdraw as non-owner
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        withdrawer.withdrawSurplusPercent(50, recipient);
        vm.stopPrank();
    }

    function testWithdrawSurplusPercentSucceedsWhenCalledByOwner() public {
        // Setup: Client has principal of 900 and surplus of 100
        setupPrincipalAndSurplus(900e18, 100e18);

        // Withdraw as owner (owner is address(this))
        uint256 amount = withdrawer.withdrawSurplusPercent(50, recipient);

        assertEq(amount, 50e18, "Should withdraw 50% of surplus");
    }

    // ============ EVENT TESTS ============

    function testWithdrawSurplusPercentEmitsEvent() public {
        // Setup: Client has principal of 800 and surplus of 200
        setupPrincipalAndSurplus(800e18, 200e18);

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit SurplusWithdrawn(
            address(vault),
            address(token),
            client,
            50,
            100e18,
            recipient
        );

        // Withdraw 50%
        withdrawer.withdrawSurplusPercent(50, recipient);
    }

    // ============ INTEGRATION TESTS ============

    function testWithdrawSurplusPercentUpdatesVaultBalance() public {
        // Setup: Client has principal of 900 and surplus of 100
        setupPrincipalAndSurplus(900e18, 100e18);

        // Get initial principal (balanceOf returns principal in AutoDolaYieldStrategy)
        uint256 initialPrincipal = vault.balanceOf(address(token), client);
        assertEq(initialPrincipal, 900e18, "Initial principal should be 900");

        // Withdraw 50% of surplus
        uint256 amount = withdrawer.withdrawSurplusPercent(50, recipient);

        // Get final principal
        uint256 finalPrincipal = vault.balanceOf(address(token), client);

        // Principal should remain unchanged (withdrawFrom only touches surplus)
        assertEq(finalPrincipal, initialPrincipal, "Principal should remain unchanged");
        assertEq(finalPrincipal, 900e18, "Principal should still be 900");
    }

    function testMultipleWithdrawalsReduceSurplus() public {
        // Setup: Client has principal of 800 and surplus of 200
        setupPrincipalAndSurplus(800e18, 200e18);
        uint256 principalBalance = 800e18;

        // First withdrawal: 25% of 200 = 50
        uint256 amount1 = withdrawer.withdrawSurplusPercent(25, recipient);
        assertEq(amount1, 50e18, "First withdrawal should be 50");

        // After first withdrawal: surplus = 150
        uint256 surplus1 = tracker.getSurplus(address(vault), address(token), client, principalBalance);
        assertEq(surplus1, 150e18, "Surplus after first withdrawal should be 150");

        // Second withdrawal: 50% of 150 = 75
        uint256 amount2 = withdrawer.withdrawSurplusPercent(50, recipient);
        assertEq(amount2, 75e18, "Second withdrawal should be 75");

        // After second withdrawal: surplus = 75
        uint256 surplus2 = tracker.getSurplus(address(vault), address(token), client, principalBalance);
        assertEq(surplus2, 75e18, "Surplus after second withdrawal should be 75");

        // Total withdrawn should be 125
        assertEq(token.balanceOf(recipient), 125e18, "Total withdrawn should be 125");
    }
}
