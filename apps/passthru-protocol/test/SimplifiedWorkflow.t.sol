// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Simplified Mock for testing without full V4 dependencies
contract MockPoolManager {
    mapping(address => mapping(uint256 => uint256)) public balances;
    bytes public lastCalldata;
    
    function unlock(bytes calldata data) external returns (bytes memory) {
        lastCalldata = data;
        (bool success, bytes memory result) = msg.sender.call(
            abi.encodeWithSignature("unlockCallback(bytes)", data)
        );
        require(success, "Callback failed");
        return result;
    }
    
    function mint(address to, uint256 id, uint256 amount) external {
        balances[to][id] += amount;
    }
    
    function burn(address from, uint256 id, uint256 amount) external {
        require(balances[from][id] >= amount, "Insufficient balance");
        balances[from][id] -= amount;
    }
    
    function take(address, address, uint256) external {}
    function settle(address) external {}
    function donate(address, uint256, uint256, bytes calldata) external {}
    function sync(address) external {}
    
    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return balances[account][id];
    }
    
    function totalSupply(uint256) external pure returns (uint256) {
        return 1000000e6; // Mock total supply
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name;
    string public symbol;
    uint8 public decimals;
    
    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

// Simple versions of our contracts for testing
contract SimpleMortgageNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public getApproved;
    uint256 public nextTokenId;
    address public router;
    
    struct MortgageDetails {
        uint256 originalBalance;
        uint256 interestRateBPS;
        uint32 termInMonths;
        uint8 ltv;
        uint8 dti;
        uint16 fico;
        string loanType;
        string amortizationScheme;
    }
    
    mapping(uint256 => MortgageDetails) public mortgageDetails;
    
    modifier onlyRouter() {
        require(msg.sender == router, "Only router");
        _;
    }
    
    function setRouter(address _router) external {
        router = _router;
    }
    
    function mint(address to, MortgageDetails calldata details) external onlyRouter returns (uint256) {
        uint256 tokenId = nextTokenId++;
        ownerOf[tokenId] = to;
        mortgageDetails[tokenId] = details;
        return tokenId;
    }
    
    function approve(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "Not owner");
        getApproved[tokenId] = to;
    }
    
    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        require(getApproved[tokenId] == msg.sender || isApprovedForAll[from][msg.sender], "Not approved");
        ownerOf[tokenId] = to;
        getApproved[tokenId] = address(0);
    }
}

contract SimpleMBSPool {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    
    uint256 public constant AAA_TRANCHE_ID = 1;
    uint256 public constant BBB_TRANCHE_ID = 2;
    uint256 public constant NR_TRANCHE_ID = 3;
    
    address public mortgageNFT;
    address public poolManager;
    
    constructor(address _owner, address _poolManager) {
        poolManager = _poolManager;
    }
    
    function setMortgageNFT(address _mortgageNFT) external {
        mortgageNFT = _mortgageNFT;
    }
    
    function securitize(uint256 nftTokenId) external {
        // Transfer NFT to pool
        SimpleMortgageNFT(mortgageNFT).transferFrom(msg.sender, address(this), nftTokenId);
        
        // Get mortgage details
        (uint256 originalBalance,,,,,,,) = SimpleMortgageNFT(mortgageNFT).mortgageDetails(nftTokenId);
        
        // Mint tranches: 70% AAA, 20% BBB, 10% NR
        balanceOf[msg.sender][AAA_TRANCHE_ID] += (originalBalance * 70) / 100;
        balanceOf[msg.sender][BBB_TRANCHE_ID] += (originalBalance * 20) / 100;
        balanceOf[msg.sender][NR_TRANCHE_ID] += (originalBalance * 10) / 100;
    }
    
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
    
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(balanceOf[from][id] >= amount, "Insufficient balance");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "Not approved");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
    }
    
    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }
}

contract SimpleOracle {
    mapping(bytes32 => uint256) public prices;
    mapping(bytes32 => uint256) public confidences;
    mapping(bytes32 => uint256) public timestamps;
    mapping(address => bool) public isValidMBSToken;
    
    function whitelistMBSToken(address token) external {
        isValidMBSToken[token] = true;
    }
    
    function updatePrice(address mbsToken, uint256 trancheId, uint256 price, uint256 confidence) external {
        bytes32 key = keccak256(abi.encodePacked(mbsToken, trancheId));
        prices[key] = price;
        confidences[key] = confidence;
        timestamps[key] = block.timestamp;
    }
    
    function getPrice(address mbsToken, uint256 trancheId) external view returns (uint256, uint256, uint256) {
        bytes32 key = keccak256(abi.encodePacked(mbsToken, trancheId));
        return (prices[key], confidences[key], timestamps[key]);
    }
}

