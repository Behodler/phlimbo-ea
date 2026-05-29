// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IFlax.sol";

/**
 * @title Flax
 * @dev Implementation of the Flax ERC20 token with advanced minting capabilities
 * 
 * Features:
 * - Standard ERC20 functionality (transfer, approve, allowance)
 * - Permissioned minting system with owner-controlled authorization
 * - Version-based privilege revocation for enhanced security
 * - Zero initial supply with controlled token creation
 */
contract FlaxToken is ERC20, Ownable, IFlax {
    
    // ========================== STATE VARIABLES ==========================
    
    /// @dev Global version number for mint privilege revocation
    uint256 public mintVersion;
    
    /// @dev Mapping from address to minter information
    mapping(address => MinterInfo) private _authorizedMinters;
    
    // ========================== CONSTRUCTOR ==========================
    
    /**
     * @dev Constructor initializes the ERC20 token with zero initial supply
     */
    constructor() ERC20("Phoenix USD", "phUSD") Ownable(msg.sender) {
        mintVersion = 0;
    }
    
    // ========================== MINTING FUNCTIONS ==========================
    
    /**
     * @dev Sets minting authorization for an address
     * @param minter The address to authorize or revoke
     * @param canMint Whether the address should be able to mint
     */
    function setMinter(address minter, bool canMint) external override onlyOwner {
        _authorizedMinters[minter] = MinterInfo({
            canMint: canMint,
            mintVersion: mintVersion
        });
        
        emit MinterSet(minter, canMint, mintVersion);
    }
    
    /**
     * @dev Mints new tokens to a recipient
     * @param recipient The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address recipient, uint256 amount) external override {
        MinterInfo memory minterInfo = _authorizedMinters[msg.sender];

        // Check if caller is authorized to mint
        require(minterInfo.canMint, "phUSD: caller is not authorized to mint");

        // Check if minter version matches current global version
        require(minterInfo.mintVersion == mintVersion, "phUSD: minter version is outdated");

        // Mint the tokens
        _mint(recipient, amount);
    }

    /**
     * @dev Burns tokens from a holder's balance using allowance mechanism
     * Works exactly like transferFrom but burns instead of transfers
     * @param holder The address whose tokens will be burned
     * @param amount The amount of tokens to burn
     */
    function burn(address holder, uint256 amount) external override {
        // Spend allowance (checks allowance and decrements it)
        _spendAllowance(holder, msg.sender, amount);

        // Burn the tokens
        _burn(holder, amount);
    }
    
    /**
     * @dev Revokes all minting privileges globally
     */
    function revokeAllMintPrivileges() external override onlyOwner {
        mintVersion++;
        emit MintPrivilegesRevoked(mintVersion);
    }
    
    // ========================== VIEW FUNCTIONS ==========================
    
    /**
     * @dev Returns minter information for a given address
     * @param minter The address to check
     * @return info The MinterInfo struct containing permission and version
     */
    function authorizedMinters(address minter) external view override returns (MinterInfo memory info) {
        return _authorizedMinters[minter];
    }
    
    // ========================== OVERRIDE FUNCTIONS ==========================
    
    /**
     * @dev Returns the token name
     */
    function name() public view override(ERC20, IFlax) returns (string memory) {
        return super.name();
    }
    
    /**
     * @dev Returns the token symbol
     */
    function symbol() public view override(ERC20, IFlax) returns (string memory) {
        return super.symbol();
    }
    
    /**
     * @dev Returns the number of decimals
     */
    function decimals() public view override(ERC20, IFlax) returns (uint8) {
        return super.decimals();
    }
    
    /**
     * @dev Returns the owner of the contract
     */
    function owner() public view override(Ownable, IFlax) returns (address) {
        return super.owner();
    }
    
    /**
     * @dev Transfers ownership of the contract
     */
    function transferOwnership(address newOwner) public override(Ownable, IFlax) onlyOwner {
        super.transferOwnership(newOwner);
    }
    
    /**
     * @dev Renounces ownership of the contract
     */
    function renounceOwnership() public override(Ownable, IFlax) onlyOwner {
        super.renounceOwnership();
    }
}