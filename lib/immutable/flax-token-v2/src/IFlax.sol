// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IFlax
 * @dev Interface for the Flax ERC20 token with advanced minting capabilities
 * 
 * Flax is an ERC20 token that implements:
 * - Standard ERC20 functionality
 * - Ownable access control
 * - Permissioned minting with version-based revocation system
 * - Zero initial supply
 * - "FLX" symbol
 */
interface IFlax is IERC20 {
    
    /**
     * @dev Structure to track minter information
     * @param canMint Whether the address is authorized to mint tokens
     * @param mintVersion The version number assigned when authorization was granted
     */
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }
    
    // ========================== EVENTS ==========================
    
    /**
     * @dev Emitted when a minter's authorization status changes
     * @param minter The address whose minting permission changed
     * @param canMint Whether the minter is now authorized
     * @param mintVersion The current mint version assigned to the minter
     */
    event MinterSet(address indexed minter, bool canMint, uint256 mintVersion);
    
    /**
     * @dev Emitted when all mint privileges are revoked globally
     * @param newMintVersion The new global mint version after revocation
     */
    event MintPrivilegesRevoked(uint256 newMintVersion);
    
    // ========================== VIEW FUNCTIONS ==========================
    
    /**
     * @dev Returns the token name
     * @return The name of the token ("Flax")
     */
    function name() external view returns (string memory);
    
    /**
     * @dev Returns the token symbol
     * @return The symbol of the token ("FLX")
     */
    function symbol() external view returns (string memory);
    
    /**
     * @dev Returns the number of decimal places
     * @return The number of decimals (18)
     */
    function decimals() external view returns (uint8);
    
    /**
     * @dev Returns the current global mint version
     * @return The current mint version number
     */
    function mintVersion() external view returns (uint256);
    
    /**
     * @dev Returns minter information for a given address
     * @param minter The address to check
     * @return info The MinterInfo struct containing permission and version
     */
    function authorizedMinters(address minter) external view returns (MinterInfo memory info);
    
    /**
     * @dev Returns the owner of the contract
     * @return The address of the current owner
     */
    function owner() external view returns (address);
    
    // ========================== MINTING FUNCTIONS ==========================
    
    /**
     * @dev Sets minting authorization for an address
     * Only the contract owner can call this function
     * When granting permission, assigns the current global mint version
     * @param minter The address to authorize or revoke
     * @param canMint Whether the address should be able to mint
     */
    function setMinter(address minter, bool canMint) external;
    
    /**
     * @dev Mints new tokens to a recipient
     * Only authorized minters can call this function
     * The caller's mint version must match the current global version
     * @param recipient The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address recipient, uint256 amount) external;

    /**
     * @dev Burns tokens from a holder's balance using allowance mechanism
     * Works like transferFrom but burns tokens instead of transferring
     * The caller must have sufficient allowance to burn from the holder
     * @param holder The address whose tokens will be burned
     * @param amount The amount of tokens to burn
     */
    function burn(address holder, uint256 amount) external;

    /**
     * @dev Revokes all minting privileges globally
     * Only the contract owner can call this function
     * Increments the global mint version, making all existing minters unauthorized
     */
    function revokeAllMintPrivileges() external;
    
    // ========================== OWNERSHIP FUNCTIONS ==========================
    
    /**
     * @dev Transfers ownership of the contract
     * Only the current owner can call this function
     * @param newOwner The address to transfer ownership to
     */
    function transferOwnership(address newOwner) external;
    
    /**
     * @dev Renounces ownership, leaving the contract without an owner
     * Only the current owner can call this function
     */
    function renounceOwnership() external;
}