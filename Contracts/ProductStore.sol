// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ProductStore is Initializable, PausableUpgradeable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    event ProductAdded(string[] indexed productIds, uint[] prices);
    event ProductUpdated(string[] indexed productId, uint[] prices);
    event ProductDeleted(string indexed productId);
    event ProductPurchased(string indexed playerId, address indexed buyer, string indexed productId, uint offerId, uint amountPaid);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    address public _treasury;
    // Use Mock token address on sepolia network
    IERC20 public _usdtToken;
    mapping(string productId => uint price) public _productPrice;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address treasury, string[] calldata productIds, uint[] calldata prices, address usdtToken) initializer public {
        require(productIds.length == prices.length, "ProductStore: Array length mismatched");
        _isValidAddress(initialOwner);
        _isValidAddress(treasury);
        _isValidAddress(usdtToken);
        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        _treasury = treasury;
        _usdtToken = IERC20(usdtToken);

        for (uint256 i = 0; i < productIds.length; i++) {
            _productPrice[productIds[i]] = prices[i];
        }
        emit ProductAdded(productIds, prices);
    }

    function addProduct(string[] calldata productIds, uint[] calldata prices) external onlyOwner whenNotPaused {
        require(productIds.length == prices.length, "ProductStore: Array length mismatched");
        for (uint256 i = 0; i < productIds.length; i++) {
            _checkIsProductNotExists(productIds[i]);  
            _productPrice[productIds[i]] = prices[i];
        }
        emit ProductAdded(productIds, prices);
    }

    function updateProduct(string[] calldata productIds, uint[] calldata prices) external onlyOwner whenNotPaused{
        require(productIds.length == prices.length, "ProductStore: Array length mismatched");
        for (uint256 i = 0; i < productIds.length; i++) {
            _checkIsProductExists(productIds[i]);
            _productPrice[productIds[i]] = prices[i];
        }
        emit ProductUpdated(productIds, prices);
    }

    function deleteProduct(string calldata productId) external onlyOwner whenNotPaused{
        _checkIsProductExists(productId);
        delete _productPrice[productId];
        emit ProductDeleted(productId);
    }

    function purchase(string calldata playerId, string calldata productId, uint offerId) external whenNotPaused nonReentrant{
        _checkIsProductExists(productId);

        _isValidTransfer(_usdtToken.transferFrom(msg.sender, _treasury, _productPrice[productId]));
        emit ProductPurchased(playerId, msg.sender, productId, offerId, _productPrice[productId]);
    }

    function updateTreasury(address newTreasury) external onlyOwner whenNotPaused{
        _isValidAddress(newTreasury);
        address oldTreasury = _treasury;
        _treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function updateUSDTContract(address newContract) external onlyOwner whenNotPaused{
        _isValidAddress(newContract);
        _usdtToken = IERC20(newContract);
    }

    function getProductPrice(string calldata productId) public view returns(uint, address){
        return (_productPrice[productId], address(_usdtToken));
    }

    function _checkIsProductExists(string calldata productId) private view {
        require(_productPrice[productId] > 0, "ProductStore: Product not found");
    }

    function _checkIsProductNotExists(string calldata productId) private view {
        require(_productPrice[productId] == 0 , "ProductStore: Product already exists");
    }

    function _isValidTransfer(bool success) private pure {
        require(success, "ProductStore: Token transfer failed");
    }

    function _isValidAddress(address addr) private pure {
        require(addr != address(0), "ProductStore: Invalid address");
    }
    
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}
}

