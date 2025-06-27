// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {MortgageNFT} from "../src/MortgageNFT.sol";
import {MortgageRouter} from "../src/MortgageRouter.sol";
import {MBSPrimeJumbo2024} from "../src/MBSPrimeJumbo2024.sol";
import {MBSOracle} from "../src/MBSOracle.sol";
import {MBSYieldSplitter} from "../src/MBSYieldSplitter.sol";
import {MBSStablecoinVault, dMBS_USD} from "../src/MBSStablecoinVault.sol";
import {MockERC20} from "./mocks/MockERC20.t.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// Mock V4 PoolManager for testing
contract MockV4PoolManager {
    mapping(address => mapping(uint256 => uint256)) public balances;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowances;
    
    event Transfer(address indexed from, address indexed to, uint256 indexed id, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);
    
    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = msg.sender.call(
            abi.encodeWithSignature("unlockCallback(bytes)", data)
        );
        require(success, "Callback failed");
        return result;
    }
    
    function mint(address to, uint256 id, uint256 amount) external {
        balances[to][id] += amount;
        emit Transfer(address(0), to, id, amount);
    }
    
    function burn(address from, uint256 id, uint256 amount) external {
        require(balances[from][id] >= amount, "Insufficient balance");
        balances[from][id] -= amount;
        emit Transfer(from, address(0), id, amount);
    }
    
    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return balances[account][id];
    }
    
    function totalSupply(uint256 id) external view returns (uint256) {
        // Mock implementation - in production would track actual supply
        return 1000000e6;
    }
    
    function transferFrom(address from, address to, uint256 id, uint256 amount) external {
        require(balances[from][id] >= amount, "Insufficient balance");
        require(allowances[from][msg.sender][id] >= amount || from == msg.sender, "Insufficient allowance");
        
        balances[from][id] -= amount;
        balances[to][id] += amount;
        
        if (from != msg.sender) {
            allowances[from][msg.sender][id] -= amount;
        }
        
        emit Transfer(from, to, id, amount);
    }
    
    function transfer(address to, uint256 id, uint256 amount) external {
        require(balances[msg.sender][id] >= amount, "Insufficient balance");
        balances[msg.sender][id] -= amount;
        balances[to][id] += amount;
        emit Transfer(msg.sender, to, id, amount);
    }
    
    function approve(address spender, uint256 id, uint256 amount) external {
        allowances[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
    }
    
    // Mock V4 specific functions
    function take(address, address, uint256) external {}
    function settle(address) external {}
    function donate(address, uint256, uint256, bytes calldata) external {}
    function sync(address) external {}
    function initialize(bytes memory, uint160) external {}
}

// Mock Hook for testing
contract MockMBSHook {
    address public poolManager;
    
    constructor(address _poolManager) {
        poolManager = _poolManager;
    }
}

