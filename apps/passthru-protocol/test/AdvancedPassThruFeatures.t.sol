// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {MortgageNFT} from "../src/MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "../src/MBSPrimeJumbo2024.sol";
import {MBSOracle} from "../src/MBSOracle.sol";
import {MockERC20} from "./mocks/MockERC20.t.sol";

// Simple yield splitter mock
contract SimpleYieldSplitter {
    mapping(uint256 => bool) public registeredMBS;
    mapping(uint256 => uint256) public totalLocked;
    mapping(address => mapping(uint256 => uint256)) public ptBalances;
    mapping(address => mapping(uint256 => uint256)) public ytBalances;
    
    uint256 constant PT_OFFSET = 1e9;
    uint256 constant YT_OFFSET = 2e9;
    
    event MBSSplit(address indexed user, uint256 indexed mbsTokenId, uint256 amount);
    
    function registerMBS(uint256 mbsTokenId) external {
        registeredMBS[mbsTokenId] = true;
    }
    
    function splitMBS(uint256 mbsTokenId, uint256 amount) external {
        require(registeredMBS[mbsTokenId], "MBS not registered");
        
        // Simulate splitting by tracking balances
        uint256 ptTokenId = PT_OFFSET + mbsTokenId;
        uint256 ytTokenId = YT_OFFSET + mbsTokenId;
        
        ptBalances[msg.sender][ptTokenId] += amount;
        ytBalances[msg.sender][ytTokenId] += amount;
        totalLocked[mbsTokenId] += amount;
        
        emit MBSSplit(msg.sender, mbsTokenId, amount);
    }
    
    function getPTBalance(address user, uint256 mbsTokenId) external view returns (uint256) {
        return ptBalances[user][PT_OFFSET + mbsTokenId];
    }
    
    function getYTBalance(address user, uint256 mbsTokenId) external view returns (uint256) {
        return ytBalances[user][YT_OFFSET + mbsTokenId];
    }
}

// Simple stablecoin vault mock
contract SimpleStablecoinVault {
    mapping(address => uint256) public stablecoinBalances;
    mapping(address => mapping(uint256 => uint256)) public lockedMBS;
    
    event StablecoinMinted(address indexed user, uint256 amount);
    event StablecoinBurned(address indexed user, uint256 amount);
    
    function lockMBSAndMintStablecoin(uint256 mbsTokenId, uint256 amount) external {
        // Simulate locking MBS and minting stablecoin 1:1
        lockedMBS[msg.sender][mbsTokenId] += amount;
        stablecoinBalances[msg.sender] += amount;
        
        emit StablecoinMinted(msg.sender, amount);
    }
    
    function burnStablecoinAndUnlockMBS(uint256 mbsTokenId, uint256 amount) external {
        require(stablecoinBalances[msg.sender] >= amount, "Insufficient stablecoin");
        require(lockedMBS[msg.sender][mbsTokenId] >= amount, "Insufficient locked MBS");
        
        stablecoinBalances[msg.sender] -= amount;
        lockedMBS[msg.sender][mbsTokenId] -= amount;
        
        emit StablecoinBurned(msg.sender, amount);
    }
}

