# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Submodule: PhlimboEa

This is a Foundry smart contract submodule for the PhlimboEa contract.

### Contract inventory

- `src/Phlimbo.sol` — `PhlimboEA` (V1, deployed). Linear-depletion staking yield farm. Has the
  V1 rate-recompute bug: `rewardPerSecond` is recomputed on every `stake`/`withdraw`/`claim`,
  effectively re-anchoring the depletion window on each user interaction. DO NOT MODIFY.
- `src/PhlimboV2.sol` — `PhlimboV2` (coexists with V1). Same shape as V1 with three deliberate
  changes: (1) depletion-rate recompute removed from `_updatePool` so the window does not reset
  on user interactions, (2) `stake`/`withdraw`/`claim` take an explicit `user` param and a new
  `migrator` role can act on behalf of any user (`pauseWithdraw` remains msg.sender-only), and
  (3) an optional `IPhlimboHook` is invoked after stake/withdraw/claim, guarded with a
  zero-address check so no default no-op hook contract is needed.
- `src/MigratorV1V2.sol` — `MigratorV1V2`. One-shot, chunkable migrator that settles V1
  pending rewards (USDC transferred, phUSD minted) and re-stakes V1 deposits into PhlimboV2
  via the V2 `migrator` role. Owner-seeded; `int256` iterators terminate at `-1`; owner has a
  `withdrawAll` escape hatch. Requires two deployment-time wirings (phUSD mint role + V2
  setMigrator) — both documented inline.

## Dependency Management

### Types of Dependencies

1. **Immutable Dependencies** (lib/immutable/)
   - External libraries and contracts that don't change based on sibling requirements
   - Full source code is available
   - Examples: OpenZeppelin, standard libraries

2. **Mutable Dependencies** (lib/mutable/)
   - Dependencies from sibling submodules
   - ONLY interfaces and abstract contracts are exposed
   - NO implementation details are available
   - Changes to these dependencies must go through the change request process

### Important Rules

- **NEVER** access implementation details of mutable dependencies
- Mutable dependencies only expose interfaces and abstract contracts
- If a feature requires changes to a mutable dependency, add it to the change request queue
- All development must follow Test-Driven Development (TDD) principles using Foundry

### Change Request Process

When a feature requires changes to a mutable dependency:

1. Add the request to `MutableChangeRequests.json` with format:
   ```json
   {
     "requests": [
       {
         "dependency": "dependency-name",
         "changes": [
           {
             "fileName": "ISomeInterface.sol",
             "description": "Plain language description of what needs to change"
           }
         ]
       }
     ]
   }
   ```

2. **STOP WORK** immediately after adding the change request
3. Inform the user that dependency changes are needed
4. Wait for the dependency to be updated before continuing

### Available Commands

Use these as slash commands (e.g., `/add-mutable-dependency`) or run the scripts directly:

- `.claude/scripts/add-mutable-dependency.sh <repo>` - Add a mutable dependency (sibling)
- `.claude/scripts/add-immutable-dependency.sh <repo>` - Add an immutable dependency
- `.claude/scripts/update-mutable-dependency.sh <name>` - Update a mutable dependency
- `.claude/scripts/consider-change-requests.sh` - Review and implement sibling change requests

## Project Structure

- `src/` - Solidity source files
- `test/` - Test files (TDD required)
- `script/` - Deployment scripts
- `lib/mutable/` - Mutable dependencies (interfaces only)
- `lib/immutable/` - Immutable dependencies (full source)

## Development Guidelines

### Test-Driven Development (TDD)

**ALL** features, bug fixes, and modifications MUST follow TDD principles:

1. **Write tests first** - Before implementing any feature
2. **Red phase** - Write failing tests that define the expected behavior
3. **Green phase** - Write minimal code to make tests pass
4. **Refactor phase** - Improve code while keeping tests green

### Testing Commands

- `forge test` - Run all tests
- `forge test -vvv` - Run tests with verbose output
- `forge test --match-contract <ContractName>` - Run specific contract tests
- `forge test --match-test <testName>` - Run specific test
- `forge coverage` - Check test coverage

### Other Commands

- `forge build` - Compile contracts
- `forge fmt` - Format Solidity code
- `forge snapshot` - Generate gas snapshots

## Important Reminders

- This submodule operates independently from sibling submodules
- Follow Solidity best practices and naming conventions
- Use Foundry testing tools exclusively (no Hardhat or Truffle)
- If you need to change a mutable dependency, use the change request process
