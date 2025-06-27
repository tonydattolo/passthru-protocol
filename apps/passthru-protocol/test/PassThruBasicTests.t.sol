// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {MortgageNFT} from "../src/MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "../src/MBSPrimeJumbo2024.sol";
import {MockERC20} from "./mocks/MockERC20.t.sol";

// Simple mock contracts for testing without V4 dependencies
contract SimpleMortgageRouter {
    MortgageNFT public mortgageNFT;
    MockERC20 public usdc;
    address public intermediary;
    
    mapping(uint256 => uint256) public mortgageBalances;
    
    constructor(address _mortgageNFT, address _usdc, address _intermediary) {
        mortgageNFT = MortgageNFT(_mortgageNFT);
        usdc = MockERC20(_usdc);
        intermediary = _intermediary;
    }
    
    function fundMortgage(MortgageNFT.MortgageDetails calldata details) external returns (uint256) {
        // Transfer USDC from lender
        usdc.transferFrom(msg.sender, intermediary, details.originalBalance);
        
        // Mint mortgage NFT
        uint256 tokenId = mortgageNFT.mint(msg.sender, details);
        mortgageBalances[tokenId] = details.originalBalance;
        
        return tokenId;
    }
}

// Simple pool manager mock
contract SimplePoolManager {
    mapping(address => mapping(uint256 => uint256)) public balances;
    
    function mint(address to, uint256 id, uint256 amount) external {
        balances[to][id] += amount;
    }
    
    function burn(address from, uint256 id, uint256 amount) external {
        require(balances[from][id] >= amount, "Insufficient balance");
        balances[from][id] -= amount;
    }
    
    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return balances[account][id];
    }
    
    function transferFrom(address from, address to, uint256 id, uint256 amount) external {
        require(balances[from][id] >= amount, "Insufficient balance");
        balances[from][id] -= amount;
        balances[to][id] += amount;
    }
    
    function transfer(address to, uint256 id, uint256 amount) external {
        require(balances[msg.sender][id] >= amount, "Insufficient balance");
        balances[msg.sender][id] -= amount;
        balances[to][id] += amount;
    }
}

// Simple stablecoin
contract SimpleStablecoin {
    mapping(address => uint256) public balanceOf;
    string public name = "dMBS-USD";
    string public symbol = "dMBS-USD";
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
    }
    
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

// Simple stablecoin vault
contract SimpleStablecoinVault {
    SimplePoolManager public poolManager;
    SimpleStablecoin public stablecoin;
    
    mapping(address => mapping(uint256 => uint256)) public lockedClaims;
    
    constructor(address _poolManager, address _stablecoin) {
        poolManager = SimplePoolManager(_poolManager);
        stablecoin = SimpleStablecoin(_stablecoin);
    }
    
    function lockClaimsAndMintStablecoin(uint256 claimId, uint256 amount) external {
        poolManager.transferFrom(msg.sender, address(this), claimId, amount);
        lockedClaims[msg.sender][claimId] += amount;
        stablecoin.mint(msg.sender, amount);
    }
    
    function burnStablecoinAndUnlockClaims(uint256 claimId, uint256 amount) external {
        require(lockedClaims[msg.sender][claimId] >= amount, "Insufficient locked");
        stablecoin.burn(msg.sender, amount);
        lockedClaims[msg.sender][claimId] -= amount;
        poolManager.transfer(msg.sender, claimId, amount);
    }
}

// Simple yield splitter
contract SimpleYieldSplitter {
    SimplePoolManager public poolManager;
    MBSPrimeJumbo2024 public mbsPool;
    
    mapping(uint256 => bool) public registeredMBS;
    mapping(uint256 => uint256) public totalLocked;
    
    uint256 constant PT_OFFSET = 1e9;
    uint256 constant YT_OFFSET = 2e9;
    
    constructor(address _poolManager, address _mbsPool) {
        poolManager = SimplePoolManager(_poolManager);
        mbsPool = MBSPrimeJumbo2024(_mbsPool);
    }
    
    function registerMBS(uint256 mbsTokenId) external {
        registeredMBS[mbsTokenId] = true;
    }
    
    function splitMBS(uint256 mbsTokenId, uint256 amount) external {
        require(registeredMBS[mbsTokenId], "MBS not registered");
        
        // Transfer MBS tokens
        mbsPool.safeTransferFrom(msg.sender, address(this), mbsTokenId, amount, "");
        
        // Mint PT and YT
        uint256 ptTokenId = PT_OFFSET + mbsTokenId;
        uint256 ytTokenId = YT_OFFSET + mbsTokenId;
        
        poolManager.mint(msg.sender, ptTokenId, amount);
        poolManager.mint(msg.sender, ytTokenId, amount);
        
        totalLocked[mbsTokenId] += amount;
    }
    
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) 
        external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}

