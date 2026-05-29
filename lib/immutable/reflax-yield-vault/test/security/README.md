# Security Test Suite

This directory contains proof-of-concept tests for vulnerabilities identified during the security audit of AutoDolaYieldStrategy.

## Test Files

### EmergencyWithdrawYieldLoss.t.sol
**Vulnerability**: L1 - Emergency Withdrawal Missing Re-Stake Logic
**Severity**: LOW

Tests that `_emergencyWithdraw()` does not re-stake remaining shares after partial emergency withdrawal, causing yield generation to stop.

**Run**: `forge test --match-contract EmergencyWithdrawYieldLossTest -vvv`

**Tests**:
- `testEmergencyWithdrawLeavesSharesUnstaked()` - Demonstrates shares sitting unstaked
- `testTokeRewardsStopAfterEmergencyWithdrawal()` - Shows TOKE rewards stop accumulating
- `testRegularWithdrawCorrectlyReStakes()` - Compares with correct behavior
- `testUserFundsRemainSafeDespiteYieldLoss()` - Confirms principal safety

---

### UnlimitedApprovalRisk.t.sol
**Vulnerability**: M1 - Unlimited Token Approvals to External Contracts
**Severity**: MEDIUM

Tests that unlimited approvals (type(uint256).max) to autoDOLA vault and MainRewarder create risk if those contracts are compromised.

**Run**: `forge test --match-contract UnlimitedApprovalRiskTest -vvv`

**Tests**:
- `testMaliciousVaultCanDrainDOLA()` - Demonstrates DOLA drainage via malicious vault
- `testMaliciousRewarderCanDrainShares()` - Demonstrates share drainage via malicious rewarder
- `testApprovalsAreUnlimited()` - Confirms approvals are type(uint256).max
- `testLargeFundExploit()` - Shows realistic high-value exploit scenario

**Note**: This test uses mock malicious contracts to demonstrate the exploit vector. In production, this would require actual compromise of Tokemak's contracts.

---

## Running All Security Tests

```bash
# Run all security tests
forge test --match-path "test/security/*.sol" -vvv

# Run specific test file
forge test --match-contract EmergencyWithdrawYieldLossTest -vvv
forge test --match-contract UnlimitedApprovalRiskTest -vvv

# Run with gas reporting
forge test --match-path "test/security/*.sol" --gas-report
```

## Vulnerability Summary

| ID | Severity | Description | Test File |
|----|----------|-------------|-----------|
| M1 | MEDIUM | Unlimited token approvals to external contracts | UnlimitedApprovalRisk.t.sol |
| L1 | LOW | Emergency withdrawal missing re-stake logic | EmergencyWithdrawYieldLoss.t.sol |
| L2 | LOW | No balance validation in emergency withdrawal | (No test - informational) |

## Mitigation Recommendations

### M1: Unlimited Token Approvals
**Options**:
1. Implement dynamic approvals (approve per operation)
2. Add `revokeApprovals()` function for emergency
3. Accept risk and document (trust in Tokemak security)

### L1: Emergency Withdrawal Re-Staking
**Fix**: Add re-staking logic to `_emergencyWithdraw()`:
```solidity
uint256 leftoverShares = autoDolaVault.balanceOf(address(this));
if (leftoverShares > 0) {
    mainRewarder.stake(address(this), leftoverShares);
}
```

### L2: Emergency Withdrawal Balance Validation
**Fix**: Add balance check before withdrawal attempt:
```solidity
uint256 availableAssets = autoDolaVault.convertToAssets(mainRewarder.balanceOf(address(this)));
require(amount <= availableAssets, "Insufficient balance");
```

## Notes

- All tests use mocks to simulate vulnerable scenarios
- Tests are for demonstration and validation purposes
- Real exploits would require actual compromise of external protocols
- User principal remains safe in all scenarios (yield/efficiency affected only)

## References

- Security Audit Report: `scratchpad/analysis-reports/story-029-security-audit-report.md`
- AutoDolaYieldStrategy: `src/concreteYieldStrategies/AutoDolaYieldStrategy.sol`
- AYieldStrategy: `src/AYieldStrategy.sol`