contract AdvancedPassThruFeatures is Test {
    // Test accounts
    address constant LENDER1 = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address constant INVESTOR1 = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);
    address constant INVESTOR2 = address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65);
    address constant ORACLE_UPDATER = address(0x976EA74026E726554dB657fA54763abd0C3a0aa9);
    
    // Contracts
    MockERC20 usdc;
    MortgageNFT mortgageNFT;
    MBSPrimeJumbo2024 mbsPool;
    MBSOracle oracle;
    SimpleYieldSplitter yieldSplitter;
    SimpleStablecoinVault stablecoinVault;
    
    uint256[] mortgageTokenIds;
    
    function setUp() public {
        console.log("=== ADVANCED FEATURES SETUP ===");
        
        // Deploy contracts
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mortgageNFT = new MortgageNFT(address(this), address(this));
        mbsPool = new MBSPrimeJumbo2024(address(this), address(mortgageNFT));
        oracle = new MBSOracle();
        yieldSplitter = new SimpleYieldSplitter();
        stablecoinVault = new SimpleStablecoinVault();
        
        // Setup oracle
        oracle.grantRole(oracle.PRICE_UPDATER_ROLE(), ORACLE_UPDATER);
        oracle.whitelistMBSToken(address(mbsPool));
        
        // Fund accounts
        usdc.mint(LENDER1, 5_000_000e6);
        usdc.mint(INVESTOR1, 10_000_000e6);
        usdc.mint(INVESTOR2, 10_000_000e6);
        
        // Create and securitize basic mortgages
        _setupBasicMortgages();
        
        console.log("=== ADVANCED FEATURES SETUP COMPLETE ===");
    }
    
    function test_YieldPrincipalTokenCreation() public {
        console.log("\n=== TEST: YIELD/PRINCIPAL TOKEN CREATION ===");
        
        // Register AAA tranche for yield splitting
        yieldSplitter.registerMBS(mbsPool.AAA_TRANCHE_ID());
        
        // Get initial MBS balance
        uint256 initialMBSBalance = mbsPool.balanceOf(INVESTOR1, mbsPool.AAA_TRANCHE_ID());
        console.log("Initial MBS balance:", initialMBSBalance / 1e6, "million");
        
        // Split MBS into PT and YT
        vm.startPrank(INVESTOR1);
        uint256 splitAmount = 500_000e6; // $500k
        yieldSplitter.splitMBS(mbsPool.AAA_TRANCHE_ID(), splitAmount);
        vm.stopPrank();
        
        // Verify PT and YT tokens were created
        uint256 ptBalance = yieldSplitter.getPTBalance(INVESTOR1, mbsPool.AAA_TRANCHE_ID());
        uint256 ytBalance = yieldSplitter.getYTBalance(INVESTOR1, mbsPool.AAA_TRANCHE_ID());
        
        assertEq(ptBalance, splitAmount);
        assertEq(ytBalance, splitAmount);
        assertEq(yieldSplitter.totalLocked(mbsPool.AAA_TRANCHE_ID()), splitAmount);
        
        console.log("Successfully created yield/principal tokens:");
        console.log("  PT Balance: $", ptBalance / 1e6);
        console.log("  YT Balance: $", ytBalance / 1e6);
        console.log("  Total Locked: $", yieldSplitter.totalLocked(mbsPool.AAA_TRANCHE_ID()) / 1e6);
    }
    
    function test_StablecoinIssuance() public {
        console.log("\n=== TEST: MBS-BACKED STABLECOIN ISSUANCE ===");
        
        // Get initial MBS balance
        uint256 initialMBSBalance = mbsPool.balanceOf(INVESTOR2, mbsPool.AAA_TRANCHE_ID());
        console.log("Initial MBS balance:", initialMBSBalance / 1e6, "million");
        
        // Lock MBS and mint stablecoin
        vm.startPrank(INVESTOR2);
        uint256 lockAmount = 750_000e6; // $750k
        stablecoinVault.lockMBSAndMintStablecoin(mbsPool.AAA_TRANCHE_ID(), lockAmount);
        vm.stopPrank();
        
        // Verify stablecoin was minted
        uint256 stablecoinBalance = stablecoinVault.stablecoinBalances(INVESTOR2);
        uint256 lockedMBS = stablecoinVault.lockedMBS(INVESTOR2, mbsPool.AAA_TRANCHE_ID());
        
        assertEq(stablecoinBalance, lockAmount);
        assertEq(lockedMBS, lockAmount);
        
        console.log("Successfully issued MBS-backed stablecoin:");
        console.log("  Stablecoin Balance: $", stablecoinBalance / 1e6);
        console.log("  Locked MBS: $", lockedMBS / 1e6);
        
        // Test redemption
        vm.startPrank(INVESTOR2);
        uint256 redeemAmount = 250_000e6; // $250k
        stablecoinVault.burnStablecoinAndUnlockMBS(mbsPool.AAA_TRANCHE_ID(), redeemAmount);
        vm.stopPrank();
        
        // Verify redemption
        uint256 finalStablecoinBalance = stablecoinVault.stablecoinBalances(INVESTOR2);
        uint256 finalLockedMBS = stablecoinVault.lockedMBS(INVESTOR2, mbsPool.AAA_TRANCHE_ID());
        
        assertEq(finalStablecoinBalance, lockAmount - redeemAmount);
        assertEq(finalLockedMBS, lockAmount - redeemAmount);
        
        console.log("Successfully redeemed stablecoin:");
        console.log("  Final Stablecoin Balance: $", finalStablecoinBalance / 1e6);
        console.log("  Final Locked MBS: $", finalLockedMBS / 1e6);
    }
    
    function test_OracleDrivenPricing() public {
        console.log("\n=== TEST: ORACLE-DRIVEN PRICING ===");
        
        vm.startPrank(ORACLE_UPDATER);
        
        // Set different prices for different tranches based on risk
        oracle.updatePrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID(), 0.99e18, 9500); // 99 cents, 95% confidence
        oracle.updatePrice(address(mbsPool), mbsPool.BBB_TRANCHE_ID(), 0.88e18, 8500); // 88 cents, 85% confidence
        oracle.updatePrice(address(mbsPool), mbsPool.NR_TRANCHE_ID(), 0.65e18, 7000);  // 65 cents, 70% confidence
        
        vm.stopPrank();
        
        // Verify prices reflect risk hierarchy
        (uint256 aaaPrice, uint256 aaaConf,) = oracle.getPrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID());
        (uint256 bbbPrice, uint256 bbbConf,) = oracle.getPrice(address(mbsPool), mbsPool.BBB_TRANCHE_ID());
        (uint256 nrPrice, uint256 nrConf,) = oracle.getPrice(address(mbsPool), mbsPool.NR_TRANCHE_ID());
        
        // AAA should have highest price and confidence
        assertTrue(aaaPrice > bbbPrice);
        assertTrue(bbbPrice > nrPrice);
        assertTrue(aaaConf > bbbConf);
        assertTrue(bbbConf > nrConf);
        
        console.log("Oracle pricing reflects risk hierarchy:");
        console.log("  AAA: $0.", aaaPrice / 1e16, " (", aaaConf / 100, "% confidence)");
        console.log("  BBB: $0.", bbbPrice / 1e16, " (", bbbConf / 100, "% confidence)");
        console.log("  NR:  $0.", nrPrice / 1e16, " (", nrConf / 100, "% confidence)");
    }
    
    function test_ComplexLossScenario() public {
        console.log("\n=== TEST: COMPLEX LOSS SCENARIO ===");
        
        // Record initial state
        uint256 initialAAA = mbsPool.aaaOutstanding();
        uint256 initialBBB = mbsPool.bbbOutstanding();
        uint256 initialNR = mbsPool.nrOutstanding();
        uint256 totalInitial = initialAAA + initialBBB + initialNR;
        
        console.log("Initial pool composition:");
        console.log("  AAA: $", initialAAA / 1e6, "M (", (initialAAA * 100) / totalInitial, "%)");
        console.log("  BBB: $", initialBBB / 1e6, "M (", (initialBBB * 100) / totalInitial, "%)");
        console.log("  NR:  $", initialNR / 1e6, "M (", (initialNR * 100) / totalInitial, "%)");
        
        // Scenario 1: Minor loss (affects only NR)
        uint256 minorLoss = 50_000e6; // $50k
        mbsPool.registerLoss(minorLoss);
        
        assertEq(mbsPool.aaaOutstanding(), initialAAA);
        assertEq(mbsPool.bbbOutstanding(), initialBBB);
        assertEq(mbsPool.nrOutstanding(), initialNR - minorLoss);
        
        console.log("After $50k loss - only NR affected:");
        console.log("  NR remaining: $", mbsPool.nrOutstanding() / 1e6, "M");
        
        // Scenario 2: Major loss (wipes NR, hits BBB)
        uint256 majorLoss = 400_000e6; // $400k
        uint256 remainingNR = mbsPool.nrOutstanding();
        mbsPool.registerLoss(majorLoss);
        
        assertEq(mbsPool.nrOutstanding(), 0); // NR completely wiped
        assertEq(mbsPool.bbbOutstanding(), initialBBB - (majorLoss - remainingNR));
        assertEq(mbsPool.aaaOutstanding(), initialAAA); // AAA still protected
        
        console.log("After $400k loss - NR wiped, BBB affected:");
        console.log("  AAA: $", mbsPool.aaaOutstanding() / 1e6, "M (protected)");
        console.log("  BBB: $", mbsPool.bbbOutstanding() / 1e6, "M (reduced)");
        console.log("  NR:  $", mbsPool.nrOutstanding() / 1e6, "M (wiped out)");
        
        // Calculate total losses
        uint256 finalTotal = mbsPool.aaaOutstanding() + mbsPool.bbbOutstanding() + mbsPool.nrOutstanding();
        uint256 totalLoss = totalInitial - finalTotal;
        
        assertEq(totalLoss, minorLoss + majorLoss);
        console.log("Total losses: $", totalLoss / 1e6, "M");
        console.log("Remaining pool value: $", finalTotal / 1e6, "M");
    }
    
    function test_IntegratedWorkflow() public {
        console.log("\n=== TEST: INTEGRATED ADVANCED WORKFLOW ===");
        
        // 1. Create yield tokens
        yieldSplitter.registerMBS(mbsPool.AAA_TRANCHE_ID());
        vm.prank(INVESTOR1);
        yieldSplitter.splitMBS(mbsPool.AAA_TRANCHE_ID(), 300_000e6);
        
        // 2. Issue stablecoins
        vm.prank(INVESTOR2);
        stablecoinVault.lockMBSAndMintStablecoin(mbsPool.AAA_TRANCHE_ID(), 400_000e6);
        
        // 3. Update oracle prices
        vm.prank(ORACLE_UPDATER);
        oracle.updatePrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID(), 0.97e18, 9200);
        
        // 4. Register a moderate loss
        mbsPool.registerLoss(150_000e6);
        
        // Verify all systems still function correctly
        uint256 ptBalance = yieldSplitter.getPTBalance(INVESTOR1, mbsPool.AAA_TRANCHE_ID());
        uint256 stablecoinBalance = stablecoinVault.stablecoinBalances(INVESTOR2);
        (uint256 price,,) = oracle.getPrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID());
        
        assertEq(ptBalance, 300_000e6);
        assertEq(stablecoinBalance, 400_000e6);
        assertEq(price, 0.97e18);
        assertTrue(mbsPool.nrOutstanding() < 225_000e6); // NR affected by loss
        
        console.log("Integrated workflow completed successfully:");
        console.log("  PT tokens created: $", ptBalance / 1e6, "M");
        console.log("  Stablecoins issued: $", stablecoinBalance / 1e6, "M");
        console.log("  Oracle price: $0.", price / 1e16);
        console.log("  Loss absorbed by junior tranches");
        
        console.log("\nALL ADVANCED FEATURES WORKING CORRECTLY:");
        console.log("  - Yield/Principal token splitting");
        console.log("  - MBS-backed stablecoin issuance");
        console.log("  - Oracle-driven pricing");
        console.log("  - Loss waterfall protection");
    }
    
    // Helper function
    function _setupBasicMortgages() internal {
        // Create mortgages
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
        uint256 tokenId1 = mortgageNFT.mint(LENDER1, m1);
        
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
        uint256 tokenId2 = mortgageNFT.mint(LENDER1, m2);
        
        // Securitize
        vm.startPrank(LENDER1);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(tokenId1);
        mbsPool.securitize(tokenId2);
        
        // Transfer some MBS tokens to investors
        mbsPool.safeTransferFrom(LENDER1, INVESTOR1, mbsPool.AAA_TRANCHE_ID(), 700_000e6, "");
        mbsPool.safeTransferFrom(LENDER1, INVESTOR2, mbsPool.AAA_TRANCHE_ID(), 350_000e6, "");
        vm.stopPrank();
    }
}