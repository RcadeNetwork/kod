// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.22;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title BaseHatch
 * @dev Base contract for the Hatch token system with claim verification and
 * vesting functionality. Implements cycle-based supply caps and token unlocking.
 */
abstract contract BaseHatch is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    /// @notice Maximum total supply of tokens (1 billion)
    uint256 public constant TOTAL_SUPPLY_CAP = 1_000_000_000 * 10**18;
    /// @notice Denominator for percentage calculations (basis points)
    uint256 public constant PERCENTAGE_DENOMINATOR = 10000;
    
    /**
     * @dev Struct to track token unlock schedules
     * @param tokenAmount Amount of tokens to be unlocked
     * @param unlockedAt Timestamp when tokens become transferable
     */
    struct Unlock {
        uint256 tokenAmount;
        uint256 unlockedAt;
    }
    
    /// @notice Cycle mint percentage in basis points (e.g., 500 = 5%)
    uint256 public cycleMintPercentage;
    /// @notice Duration of each cycle in seconds
    uint256 public cycleDuration;
    /// @notice Merkle root for verifying claim allocations
    bytes32 public merkleRoot;
    /// @notice Token unlock time
    uint256 public tokenUnlockTime; 
    /// @notice Timestamp when minting schedule starts
    uint256 public mintingStartTime;
    /// @dev Mapping of user addresses to their unlock schedules
    mapping(address => Unlock[]) public userUnlocks;
    /// @dev Mapping of total claimed amounts per user
    mapping(address => uint256) public userTotalClaimed;

    /// @dev Mapping of allowed operators that can transfer locked tokens
    mapping(address => bool) public isAllowedOperator;
    
    /// @notice Emitted when cycle mint percentage is updated
    event CycleMintPercentageUpdated(
        uint256 oldPercentage,
        uint256 newPercentage,
        uint256 timestamp,
        address indexed initiatedBy
    );

    /// @notice Emitted when merkle root is updated
    event MerkleRootUpdated(
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot,
        uint256 timestamp,
        address indexed initiatedBy
    );

    /// @notice Emitted when tokens are claimed
    event TokensClaimed(
        address indexed user,
        uint256 amount,
        uint256 totalClaimed,
        uint256 cycle,
        uint256 unlockedAt
    );

    /// @notice Emitted when an operator's allowed status is updated
    event AllowedOperatorUpdated(
        address indexed operator,
        bool status,
        uint256 timestamp,
        address indexed initiatedBy
    );

    /// @notice Emitted when token unlock time is updated
    event TokenUnlockTimeUpdated(
        uint256 oldUnlockTime,
        uint256 newUnlockTime,
        uint256 timestamp,
        address indexed initiatedBy
    );

    /// @notice Emitted when cycle duration is updated
    event CycleDurationUpdated(
        uint256 oldDuration,
        uint256 newDuration,
        uint256 timestamp,
        address indexed initiatedBy
    );
    
    /**
     * @dev Prevents implementation contract from being initialized.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the base contract
     * @param initialOwner Address of the initial contract owner
     * @param _cycleMintPercentage Cycle mint percentage in basis points
     * @param _merkleRoot Merkle root for initial claims
     * @param _tokenUnlockTime Token unlock time in seconds
     * @param _cycleDuration Duration of each cycle in seconds
     */
    function __BaseHatch_init(
        address initialOwner,
        uint256 _cycleMintPercentage,
        bytes32 _merkleRoot,
        uint256 _tokenUnlockTime,
        uint256 _cycleDuration
    ) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();
        
        _isValidPercentage(_cycleMintPercentage);
        _isValidMerkleRoot(_merkleRoot);
        _isValidTokenUnlockTime(_tokenUnlockTime);
        _isValidCycleDuration(_cycleDuration);
        
        cycleMintPercentage = _cycleMintPercentage;
        merkleRoot = _merkleRoot;
        tokenUnlockTime = _tokenUnlockTime;
        cycleDuration = _cycleDuration;
        mintingStartTime = block.timestamp;
    }

    /**
     * @notice Updates token unlock time
     * @dev Only callable by owner
     * @param newUnlockTime New unlock time in seconds
     */
    function updateTokenUnlockTime(uint256 newUnlockTime) public onlyOwner {
        _isValidTokenUnlockTime(newUnlockTime);
        uint256 oldUnlockTime = tokenUnlockTime;
        tokenUnlockTime = newUnlockTime;
        emit TokenUnlockTimeUpdated(
            oldUnlockTime,
            newUnlockTime,
            block.timestamp,
            msg.sender
        );
    }

    /**
     * @notice Updates merkle root for claims
     * @dev Only callable by owner
     * @param newRoot New merkle root hash
     */
    function updateMerkleRoot(bytes32 newRoot) public onlyOwner {
        _isValidMerkleRoot(newRoot);
        bytes32 oldRoot = merkleRoot;
        merkleRoot = newRoot;
        emit MerkleRootUpdated(
            oldRoot,
            newRoot,
            block.timestamp,
            msg.sender
        );
    }

    /**
     * @notice Updates cycle mint percentage
     * @dev Only callable by owner. Percentage must be between 0.01% and 5%
     * @param newPercentage New percentage in basis points
     */ 
    function updateCycleMintPercentage(uint256 newPercentage) public onlyOwner {
        _isValidPercentage(newPercentage);
        uint256 oldPercentage = cycleMintPercentage;
        cycleMintPercentage = newPercentage;
        emit CycleMintPercentageUpdated(
            oldPercentage,
            newPercentage,
            block.timestamp,
            msg.sender
        );
    }

    /** 
     * @notice Updates cycle duration
     * @dev Only callable by owner
     * @param newDuration New duration in seconds
     */
    function updateCycleDuration(uint256 newDuration) public onlyOwner {
        _isValidCycleDuration(newDuration);
        uint256 oldDuration = cycleDuration;
        cycleDuration = newDuration;
        emit CycleDurationUpdated(oldDuration, newDuration, block.timestamp, msg.sender);
    }

    /**
     * @dev Validates claim parameters and merkle proof
     * @param totalAllocation Total allocated tokens for user
     * @param remainingAmount Remaining tokens to claim
     * @param merkleProof Merkle proof for verification
     * @param claimer Address of the claimer
     * @param currentSupply Current total supply
     */
    function _isValidClaim(
        uint256 totalAllocation,
        uint256 remainingAmount,
        bytes32[] calldata merkleProof,
        address claimer,
        uint256 currentSupply
    ) internal view {
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(claimer, totalAllocation)))
        );
        require(
            MerkleProof.verify(merkleProof, merkleRoot, leaf),
            "Invalid merkle proof"
        );

        require(remainingAmount > 0, "No tokens left to claim");

        require(
            currentSupply + remainingAmount <= TOTAL_SUPPLY_CAP && currentSupply + remainingAmount <= _getTotalAllowedMint(),
            "Exceeds supply caps"
        );
    }

    /**
     * @notice Returns locked token balance for an account
     * @param account Address to check locked balance for
     * @return total Sum of all locked tokens for the account
     */
    function getLockedBalance(address account) public view returns (uint256) {
        uint256 total = 0;
        Unlock[] memory unlocks = userUnlocks[account];
        uint256 length = unlocks.length;

        for (uint256 i = 0; i < length;) {
            if (block.timestamp < unlocks[i].unlockedAt) {
                total += unlocks[i].tokenAmount;
            }
            unchecked { ++i; }
        }
        return total;
    }

    /// @dev Returns maximum supply of the token
    function maxSupply() public pure returns (uint256) {
        return TOTAL_SUPPLY_CAP;
    }

    /// @dev Returns total allowed mint based on current cycle and cycle cap
    function _getTotalAllowedMint() public view returns (uint256) {
        return _getCurrentCycle() * _getCycleMintCap();
    }

    /// @dev Returns cycle mint cap based on percentage of total supply
    function _getCycleMintCap() public view returns (uint256) {
        return (TOTAL_SUPPLY_CAP * cycleMintPercentage) / PERCENTAGE_DENOMINATOR;
    }

    /// @dev Returns current cycle count since deployment
    function _getCurrentCycle() public view returns (uint256) {
        return (block.timestamp - mintingStartTime) / cycleDuration + 1;
    }

    /// @dev Validates percentage parameter (0 < percentage <= 500)
    function _isValidPercentage(uint256 percentage) internal pure {
        require(
            percentage > 0 && percentage <= 500,
            "Invalid percentage: must be between 0.01% and 5%"
        );
    }

    /// @dev Validates merkle root is non-zero
    function _isValidMerkleRoot(bytes32 root) internal pure {
        require(root != bytes32(0), "Invalid merkle root");
    }

    /// @dev Validates token unlock time (0 < time)
    function _isValidTokenUnlockTime(uint256 time) internal pure {
        require(time > 0, "Invalid token unlock time: must be in greater than 0");
    }

    /// @dev Validates cycle duration (0 < duration)
    function _isValidCycleDuration(uint256 duration) internal pure {
        require(duration > 0, "Invalid cycle duration: must be greater than 0");
    }

    /**
     * @notice Sets or revokes allowed operator status
     * @dev Only callable by owner. Allowed operators can transfer locked tokens.
     * @param operator Address to update
     * @param status New allowed status
     */
    function setAllowedOperator(address operator, bool status) public onlyOwner {
        require(operator != address(0), "Invalid operator address");
        isAllowedOperator[operator] = status;
        emit AllowedOperatorUpdated(
            operator,
            status,
            block.timestamp,
            msg.sender
        );
    }
} 