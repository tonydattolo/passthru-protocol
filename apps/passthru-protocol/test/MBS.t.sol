// test/MBS.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

// Our Contracts
import {MortgageNFT} from "../src/MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "../src/MBSPrimeJumbo2024.sol";
import {MortgageRouter} from "../src/MortgageRouter.sol";
import {MBSOracle} from "../src/MBSOracle.sol";
import {MBSHook} from "../src/MBSHook.sol";
import {LiquidityRouter} from "../src/LiquidityRouter.sol";

// Mocks
import {MockERC20} from "./mocks/MockERC20.sol";

// This mock PoolManager will actually perform callbacks for testing.
contract MockPoolManager is IPoolManager, IUnlockCallback {
    mapping(address => bytes) public lastUnlockData;

    function unlock(bytes calldata data) external returns (bytes memory) {
        lastUnlockData[msg.sender] = data;
        // In a test, the caller is often the test contract itself implementing IUnlockCallback
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function donate(
        PoolKey calldata,
        Currency,
        uint256
    ) external returns (BalanceDelta) {
        // Mock implementation
        return BalanceDeltaLibrary.ZERO_DELTA;
    }

    function settle(Currency, address, uint256, bool) external payable {}

    function take(Currency, address, uint256, bool) external {}

    function mint(address, uint256, uint256) external {}

    function burn(address, uint256, uint256) external {}

    // Stub out other IPoolManager functions
    function initialize(PoolKey memory, uint160) external returns (int24) {
        return 0;
    }
    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    ) external returns (BalanceDelta, BalanceDelta) {
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }
    function swap(
        PoolKey memory,
        SwapParams memory,
        bytes calldata
    ) external returns (BalanceDelta) {
        return BalanceDeltaLibrary.ZERO_DELTA;
    }
    function sync(Currency) external {}
    function updateDynamicLPFee(PoolKey memory, uint24) external {}
    //...etc for all interface functions
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        return "";
    }
}

