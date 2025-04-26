// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract HatchStaking is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    event StakingCapUpdated(address[] users, uint256[] newCaps, uint256 timestamp);
    event StakingCapInitialized(address[] users, uint256[] newCaps, uint256 timestamp);
    event Staked(address indexed user, uint256 amount, uint256 stakedAt, uint bundleStaked, uint previousTotalBundles);
    event Withdrawn(address indexed user, uint256 amount, uint256 withdrawnAt);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner,
        uint256 timestamp,
        address initiatedBy
    );
    
    struct StakeInfo {
        uint256 amount;
        uint256 stakedAt;
    }

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant STAKE_UNIT = 5000 * (10 ** 18); // 5,000 HATCH
    uint256 public constant LOCK_PERIOD = 90 days; // 90 days

    /* 
    * @dev For local testing, we have made _hatchToken as mutable.
    * @dev In production, _hatchToken will be immutable (same as STAKE_UNIT and LOCK_PERIOD).
    */
    IERC20 public _hatchToken;

    mapping(address user => StakeInfo[]) public _stakes;
    mapping(address user => uint256) public _stakingCaps;
    mapping(address user => uint256 stakedAmount) public _totalStakedTokens;

    uint public _totalStakedBundles;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address hatchToken,
        address[] calldata initialStakers,
        uint256[] calldata initialStakingCaps
    ) public initializer {
        _isValidAddress(hatchToken);
        _checkArrayLengthMismatch(initialStakers.length, initialStakingCaps.length);

        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _hatchToken = IERC20(hatchToken);
        
        for (uint256 i; i < initialStakers.length; i++) {
            _isValidAddress(initialStakers[i]);
            _isValidValue(initialStakingCaps[i]);
            _stakingCaps[initialStakers[i]] = initialStakingCaps[i];
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        emit StakingCapInitialized(initialStakers, initialStakingCaps, block.timestamp);
    }

    function stake(uint256 stakeAmount) external whenNotPaused nonReentrant {
        _checkIsValidStakeAmount(msg.sender, stakeAmount);
        _checkHasRequiredBalance(msg.sender, stakeAmount);

        uint256 stakeBundles = stakeAmount / STAKE_UNIT;
        uint256 previousTotalBundles = _totalStakedBundles;
        
        _stakes[msg.sender].push(StakeInfo({
            amount: stakeAmount,
            stakedAt: block.timestamp
        }));

        _totalStakedTokens[msg.sender] += stakeAmount;
        _totalStakedBundles += stakeBundles;
        _hatchToken.transferFrom(msg.sender, address(this), stakeAmount);
        emit Staked(msg.sender, stakeAmount, block.timestamp, stakeBundles, previousTotalBundles);
    }

    function withdraw() external whenNotPaused nonReentrant {
        _checkHasStakes(msg.sender);
        
        StakeInfo memory userStake = _stakes[msg.sender][0];
        require(block.timestamp >= userStake.stakedAt + LOCK_PERIOD, "HatchStaking: Lock period not ended");
        
        _totalStakedTokens[msg.sender] -= userStake.amount;
        _removeStakeInfo(msg.sender);
        _hatchToken.transfer(msg.sender, userStake.amount);
        emit Withdrawn(msg.sender, userStake.amount, block.timestamp);
    }

    function batchWithdraw() external whenNotPaused nonReentrant {
        _checkHasStakes(msg.sender);
        uint totalMatureStakes;
        
        while (_stakes[msg.sender].length > 0) {
            uint startIndex;
            StakeInfo memory userStake = _stakes[msg.sender][startIndex];

            if (block.timestamp >= userStake.stakedAt + LOCK_PERIOD) {
                _totalStakedTokens[msg.sender] -= userStake.amount;
                _removeStakeInfo(msg.sender);
                _hatchToken.transfer(msg.sender, userStake.amount);
                totalMatureStakes++;
                emit Withdrawn(msg.sender, userStake.amount, block.timestamp);
            } else {
                break;
            }
        }

        require(totalMatureStakes > 0, "HatchStaking: No mature stakes");
    }

    function batchUpdateStakingCaps(
        address[] calldata users,
        uint256[] calldata newCaps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkArrayLengthMismatch(users.length, newCaps.length);
        
        for (uint256 i; i < users.length; i++) {
            _isValidAddress(users[i]);
            _isValidValue(newCaps[i]);
            _stakingCaps[users[i]] = newCaps[i];
        }

        emit StakingCapUpdated(users, newCaps, block.timestamp);
    }

    function transferContractOwnership(
        address newOwner
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _isValidAddress(newOwner);
        address oldOwner = msg.sender;

        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _revokeRole(PAUSER_ROLE, msg.sender);
        _revokeRole(UPGRADER_ROLE, msg.sender);

        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _grantRole(PAUSER_ROLE, newOwner);
        _grantRole(UPGRADER_ROLE, newOwner);

        emit OwnershipTransferred(
            oldOwner,
            newOwner,
            block.timestamp,
            msg.sender
        );
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    // ----------------------- VIEW FUNCTIONS -----------------------

    function getStakes(address user) public view returns (StakeInfo[] memory) {
        return _stakes[user];
    }

    function canWithdraw(address user) public view returns (bool) {
        require(_stakes[user].length > 0, "HatchStaking: No stake found");
        return block.timestamp >= _stakes[user][0].stakedAt + LOCK_PERIOD;
    }

    // ----------------------- PRIVATE FUNCTIONS -----------------------

    function _removeStakeInfo(address user) private {
        for (uint256 i; i < _stakes[user].length - 1; i++) {
            _stakes[user][i] = _stakes[user][i + 1];
        }
        _stakes[user].pop();
    }

    function _checkIsValidStakeAmount(address user, uint256 stakeAmount) private view {
        require(stakeAmount > 0 && stakeAmount % STAKE_UNIT == 0, "HatchStaking: Amount must be a multiple of stake unit");
        require(stakeAmount + _totalStakedTokens[user] <= _stakingCaps[user], "HatchStaking: Amount exceeds staking cap");
    }

    function _checkHasRequiredBalance(address user, uint256 stakeAmount) private view{
        uint256 hatchBalance = _hatchToken.balanceOf(user);
        require(
            hatchBalance >= stakeAmount,
            "HatchStaking: Insufficient balance to stake"
        );
    }

    function _checkArrayLengthMismatch(uint256 array1Length, uint256 array2Length) private pure {
        require(array1Length == array2Length, "HatchStaking: Array lengths mismatch");
    }

    function _isValidAddress(address addr) private pure {
        require(addr != address(0), "HatchStaking: Invalid address");
    }

    function _isValidValue(uint256 value) private pure {
        require(value > 0, "HatchStaking: Value must be greater than 0");
    }

    function _checkHasStakes(address user) private view {
        require(_stakes[user].length > 0, "HatchStaking: No stake found");
    }
}