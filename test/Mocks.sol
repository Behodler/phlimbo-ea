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
 * @title MockUSDC6
 * @notice Mock 6-decimal ERC20 (USDC-style) for partner-token decimals testing
 */
contract MockUSDC6 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockFeeToken
 * @notice Fee-on-transfer ERC20 (1% burned on every transfer) used to verify the
 *         balance-delta guard in startPromotion/topUpPromotion.
 */
contract MockFeeToken is ERC20 {
    constructor() ERC20("Mock Fee Token", "mFEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            if (fee > 0) {
                super._update(from, address(0), fee);
            }
        } else {
            super._update(from, to, value);
        }
    }
}

/**
 * @title MockBlocklistToken
 * @notice ERC20 with a USDT-style recipient blocklist. Transfers to a blocked
 *         address revert — used to verify batchClaim's non-reverting transfer
 *         path banks failed amounts into unclaimablePromo.
 */
contract MockBlocklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Mock Blocklist Token", "mBLK") {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "recipient blocked");
        super._update(from, to, value);
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
