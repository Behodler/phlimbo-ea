# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Submodule: Vault

This is a Foundry smart contract submodule for the Vault contract.

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

- `.claude/commands/add-mutable-dependency.sh <repo>` - Add a mutable dependency (sibling)
- `.claude/commands/add-immutable-dependency.sh <repo>` - Add an immutable dependency
- `.claude/commands/update-mutable-dependency.sh <name>` - Update a mutable dependency
- `.claude/commands/consider-change-requests.sh` - Review and implement sibling change requests

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

### OpenZeppelin Standards

**ALWAYS use OpenZeppelin contracts for standard implementations.** This is a mandatory security requirement.

#### Required Standards
- **Always use OpenZeppelin** for standard interfaces (ERC20, ERC721, Ownable, etc.)
- **Custom implementations are prohibited** unless explicitly justified
- **Third-party audited providers** like OpenZeppelin are preferred over custom code
- **Replace in-situ implementations** with OpenZeppelin versions immediately
- **Document any deviation** from OpenZeppelin with clear reasoning and approval

#### Security Rationale
- Custom implementations unnecessarily expand the exploit surface area
- OpenZeppelin contracts are battle-tested and audited by security experts
- Standard implementations reduce maintenance burden and improve interoperability
- Industry standard patterns improve code readability and developer confidence

#### Common OpenZeppelin Imports
```solidity
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
```

#### Implementation Priority
1. **First Priority**: Replace any custom Ownable implementations
2. **Second Priority**: Replace any custom IERC20/IERC721 interfaces
3. **Third Priority**: Replace other security-critical contracts
4. **Document all changes**: List replaced contracts in commit messages

## Vault-RM Project Naming Conventions

**CRITICAL: YieldStrategy vs Vault Naming Distinction**

The vault-RM project uses specific naming conventions to distinguish between two different concepts that were previously both called "Vault", causing confusion:

### Terminology

**YieldStrategy** (Our Adapter Pattern):
- The interface and abstract contracts that define how we integrate with external yield sources
- Files: `IYieldStrategy.sol`, `AYieldStrategy.sol`, `AutoDolaYieldStrategy.sol`
- Purpose: Provides a standardized adapter pattern for integrating various yield-generating protocols
- This is OUR code that wraps external vaults

**Vault** (External ERC4626 Vaults):
- The actual ERC4626 vault contracts from external yield sources (e.g., Inverse Finance)
- Variable names: `autoDolaVault`, `vault` (when referring to external ERC4626 instances)
- Purpose: The actual yield-generating contracts from third-party protocols
- This is EXTERNAL code we integrate with

### Naming Rules

When working in this codebase or downstream projects that depend on vault-RM:

1. **Use YieldStrategy for our contracts:**
   - Interface: `IYieldStrategy`
   - Abstract base: `AYieldStrategy`
   - Concrete implementation: `AutoDolaYieldStrategy`

2. **Use Vault for external ERC4626 instances:**
   - Variable names: `autoDolaVault`, `vault`
   - When referring to the external ERC4626 contract
   - Example: `address autoDolaVault = 0x...`

3. **Context matters:**
   - If referring to our adapter pattern → use YieldStrategy
   - If referring to external ERC4626 contracts → use Vault

### Code Examples

**Correct Usage:**
```solidity
// Our adapter interface
IYieldStrategy public yieldStrategy;

// External ERC4626 vault
address public autoDolaVault = 0x...;

// Concrete implementation of our adapter
AutoDolaYieldStrategy strategy = new AutoDolaYieldStrategy(autoDolaVault);
```

**What Changed (Historical Context):**
- Previously: `IVault`, `Vault`, `AutoDolaVault` (all called "Vault")
- Now: `IYieldStrategy`, `AYieldStrategy`, `AutoDolaYieldStrategy` (our code)
- External contracts still use "vault" in variable names

### Impact on Downstream Projects

Projects that reference vault-RM contracts will need to update their imports and type references:
- Old: `import {IVault} from "vault-RM/src/IVault.sol";`
- New: `import {IYieldStrategy} from "vault-RM/src/interfaces/IYieldStrategy.sol";`

This naming convention eliminates ambiguity and makes the codebase more maintainable for both humans and AI agents.
