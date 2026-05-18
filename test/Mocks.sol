// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/IFlax.sol";
import "../src/interfaces/IPhlimboHook.sol";

/**
 * @title MockFlax
 * @notice Mock implementation of IFlax for testing
 */
contract MockFlax is ERC20 {
    mapping(address => bool) public minters;

    constructor() ERC20("Mock Flax", "mFLX") {}

    function setMinter(address minter, bool canMint) external {
        minters[minter] = canMint;
    }

    function mint(address recipient, uint256 amount) external {
        // Allow anyone to mint for testing purposes
        _mint(recipient, amount);
    }

    function burn(address holder, uint256 amount) external {
        _burn(holder, amount);
    }

    function authorizedMinters(address minter) external view returns (IFlax.MinterInfo memory) {
        return IFlax.MinterInfo({canMint: minters[minter], mintVersion: 1});
    }

    function mintVersion() external pure returns (uint256) {
        return 1;
    }

    function revokeAllMintPrivileges() external {
        // No-op for testing
    }
}

/**
 * @title MockStable
 * @notice Mock stablecoin token for testing
 */
contract MockStable is ERC20 {
    constructor() ERC20("Mock Stable", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockPhlimboHook
 * @notice Records every call from PhlimboV2 so tests can assert on caller/user/amount.
 */
contract MockPhlimboHook is IPhlimboHook {
    struct Call {
        string kind; // "deposit" | "withdraw" | "claim"
        address caller;
        address user;
        uint256 amount;        // stake amount or withdraw amount; 0 for claim
        uint256 phUSDAmount;   // claim only
        uint256 stableAmount;  // claim only
    }

    Call[] public calls;
    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public claimCount;

    function onDeposit(address caller, address user, uint256 amount) external {
        calls.push(Call("deposit", caller, user, amount, 0, 0));
        depositCount++;
    }

    function onWithdraw(address caller, address user, uint256 amount) external {
        calls.push(Call("withdraw", caller, user, amount, 0, 0));
        withdrawCount++;
    }

    function onClaim(address caller, address user, uint256 phUSDAmount, uint256 stableAmount) external {
        calls.push(Call("claim", caller, user, 0, phUSDAmount, stableAmount));
        claimCount++;
    }

    function callsLength() external view returns (uint256) {
        return calls.length;
    }

    function lastCall() external view returns (Call memory) {
        return calls[calls.length - 1];
    }
}

/**
 * @title RevertingPhlimboHook
 * @notice Always reverts to verify hook revert propagation.
 */
contract RevertingPhlimboHook is IPhlimboHook {
    string public reason;

    constructor(string memory _reason) {
        reason = _reason;
    }

    function onDeposit(address, address, uint256) external view {
        revert(reason);
    }

    function onWithdraw(address, address, uint256) external view {
        revert(reason);
    }

    function onClaim(address, address, uint256, uint256) external view {
        revert(reason);
    }
}
