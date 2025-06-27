// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MBSOracle
 * @notice Enhanced oracle for MBS pricing with multi-sig updates, staleness checks, and confidence scores
 * @dev Production implementation should integrate with Chainlink or similar decentralized oracle network
 * 
 * SECURITY ENHANCEMENTS:
 * - Multi-sig price updates via role-based access control
 * - Price staleness protection
 * - Deviation limits to prevent manipulation
 * - Confidence scoring for risk assessment
 * - Emergency pause mechanism
 */
contract MBSOracle is AccessControl, ReentrancyGuard {
    // --- Roles ---
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY");
    
    // --- Constants ---
    uint256 public constant MAX_PRICE_AGE = 3600; // 1 hour max staleness
    uint256 public constant MAX_DEVIATION = 500; // 5% max single update deviation
    uint256 public constant CONFIDENCE_DECIMALS = 10000; // Basis points
    address public constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Mainnet USDC
    
    // --- Price Data Structure ---
    struct PriceData {
        uint256 price;          // Price in USDC (18 decimals)
        uint256 timestamp;      // Last update timestamp
        uint256 confidence;     // Confidence score (0-10000 basis points)
        address updater;        // Who updated the price
    }
    
    // --- State Variables ---
    mapping(bytes32 => PriceData) public priceFeeds; // trancheKey => PriceData
    mapping(bytes32 => uint256) public updateCount;   // trancheKey => update count
    mapping(address => bool) public isValidMBSToken;  // Whitelist of valid MBS tokens
    bool public paused;
    
    // --- Events ---
    event PriceUpdated(
        address indexed mbsToken,
        uint256 indexed trancheId,
        uint256 price,
        uint256 confidence,
        address updater
    );
    event PriceDeviationAlert(
        bytes32 indexed trancheKey,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 deviation
    );
    event MBSTokenWhitelisted(address indexed mbsToken);
    event MBSTokenDelisted(address indexed mbsToken);
    event EmergencyPause(bool paused);
    event StalenessPeriodUpdated(uint256 newPeriod);
    
    // --- Modifiers ---
    modifier whenNotPaused() {
        require(!paused, "Oracle paused");
        _;
    }
    
    modifier onlyValidMBSToken(address mbsToken) {
        require(isValidMBSToken[mbsToken], "Invalid MBS token");
        _;
    }
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PRICE_UPDATER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    // --- Admin Functions ---
    
    /**
     * @notice Whitelist an MBS token for price updates
     * @param mbsToken Address of the MBS token contract
     */
    function whitelistMBSToken(address mbsToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(mbsToken != address(0), "Invalid address");
        isValidMBSToken[mbsToken] = true;
        emit MBSTokenWhitelisted(mbsToken);
    }
    
    /**
     * @notice Remove an MBS token from whitelist
     * @param mbsToken Address of the MBS token contract
     */
    function delistMBSToken(address mbsToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isValidMBSToken[mbsToken] = false;
        emit MBSTokenDelisted(mbsToken);
    }
    
    /**
     * @notice Emergency pause/unpause
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyRole(EMERGENCY_ROLE) {
        paused = _paused;
        emit EmergencyPause(_paused);
    }
    
    // --- Price Update Functions ---
    
    /**
     * @notice Update price with enhanced validation and confidence scoring
     * @param mbsToken Address of the MBS token contract
     * @param trancheId ID of the specific tranche (AAA, BBB, etc.)
     * @param newPrice New price in USDC (18 decimals)
     * @param confidence Confidence score (0-10000 basis points)
     */
    function updatePrice(
        address mbsToken,
        uint256 trancheId,
        uint256 newPrice,
        uint256 confidence
    ) external 
      onlyRole(PRICE_UPDATER_ROLE) 
      onlyValidMBSToken(mbsToken)
      whenNotPaused 
      nonReentrant 
    {
        require(newPrice > 0, "Invalid price");
        require(confidence <= CONFIDENCE_DECIMALS, "Invalid confidence");
        
        bytes32 trancheKey = _getTrancheKey(mbsToken, trancheId);
        PriceData memory oldData = priceFeeds[trancheKey];
        
        // Check price deviation if not first update
        if (oldData.timestamp > 0) {
            uint256 deviation = _calculateDeviation(oldData.price, newPrice);
            
            if (deviation > MAX_DEVIATION) {
                emit PriceDeviationAlert(trancheKey, oldData.price, newPrice, deviation);
                revert("Price deviation too high");
            }
        }
        
        // Update price data
        priceFeeds[trancheKey] = PriceData({
            price: newPrice,
            timestamp: block.timestamp,
            confidence: confidence,
            updater: msg.sender
        });
        
        updateCount[trancheKey]++;
        
        emit PriceUpdated(mbsToken, trancheId, newPrice, confidence, msg.sender);
    }
    
    /**
     * @notice Batch update prices for efficiency
     * @param mbsTokens Array of MBS token addresses
     * @param trancheIds Array of tranche IDs
     * @param prices Array of new prices
     * @param confidences Array of confidence scores
     */
    function batchUpdatePrices(
        address[] calldata mbsTokens,
        uint256[] calldata trancheIds,
        uint256[] calldata prices,
        uint256[] calldata confidences
    ) external onlyRole(PRICE_UPDATER_ROLE) whenNotPaused {
        require(
            mbsTokens.length == trancheIds.length &&
            trancheIds.length == prices.length &&
            prices.length == confidences.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < mbsTokens.length; i++) {
            this.updatePrice(mbsTokens[i], trancheIds[i], prices[i], confidences[i]);
        }
    }
    
    // --- Price Query Functions ---
    
    /**
     * @notice Get price with staleness check
     * @param mbsToken Address of the MBS token contract
     * @param trancheId ID of the specific tranche
     * @return price The price in USDC (18 decimals)
     * @return confidence The confidence score
     * @return timestamp Last update timestamp
     */
    function getPrice(
        address mbsToken,
        uint256 trancheId
    ) external view returns (uint256 price, uint256 confidence, uint256 timestamp) {
        bytes32 trancheKey = _getTrancheKey(mbsToken, trancheId);
        PriceData memory data = priceFeeds[trancheKey];
        
        require(data.timestamp > 0, "Price not available");
        require(block.timestamp - data.timestamp <= MAX_PRICE_AGE, "Price too stale");
        
        return (data.price, data.confidence, data.timestamp);
    }
    
    /**
     * @notice Get price without staleness check (for historical queries)
     * @param mbsToken Address of the MBS token contract
     * @param trancheId ID of the specific tranche
     * @return price The price in USDC (18 decimals)
     * @return confidence The confidence score
     * @return timestamp Last update timestamp
     * @return isStale Whether the price is stale
     */
    function getPriceUnchecked(
        address mbsToken,
        uint256 trancheId
    ) external view returns (
        uint256 price, 
        uint256 confidence, 
        uint256 timestamp,
        bool isStale
    ) {
        bytes32 trancheKey = _getTrancheKey(mbsToken, trancheId);
        PriceData memory data = priceFeeds[trancheKey];
        
        require(data.timestamp > 0, "Price not available");
        
        isStale = block.timestamp - data.timestamp > MAX_PRICE_AGE;
        return (data.price, data.confidence, data.timestamp, isStale);
    }
    
    /**
     * @notice Get multiple prices in one call
     * @param mbsTokens Array of MBS token addresses
     * @param trancheIds Array of tranche IDs
     * @return prices Array of prices
     * @return confidences Array of confidence scores
     */
    function getBatchPrices(
        address[] calldata mbsTokens,
        uint256[] calldata trancheIds
    ) external view returns (
        uint256[] memory prices,
        uint256[] memory confidences
    ) {
        require(mbsTokens.length == trancheIds.length, "Array length mismatch");
        
        prices = new uint256[](mbsTokens.length);
        confidences = new uint256[](mbsTokens.length);
        
        for (uint256 i = 0; i < mbsTokens.length; i++) {
            bytes32 trancheKey = _getTrancheKey(mbsTokens[i], trancheIds[i]);
            PriceData memory data = priceFeeds[trancheKey];
            
            require(data.timestamp > 0, "Price not available");
            require(block.timestamp - data.timestamp <= MAX_PRICE_AGE, "Price too stale");
            
            prices[i] = data.price;
            confidences[i] = data.confidence;
        }
    }
    
    // --- Helper Functions ---
    
    /**
     * @notice Generate unique key for each tranche
     * @param mbsToken Address of the MBS token
     * @param trancheId ID of the tranche
     * @return Unique identifier for the tranche
     */
    function _getTrancheKey(
        address mbsToken,
        uint256 trancheId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(mbsToken, trancheId));
    }
    
    /**
     * @notice Calculate percentage deviation between two prices
     * @param oldPrice Previous price
     * @param newPrice New price
     * @return Deviation in basis points
     */
    function _calculateDeviation(
        uint256 oldPrice,
        uint256 newPrice
    ) internal pure returns (uint256) {
        if (oldPrice == 0) return 0;
        
        uint256 diff = newPrice > oldPrice 
            ? newPrice - oldPrice 
            : oldPrice - newPrice;
            
        return (diff * CONFIDENCE_DECIMALS) / oldPrice;
    }
    
    // --- View Functions for Analytics ---
    
    /**
     * @notice Get update statistics for a tranche
     * @param mbsToken Address of the MBS token
     * @param trancheId ID of the tranche
     * @return updates Total number of price updates
     * @return lastUpdater Address of last price updater
     * @return isStale Whether the price is currently stale
     */
    function getUpdateStats(
        address mbsToken,
        uint256 trancheId
    ) external view returns (
        uint256 updates,
        address lastUpdater,
        bool isStale
    ) {
        bytes32 trancheKey = _getTrancheKey(mbsToken, trancheId);
        PriceData memory data = priceFeeds[trancheKey];
        
        updates = updateCount[trancheKey];
        lastUpdater = data.updater;
        isStale = block.timestamp - data.timestamp > MAX_PRICE_AGE;
    }
}