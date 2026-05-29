// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IYieldStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AYieldStrategy
 * @notice Abstract yield strategy contract with security features and access control
 * @dev Provides base implementation for yield strategy adapters with owner and multiple client access control
 */
abstract contract AYieldStrategy is IYieldStrategy, Ownable, ReentrancyGuard {
    
    // ============ STATE VARIABLES ============

    /// @notice Mapping of addresses authorized to deposit/withdraw
    mapping(address => bool) public authorizedClients;

    /// @notice Mapping of addresses authorized to withdraw on behalf of clients
    mapping(address => bool) public authorizedWithdrawers;

    /// @notice Withdrawal status enumeration
    enum WithdrawalStatus {
        None,       // No withdrawal initiated
        Initiated,  // Withdrawal initiated, in 24-hour waiting period
        Executable, // Past waiting period, within 48-hour execution window
        Expired     // Past execution window, state reset needed
    }

    /// @notice Structure to track withdrawal state per token/client combination
    struct WithdrawalState {
        uint256 initiatedAt;        // Timestamp when withdrawal was initiated
        WithdrawalStatus status;    // Current status of the withdrawal
        uint256 balance;           // Cached balance at initiation time
    }

    /// @notice Mapping to track withdrawal states: token => client => WithdrawalState
    mapping(address => mapping(address => WithdrawalState)) public withdrawalStates;

    /// @notice Time constants for withdrawal phases
    uint256 public constant WAITING_PERIOD = 24 hours;    // Phase 1 duration
    uint256 public constant EXECUTION_WINDOW = 48 hours;  // Phase 2 duration
    uint256 public constant TOTAL_DURATION = WAITING_PERIOD + EXECUTION_WINDOW; // 72 hours total
    
    // ============ EVENTS ============
    
    /**
     * @notice Emitted when client authorization is updated
     * @param client The client address whose authorization was changed
     * @param authorized Whether the client is now authorized (true) or not (false)
     */
    event ClientAuthorizationSet(address indexed client, bool authorized);

    /**
     * @notice Emitted when withdrawer authorization is updated
     * @param withdrawer The withdrawer address whose authorization was changed
     * @param authorized Whether the withdrawer is now authorized (true) or not (false)
     */
    event WithdrawerAuthorizationSet(address indexed withdrawer, bool authorized);

    /**
     * @notice Emitted when an authorized withdrawer withdraws from a client balance
     * @param token The token address that was withdrawn
     * @param client The client address whose balance was withdrawn from
     * @param withdrawer The withdrawer address that performed the withdrawal
     * @param amount The amount that was withdrawn
     * @param recipient The address that received the withdrawn tokens
     */
    event WithdrawnFrom(
        address indexed token,
        address indexed client,
        address indexed withdrawer,
        uint256 amount,
        address recipient
    );
    
    /**
     * @notice Emitted when an emergency withdrawal is performed
     * @param owner The owner who performed the withdrawal
     * @param amount The amount withdrawn
     */
    event EmergencyWithdraw(address indexed owner, uint256 amount);

    /**
     * @notice Emitted when a total withdrawal is initiated (Phase 1)
     * @param token The token address for which withdrawal was initiated
     * @param client The client address whose tokens will be withdrawn
     * @param balance The balance amount that will be withdrawn in Phase 2
     * @param initiatedAt The timestamp when the withdrawal was initiated
     * @param executableAt The timestamp when Phase 2 becomes available
     */
    event WithdrawalInitiated(
        address indexed token,
        address indexed client,
        uint256 balance,
        uint256 initiatedAt,
        uint256 executableAt
    );

    /**
     * @notice Emitted when a total withdrawal is executed (Phase 2)
     * @param token The token address that was withdrawn
     * @param client The client address whose tokens were withdrawn
     * @param amount The amount that was withdrawn
     * @param executedAt The timestamp when the withdrawal was executed
     */
    event WithdrawalExecuted(
        address indexed token,
        address indexed client,
        uint256 amount,
        uint256 executedAt
    );
    
    // ============ MODIFIERS ============

    /**
     * @notice Restricts access to only authorized client contracts
     * @dev Reverts if the caller is not an authorized client address
     */
    modifier onlyAuthorizedClient() {
        require(authorizedClients[msg.sender], "AYieldStrategy: unauthorized, only authorized clients");
        _;
    }

    /**
     * @notice Restricts access to only authorized withdrawer addresses
     * @dev Reverts if the caller is not an authorized withdrawer
     */
    modifier onlyAuthorizedWithdrawer() {
        require(authorizedWithdrawers[msg.sender], "AYieldStrategy: unauthorized, only authorized withdrawers");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    
    /**
     * @notice Initialize the vault with initial owner
     * @param _owner The initial owner of the contract
     */
    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "AYieldStrategy: owner cannot be zero address");
    }
    
    // ============ OWNER FUNCTIONS ============
    
    /**
     * @notice Set client authorization for deposit/withdraw operations
     * @param client The address of the client contract
     * @param _auth Whether to authorize (true) or deauthorize (false) the client
     * @dev Only the contract owner can call this function
     */
    function setClient(address client, bool _auth) external override onlyOwner {
        require(client != address(0), "AYieldStrategy: client cannot be zero address");

        authorizedClients[client] = _auth;

        emit ClientAuthorizationSet(client, _auth);
    }

    /**
     * @notice Set withdrawer authorization for surplus withdrawal operations
     * @param withdrawer The address of the withdrawer
     * @param _auth Whether to authorize (true) or deauthorize (false) the withdrawer
     * @dev Only the contract owner can call this function
     */
    function setWithdrawer(address withdrawer, bool _auth) external onlyOwner {
        require(withdrawer != address(0), "AYieldStrategy: withdrawer cannot be zero address");

        authorizedWithdrawers[withdrawer] = _auth;

        emit WithdrawerAuthorizationSet(withdrawer, _auth);
    }
    
    /**
     * @notice Emergency withdraw function for owner to withdraw funds
     * @param amount The amount of tokens to withdraw
     * @dev Only the contract owner can call this function. Delegates to internal _emergencyWithdraw
     */
    function emergencyWithdraw(uint256 amount) external override onlyOwner {
        require(amount > 0, "AYieldStrategy: amount must be greater than zero");

        _emergencyWithdraw(amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }

    /**
     * @notice Two-phase total withdrawal function for emergency fund migration
     * @param token The token address to withdraw from
     * @param client The client address whose tokens to withdraw
     * @dev Phase 1: Initiates 24-hour waiting period. Phase 2: Executes withdrawal within 48-hour window.
     *      Provides community protection against rugpulls while allowing legitimate fund migrations.
     */
    function totalWithdrawal(address token, address client) external override onlyOwner nonReentrant {
        require(token != address(0), "AYieldStrategy: token cannot be zero address");
        require(client != address(0), "AYieldStrategy: client cannot be zero address");

        WithdrawalState storage state = withdrawalStates[token][client];
        uint256 currentTime = block.timestamp;

        // Update status based on time progression
        _updateWithdrawalStatus(state, currentTime);

        if (state.status == WithdrawalStatus.None || state.status == WithdrawalStatus.Expired) {
            // Phase 1: Initiate withdrawal
            _initiateWithdrawal(token, client, state, currentTime);
        } else if (state.status == WithdrawalStatus.Executable) {
            // Phase 2: Execute withdrawal
            _executeWithdrawal(token, client, state, currentTime);
        } else if (state.status == WithdrawalStatus.Initiated) {
            // Still in waiting period
            uint256 executableAt = state.initiatedAt + WAITING_PERIOD;
            revert(
                string(
                    abi.encodePacked(
                        "AYieldStrategy: withdrawal still in waiting period, executable at timestamp: ",
                        _uint256ToString(executableAt)
                    )
                )
            );
        }
    }

    /**
     * @notice Withdraw surplus from a client's balance to a specified recipient
     * @param token The token address to withdraw
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw
     * @param recipient The address that will receive the withdrawn tokens
     * @dev Only authorized withdrawers can call this function. This is used to extract surplus yield.
     */
    function withdrawFrom(
        address token,
        address client,
        uint256 amount,
        address recipient
    ) external onlyAuthorizedWithdrawer nonReentrant {
        require(token != address(0), "AYieldStrategy: token cannot be zero address");
        require(client != address(0), "AYieldStrategy: client cannot be zero address");
        require(recipient != address(0), "AYieldStrategy: recipient cannot be zero address");
        require(amount > 0, "AYieldStrategy: amount must be greater than zero");

        // Check that client has sufficient balance
        uint256 clientBalance = this.balanceOf(token, client);
        require(clientBalance >= amount, "AYieldStrategy: insufficient client balance");

        // Perform the withdrawal through the virtual function
        _withdrawFrom(token, client, amount, recipient);

        emit WithdrawnFrom(token, client, msg.sender, amount, recipient);
    }

    // ============ VIRTUAL FUNCTIONS ============
    
    /**
     * @notice Internal emergency withdraw implementation to be overridden by concrete contracts
     * @param amount The amount of tokens to withdraw
     * @dev Must be implemented by concrete vault contracts to define emergency withdrawal logic
     */
    function _emergencyWithdraw(uint256 amount) internal virtual;

    /**
     * @notice Internal total withdraw implementation to be overridden by concrete contracts
     * @param token The token address to withdraw
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw
     * @dev Must be implemented by concrete vault contracts to define total withdrawal logic
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal virtual;

    /**
     * @notice Internal withdrawFrom implementation to be overridden by concrete contracts
     * @param token The token address to withdraw
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw
     * @param recipient The address that will receive the withdrawn tokens
     * @dev Must be implemented by concrete vault contracts to define withdrawFrom logic
     */
    function _withdrawFrom(address token, address client, uint256 amount, address recipient) internal virtual;
    
    // ============ VIRTUAL FUNCTIONS ============
    
    /**
     * @notice Deposit tokens into the vault
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     * @dev Must be overridden by concrete contracts - implement onlyAuthorizedClient access control
     */
    function deposit(address token, uint256 amount, address recipient) external virtual override;
    
    /**
     * @notice Withdraw tokens from the vault
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     * @dev Must be overridden by concrete contracts - implement onlyAuthorizedClient access control
     */
    function withdraw(address token, uint256 amount, address recipient) external virtual override;

    // ============ INTERNAL HELPER FUNCTIONS ============

    /**
     * @notice Updates the withdrawal status based on current time
     * @param state The withdrawal state to update
     * @param currentTime The current block timestamp
     */
    function _updateWithdrawalStatus(WithdrawalState storage state, uint256 currentTime) internal {
        if (state.status == WithdrawalStatus.Initiated) {
            if (currentTime >= state.initiatedAt + WAITING_PERIOD) {
                if (currentTime <= state.initiatedAt + TOTAL_DURATION) {
                    state.status = WithdrawalStatus.Executable;
                } else {
                    state.status = WithdrawalStatus.Expired;
                }
            }
        } else if (state.status == WithdrawalStatus.Executable) {
            if (currentTime > state.initiatedAt + TOTAL_DURATION) {
                state.status = WithdrawalStatus.Expired;
            }
        }
    }

    /**
     * @notice Initiates a withdrawal (Phase 1)
     * @param token The token address
     * @param client The client address
     * @param state The withdrawal state to initialize
     * @param currentTime The current block timestamp
     */
    function _initiateWithdrawal(
        address token,
        address client,
        WithdrawalState storage state,
        uint256 currentTime
    ) internal {
        // Get current balance
        uint256 balance = this.balanceOf(token, client);
        require(balance > 0, "AYieldStrategy: no balance to withdraw");

        // Initialize withdrawal state
        state.initiatedAt = currentTime;
        state.status = WithdrawalStatus.Initiated;
        state.balance = balance;

        uint256 executableAt = currentTime + WAITING_PERIOD;

        emit WithdrawalInitiated(token, client, balance, currentTime, executableAt);
    }

    /**
     * @notice Executes a withdrawal (Phase 2)
     * @param token The token address
     * @param client The client address
     * @param state The withdrawal state to process
     * @param currentTime The current block timestamp
     */
    function _executeWithdrawal(
        address token,
        address client,
        WithdrawalState storage state,
        uint256 currentTime
    ) internal {
        uint256 withdrawAmount = state.balance;

        // Reset state before external call to prevent reentrancy issues
        state.status = WithdrawalStatus.None;
        state.initiatedAt = 0;
        state.balance = 0;

        // Execute the actual withdrawal through virtual function
        _totalWithdraw(token, client, withdrawAmount);

        emit WithdrawalExecuted(token, client, withdrawAmount, currentTime);
    }

    /**
     * @notice Converts uint256 to string for error messages
     * @param value The number to convert
     * @return The string representation
     */
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}