// Simple router that implements the core workflow
contract SimpleMortgageRouter {
    SimpleMortgageNFT public mortgageNFT;
    SimpleMBSPool public mbsPool;
    MockERC20 public usdc;
    address public intermediary;
    MockPoolManager public poolManager;
    
    mapping(uint256 => uint256) public mortgageBalances;
    
    struct PaymentData {
        uint256 nftTokenId;
        uint256 amount;
        address sender;
    }
    
    constructor(
        address _poolManager,
        address _mortgageNFT,
        address _mbsPool,
        address _usdc,
        address _intermediary
    ) {
        poolManager = MockPoolManager(_poolManager);
        mortgageNFT = SimpleMortgageNFT(_mortgageNFT);
        mbsPool = SimpleMBSPool(_mbsPool);
        usdc = MockERC20(_usdc);
        intermediary = _intermediary;
    }
    
    function fundMortgage(SimpleMortgageNFT.MortgageDetails calldata details) external returns (uint256) {
        // Transfer USDC from lender
        usdc.transferFrom(msg.sender, intermediary, details.originalBalance);
        
        // Mint mortgage NFT
        uint256 tokenId = mortgageNFT.mint(msg.sender, details);
        mortgageBalances[tokenId] = details.originalBalance;
        
        return tokenId;
    }
    
    function makeMonthlyPayment(uint256 nftTokenId, uint256 amount) external {
        PaymentData memory data = PaymentData({
            nftTokenId: nftTokenId,
            amount: amount,
            sender: msg.sender
        });
        
        poolManager.unlock(abi.encode(data));
    }
    
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        
        PaymentData memory paymentData = abi.decode(data, (PaymentData));
        
        // Transfer payment from borrower
        usdc.transferFrom(paymentData.sender, address(this), paymentData.amount);
        
        // Calculate servicing fee (0.25%)
        uint256 servicingFee = (paymentData.amount * 25) / 10000;
        uint256 distributionAmount = paymentData.amount - servicingFee;
        
        // Transfer servicing fee
        usdc.transfer(intermediary, servicingFee);
        
        // Update mortgage balance (simplified)
        if (mortgageBalances[paymentData.nftTokenId] >= distributionAmount) {
            mortgageBalances[paymentData.nftTokenId] -= distributionAmount;
        }
        
        return "";
    }
}

