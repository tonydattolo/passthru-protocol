// src/MBSHook.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MBSOracle} from "./MBSOracle.sol";
import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";

/**
 * @title MBSHook
 * @notice A hook for creating a custom, oracle-based pricing curve for MBS tokens.
 * This hook bypasses the standard AMM logic and manages its own accounting via ERC-6909 claims.
 * 
 * SECURITY NOTE: This hook implements pool whitelisting to prevent unauthorized pools
 * from using the hook and potentially corrupting its state or exploiting its logic.
 * This protects against attacks similar to the Cork protocol hack where attackers
 * created malicious pools that used legitimate hooks.
 */
contract MBSHook is BaseHook, Ownable {
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    MBSOracle public immutable oracle;

    // Placeholder for the address of the MBS ERC-1155 contract.
    // In a real system, this would be a registry or part of the PoolKey.
    address public constant MBS_TOKEN_ADDRESS = <YOUR_MBS_TOKEN_CONTRACT_ADDRESS>;

    // --- Pool Whitelisting for Security ---
    // This mapping tracks which pools are authorized to use this hook.
    // Without this protection, any malicious actor could deploy a pool with fake tokens
    // and attach our hook, potentially exploiting our pricing logic or corrupting state.
    mapping(bytes32 => bool) public isAllowedPool;

    // --- Events ---
    event PoolAllowed(bytes32 indexed poolId);
    event PoolDisallowed(bytes32 indexed poolId);

    constructor(IPoolManager _manager, address _oracleAddress) BaseHook(_manager) Ownable(msg.sender) {
        oracle = MBSOracle(_oracleAddress);
        // On deployment, the hook needs its own liquidity to make markets.
        // This would typically be funded by the protocol owner/DAO.
    }

    // --- Access Control ---
    /**
     * @notice Ensures only whitelisted pools can interact with this hook
     * @dev This prevents the Cork-style attack where malicious pools could exploit hook logic
     * @param key The PoolKey to verify authorization for
     */
    modifier onlyAllowedPool(PoolKey calldata key) {
        require(isAllowedPool[key.toId()], "MBSHook: Pool not authorized");
        _;
    }

    // --- Admin Functions ---
    /**
     * @notice Authorizes a pool to use this hook
     * @dev Only the owner (protocol DAO) can whitelist pools. This ensures only legitimate
     * MBS/USDC pools with proper token contracts can interact with our pricing logic.
     * @param key The PoolKey to authorize
     */
    function allowPool(PoolKey calldata key) external onlyOwner {
        isAllowedPool[key.toId()] = true;
        emit PoolAllowed(key.toId());
    }

    /**
     * @notice Removes authorization for a pool to use this hook
     * @dev Allows emergency removal of compromised or deprecated pools
     * @param key The PoolKey to deauthorize
     */
    function disallowPool(PoolKey calldata key) external onlyOwner {
        isAllowedPool[key.toId()] = false;
        emit PoolDisallowed(key.toId());
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Disable standard liquidity management
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // Disable standard liquidity management
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // CRITICAL: This enables our custom curve
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Disable default V4 liquidity management ---
    /**
     * @notice Prevents direct liquidity addition through V4's standard mechanism
     * @dev Added pool authorization check to prevent malicious pools from attempting
     * to interact with hook liquidity management functions
     */
    function beforeAddLiquidity(
        address, 
        PoolKey calldata key, 
        IPoolManager.ModifyLiquidityParams calldata, 
        bytes calldata
    ) external view override onlyAllowedPool(key) returns (bytes4) {
        revert("Liquidity managed by hook; not allowed directly.");
    }

    /**
     * @notice Prevents direct liquidity removal through V4's standard mechanism
     * @dev Added pool authorization check for consistency and security
     */
    function beforeRemoveLiquidity(
        address, 
        PoolKey calldata key, 
        IPoolManager.ModifyLiquidityParams calldata, 
        bytes calldata
    ) external view override onlyAllowedPool(key) returns (bytes4) {
        revert("Liquidity managed by hook; not allowed directly.");
    }
    
    // --- The Custom Pricing Logic ---
    /**
     * @notice Implements custom oracle-based pricing for MBS token swaps
     * @dev CRITICAL SECURITY: Only authorized pools can execute swaps through this hook.
     * This prevents attackers from creating fake MBS tokens and exploiting our pricing logic.
     */
    function _beforeSwap(
        address, // is the router
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override onlyAllowedPool(key) returns (bytes4, BeforeSwapDelta, uint24) {
        // For simplicity, this example assumes the MBS token is currency1 and USDC is currency0.
        // A production hook would handle both cases.
        require(params.zeroForOne, "Only USDC -> MBS swaps supported in this example");
        
        // Let's assume the tranche ID can be derived or is known.
        // In a real system, this might be encoded in hookData or a registry.
        uint256 trancheId = MBSPrimeJumbo2024.AAA_TRANCHE_ID;
        uint256 oraclePrice = oracle.getPrice(MBS_TOKEN_ADDRESS, trancheId); // Price of MBS in USDC (1e18)

        int256 amountSpecified = params.amountSpecified;
        uint256 amountIn;
        uint256 amountOut;

        // Swapping USDC (token0) for MBS (token1)
        if (amountSpecified < 0) { // Exact Input: User specifies exact USDC to spend
            amountIn = uint256(-amountSpecified); // Amount of USDC
            amountOut = (amountIn * 1e18) / oraclePrice;
        } else { // Exact Output: User specifies exact MBS to receive
            revert("Exact output not supported in this simplified example");
        }

        // --- Hook Accounting via ERC-6909 Claims ---
        // 1. The hook takes the user's USDC input for itself.
        // This is a "virtual" take. The PoolManager will enforce this delta against the user.
        poolManager.mint(key.currency0, address(this), amountIn);
        
        // 2. The hook provides the calculated MBS output from its own balance.
        // This is a "virtual" transfer. The hook must have sufficient claims to burn.
        poolManager.burn(key.currency1, address(this), amountOut);

        // --- The Return Delta Magic ---
        // This delta tells the PoolManager what the hook's actions imply for the user's swap.
        BeforeSwapDelta returnDelta = toBeforeSwapDelta(
            -int128(amountIn),   // The hook 'owes' the user the input USDC it took.
            int128(amountOut)    // The hook 'gives' the user the output MBS.
        );
        
        // The PoolManager will net this against the user's initial swap delta,
        // effectively canceling the PoolManager's swap logic and executing ours.
        // Final result: user pays `amountIn` USDC, receives `amountOut` MBS.
        // The hook's balance of claims is updated accordingly.
        
        // No fee override, as our price is all-in.
        return (this.beforeSwap.selector, returnDelta, 0);
    }
}

// // src/MBSHook.sol
// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.30;

// import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {MBSOracle} from "./MBSOracle.sol";
// import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
// import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";


// contract MBSHook is BaseHook {
//     MBSOracle public immutable oracle;

//     // The hook holds its own liquidity for the custom curve
//     uint256 public reserveMBS;
//     uint256 public reserveUSDC;

//     constructor(IPoolManager _manager, address _oracleAddress) BaseHook(_manager) {
//         oracle = MBSOracle(_oracleAddress);
//     }

//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: false,
//             afterInitialize: false,
//             beforeAddLiquidity: true, // We manage liquidity
//             afterAddLiquidity: false,
//             beforeRemoveLiquidity: true, // We manage liquidity
//             afterRemoveLiquidity: false,
//             beforeSwap: true,
//             afterSwap: false,
//             beforeDonate: false,
//             afterDonate: false,
//             beforeSwapReturnDelta: true, // CRITICAL: Enables custom curve
//             afterSwapReturnDelta: false,
//             afterAddLiquidityReturnDelta: false,
//             afterRemoveLiquidityReturnDelta: false
//         });
//     }

//     // --- Liquidity Management for the Hook ---
//     // Users deposit directly into the hook, which acts as the MM
//     function addLiquidity(address mbsToken, uint256 trancheId, uint256 amountMBS, uint256 amountUSDC) external {
//         // In a real system, you'd mint LP tokens. Here, we simplify.
//         MBSPrimeJumbo2024(mbsToken).safeTransferFrom(msg.sender, address(this), trancheId, amountMBS, "");
//         IERC20Minimal(USDC_ADDRESS).transferFrom(msg.sender, address(this), amountUSDC);
//         reserveMBS += amountMBS;
//         reserveUSDC += amountUSDC;
//     }

//     // --- Disable default V4 liquidity management ---
//     function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
//         revert("Use hook's addLiquidity function");
//     }
//     function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
//         revert("Use hook's removeLiquidity function");
//     }

//     // --- The Custom Pricing Logic ---
//     function beforeSwap(
//         address,
//         PoolKey calldata key,
//         IPoolManager.SwapParams calldata params,
//         bytes calldata
//     ) external override returns (bytes4, BeforeSwapDelta, uint24) {
//         // key.currency0 must be USDC, key.currency1 is the MBS Token address
//         // For simplicity, we assume this hook is only for MBS/USDC pools
        
//         // This is a placeholder for the actual MBS contract address and tranche ID
//         // In a real system, you would have a registry or parse this from the PoolKey
//         address mbsTokenAddress = <MBS_POOL_ADDRESS>; 
//         uint256 trancheId = <TRANCHE_ID>;
//         uint256 oraclePrice = oracle.getPrice(mbsTokenAddress, trancheId); // Price of MBS in USDC (1e18)

//         int256 amountSpecified = params.amountSpecified;
//         uint256 amountIn;
//         uint256 amountOut;

//         if (params.zeroForOne) { // Swapping USDC for MBS
//             if (amountSpecified < 0) { // Exact input (USDC)
//                 amountIn = uint256(-amountSpecified); // amount of USDC
//                 amountOut = (amountIn * 1e18) / oraclePrice; // amount of MBS
//                 reserveUSDC += amountIn;
//                 reserveMBS -= amountOut;
//             } else { // Exact output (MBS)
//                 amountOut = uint256(amountSpecified);
//                 amountIn = (amountOut * oraclePrice) / 1e18;
//                 reserveUSDC += amountIn;
//                 reserveMBS -= amountOut;
//             }
//         } else { // Swapping MBS for USDC
//              if (amountSpecified < 0) { // Exact input (MBS)
//                 amountIn = uint256(-amountSpecified); // amount of MBS
//                 amountOut = (amountIn * oraclePrice) / 1e18; // amount of USDC
//                 reserveMBS += amountIn;
//                 reserveUSDC -= amountOut;
//             } else { // Exact output (USDC)
//                 amountOut = uint256(amountSpecified);
//                 amountIn = (amountOut * 1e18) / oraclePrice;
//                 reserveMBS += amountIn;
//                 reserveUSDC -= amountOut;
//             }
//         }
        
//         // This is the magic. We tell the PoolManager how the balances should change
//         // *without* it running its own swap logic.
//         // We "consume" the user's input and provide the calculated output.
//         BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
//             int128(-amountSpecified), // Consume the user's specified amount
//             -int128(amountOut) // Provide the calculated output amount
//         );
        
//         // We're bypassing the core logic, so let's not charge a V4 fee for now.
//         // Fees could be built into the oraclePrice spread.
//         return (this.beforeSwap.selector, beforeSwapDelta, 0);
//     }
// }