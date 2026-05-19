// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IMigratorV1V2
 * @notice Interface for MigratorV1V2 — single-purpose contract that settles V1 reward
 *         obligations (USDC + phUSD) and re-stakes V1 deposits into PhlimboV2.
 */
interface IMigratorV1V2 {
    // ========================== EVENTS ==========================

    /**
     * @notice Emitted once when seedObligations is called.
     * @param userCount Number of V1 users seeded into the migrator.
     * @param totalUSDC Sum of all per-user USDC rewards owed.
     * @param totalPHUSD_deposited Sum of all per-user V1 deposits to be migrated.
     * @param totalPHUSD_pending Sum of all per-user pending phUSD rewards to be minted.
     */
    event Seeded(
        uint256 userCount,
        uint256 totalUSDC,
        uint256 totalPHUSD_deposited,
        uint256 totalPHUSD_pending
    );

    /**
     * @notice Emitted at the end of each settleDebt call.
     * @param iterator Updated settleIterator (-1 when settlement is complete).
     * @param remainingUSDC Remaining USDC obligations after this batch.
     * @param remainingPHUSDPending Remaining phUSD rewards still to mint.
     */
    event SettleProgress(int256 iterator, uint256 remainingUSDC, uint256 remainingPHUSDPending);

    /**
     * @notice Emitted at the end of each migrateDeposits call.
     * @param iterator Updated migrateIterator (-1 when migration is complete).
     * @param remainingDepositPHUSD Remaining phUSD still to re-stake into V2.
     */
    event MigrateProgress(int256 iterator, uint256 remainingDepositPHUSD);

    /**
     * @notice Emitted when withdrawAll drains the migrator's balances to the owner.
     * @param owner Owner that received the balances.
     * @param usdcAmount Amount of USDC transferred (may be 0).
     * @param phUSDAmount Amount of phUSD transferred (may be 0).
     */
    event WithdrawnAll(address indexed owner, uint256 usdcAmount, uint256 phUSDAmount);

    // ========================== FUNCTIONS ==========================

    /**
     * @notice One-shot seed of V1 user state. Owner-only.
     * @param _users V1 staker addresses.
     * @param _deposits Per-user V1 staked phUSD amounts.
     * @param _usdc Per-user pending USDC rewards owed.
     * @param _phUSD Per-user pending phUSD rewards owed (will be minted, not transferred).
     */
    function seedObligations(
        address[] calldata _users,
        uint256[] calldata _deposits,
        uint256[] calldata _usdc,
        uint256[] calldata _phUSD
    ) external;

    /**
     * @notice Pays out a batch of pending rewards. Transfers USDC, mints phUSD.
     * @param maxIterations Maximum number of users to process in this call.
     */
    function settleDebt(uint256 maxIterations) external;

    /**
     * @notice Re-stakes a batch of V1 deposits into PhlimboV2 on each user's behalf.
     * @param maxIterations Maximum number of users to process in this call.
     */
    function migrateDeposits(uint256 maxIterations) external;

    /**
     * @notice Owner-only escape hatch. Drains any USDC and phUSD balance to owner.
     */
    function withdrawAll() external;

    /**
     * @notice Returns the number of V1 users seeded into the migrator.
     */
    function userCount() external view returns (uint256);
}