contract MBSTest is Test, IUnlockCallback {
    // --- Actors ---
    address lender = address(0x100);
    address homeowner = address(0x200);
    address institutionalTrader = address(0x300);
    address intermediary = address(0x1337);

    // --- Contracts ---
    MockPoolManager poolManager;
    MortgageRouter mortgageRouter;
    LiquidityRouter liquidityRouter;
    MBSHook mbsHook;
    MortgageNFT mortgageNFT;
    MBSPrimeJumbo2024 mbsPool;
    MBSOracle oracle;
    MockERC20 usdc;

    // --- Uniswap V4 Pool Key ---
    PoolKey public mbsAaaPoolKey;

    function setUp() public {
        // --- Deploy Core Infrastructure ---
        poolManager = new MockPoolManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MBSOracle(address(this));

        // --- Deploy MBS Contracts ---
        mbsPool = new MBSPrimeJumbo2024(address(this), address(poolManager));
        mortgageNFT = new MortgageNFT(address(this));
        mortgageRouter = new MortgageRouter(
            address(this),
            address(poolManager),
            address(mortgageNFT),
            address(mbsPool),
            address(usdc),
            intermediary
        );

        // Link dependencies
        mortgageNFT.setRouter(address(mortgageRouter));
        mbsPool.setMortgageNFT(address(mortgageNFT));

        // --- Deploy Hook and Liquidity Router ---
        bytes memory hookConstructorArgs = abi.encode(
            poolManager,
            address(oracle)
        );
        uint160 hookFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddress, ) = HookMiner.find(
            address(this),
            hookFlags,
            type(MBSHook).creationCode,
            hookConstructorArgs
        );
        vm.etch(hookAddress, type(MBSHook).creationCode);
        mbsHook = MBSHook(payable(hookAddress));
        (bool success, ) = hookAddress.call(hookConstructorArgs);
        require(success, "Hook constructor failed");

        liquidityRouter = new LiquidityRouter(address(poolManager));

        // --- Set up Pool Key ---
        Currency mbsCurrency = Currency.wrap(address(mbsPool));
        Currency usdcCurrency = Currency.wrap(address(usdc));

        // Ensure correct currency order for PoolKey
        (Currency currency0, Currency currency1) = usdcCurrency < mbsCurrency
            ? (usdcCurrency, mbsCurrency)
            : (mbsCurrency, usdcCurrency);

        mbsAaaPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: mbsHook
        });

        // --- Fund Users ---
        usdc.mint(lender, 1_000_000 * 1e6); // 1M USDC
        usdc.mint(homeowner, 10_000 * 1e6); // 10k USDC
    }

    /// @notice A comprehensive test covering the entire lifecycle.
    function test_FullMortgageLifecycle() public {
        // =============================================================
        // PHASE 1: MORTGAGE ORIGINATION & FUNDING
        // =============================================================
        console.log("--- PHASE 1: ORIGINATION ---");

        // Mock: Lender approves the router to spend their USDC
        vm.startPrank(lender);
        usdc.approve(address(mortgageRouter), 500_000 * 1e6);

        // Action: Lender funds a mortgage
        MortgageNFT.MortgageDetails memory details = MortgageNFT
            .MortgageDetails({
                originalBalance: 500_000 * 1e6, // $500k
                interestRateBPS: 550, // 5.50%
                termInMonths: 360,
                ltv: 80,
                dti: 35,
                fico: 780,
                loanType: "Prime",
                amortizationScheme: "FullyAmortizing"
            });

        console.log("Lender funding mortgage...");
        mortgageRouter.fundMortgage(details);
        vm.stopPrank();

        // Verification:
        assertEq(
            usdc.balanceOf(intermediary),
            500_000 * 1e6,
            "Intermediary should have received funds"
        );
        assertEq(
            mortgageNFT.ownerOf(0),
            lender,
            "Lender should own the new MortgageNFT"
        );
        console.log("Mortgage funded. NFT minted to lender.");

        // =============================================================
        // PHASE 2: SECURITIZATION
        // =============================================================
        console.log("\n--- PHASE 2: SECURITIZATION ---");

        vm.startPrank(lender);
        console.log("Lender securitizing NFT...");
        mortgageRouter.securitizeMortgage(0);
        vm.stopPrank();

        // Verification:
        uint256 expectedAaa = (500_000 * 1e6 * 70) / 100;
        uint256 expectedBbb = (500_000 * 1e6 * 20) / 100;

        assertEq(
            mbsPool.balanceOf(lender, mbsPool.AAA_TRANCHE_ID()),
            expectedAaa,
            "Incorrect AAA tranche amount"
        );
        assertEq(
            mbsPool.balanceOf(lender, mbsPool.BBB_TRANCHE_ID()),
            expectedBbb,
            "Incorrect BBB tranche amount"
        );
        assertEq(
            mortgageNFT.ownerOf(0),
            address(mbsPool),
            "MBS Pool should now own the NFT"
        );
        console.log("NFT securitized. Tranched MBS tokens minted to investor.");

        // =============================================================
        // PHASE 3: SERVICING & CASH FLOW
        // =============================================================
        console.log("\n--- PHASE 3: SERVICING ---");

        // Mock: Homeowner makes a payment
        uint256 paymentAmount = 2838 * 1e6; // ~$2.8k payment
        vm.startPrank(homeowner);
        usdc.approve(address(mortgageRouter), paymentAmount);

        console.log("Homeowner making monthly payment...");
        // This test requires the router to implement IUnlockCallback, which it does.
        // The mock pool manager will call back to the router.
        mortgageRouter.makeMonthlyPayment(mbsAaaPoolKey, paymentAmount);
        vm.stopPrank();

        // Verification:
        uint256 expectedFee = (paymentAmount * 25) / 10000;
        assertEq(
            usdc.balanceOf(intermediary),
            500_000 * 1e6 + expectedFee,
            "Intermediary should have received servicing fee"
        );
        // We can check the unlock data to see if donate was called correctly
        MortgageRouter.CallbackData memory cbData = abi.decode(
            poolManager.lastUnlockData(address(mortgageRouter)),
            (MortgageRouter.CallbackData)
        );
        assertEq(uint(cbData.action), uint(MortgageRouter.Action.MAKE_PAYMENT));
        console.log("Payment processed and distributed via donate().");

        // =============================================================
        // PHASE 4: SECONDARY MARKET & TRADING
        // =============================================================
        console.log("\n--- PHASE 4: TRADING ---");

        // Mock: Set oracle price for the AAA tranche
        uint256 mbsTokenId = mbsPool.AAA_TRANCHE_ID();
        uint256 fairValue = 0.98 * 1e18; // Trading at 98 cents on the dollar
        oracle.updatePrice(address(mbsPool), mbsTokenId, fairValue);

        // Mock: Provide liquidity directly to the hook for its custom AMM
        vm.startPrank(institutionalTrader);
        mbsPool.mint(institutionalTrader, mbsTokenId, 100_000 * 1e6); // Give trader some AAA tokens
        usdc.mint(institutionalTrader, 100_000 * 1e6); // and some USDC

        mbsPool.setApprovalForAll(address(mbsHook), true);
        usdc.approve(address(mbsHook), type(uint256).max);

        console.log("Institutional trader providing liquidity to the hook...");
        // Placeholder values for addresses
        mbsHook.addLiquidity(
            address(mbsPool),
            mbsTokenId,
            100_000 * 1e6,
            98_000 * 1e6
        );
        vm.stopPrank();

        // Action: A retail user (the lender) sells some of their BBB tranche
        // This part is more complex as it involves a real swap. For this test,
        // we'll focus on the HFT flow which is more unique.

        // Action: Institutional trader uses the LiquidityRouter for gasless trading
        console.log(
            "Institutional trader depositing assets for gasless trading..."
        );
        vm.startPrank(institutionalTrader);
        uint256 depositAmount = 10_000 * 1e6;
        usdc.approve(address(liquidityRouter), depositAmount);
        liquidityRouter.deposit(
            CurrencyLibrary.wrap(address(usdc)),
            depositAmount
        );

        // Verification for ERC-6909 is tricky without a full PoolManager.
        // A full integration test would check the claim token balance on the PoolManager.
        // For now, we confirm the router's logic path was executed.
        LiquidityRouter.CallbackData memory liqCbData = abi.decode(
            poolManager.lastUnlockData(address(liquidityRouter)),
            (LiquidityRouter.CallbackData)
        );
        assertEq(uint(liqCbData.action), uint(LiquidityRouter.Action.DEPOSIT));
        assertEq(liqCbData.amount, depositAmount);
        vm.stopPrank();
        console.log("Assets deposited for ERC-6909 claims.");
    }
}