contract CompletePassThruWorkflowTest is Test {
    // Test accounts (using Anvil's default accounts)
    address constant LENDER1 = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address constant LENDER2 = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    address constant BORROWER = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
    address constant INVESTOR1 = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);
    address constant INVESTOR2 = address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65);
    address constant INTERMEDIARY = address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc);
    address constant ORACLE_UPDATER = address(0x976EA74026E726554dB657fA54763abd0C3a0aa9);
    
    // Contracts
    MockV4PoolManager poolManager;
    MockERC20 usdc;
    MortgageNFT mortgageNFT;
    MortgageRouter mortgageRouter;
    MBSPrimeJumbo2024 mbsPool;
    MBSOracle oracle;
    MBSYieldSplitter yieldSplitter;
    dMBS_USD stablecoin;
    MBSStablecoinVault stablecoinVault;
    MockMBSHook mbsHook;
    
    // Test state variables
    uint256[] mortgageTokenIds;
    
    function setUp() public {
        console.log("=== SETUP STARTING ===");
        
        // Deploy mock infrastructure
        poolManager = new MockV4PoolManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mbsHook = new MockMBSHook(address(poolManager));
        
        // Deploy core contracts
        mortgageNFT = new MortgageNFT(address(this), address(0)); // Router will be set later
        oracle = new MBSOracle(address(this));
        mbsPool = new MBSPrimeJumbo2024(address(this), address(mortgageNFT));
        
        // Deploy router with all dependencies
        mortgageRouter = new MortgageRouter(
            address(poolManager),
            address(mortgageNFT),
            address(mbsPool),
            address(oracle),
            address(usdc),
            INTERMEDIARY
        );
        
        // Deploy advanced features
        yieldSplitter = new MBSYieldSplitter(poolManager, address(mbsHook));
        stablecoin = new dMBS_USD(address(this));
        stablecoinVault = new MBSStablecoinVault(
            address(this),
            address(poolManager),
            address(stablecoin)
        );
        
        // Configure relationships
        mortgageNFT.setRouter(address(mortgageRouter));
        mortgageRouter.addAuthorizedLiquidator(INVESTOR1);
        oracle.grantRole(oracle.PRICE_UPDATER_ROLE(), ORACLE_UPDATER);
        
        // Fund test accounts with USDC
        usdc.mint(LENDER1, 5_000_000e6);      // $5M
        usdc.mint(LENDER2, 3_000_000e6);      // $3M
        usdc.mint(BORROWER, 100_000e6);       // $100k for payments
        usdc.mint(INVESTOR1, 10_000_000e6);   // $10M
        usdc.mint(INVESTOR2, 10_000_000e6);   // $10M
        
        console.log("=== SETUP COMPLETE ===");
        console.log("Contracts deployed:");
        console.log("  MortgageNFT:", address(mortgageNFT));
        console.log("  MortgageRouter:", address(mortgageRouter));
        console.log("  MBSPool:", address(mbsPool));
        console.log("  Oracle:", address(oracle));
        console.log("  YieldSplitter:", address(yieldSplitter));
        console.log("  Stablecoin:", address(stablecoin));
    }
    
    function test_1_LaunchMortgageNFT() public {
        console.log("\n=== TEST 1: LAUNCHING MORTGAGE NFTs ===");
        
        // Test launching multiple mortgages with different characteristics
        vm.startPrank(LENDER1);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        // Mortgage 1: Prime Jumbo Loan
        MortgageNFT.MortgageDetails memory mortgage1 = MortgageNFT.MortgageDetails({
            originalBalance: 1_000_000e6,  // $1M
            interestRateBPS: 550,          // 5.5%
            termInMonths: 360,             // 30 years
            ltv: 70,                       // 70% LTV
            dti: 30,                       // 30% DTI
            fico: 780,                     // Excellent credit
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        
        uint256 tokenId1 = mortgageRouter.fundMortgage(mortgage1);
        mortgageTokenIds.push(tokenId1);
        
        // Mortgage 2: Smaller Prime Loan
        MortgageNFT.MortgageDetails memory mortgage2 = MortgageNFT.MortgageDetails({
            originalBalance: 500_000e6,    // $500k
            interestRateBPS: 525,          // 5.25%
            termInMonths: 360,             // 30 years
            ltv: 80,                       // 80% LTV
            dti: 35,                       // 35% DTI
            fico: 750,                     // Good credit
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        
        uint256 tokenId2 = mortgageRouter.fundMortgage(mortgage2);
        mortgageTokenIds.push(tokenId2);
        
        vm.stopPrank();
        
        // Lender 2 creates a mortgage
        vm.startPrank(LENDER2);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        MortgageNFT.MortgageDetails memory mortgage3 = MortgageNFT.MortgageDetails({
            originalBalance: 750_000e6,    // $750k
            interestRateBPS: 600,          // 6%
            termInMonths: 180,             // 15 years
            ltv: 65,                       // 65% LTV
            dti: 25,                       // 25% DTI
            fico: 820,                     // Excellent credit
            loanType: "SuperPrime",
            amortizationScheme: "FullyAmortizing"
        });
        
        uint256 tokenId3 = mortgageRouter.fundMortgage(mortgage3);
        mortgageTokenIds.push(tokenId3);
        
        vm.stopPrank();
        
        // Verify mortgages were created correctly
        assertEq(mortgageNFT.ownerOf(tokenId1), LENDER1);
        assertEq(mortgageNFT.ownerOf(tokenId2), LENDER1);
        assertEq(mortgageNFT.ownerOf(tokenId3), LENDER2);
        
        // Verify funds were transferred
        assertEq(usdc.balanceOf(INTERMEDIARY), 2_250_000e6); // $1M + $500k + $750k
        
        console.log("✓ Successfully launched 3 mortgage NFTs");
        console.log("  Token ID 1: $1M @ 5.5%");
        console.log("  Token ID 2: $500k @ 5.25%");
        console.log("  Token ID 3: $750k @ 6%");
        console.log("  Total funded: $2.25M");
    }
    
    function test_2_FundingMortgageNFT() public {
        console.log("\n=== TEST 2: FUNDING MORTGAGE NFT ===");
        
        // First create a mortgage
        vm.startPrank(LENDER1);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        uint256 balanceBefore = usdc.balanceOf(LENDER1);
        
        MortgageNFT.MortgageDetails memory details = MortgageNFT.MortgageDetails({
            originalBalance: 2_000_000e6,  // $2M
            interestRateBPS: 475,          // 4.75%
            termInMonths: 360,             // 30 years
            ltv: 60,                       // 60% LTV
            dti: 28,                       // 28% DTI
            fico: 800,                     // Excellent credit
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        
        uint256 tokenId = mortgageRouter.fundMortgage(details);
        
        vm.stopPrank();
        
        // Verify funding completed
        assertEq(usdc.balanceOf(LENDER1), balanceBefore - 2_000_000e6);
        assertEq(usdc.balanceOf(INTERMEDIARY), 2_000_000e6);
        assertEq(mortgageNFT.ownerOf(tokenId), LENDER1);
        
        // Verify mortgage details stored correctly
        (
            uint256 balance,
            uint256 rate,
            uint32 term,
            uint8 ltv,
            uint8 dti,
            uint16 fico,
            string memory loanType,
            string memory amortScheme
        ) = mortgageNFT.mortgageDetails(tokenId);
        
        assertEq(balance, 2_000_000e6);
        assertEq(rate, 475);
        assertEq(term, 360);
        assertEq(ltv, 60);
        assertEq(dti, 28);
        assertEq(fico, 800);
        assertEq(loanType, "Prime");
        assertEq(amortScheme, "FullyAmortizing");
        
        console.log("✓ Successfully funded mortgage NFT");
        console.log("  Amount: $2M");
        console.log("  Rate: 4.75%");
        console.log("  NFT Owner:", mortgageNFT.ownerOf(tokenId));
    }
    
    function test_3_CreateMBSPoolWithMultipleMortgages() public {
        console.log("\n=== TEST 3: CREATING MBS POOL WITH MULTIPLE MORTGAGES ===");
        
        // First create several mortgages
        _createMultipleMortgages();
        
        // Now securitize them into the MBS pool
        vm.startPrank(LENDER1);
        
        // Approve MBS pool to take NFTs
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        
        // Securitize first mortgage
        mbsPool.securitize(mortgageTokenIds[0]);
        
        // Securitize second mortgage
        mbsPool.securitize(mortgageTokenIds[1]);
        
        vm.stopPrank();
        
        // Lender 2 securitizes their mortgage
        vm.startPrank(LENDER2);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[2]);
        vm.stopPrank();
        
        // Verify MBS tokens were minted correctly
        uint256 totalValue = 2_250_000e6; // $1M + $500k + $750k
        uint256 expectedAAA = (totalValue * 70) / 100;
        uint256 expectedBBB = (totalValue * 20) / 100;
        uint256 expectedNR = (totalValue * 10) / 100;
        
        // Check Lender1's balances (2 mortgages)
        uint256 lender1Value = 1_500_000e6; // $1M + $500k
        assertEq(
            mbsPool.balanceOf(LENDER1, mbsPool.AAA_TRANCHE_ID()),
            (lender1Value * 70) / 100
        );
        assertEq(
            mbsPool.balanceOf(LENDER1, mbsPool.BBB_TRANCHE_ID()),
            (lender1Value * 20) / 100
        );
        assertEq(
            mbsPool.balanceOf(LENDER1, mbsPool.NR_TRANCHE_ID()),
            (lender1Value * 10) / 100
        );
        
        // Check Lender2's balances (1 mortgage)
        uint256 lender2Value = 750_000e6; // $750k
        assertEq(
            mbsPool.balanceOf(LENDER2, mbsPool.AAA_TRANCHE_ID()),
            (lender2Value * 70) / 100
        );
        
        // Verify pool state
        assertEq(mbsPool.totalCollateralValue(), totalValue);
        assertEq(mbsPool.aaaOutstanding(), expectedAAA);
        assertEq(mbsPool.bbbOutstanding(), expectedBBB);
        assertEq(mbsPool.nrOutstanding(), expectedNR);
        
        console.log("✓ Successfully created MBS pool with 3 mortgages");
        console.log("  Total pool value: $2.25M");
        console.log("  AAA tranche: $", expectedAAA / 1e6);
        console.log("  BBB tranche: $", expectedBBB / 1e6);
        console.log("  NR tranche: $", expectedNR / 1e6);
    }
    
    function test_4_CreateTradeableYieldPrincipalTokens() public {
        console.log("\n=== TEST 4: CREATING TRADEABLE YIELD/PRINCIPAL TOKENS ===");
        
        // Setup: Create and securitize mortgages
        _createMultipleMortgages();
        _securitizeMortgages();
        
        // Register MBS tranches for yield splitting
        uint256 maturityDate = block.timestamp + 365 days * 30; // 30 year maturity
        
        yieldSplitter.registerMBS(
            mbsPool.AAA_TRANCHE_ID(),
            address(mbsPool),
            maturityDate,
            450, // 4.5% coupon
            12   // Monthly payments
        );
        
        yieldSplitter.registerMBS(
            mbsPool.BBB_TRANCHE_ID(),
            address(mbsPool),
            maturityDate,
            650, // 6.5% coupon
            12   // Monthly payments
        );
        
        // Investor 1 splits their AAA tokens
        vm.startPrank(INVESTOR1);
        
        // First acquire some MBS tokens
        vm.stopPrank();
        vm.startPrank(LENDER1);
        mbsPool.setApprovalForAll(INVESTOR1, true);
        mbsPool.safeTransferFrom(
            LENDER1,
            INVESTOR1,
            mbsPool.AAA_TRANCHE_ID(),
            500_000e6,
            ""
        );
        vm.stopPrank();
        
        vm.startPrank(INVESTOR1);
        mbsPool.setApprovalForAll(address(yieldSplitter), true);
        
        // Split MBS into PT and YT
        uint256 splitAmount = 500_000e6;
        yieldSplitter.splitMBS(mbsPool.AAA_TRANCHE_ID(), splitAmount);
        
        vm.stopPrank();
        
        // Verify PT and YT tokens were created
        uint256 ptTokenId = yieldSplitter.getPTTokenId(mbsPool.AAA_TRANCHE_ID());
        uint256 ytTokenId = yieldSplitter.getYTTokenId(mbsPool.AAA_TRANCHE_ID());
        
        assertEq(poolManager.balanceOf(INVESTOR1, ptTokenId), splitAmount);
        assertEq(poolManager.balanceOf(INVESTOR1, ytTokenId), splitAmount);
        
        // Test yield distribution
        vm.prank(address(yieldSplitter.owner()));
        uint256 monthlyYield = 1_875e6; // $500k * 4.5% / 12 months
        yieldSplitter.distributeYield(mbsPool.AAA_TRANCHE_ID(), monthlyYield);
        
        // Check yield accumulation
        (uint256 totalYield, uint256 claimable) = yieldSplitter.getYieldInfo(ytTokenId);
        assertGt(totalYield, 0);
        
        console.log("✓ Successfully created PT/YT tokens");
        console.log("  Split amount: $500k");
        console.log("  PT Token ID:", ptTokenId);
        console.log("  YT Token ID:", ytTokenId);
        console.log("  Monthly yield distributed: $", monthlyYield / 1e6);
    }
    
    function test_5_IssueStablecoinsBackedByMBS() public {
        console.log("\n=== TEST 5: ISSUING STABLECOINS BACKED BY MBS ===");
        
        // Setup: Create MBS tokens
        _createMultipleMortgages();
        _securitizeMortgages();
        
        // Transfer some MBS tokens to investor
        vm.startPrank(LENDER1);
        mbsPool.setApprovalForAll(INVESTOR2, true);
        mbsPool.safeTransferFrom(
            LENDER1,
            INVESTOR2,
            mbsPool.AAA_TRANCHE_ID(),
            1_000_000e6,
            ""
        );
        vm.stopPrank();
        
        // Convert MBS tokens to ERC-6909 claims
        vm.startPrank(INVESTOR2);
        
        // First, we need to deposit MBS tokens into the pool manager
        // In a real implementation, this would be done through a liquidity router
        // For testing, we'll mint claims directly
        uint256 claimId = mbsPool.AAA_TRANCHE_ID();
        poolManager.mint(INVESTOR2, claimId, 1_000_000e6);
        
        // Approve stablecoin vault to spend claims
        poolManager.approve(address(stablecoinVault), claimId, 1_000_000e6);
        
        // Lock claims and mint stablecoins
        uint256 lockAmount = 500_000e6; // Lock $500k worth
        stablecoinVault.lockClaimsAndMintStablecoin(claimId, lockAmount);
        
        vm.stopPrank();
        
        // Verify stablecoins were minted
        assertEq(stablecoin.balanceOf(INVESTOR2), lockAmount);
        assertEq(stablecoinVault.lockedClaims(INVESTOR2, claimId), lockAmount);
        assertEq(poolManager.balanceOf(address(stablecoinVault), claimId), lockAmount);
        
        // Test redemption
        vm.startPrank(INVESTOR2);
        
        uint256 redeemAmount = 200_000e6;
        stablecoin.approve(address(stablecoinVault), redeemAmount);
        stablecoinVault.burnStablecoinAndUnlockClaims(claimId, redeemAmount);
        
        vm.stopPrank();
        
        // Verify redemption
        assertEq(stablecoin.balanceOf(INVESTOR2), lockAmount - redeemAmount);
        assertEq(stablecoinVault.lockedClaims(INVESTOR2, claimId), lockAmount - redeemAmount);
        assertEq(poolManager.balanceOf(INVESTOR2, claimId), 500_000e6 + redeemAmount);
        
        console.log("✓ Successfully issued and redeemed MBS-backed stablecoins");
        console.log("  Initial lock: $500k");
        console.log("  Stablecoins minted: $500k");
        console.log("  Redeemed: $200k");
        console.log("  Remaining locked: $300k");
    }
    
    function test_CompleteWorkflow() public {
        console.log("\n=== COMPLETE END-TO-END WORKFLOW TEST ===");
        
        // 1. Launch mortgages
        test_1_LaunchMortgageNFT();
        
        // 2. Create MBS pool
        console.log("\n--- Creating MBS Pool ---");
        _securitizeMortgages();
        
        // 3. Setup payment distribution pools
        console.log("\n--- Setting up payment distribution ---");
        _setupPaymentDistribution();
        
        // 4. Process monthly payments
        console.log("\n--- Processing monthly payments ---");
        _processMonthlyPayments();
        
        // 5. Create yield tokens
        console.log("\n--- Creating yield/principal tokens ---");
        _createYieldTokens();
        
        // 6. Issue stablecoins
        console.log("\n--- Issuing MBS-backed stablecoins ---");
        _issueStablecoins();
        
        console.log("\n✓ COMPLETE WORKFLOW EXECUTED SUCCESSFULLY");
    }
    
    // Helper functions
    
    function _createMultipleMortgages() internal {
        vm.startPrank(LENDER1);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        MortgageNFT.MortgageDetails memory mortgage1 = MortgageNFT.MortgageDetails({
            originalBalance: 1_000_000e6,
            interestRateBPS: 550,
            termInMonths: 360,
            ltv: 70,
            dti: 30,
            fico: 780,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        mortgageTokenIds.push(mortgageRouter.fundMortgage(mortgage1));
        
        MortgageNFT.MortgageDetails memory mortgage2 = MortgageNFT.MortgageDetails({
            originalBalance: 500_000e6,
            interestRateBPS: 525,
            termInMonths: 360,
            ltv: 80,
            dti: 35,
            fico: 750,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        mortgageTokenIds.push(mortgageRouter.fundMortgage(mortgage2));
        
        vm.stopPrank();
        
        vm.startPrank(LENDER2);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        MortgageNFT.MortgageDetails memory mortgage3 = MortgageNFT.MortgageDetails({
            originalBalance: 750_000e6,
            interestRateBPS: 600,
            termInMonths: 180,
            ltv: 65,
            dti: 25,
            fico: 820,
            loanType: "SuperPrime",
            amortizationScheme: "FullyAmortizing"
        });
        mortgageTokenIds.push(mortgageRouter.fundMortgage(mortgage3));
        
        vm.stopPrank();
    }
    
    function _securitizeMortgages() internal {
        vm.startPrank(LENDER1);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[0]);
        mbsPool.securitize(mortgageTokenIds[1]);
        vm.stopPrank();
        
        vm.startPrank(LENDER2);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[2]);
        vm.stopPrank();
    }
    
    function _setupPaymentDistribution() internal {
        // Create mock pool keys for payment distribution
        PoolKey memory aaaPoolKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(mbsPool)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        // Add distribution pools for each mortgage
        for (uint i = 0; i < mortgageTokenIds.length; i++) {
            mortgageRouter.addDistributionPool(mortgageTokenIds[i], aaaPoolKey);
        }
    }
    
    function _processMonthlyPayments() internal {
        vm.startPrank(BORROWER);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        // Make payments for each mortgage
        uint256[] memory paymentAmounts = new uint256[](3);
        paymentAmounts[0] = 5_370e6;  // ~$5,370 for $1M mortgage
        paymentAmounts[1] = 2_685e6;  // ~$2,685 for $500k mortgage
        paymentAmounts[2] = 6_325e6;  // ~$6,325 for $750k mortgage (15-year)
        
        for (uint i = 0; i < mortgageTokenIds.length; i++) {
            mortgageRouter.makeMonthlyPayment(mortgageTokenIds[i], paymentAmounts[i]);
        }
        
        vm.stopPrank();
        
        console.log("  Processed 3 monthly payments totaling $", (paymentAmounts[0] + paymentAmounts[1] + paymentAmounts[2]) / 1e6);
    }
    
    function _createYieldTokens() internal {
        // Register AAA tranche for yield splitting
        yieldSplitter.registerMBS(
            mbsPool.AAA_TRANCHE_ID(),
            address(mbsPool),
            block.timestamp + 365 days * 30,
            450,
            12
        );
        
        // Transfer some AAA tokens to investor
        vm.prank(LENDER1);
        mbsPool.safeTransferFrom(
            LENDER1,
            INVESTOR1,
            mbsPool.AAA_TRANCHE_ID(),
            300_000e6,
            ""
        );
        
        // Split into PT/YT
        vm.startPrank(INVESTOR1);
        mbsPool.setApprovalForAll(address(yieldSplitter), true);
        yieldSplitter.splitMBS(mbsPool.AAA_TRANCHE_ID(), 300_000e6);
        vm.stopPrank();
        
        console.log("  Created PT/YT tokens for $300k AAA tranche");
    }
    
    function _issueStablecoins() internal {
        // Mint claims for investor
        poolManager.mint(INVESTOR2, mbsPool.AAA_TRANCHE_ID(), 500_000e6);
        
        vm.startPrank(INVESTOR2);
        poolManager.approve(address(stablecoinVault), mbsPool.AAA_TRANCHE_ID(), 500_000e6);
        stablecoinVault.lockClaimsAndMintStablecoin(mbsPool.AAA_TRANCHE_ID(), 250_000e6);
        vm.stopPrank();
        
        console.log("  Issued $250k dMBS-USD stablecoins");
    }
}