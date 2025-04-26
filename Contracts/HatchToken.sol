// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BaseHatch} from "./BaseHatch.sol";

/**
 * @title HatchToken
 * @dev ERC20 token with vesting mechanism, merkle-based claims, and supply cap.
 * Tokens are claimable through merkle proofs with a vesting period before transferability.
 * The contract allows for cycle-based minting up to a percentage of total supply cap.
 * This contract is upgradeable using the UUPS proxy pattern.
 */
contract HatchToken is Initializable, BaseHatch, ERC20Upgradeable, ERC20PausableUpgradeable, UUPSUpgradeable {
    /**
     * @dev Prevents implementation contract from being initialized.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     * @param initialOwner Address of the initial contract owner
     * @param _cycleMintPercentage Cycle mint percentage in basis points
     * @param _merkleRoot Merkle root for initial claims
     * @param _tokenUnlockTime Token unlock time period
     * @param _cycleDuration Duration of each cycle in seconds
     */
    function initialize(
        address initialOwner,
        uint256 _cycleMintPercentage,
        bytes32 _merkleRoot,
        uint256 _tokenUnlockTime,
        uint256 _cycleDuration
    ) public initializer {
        __HatchToken_init(initialOwner, _cycleMintPercentage, _merkleRoot, _tokenUnlockTime, _cycleDuration);
    }

    /**
     * @dev Internal initialization function called by initialize
     * @param initialOwner Address of the initial contract owner
     * @param _cycleMintPercentage Cycle mint percentage in basis points
     * @param _merkleRoot Merkle root for initial claims
     * @param _tokenUnlockTime Token unlock time period
     * @param _cycleDuration Duration of each cycle in seconds
     */
    function __HatchToken_init(
        address initialOwner,
        uint256 _cycleMintPercentage,
        bytes32 _merkleRoot,
        uint256 _tokenUnlockTime,
        uint256 _cycleDuration
    ) internal onlyInitializing {
        __ERC20_init("Hatch", "$HATCH");
        __ERC20Pausable_init();
        __BaseHatch_init(initialOwner, _cycleMintPercentage, _merkleRoot, _tokenUnlockTime, _cycleDuration);
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Claim tokens using merkle proof
     * @dev Claims all remaining allocated tokens for sender. Tokens are vested
     * @param totalAllocation Total tokens allocated to sender
     * @param merkleProof Merkle proof for allocation verification
     */
    function claimTokens(
        uint256 totalAllocation,
        bytes32[] calldata merkleProof
    ) external whenNotPaused nonReentrant {
        require(totalAllocation >= userTotalClaimed[msg.sender], "Invalid total allocation");
        uint256 remainingAmount = totalAllocation - userTotalClaimed[msg.sender];
        
        _isValidClaim(totalAllocation, remainingAmount, merkleProof, msg.sender, totalSupply());
        
        uint256 unlockTime = block.timestamp + tokenUnlockTime;
        userUnlocks[msg.sender].push(Unlock({
            tokenAmount: remainingAmount,
            unlockedAt: unlockTime
        }));
        userTotalClaimed[msg.sender] = totalAllocation;

        _mint(msg.sender, remainingAmount);
        
        emit TokensClaimed(
            msg.sender,
            remainingAmount,
            totalAllocation,
            _getCurrentCycle(),
            unlockTime
        );
    }

    /// @notice Admin function to mint tokens for a specific address
    function mint(address to, uint256 amount) public onlyOwner {
        require(amount + totalSupply() <= _getTotalAllowedMint() && amount + totalSupply() <= TOTAL_SUPPLY_CAP, "Exceeds supply caps");
        _mint(to, amount);
    }

    /// @notice Pauses all token transfers (owner only)
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice Unpauses all token transfers (owner only)
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Hook override for ERC20 transfers
     * @param from Sender address
     * @param to Recipient address
     * @param value Transfer amount
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        // Allow minting (from == address(0))
        // Allow transfers from allowed operators
        if (from != address(0) && !isAllowedOperator[from] && !isAllowedOperator[to]) { 
            uint256 lockedBalance = getLockedBalance(from);
            require(
                value <= balanceOf(from) - lockedBalance,
                "Transfer amount exceeds locked balance"
            );
        }
        super._update(from, to, value);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     * 
     * Reverts if called by any account other than the owner.
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyOwner 
    {}
}