contract SimplifiedWorkflowTest is Test {
    // Test accounts
    address constant LENDER = address(0x100);
    address constant BORROWER = address(0x200);
    address constant INVESTOR = address(0x300);
    address constant INTERMEDIARY = address(0x1337);
    
    // Contracts
    MockPoolManager poolManager;
    MockERC20 usdc;
    SimpleMortgageNFT mortgageNFT;
    SimpleMBSPool mbsPool;
    SimpleOracle oracle;
    SimpleMortgageRouter mortgageRouter;
    
    // Test state
    uint256 mortgageTokenId;
    
    function setUp() public {
        // Deploy contracts
        poolManager = new MockPoolManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new SimpleOracle();
        
        mortgageNFT = new SimpleMortgageNFT();
        mbsPool = new SimpleMBSPool(address(this), address(poolManager));
        
        mortgageRouter = new SimpleMortgageRouter(
            address(poolManager),
            address(mortgageNFT),
            address(mbsPool),
            address(usdc),
            INTERMEDIARY
        );
        
        // Setup relationships
        mortgageNFT.setRouter(address(mortgageRouter));
        mbsPool.setMortgageNFT(address(mortgageNFT));
        oracle.whitelistMBSToken(address(mbsPool));
        
        // Fund test accounts
        usdc.mint(LENDER, 1_000_000e6);
        usdc.mint(BORROWER, 50_000e6);
        usdc.mint(INVESTOR, 500_000e6);
        
        console.log("=== SETUP COMPLETE ===");
        console.log("LENDER USDC balance:", usdc.balanceOf(LENDER));
        console.log("BORROWER USDC balance:", usdc.balanceOf(BORROWER));
    }
    
    function test_CompleteWorkflow() public {
        console.log("\n=== STARTING COMPLETE WORKFLOW TEST ===");
        
        // Phase 1: Mortgage Origination
        _testMortgageOrigination();
        
        // Phase 2: Securitization
        _testSecuritization();
        
        // Phase 3: Payment Processing
        _testPaymentProcessing();
        
        console.log("\n=== WORKFLOW TEST COMPLETE ===");
    }
    
    function _testMortgageOrigination() internal {
        console.log("\n--- PHASE 1: MORTGAGE ORIGINATION ---");
        
        vm.startPrank(LENDER);
        
        // Approve router to spend USDC
        usdc.approve(address(mortgageRouter), 500_000e6);
        
        // Create mortgage details
        SimpleMortgageNFT.MortgageDetails memory details = SimpleMortgageNFT.MortgageDetails({
            originalBalance: 500_000e6,
            interestRateBPS: 550,
            termInMonths: 360,
            ltv: 80,
            dti: 35,
            fico: 780,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        
        // Fund mortgage
        mortgageTokenId = mortgageRouter.fundMortgage(details);
        
        vm.stopPrank();
        
        // Verify results
        assertEq(mortgageNFT.ownerOf(mortgageTokenId), LENDER);
        assertEq(usdc.balanceOf(INTERMEDIARY), 500_000e6);
        
        console.log("SUCCESS: Mortgage originated successfully");
        console.log("  - NFT ID:", mortgageTokenId);
        console.log("  - Intermediary received:", usdc.balanceOf(INTERMEDIARY));
    }
    
    function _testSecuritization() internal {
        console.log("\n--- PHASE 2: SECURITIZATION ---");
        
        vm.startPrank(LENDER);
        
        // Approve MBS pool to take NFT
        mortgageNFT.approve(address(mbsPool), mortgageTokenId);
        
        // Securitize the mortgage
        mbsPool.securitize(mortgageTokenId);
        
        vm.stopPrank();
        
        // Verify securitization
        uint256 aaaBalance = mbsPool.balanceOf(LENDER, mbsPool.AAA_TRANCHE_ID());
        uint256 bbbBalance = mbsPool.balanceOf(LENDER, mbsPool.BBB_TRANCHE_ID());
        uint256 nrBalance = mbsPool.balanceOf(LENDER, mbsPool.NR_TRANCHE_ID());
        
        assertEq(aaaBalance, 350_000e6); // 70%
        assertEq(bbbBalance, 100_000e6); // 20%
        assertEq(nrBalance, 50_000e6);   // 10%
        assertEq(mortgageNFT.ownerOf(mortgageTokenId), address(mbsPool));
        
        console.log("SUCCESS: Mortgage securitized successfully");
        console.log("  - AAA Tranche:", aaaBalance);
        console.log("  - BBB Tranche:", bbbBalance);
        console.log("  - NR Tranche:", nrBalance);
    }
    
    function _testPaymentProcessing() internal {
        console.log("\n--- PHASE 3: PAYMENT PROCESSING ---");
        
        vm.startPrank(BORROWER);
        
        // Make monthly payment
        uint256 paymentAmount = 2_685e6; // ~$2,685 monthly payment
        usdc.approve(address(mortgageRouter), paymentAmount);
        
        uint256 balanceBefore = mortgageRouter.mortgageBalances(mortgageTokenId);
        
        mortgageRouter.makeMonthlyPayment(mortgageTokenId, paymentAmount);
        
        vm.stopPrank();
        
        // Verify payment processing
        uint256 expectedFee = (paymentAmount * 25) / 10000; // 0.25%
        uint256 distributionAmount = paymentAmount - expectedFee;
        
        assertEq(usdc.balanceOf(INTERMEDIARY), 500_000e6 + expectedFee);
        
        uint256 balanceAfter = mortgageRouter.mortgageBalances(mortgageTokenId);
        assertEq(balanceAfter, balanceBefore - distributionAmount);
        
        console.log("SUCCESS: Payment processed successfully");
        console.log("  - Payment amount:", paymentAmount);
        console.log("  - Servicing fee:", expectedFee);
        console.log("  - Distribution amount:", distributionAmount);
        console.log("  - Remaining balance:", balanceAfter);
    }
    
    function test_IndividualFunctions() public {
        console.log("\n=== TESTING INDIVIDUAL FUNCTIONS ===");
        
        // Test mortgage details storage
        _testMortgageDetails();
        
        // Test oracle functionality
        _testOracleOperations();
        
        // Test multiple payments
        _testMultiplePayments();
    }
    
    function _testMortgageDetails() internal {
        console.log("\n--- Testing Mortgage Details ---");
        
        vm.startPrank(LENDER);
        usdc.approve(address(mortgageRouter), 300_000e6);
        
        SimpleMortgageNFT.MortgageDetails memory details = SimpleMortgageNFT.MortgageDetails({
            originalBalance: 300_000e6,
            interestRateBPS: 475,
            termInMonths: 240,
            ltv: 75,
            dti: 28,
            fico: 820,
            loanType: "SuperPrime",
            amortizationScheme: "FullyAmortizing"
        });
        
        uint256 tokenId = mortgageRouter.fundMortgage(details);
        vm.stopPrank();
        
        // Verify details are stored correctly
        (uint256 balance, uint256 rate, uint32 term, uint8 ltv, uint8 dti, uint16 fico,,) = 
            mortgageNFT.mortgageDetails(tokenId);
        
        assertEq(balance, 300_000e6);
        assertEq(rate, 475);
        assertEq(term, 240);
        assertEq(ltv, 75);
        assertEq(dti, 28);
        assertEq(fico, 820);
        
        console.log("SUCCESS: Mortgage details stored correctly");
    }
    
    function _testOracleOperations() internal {
        console.log("\n--- Testing Oracle Operations ---");
        
        // Set oracle prices
        oracle.updatePrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID(), 0.98e18, 9000);
        oracle.updatePrice(address(mbsPool), mbsPool.BBB_TRANCHE_ID(), 0.85e18, 8000);
        oracle.updatePrice(address(mbsPool), mbsPool.NR_TRANCHE_ID(), 0.50e18, 6000);
        
        // Verify prices
        (uint256 aaaPrice, uint256 aaaConf,) = oracle.getPrice(address(mbsPool), mbsPool.AAA_TRANCHE_ID());
        (uint256 bbbPrice, uint256 bbbConf,) = oracle.getPrice(address(mbsPool), mbsPool.BBB_TRANCHE_ID());
        (uint256 nrPrice, uint256 nrConf,) = oracle.getPrice(address(mbsPool), mbsPool.NR_TRANCHE_ID());
        
        assertEq(aaaPrice, 0.98e18);
        assertEq(aaaConf, 9000);
        assertEq(bbbPrice, 0.85e18);
        assertEq(bbbConf, 8000);
        assertEq(nrPrice, 0.50e18);
        assertEq(nrConf, 6000);
        
        console.log("SUCCESS: Oracle prices set and retrieved correctly");
        console.log("  - AAA Price: 98 cents, Confidence: 90%");
        console.log("  - BBB Price: 85 cents, Confidence: 80%");
        console.log("  - NR Price: 50 cents, Confidence: 60%");
    }
    
    function _testMultiplePayments() internal {
        // First originate and securitize a mortgage
        _testMortgageOrigination();
        
        console.log("\n--- Testing Multiple Payments ---");
        
        uint256 initialBalance = mortgageRouter.mortgageBalances(mortgageTokenId);
        uint256 paymentAmount = 2_685e6;
        
        vm.startPrank(BORROWER);
        
        // Make 3 payments
        for (uint i = 0; i < 3; i++) {
            usdc.approve(address(mortgageRouter), paymentAmount);
            mortgageRouter.makeMonthlyPayment(mortgageTokenId, paymentAmount);
            
            console.log("Payment", i + 1, "processed");
        }
        
        vm.stopPrank();
        
        uint256 finalBalance = mortgageRouter.mortgageBalances(mortgageTokenId);
        uint256 totalPaid = initialBalance - finalBalance;
        uint256 expectedDistribution = 3 * (paymentAmount - (paymentAmount * 25) / 10000);
        
        assertEq(totalPaid, expectedDistribution);
        
        console.log("SUCCESS: Multiple payments processed correctly");
        console.log("  - Initial balance:", initialBalance);
        console.log("  - Final balance:", finalBalance);
        console.log("  - Total principal paid:", totalPaid);
    }
    
    function test_EdgeCases() public {
        console.log("\n=== TESTING EDGE CASES ===");
        
        // Test zero amount payment
        vm.startPrank(BORROWER);
        vm.expectRevert();
        mortgageRouter.makeMonthlyPayment(999, 0); // Non-existent mortgage
        vm.stopPrank();
        
        // Test insufficient approval
        vm.startPrank(LENDER);
        SimpleMortgageNFT.MortgageDetails memory details = SimpleMortgageNFT.MortgageDetails({
            originalBalance: 100_000e6,
            interestRateBPS: 400,
            termInMonths: 180,
            ltv: 70,
            dti: 25,
            fico: 750,
            loanType: "Prime",
            amortizationScheme: "FullyAmortizing"
        });
        
        // Should fail without approval
        vm.expectRevert();
        mortgageRouter.fundMortgage(details);
        
        vm.stopPrank();
        
        console.log("SUCCESS: Edge cases handled correctly");
    }
}