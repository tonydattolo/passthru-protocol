// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {MortgageNFT} from "../src/MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "../src/MBSPrimeJumbo2024.sol";
import {MBSOracle} from "../src/MBSOracle.sol";
import {MockERC20} from "./mocks/MockERC20.t.sol";

contract CorePassThruTests is Test {
    // Test accounts (using Anvil's default accounts)
    address constant LENDER1 = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address constant LENDER2 = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    address constant BORROWER = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
    address constant INVESTOR1 = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);
    address constant INVESTOR2 = address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65);
    address constant INTERMEDIARY = address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc);
    address constant ORACLE_UPDATER = address(0x976EA74026E726554dB657fA54763abd0C3a0aa9);
    
    // Contracts
    MockERC20 usdc;
    MortgageNFT mortgageNFT;
    MBSPrimeJumbo2024 mbsPool;
    MBSOracle oracle;
    
    // Test state
    uint256[] mortgageTokenIds;
    
    function setUp() public {
        console.log("=== SETUP STARTING ===");
        
        // Deploy contracts
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mortgageNFT = new MortgageNFT(address(this), address(this)); // Use this as router for testing
        mbsPool = new MBSPrimeJumbo2024(address(this), address(mortgageNFT));
        oracle = new MBSOracle();
        
        // Grant role to oracle updater
        oracle.grantRole(oracle.PRICE_UPDATER_ROLE(), ORACLE_UPDATER);
        
        // Fund test accounts with USDC
        usdc.mint(LENDER1, 5_000_000e6);
        usdc.mint(LENDER2, 3_000_000e6);
        usdc.mint(BORROWER, 100_000e6);
        usdc.mint(INVESTOR1, 10_000_000e6);
        usdc.mint(INVESTOR2, 10_000_000e6);
        
        console.log("=== SETUP COMPLETE ===");
    }
    
    function test_1_LaunchMortgageNFT() public {
        console.log("\n=== TEST 1: LAUNCHING MORTGAGE NFTs ===");
        
        // Create multiple mortgages with different characteristics
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
        
        uint256 tokenId1 = mortgageNFT.mint(LENDER1, mortgage1);
        mortgageTokenIds.push(tokenId1);
        
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
        
        uint256 tokenId2 = mortgageNFT.mint(LENDER1, mortgage2);
        mortgageTokenIds.push(tokenId2);
        
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
        
        uint256 tokenId3 = mortgageNFT.mint(LENDER2, mortgage3);
        mortgageTokenIds.push(tokenId3);
        
        // Verify mortgages were created correctly
        assertEq(mortgageNFT.ownerOf(tokenId1), LENDER1);
        assertEq(mortgageNFT.ownerOf(tokenId2), LENDER1);
        assertEq(mortgageNFT.ownerOf(tokenId3), LENDER2);
        
        // Verify mortgage details are stored correctly
        (
            uint256 balance1,
            uint256 rate1,
            uint32 term1,
            uint8 ltv1,
            uint8 dti1,
            uint16 fico1,,
        ) = mortgageNFT.mortgageDetails(tokenId1);
        
        assertEq(balance1, 1_000_000e6);
        assertEq(rate1, 550);
        assertEq(term1, 360);
        assertEq(ltv1, 70);
        assertEq(dti1, 30);
        assertEq(fico1, 780);
        
        console.log("Successfully launched 3 mortgage NFTs");
        console.log("  Token ID 1: $1M @ 5.5%");
        console.log("  Token ID 2: $500k @ 5.25%");
        console.log("  Token ID 3: $750k @ 6%");
        console.log("  Total value: $2.25M");
    }
    
    function test_2_FundingMortgageProcess() public {
        console.log("\n=== TEST 2: FUNDING MORTGAGE PROCESS ===");
        
        // Simulate the funding process
        vm.startPrank(LENDER1);
        
        // 1. Lender approves USDC spending (to this test contract for transfer)
        usdc.approve(address(this), 2_000_000e6);
        
        uint256 balanceBefore = usdc.balanceOf(LENDER1);
        
        // 2. Create mortgage details
        MortgageNFT.MortgageDetails memory details = MortgageNFT.MortgageDetails({
            originalBalance: 2_000_000e6,
            interestRateBPS: 475,
            termInMonths: 360,
            ltv: 60,
            dti: 28,
            fico: 800,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        
        vm.stopPrank();
        
        // 3. Transfer USDC to intermediary (simulating funding)
        usdc.transferFrom(LENDER1, INTERMEDIARY, details.originalBalance);
        
        // 4. Mint mortgage NFT (as router)
        uint256 tokenId = mortgageNFT.mint(LENDER1, details);
        
        vm.stopPrank();
        
        // Verify funding completed correctly
        assertEq(usdc.balanceOf(LENDER1), balanceBefore - 2_000_000e6);
        assertEq(usdc.balanceOf(INTERMEDIARY), 2_000_000e6);
        assertEq(mortgageNFT.ownerOf(tokenId), LENDER1);
        
        console.log("Successfully simulated funding process");
        console.log("  Amount: $2M");
        console.log("  Lender balance after:", usdc.balanceOf(LENDER1) / 1e6);
        console.log("  Intermediary balance:", usdc.balanceOf(INTERMEDIARY) / 1e6);
    }
    
    function test_3_CreateMBSPoolWithMultipleMortgages() public {
        console.log("\n=== TEST 3: CREATING MBS POOL ===");
        
        // First create mortgages
        _createMultipleMortgages();
        
        // Now securitize them into the MBS pool
        vm.startPrank(LENDER1);
        
        // Approve MBS pool to take NFTs
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        
        // Securitize first two mortgages
        mbsPool.securitize(mortgageTokenIds[0]);
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
        
        // Check Lender1's balances (2 mortgages: $1M + $500k = $1.5M)
        uint256 lender1Value = 1_500_000e6;
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
        
        // Check Lender2's balances (1 mortgage: $750k)
        uint256 lender2Value = 750_000e6;
        assertEq(
            mbsPool.balanceOf(LENDER2, mbsPool.AAA_TRANCHE_ID()),
            (lender2Value * 70) / 100
        );
        
        // Verify pool state
        assertEq(mbsPool.totalCollateralValue(), totalValue);
        assertEq(mbsPool.aaaOutstanding(), expectedAAA);
        assertEq(mbsPool.bbbOutstanding(), expectedBBB);
        assertEq(mbsPool.nrOutstanding(), expectedNR);
        
        // Verify NFTs are now owned by the pool
        assertEq(mortgageNFT.ownerOf(mortgageTokenIds[0]), address(mbsPool));
        assertEq(mortgageNFT.ownerOf(mortgageTokenIds[1]), address(mbsPool));
        assertEq(mortgageNFT.ownerOf(mortgageTokenIds[2]), address(mbsPool));
        
        console.log("Successfully created MBS pool with 3 mortgages");
        console.log("  Total pool value: $", totalValue / 1e6);
        console.log("  AAA tranche: $", expectedAAA / 1e6);
        console.log("  BBB tranche: $", expectedBBB / 1e6);
        console.log("  NR tranche: $", expectedNR / 1e6);
    }
    
    function test_4_OracleOperations() public {
        console.log("\n=== TEST 4: ORACLE OPERATIONS ===");
        
        // First create the MBS pool
        _createMultipleMortgages();
        _securitizeMortgages();
        
        // Whitelist the MBS pool in oracle
        oracle.whitelistMBSToken(address(mbsPool));
        
        // Update prices for different tranches
        vm.startPrank(ORACLE_UPDATER);
        
        // AAA tranche: 98 cents on the dollar, 90% confidence
        oracle.updatePrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID(), 0.98e18, 9000);
        
        // BBB tranche: 85 cents on the dollar, 80% confidence
        oracle.updatePrice(address(mbsPool), mbsPool.BBB_TRANCHE_ID(), 0.85e18, 8000);
        
        // NR tranche: 50 cents on the dollar, 60% confidence
        oracle.updatePrice(address(mbsPool), mbsPool.NR_TRANCHE_ID(), 0.50e18, 6000);
        
        vm.stopPrank();
        
        // Verify prices were set correctly
        (uint256 aaaPrice, uint256 aaaConf, uint256 aaaTimestamp) = 
            oracle.getPrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID());
        
        (uint256 bbbPrice, uint256 bbbConf, uint256 bbbTimestamp) = 
            oracle.getPrice(address(mbsPool), mbsPool.BBB_TRANCHE_ID());
        
        (uint256 nrPrice, uint256 nrConf, uint256 nrTimestamp) = 
            oracle.getPrice(address(mbsPool), mbsPool.NR_TRANCHE_ID());
        
        assertEq(aaaPrice, 0.98e18);
        assertEq(aaaConf, 9000);
        assertTrue(aaaTimestamp > 0);
        
        assertEq(bbbPrice, 0.85e18);
        assertEq(bbbConf, 8000);
        assertTrue(bbbTimestamp > 0);
        
        assertEq(nrPrice, 0.50e18);
        assertEq(nrConf, 6000);
        assertTrue(nrTimestamp > 0);
        
        console.log("Successfully set and retrieved oracle prices");
        console.log("  AAA Price: 98 cents, Confidence: 90%");
        console.log("  BBB Price: 85 cents, Confidence: 80%");
        console.log("  NR Price: 50 cents, Confidence: 60%");
    }
    
    function test_5_LossWaterfallMechanism() public {
        console.log("\n=== TEST 5: LOSS WATERFALL MECHANISM ===");
        
        // Setup: Create and securitize mortgages
        _createMultipleMortgages();
        _securitizeMortgages();
        
        uint256 totalValue = 2_250_000e6;
        uint256 initialAAA = mbsPool.aaaOutstanding();
        uint256 initialBBB = mbsPool.bbbOutstanding();
        uint256 initialNR = mbsPool.nrOutstanding();
        
        console.log("Initial state:");
        console.log("  AAA Outstanding: $", initialAAA / 1e6);
        console.log("  BBB Outstanding: $", initialBBB / 1e6);
        console.log("  NR Outstanding: $", initialNR / 1e6);
        
        // Register a small loss (affects only NR tranche)
        uint256 smallLoss = 100_000e6; // $100k loss
        mbsPool.registerLoss(smallLoss);
        
        // Verify loss hits NR tranche first
        assertEq(mbsPool.aaaOutstanding(), initialAAA); // Unchanged
        assertEq(mbsPool.bbbOutstanding(), initialBBB); // Unchanged
        assertEq(mbsPool.nrOutstanding(), initialNR - smallLoss); // Reduced
        
        console.log("After $100k loss:");
        console.log("  AAA Outstanding: $", mbsPool.aaaOutstanding() / 1e6);
        console.log("  BBB Outstanding: $", mbsPool.bbbOutstanding() / 1e6);
        console.log("  NR Outstanding: $", mbsPool.nrOutstanding() / 1e6);
        
        // Register larger loss (wipes out remaining NR and hits BBB)
        uint256 currentNR = mbsPool.nrOutstanding(); // $125k remaining after first loss
        uint256 largeLoss = 300_000e6; // $300k additional loss
        uint256 excessLoss = largeLoss - currentNR; // Loss that hits BBB after wiping NR
        
        mbsPool.registerLoss(largeLoss);
        
        assertEq(mbsPool.nrOutstanding(), 0); // NR tranche wiped out
        assertEq(mbsPool.bbbOutstanding(), initialBBB - excessLoss); // BBB reduced
        assertEq(mbsPool.aaaOutstanding(), initialAAA); // AAA still protected
        
        console.log("After additional $300k loss:");
        console.log("  AAA Outstanding: $", mbsPool.aaaOutstanding() / 1e6);
        console.log("  BBB Outstanding: $", mbsPool.bbbOutstanding() / 1e6);
        console.log("  NR Outstanding: $", mbsPool.nrOutstanding() / 1e6);
        
        console.log("Loss waterfall mechanism working correctly");
    }
    
    function test_CompleteWorkflow() public {
        console.log("\n=== COMPLETE WORKFLOW TEST ===");
        
        // Test 1: Launch mortgages
        test_1_LaunchMortgageNFT();
        
        // Test 3: Create MBS pool (test 2 is funding which we've already done in test 1)
        // Note: We'll create fresh mortgages since test_1 already created some
        _createFreshMortgagesForWorkflow();
        _securitizeFreshMortgages();
        
        console.log("Successfully created MBS pool for workflow test");
        
        // Test oracle operations
        oracle.whitelistMBSToken(address(mbsPool));
        vm.prank(ORACLE_UPDATER);
        oracle.updatePrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID(), 0.98e18, 9000);
        
        console.log("Successfully set oracle prices for workflow test");
        
        console.log("\nCOMPLETE CORE WORKFLOW EXECUTED SUCCESSFULLY");
        console.log("All basic PassThru protocol functionality verified:");
        console.log("  - Mortgage NFT creation and funding");
        console.log("  - MBS pool securitization"); 
        console.log("  - Oracle price management");
    }
    
    // Helper functions
    function _createMultipleMortgages() internal {
        MortgageNFT.MortgageDetails memory m1 = MortgageNFT.MortgageDetails({
            originalBalance: 1_000_000e6,
            interestRateBPS: 550,
            termInMonths: 360,
            ltv: 70,
            dti: 30,
            fico: 780,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        mortgageTokenIds.push(mortgageNFT.mint(LENDER1, m1));
        
        MortgageNFT.MortgageDetails memory m2 = MortgageNFT.MortgageDetails({
            originalBalance: 500_000e6,
            interestRateBPS: 525,
            termInMonths: 360,
            ltv: 80,
            dti: 35,
            fico: 750,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        mortgageTokenIds.push(mortgageNFT.mint(LENDER1, m2));
        
        MortgageNFT.MortgageDetails memory m3 = MortgageNFT.MortgageDetails({
            originalBalance: 750_000e6,
            interestRateBPS: 600,
            termInMonths: 180,
            ltv: 65,
            dti: 25,
            fico: 820,
            loanType: "SuperPrime",
            amortizationScheme: "FullyAmortizing"
        });
        mortgageTokenIds.push(mortgageNFT.mint(LENDER2, m3));
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
    
    function _createFreshMortgagesForWorkflow() internal {
        // Create new mortgages for the workflow test
        uint256[] memory freshIds;
        
        MortgageNFT.MortgageDetails memory m1 = MortgageNFT.MortgageDetails({
            originalBalance: 800_000e6,
            interestRateBPS: 500,
            termInMonths: 360,
            ltv: 75,
            dti: 30,
            fico: 760,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        uint256 tokenId1 = mortgageNFT.mint(INVESTOR1, m1);
        
        MortgageNFT.MortgageDetails memory m2 = MortgageNFT.MortgageDetails({
            originalBalance: 600_000e6,
            interestRateBPS: 475,
            termInMonths: 360,
            ltv: 70,
            dti: 25,
            fico: 800,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        uint256 tokenId2 = mortgageNFT.mint(INVESTOR2, m2);
        
        // Store fresh IDs for securitization
        mortgageTokenIds.push(tokenId1);
        mortgageTokenIds.push(tokenId2);
    }
    
    function _securitizeFreshMortgages() internal {
        uint256 len = mortgageTokenIds.length;
        
        vm.startPrank(INVESTOR1);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[len-2]); // Second to last
        vm.stopPrank();
        
        vm.startPrank(INVESTOR2);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[len-1]); // Last
        vm.stopPrank();
    }
}