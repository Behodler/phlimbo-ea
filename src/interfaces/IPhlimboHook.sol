// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IPhlimboHook
 * @notice Generic hook interface invoked by PhlimboV2 after stake, withdraw, and claim actions.
 * @dev Implementations receive both the caller (msg.sender that initiated the action) and the
 *      user whose balance/rewards are affected. This is enough information to implement
 *      migration accounting, analytics, or governance side effects.
 *
 *      Hooks fire AFTER all internal state mutations and external token transfers complete,
 *      inside PhlimboV2's `nonReentrant` guard. The owner of PhlimboV2 is trusted to set
 *      non-malicious hooks; a reverting hook will revert the outer call.
 */
interface IPhlimboHook {
    /**
     * @notice Called after a successful stake.
     * @param caller The msg.sender that initiated the stake (user or migrator).
     * @param user The address whose `userInfo.amount` was credited.
     * @param amount The amount of phUSD staked.
     */
    function onDeposit(address caller, address user, uint256 amount) external;

    /**
     * @notice Called after a successful withdraw.
     * @param caller The msg.sender that initiated the withdraw (user or migrator).
     * @param user The address whose `userInfo.amount` was debited.
     * @param amount The amount of phUSD withdrawn (may be larger than the requested amount
     *               if a dust-prevention forced-full-withdraw kicked in).
     */
    function onWithdraw(address caller, address user, uint256 amount) external;

    /**
     * @notice Called after a successful claim of pending rewards.
     * @param caller The msg.sender that initiated the claim (user or migrator).
     * @param user The address whose accrued rewards were drained.
     * @param phUSDAmount The amount of phUSD minted to the caller.
     * @param stableAmount The amount of stable reward token transferred to the caller.
     */
    function onClaim(address caller, address user, uint256 phUSDAmount, uint256 stableAmount) external;
}
