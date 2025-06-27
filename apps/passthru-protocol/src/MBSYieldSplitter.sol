// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";

/**
 * @title MBSYieldSplitter
 * @notice Splits MBS tokens into Principal Tokens (PT) and Yield Tokens (YT) using V4's ERC-6909
 * @dev Enables yield trading without selling underlying MBS, similar to Pendle Finance
 * 
 * KEY FEATURES:
 * - Split MBS into tradeable PT and YT components
 * - Create dedicated V4 pools for yield trading
 * - Flash accounting for efficient rebalancing
 * - Automatic yield distribution to YT holders
 */
contract MBSYieldSplitter is ReentrancyGuard, Ownable {
    // --- Core Components ---
    IPoolManager public immutable poolManager;
    address public immutable mbsHook; // Hook for yield token pools
    
    // --- Token ID Generation ---
    uint256 constant PT_OFFSET = 1e9; // Principal tokens start at 1 billion
    uint256 constant YT_OFFSET = 2e9; // Yield tokens start at 2 billion
    
    // --- State Variables ---
    mapping(uint256 => MBSInfo) public mbsRegistry; // Original MBS token ID => info
    mapping(uint256 => uint256) public totalLocked; // MBS token ID => amount locked
    mapping(uint256 => uint256) public accumulatedYield; // YT token ID => accumulated yield per token
    mapping(address => mapping(uint256 => uint256)) public lastClaimedYield; // user => YT ID => last claimed index
    
    struct MBSInfo {
        address mbsContract;
        uint256 maturityDate;
        uint256 couponRate; // Annual rate in basis points
        uint256 paymentFrequency; // Payments per year
        bool isActive;
    }
    
    struct SplitPosition {
        uint256 mbsTokenId;
        uint256 amount;
        uint256 lockedAt;
        address owner;
    }
    
    // --- Events ---
    event MBSSplit(
        address indexed user,
        uint256 indexed mbsTokenId,
        uint256 amount,
        uint256 ptTokenId,
        uint256 ytTokenId
    );
    event MBSRedeemed(
        address indexed user,
        uint256 indexed mbsTokenId,
        uint256 amount
    );
    event YieldClaimed(
        address indexed user,
        uint256 indexed ytTokenId,
        uint256 yieldAmount
    );
    event YieldPoolCreated(
        uint256 indexed ytTokenId,
        PoolKey poolKey
    );
    event YieldDistributed(
        uint256 indexed ytTokenId,
        uint256 totalYield,
        uint256 yieldPerToken
    );
    
    constructor(IPoolManager _poolManager, address _mbsHook) Ownable(msg.sender) {
        poolManager = _poolManager;
        mbsHook = _mbsHook;
    }
    
    // --- Admin Functions ---
    
    /**
     * @notice Register an MBS token for yield splitting
     * @param mbsTokenId Original MBS token ID
     * @param mbsContract Address of the MBS contract
     * @param maturityDate Unix timestamp of maturity
     * @param couponRate Annual coupon rate in basis points
     * @param paymentFrequency Number of payments per year
     */
    function registerMBS(
        uint256 mbsTokenId,
        address mbsContract,
        uint256 maturityDate,
        uint256 couponRate,
        uint256 paymentFrequency
    ) external onlyOwner {
        require(maturityDate > block.timestamp, "Already matured");
        require(couponRate > 0 && couponRate <= 10000, "Invalid coupon rate");
        require(paymentFrequency > 0 && paymentFrequency <= 12, "Invalid frequency");
        
        mbsRegistry[mbsTokenId] = MBSInfo({
            mbsContract: mbsContract,
            maturityDate: maturityDate,
            couponRate: couponRate,
            paymentFrequency: paymentFrequency,
            isActive: true
        });
    }
    
    // --- Core Functions ---
    
    /**
     * @notice Split MBS tokens into PT and YT
     * @param mbsTokenId ID of the MBS token to split
     * @param amount Amount of MBS tokens to split
     */
    function splitMBS(
        uint256 mbsTokenId,
        uint256 amount
    ) external nonReentrant {
        MBSInfo memory info = mbsRegistry[mbsTokenId];
        require(info.isActive, "MBS not registered");
        require(block.timestamp < info.maturityDate, "MBS matured");
        require(amount > 0, "Invalid amount");
        
        // Transfer MBS tokens to this contract
        IERC1155(info.mbsContract).safeTransferFrom(
            msg.sender,
            address(this),
            mbsTokenId,
            amount,
            ""
        );
        
        // Generate PT and YT token IDs
        uint256 ptTokenId = getPTTokenId(mbsTokenId);
        uint256 ytTokenId = getYTTokenId(mbsTokenId);
        
        // Mint PT and YT as ERC-6909 claims
        poolManager.unlock(
            abi.encode(SplitAction({
                actionType: ActionType.SPLIT,
                user: msg.sender,
                mbsTokenId: mbsTokenId,
                amount: amount,
                ptTokenId: ptTokenId,
                ytTokenId: ytTokenId
            }))
        );
        
        totalLocked[mbsTokenId] += amount;
        
        emit MBSSplit(msg.sender, mbsTokenId, amount, ptTokenId, ytTokenId);
    }
    
    /**
     * @notice Redeem PT tokens for underlying MBS at maturity
     * @param mbsTokenId Original MBS token ID
     * @param amount Amount of PT tokens to redeem
     */
    function redeemPrincipal(
        uint256 mbsTokenId,
        uint256 amount
    ) external nonReentrant {
        MBSInfo memory info = mbsRegistry[mbsTokenId];
        require(block.timestamp >= info.maturityDate, "Not matured");
        
        uint256 ptTokenId = getPTTokenId(mbsTokenId);
        
        // Burn PT tokens and return MBS
        poolManager.unlock(
            abi.encode(SplitAction({
                actionType: ActionType.REDEEM,
                user: msg.sender,
                mbsTokenId: mbsTokenId,
                amount: amount,
                ptTokenId: ptTokenId,
                ytTokenId: 0
            }))
        );
        
        // Transfer MBS back to user
        IERC1155(info.mbsContract).safeTransferFrom(
            address(this),
            msg.sender,
            mbsTokenId,
            amount,
            ""
        );
        
        totalLocked[mbsTokenId] -= amount;
        
        emit MBSRedeemed(msg.sender, mbsTokenId, amount);
    }
    
    /**
     * @notice Claim accumulated yield for YT tokens
     * @param ytTokenId YT token ID
     */
    function claimYield(uint256 ytTokenId) external nonReentrant {
        uint256 mbsTokenId = getMBSTokenId(ytTokenId);
        require(mbsRegistry[mbsTokenId].isActive, "Invalid YT token");
        
        uint256 ytBalance = poolManager.balanceOf(msg.sender, ytTokenId);
        require(ytBalance > 0, "No YT balance");
        
        uint256 totalYield = accumulatedYield[ytTokenId];
        uint256 lastClaimed = lastClaimedYield[msg.sender][ytTokenId];
        uint256 yieldToClaim = ((totalYield - lastClaimed) * ytBalance) / 1e18;
        
        if (yieldToClaim > 0) {
            lastClaimedYield[msg.sender][ytTokenId] = totalYield;
            
            // Transfer yield in USDC
            poolManager.unlock(
                abi.encode(YieldClaim({
                    user: msg.sender,
                    ytTokenId: ytTokenId,
                    yieldAmount: yieldToClaim
                }))
            );
            
            emit YieldClaimed(msg.sender, ytTokenId, yieldToClaim);
        }
    }
    
    /**
     * @notice Distribute yield payment to YT holders
     * @param mbsTokenId Original MBS token ID
     * @param yieldAmount Total yield to distribute
     */
    function distributeYield(
        uint256 mbsTokenId,
        uint256 yieldAmount
    ) external onlyOwner {
        require(mbsRegistry[mbsTokenId].isActive, "MBS not registered");
        
        uint256 ytTokenId = getYTTokenId(mbsTokenId);
        uint256 totalYTSupply = poolManager.totalSupply(ytTokenId);
        
        if (totalYTSupply > 0 && yieldAmount > 0) {
            uint256 yieldPerToken = (yieldAmount * 1e18) / totalYTSupply;
            accumulatedYield[ytTokenId] += yieldPerToken;
            
            emit YieldDistributed(ytTokenId, yieldAmount, yieldPerToken);
        }
    }
    
    /**
     * @notice Create a V4 pool for yield token trading
     * @param ytTokenId YT token ID
     * @param sqrtPriceX96 Initial price
     */
    function createYieldPool(
        uint256 ytTokenId,
        uint160 sqrtPriceX96
    ) external returns (PoolKey memory poolKey) {
        uint256 mbsTokenId = getMBSTokenId(ytTokenId);
        require(mbsRegistry[mbsTokenId].isActive, "Invalid YT token");
        
        // Create pool key for YT/USDC trading
        poolKey = PoolKey({
            currency0: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            currency1: Currency.wrap(address(uint160(ytTokenId))), // YT as currency
            fee: 3000, // 0.3% fee
            tickSpacing: 60,
            hooks: IHooks(mbsHook)
        });
        
        // Initialize pool
        poolManager.initialize(poolKey, sqrtPriceX96);
        
        emit YieldPoolCreated(ytTokenId, poolKey);
    }
    
    // --- V4 Callback ---
    
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        
        bytes memory result = abi.decode(data, (bytes));
        
        // Decode action type
        uint8 actionTypeRaw = uint8(result[0]);
        
        if (actionTypeRaw == uint8(ActionType.SPLIT)) {
            SplitAction memory action = abi.decode(result, (SplitAction));
            
            // Mint PT and YT tokens
            poolManager.mint(action.user, action.ptTokenId, action.amount);
            poolManager.mint(action.user, action.ytTokenId, action.amount);
            
            return abi.encode(BalanceDelta(0, 0));
            
        } else if (actionTypeRaw == uint8(ActionType.REDEEM)) {
            SplitAction memory action = abi.decode(result, (SplitAction));
            
            // Burn PT tokens
            poolManager.burn(action.user, action.ptTokenId, action.amount);
            
            return abi.encode(BalanceDelta(0, 0));
            
        } else if (actionTypeRaw == uint8(ActionType.CLAIM_YIELD)) {
            YieldClaim memory claim = abi.decode(result, (YieldClaim));
            
            // Transfer yield to user
            poolManager.take(
                Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
                claim.user,
                claim.yieldAmount
            );
            
            return abi.encode(BalanceDelta(int256(claim.yieldAmount), 0));
        }
        
        revert("Invalid action");
    }
    
    // --- Helper Functions ---
    
    function getPTTokenId(uint256 mbsTokenId) public pure returns (uint256) {
        return PT_OFFSET + mbsTokenId;
    }
    
    function getYTTokenId(uint256 mbsTokenId) public pure returns (uint256) {
        return YT_OFFSET + mbsTokenId;
    }
    
    function getMBSTokenId(uint256 tokenId) public pure returns (uint256) {
        if (tokenId >= YT_OFFSET) {
            return tokenId - YT_OFFSET;
        } else if (tokenId >= PT_OFFSET) {
            return tokenId - PT_OFFSET;
        }
        revert("Invalid token ID");
    }
    
    function isPrincipalToken(uint256 tokenId) public pure returns (bool) {
        return tokenId >= PT_OFFSET && tokenId < YT_OFFSET;
    }
    
    function isYieldToken(uint256 tokenId) public pure returns (bool) {
        return tokenId >= YT_OFFSET;
    }
    
    // --- View Functions ---
    
    function getMBSInfo(uint256 mbsTokenId) external view returns (MBSInfo memory) {
        return mbsRegistry[mbsTokenId];
    }
    
    function getYieldInfo(uint256 ytTokenId) external view returns (
        uint256 totalYield,
        uint256 userClaimable
    ) {
        uint256 mbsTokenId = getMBSTokenId(ytTokenId);
        require(mbsRegistry[mbsTokenId].isActive, "Invalid YT token");
        
        uint256 ytBalance = poolManager.balanceOf(msg.sender, ytTokenId);
        totalYield = accumulatedYield[ytTokenId];
        
        if (ytBalance > 0) {
            uint256 lastClaimed = lastClaimedYield[msg.sender][ytTokenId];
            userClaimable = ((totalYield - lastClaimed) * ytBalance) / 1e18;
        }
    }
    
    // --- ERC1155 Receiver ---
    
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    // --- Action Types ---
    
    enum ActionType {
        SPLIT,
        REDEEM,
        CLAIM_YIELD
    }
    
    struct SplitAction {
        ActionType actionType;
        address user;
        uint256 mbsTokenId;
        uint256 amount;
        uint256 ptTokenId;
        uint256 ytTokenId;
    }
    
    struct YieldClaim {
        address user;
        uint256 ytTokenId;
        uint256 yieldAmount;
    }
}