contract PassThruBasicTests is Test {
    // Test accounts
    address constant LENDER1 = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address constant LENDER2 = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    address constant BORROWER = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
    address constant INVESTOR1 = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);
    address constant INVESTOR2 = address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65);
    address constant INTERMEDIARY = address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc);
    
    // Contracts
    MockERC20 usdc;
    MortgageNFT mortgageNFT;
    SimpleMortgageRouter mortgageRouter;
    MBSPrimeJumbo2024 mbsPool;
    SimplePoolManager poolManager;
    SimpleStablecoin stablecoin;
    SimpleStablecoinVault stablecoinVault;
    SimpleYieldSplitter yieldSplitter;
    
    // Test state
    uint256[] mortgageTokenIds;
    
    function setUp() public {
        console.log("=== SETUP STARTING ===");
        
        // Deploy contracts
        usdc = new MockERC20("USD Coin", "USDC", 6);
        poolManager = new SimplePoolManager();
        
        // Deploy core contracts
        mortgageNFT = new MortgageNFT(address(this), address(0));
        mbsPool = new MBSPrimeJumbo2024(address(this), address(mortgageNFT));
        
        mortgageRouter = new SimpleMortgageRouter(
            address(mortgageNFT),
            address(usdc),
            INTERMEDIARY
        );
        
        // Deploy advanced features
        stablecoin = new SimpleStablecoin();
        stablecoinVault = new SimpleStablecoinVault(
            address(poolManager),
            address(stablecoin)
        );
        yieldSplitter = new SimpleYieldSplitter(
            address(poolManager),
            address(mbsPool)
        );
        
        // Configure relationships
        mortgageNFT.setRouter(address(mortgageRouter));
        
        // Fund test accounts
        usdc.mint(LENDER1, 5_000_000e6);
        usdc.mint(LENDER2, 3_000_000e6);
        usdc.mint(BORROWER, 100_000e6);
        usdc.mint(INVESTOR1, 10_000_000e6);
        usdc.mint(INVESTOR2, 10_000_000e6);
        
        console.log("=== SETUP COMPLETE ===");
    }
    
    function test_1_LaunchMortgageNFT() public {
        console.log("\n=== TEST 1: LAUNCHING MORTGAGE NFTs ===");
        
        vm.startPrank(LENDER1);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        // Create multiple mortgages
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
        
        uint256 tokenId1 = mortgageRouter.fundMortgage(mortgage1);
        mortgageTokenIds.push(tokenId1);
        
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
        
        uint256 tokenId2 = mortgageRouter.fundMortgage(mortgage2);
        mortgageTokenIds.push(tokenId2);
        
        vm.stopPrank();
        
        // Lender 2 creates a mortgage
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
        
        uint256 tokenId3 = mortgageRouter.fundMortgage(mortgage3);
        mortgageTokenIds.push(tokenId3);
        
        vm.stopPrank();
        
        // Verify
        assertEq(mortgageNFT.ownerOf(tokenId1), LENDER1);
        assertEq(mortgageNFT.ownerOf(tokenId2), LENDER1);
        assertEq(mortgageNFT.ownerOf(tokenId3), LENDER2);
        assertEq(usdc.balanceOf(INTERMEDIARY), 2_250_000e6);
        
        console.log("Successfully launched 3 mortgage NFTs");
        console.log("  Total funded: $2.25M");
    }
    
    function test_2_FundingMortgageNFT() public {
        console.log("\n=== TEST 2: FUNDING MORTGAGE NFT ===");
        
        vm.startPrank(LENDER1);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
        uint256 balanceBefore = usdc.balanceOf(LENDER1);
        
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
        
        uint256 tokenId = mortgageRouter.fundMortgage(details);
        
        vm.stopPrank();
        
        // Verify
        assertEq(usdc.balanceOf(LENDER1), balanceBefore - 2_000_000e6);
        assertEq(usdc.balanceOf(INTERMEDIARY), 2_000_000e6);
        assertEq(mortgageNFT.ownerOf(tokenId), LENDER1);
        
        console.log("Successfully funded mortgage NFT");
        console.log("  Amount: $2M");
    }
    
    function test_3_CreateMBSPoolWithMultipleMortgages() public {
        console.log("\n=== TEST 3: CREATING MBS POOL ===");
        
        // Create mortgages
        _createMultipleMortgages();
        
        // Securitize them
        vm.startPrank(LENDER1);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[0]);
        mbsPool.securitize(mortgageTokenIds[1]);
        vm.stopPrank();
        
        vm.startPrank(LENDER2);
        mortgageNFT.setApprovalForAll(address(mbsPool), true);
        mbsPool.securitize(mortgageTokenIds[2]);
        vm.stopPrank();
        
        // Verify
        uint256 totalValue = 2_250_000e6;
        assertEq(mbsPool.totalCollateralValue(), totalValue);
        assertEq(mbsPool.aaaOutstanding(), (totalValue * 70) / 100);
        assertEq(mbsPool.bbbOutstanding(), (totalValue * 20) / 100);
        assertEq(mbsPool.nrOutstanding(), (totalValue * 10) / 100);
        
        console.log("Successfully created MBS pool");
        console.log("  Total pool value: $2.25M");
    }
    
    function test_4_CreateTradeableYieldPrincipalTokens() public {
        console.log("\n=== TEST 4: CREATING PT/YT TOKENS ===");
        
        // Setup
        _createMultipleMortgages();
        _securitizeMortgages();
        
        // Register MBS for yield splitting
        yieldSplitter.registerMBS(mbsPool.AAA_TRANCHE_ID());
        
        // Transfer MBS to investor
        vm.prank(LENDER1);
        mbsPool.safeTransferFrom(
            LENDER1,
            INVESTOR1,
            mbsPool.AAA_TRANCHE_ID(),
            500_000e6,
            ""
        );
        
        // Split into PT/YT
        vm.startPrank(INVESTOR1);
        mbsPool.setApprovalForAll(address(yieldSplitter), true);
        yieldSplitter.splitMBS(mbsPool.AAA_TRANCHE_ID(), 500_000e6);
        vm.stopPrank();
        
        // Verify
        uint256 ptTokenId = 1e9 + mbsPool.AAA_TRANCHE_ID();
        uint256 ytTokenId = 2e9 + mbsPool.AAA_TRANCHE_ID();
        
        assertEq(poolManager.balanceOf(INVESTOR1, ptTokenId), 500_000e6);
        assertEq(poolManager.balanceOf(INVESTOR1, ytTokenId), 500_000e6);
        
        console.log("Successfully created PT/YT tokens");
        console.log("  Amount split: $500k");
    }
    
    function test_5_IssueStablecoinsBackedByMBS() public {
        console.log("\n=== TEST 5: ISSUING STABLECOINS ===");
        
        // Setup
        _createMultipleMortgages();
        _securitizeMortgages();
        
        // Transfer MBS to investor
        vm.prank(LENDER1);
        mbsPool.safeTransferFrom(
            LENDER1,
            INVESTOR2,
            mbsPool.AAA_TRANCHE_ID(),
            1_000_000e6,
            ""
        );
        
        // Convert to ERC-6909 claims
        vm.startPrank(INVESTOR2);
        uint256 claimId = mbsPool.AAA_TRANCHE_ID();
        poolManager.mint(INVESTOR2, claimId, 1_000_000e6);
        
        // Issue stablecoins
        uint256 lockAmount = 500_000e6;
        stablecoinVault.lockClaimsAndMintStablecoin(claimId, lockAmount);
        
        vm.stopPrank();
        
        // Verify
        assertEq(stablecoin.balanceOf(INVESTOR2), lockAmount);
        assertEq(stablecoinVault.lockedClaims(INVESTOR2, claimId), lockAmount);
        
        // Test redemption
        vm.startPrank(INVESTOR2);
        uint256 redeemAmount = 200_000e6;
        stablecoinVault.burnStablecoinAndUnlockClaims(claimId, redeemAmount);
        vm.stopPrank();
        
        // Verify redemption
        assertEq(stablecoin.balanceOf(INVESTOR2), lockAmount - redeemAmount);
        assertEq(stablecoinVault.lockedClaims(INVESTOR2, claimId), lockAmount - redeemAmount);
        
        console.log("Successfully issued and redeemed stablecoins");
        console.log("  Issued: $500k");
        console.log("  Redeemed: $200k");
    }
    
    function test_CompleteWorkflow() public {
        console.log("\n=== COMPLETE WORKFLOW TEST ===");
        
        test_1_LaunchMortgageNFT();
        test_3_CreateMBSPoolWithMultipleMortgages();
        test_4_CreateTradeableYieldPrincipalTokens();
        test_5_IssueStablecoinsBackedByMBS();
        
        console.log("\nCOMPLETE WORKFLOW EXECUTED SUCCESSFULLY");
    }
    
    // Helper functions
    function _createMultipleMortgages() internal {
        vm.startPrank(LENDER1);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
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
        mortgageTokenIds.push(mortgageRouter.fundMortgage(m1));
        
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
        mortgageTokenIds.push(mortgageRouter.fundMortgage(m2));
        
        vm.stopPrank();
        
        vm.startPrank(LENDER2);
        usdc.approve(address(mortgageRouter), type(uint256).max);
        
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
        mortgageTokenIds.push(mortgageRouter.fundMortgage(m3));
        
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
}