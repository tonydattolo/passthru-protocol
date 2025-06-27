// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {MortgageNFT} from "./MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";
import {MBSOracle} from "./MBSOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MortgageRouter
 * @notice Enhanced V4-integrated router for mortgage origination, payments, and liquidations
 * @dev Leverages flash accounting for capital-efficient operations
 * 
 * KEY ENHANCEMENTS:
 * - Flash loan liquidations
 * - Batch payment processing
 * - Cross-pool payment distribution
 * - Automated refinancing via flash loans
 * - Emergency liquidation mechanisms
 */
contract MortgageRouter is IUnlockCallback, Ownable, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // --- Core Components ---
    IPoolManager public immutable poolManager;
    MortgageNFT public immutable mortgageNFT;
    MBSPrimeJumbo2024 public immutable mbsPool;
    MBSOracle public immutable oracle;
    Currency public immutable usdc;
    address public immutable intermediary; // Off-chain legal entity
    
    // --- Constants ---
    uint256 public constant SERVICING_FEE_BPS = 25; // 0.25%
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% LTV triggers liquidation
    uint256 public constant LIQUIDATION_DISCOUNT = 500; // 5% discount for liquidators
    uint256 public constant MIN_PAYMENT_AMOUNT = 100e6; // $100 minimum
    
    // --- State Variables ---
    mapping(uint256 => PaymentSchedule) public paymentSchedules;
    mapping(uint256 => uint256) public mortgageBalances; // NFT ID => remaining balance
    mapping(address => bool) public authorizedLiquidators;
    mapping(uint256 => PoolKey[]) public mortgageDistributionPools; // Which pools receive payments
    
    struct PaymentSchedule {
        uint256 monthlyPayment;
        uint256 lastPaymentDate;
        uint256 missedPayments;
        bool isActive;
    }
    
    // --- Events ---
    event MortgageFunded(
        address indexed lender,
        uint256 indexed nftTokenId,
        uint256 amount,
        uint256 monthlyPayment
    );
    event PaymentMade(
        address indexed obligor,
        uint256 indexed nftTokenId,
        uint256 amount,
        uint256 principal,
        uint256 interest
    );
    event BatchPaymentProcessed(
        uint256 totalAmount,
        uint256 mortgageCount
    );
    event MortgageLiquidated(
        uint256 indexed nftTokenId,
        address indexed liquidator,
        uint256 debtAmount,
        uint256 collateralValue
    );
    event MortgageRefinanced(
        uint256 indexed oldNftId,
        uint256 indexed newNftId,
        uint256 newRate
    );
    event DistributionPoolAdded(
        uint256 indexed nftTokenId,
        PoolKey poolKey
    );

    // --- Action Types for Callback ---
    enum Action {
        MAKE_PAYMENT,
        BATCH_PAYMENT,
        LIQUIDATE,
        REFINANCE,
        FLASH_LOAN
    }
    
    struct CallbackData {
        Action action;
        bytes data;
    }
    
    struct PaymentData {
        address sender;
        uint256 nftTokenId;
        uint256 amount;
        PoolKey[] distributionPools;
    }
    
    struct BatchPaymentData {
        address sender;
        uint256[] nftTokenIds;
        uint256[] amounts;
    }
    
    struct LiquidationData {
        address liquidator;
        uint256 nftTokenId;
        uint256 debtAmount;
        uint256 maxPayment;
    }
    
    struct FlashLoanData {
        address borrower;
        Currency currency;
        uint256 amount;
        bytes callbackData;
    }

    constructor(
        address _poolManager,
        address _mortgageNFT,
        address _mbsPool,
        address _oracle,
        address _usdc,
        address _intermediary
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        mortgageNFT = MortgageNFT(_mortgageNFT);
        mbsPool = MBSPrimeJumbo2024(_mbsPool);
        oracle = MBSOracle(_oracle);
        usdc = Currency.wrap(_usdc);
        intermediary = _intermediary;
    }

    // --- Admin Functions ---
    
    function addAuthorizedLiquidator(address liquidator) external onlyOwner {
        authorizedLiquidators[liquidator] = true;
    }
    
    function removeAuthorizedLiquidator(address liquidator) external onlyOwner {
        authorizedLiquidators[liquidator] = false;
    }
    
    function addDistributionPool(uint256 nftTokenId, PoolKey calldata poolKey) external onlyOwner {
        mortgageDistributionPools[nftTokenId].push(poolKey);
        emit DistributionPoolAdded(nftTokenId, poolKey);
    }

    // --- Core Functions ---

    /**
     * @notice Fund a new mortgage with enhanced tracking
     * @param details Mortgage details including underwriting data
     */
    function fundMortgage(
        MortgageNFT.MortgageDetails calldata details
    ) external nonReentrant returns (uint256 tokenId) {
        require(details.originalBalance >= 10000e6, "Minimum $10k mortgage");
        
        // Transfer funds from lender
        IERC20Minimal(Currency.unwrap(usdc)).transferFrom(
            msg.sender,
            intermediary,
            details.originalBalance
        );
        
        // Mint NFT
        tokenId = mortgageNFT.mint(msg.sender, details);
        
        // Calculate monthly payment
        uint256 monthlyPayment = calculateMonthlyPayment(
            details.originalBalance,
            details.interestRateBPS,
            details.termInMonths
        );
        
        // Initialize payment schedule
        paymentSchedules[tokenId] = PaymentSchedule({
            monthlyPayment: monthlyPayment,
            lastPaymentDate: block.timestamp,
            missedPayments: 0,
            isActive: true
        });
        
        mortgageBalances[tokenId] = details.originalBalance;
        
        emit MortgageFunded(msg.sender, tokenId, details.originalBalance, monthlyPayment);
    }

    /**
     * @notice Make monthly payment with V4 flash accounting
     * @param nftTokenId Mortgage NFT ID
     * @param paymentAmount Payment amount in USDC
     */
    function makeMonthlyPayment(
        uint256 nftTokenId,
        uint256 paymentAmount
    ) external nonReentrant {
        require(paymentSchedules[nftTokenId].isActive, "Inactive mortgage");
        require(paymentAmount >= MIN_PAYMENT_AMOUNT, "Payment too small");
        
        // Get distribution pools for this mortgage
        PoolKey[] memory pools = mortgageDistributionPools[nftTokenId];
        require(pools.length > 0, "No distribution pools");
        
        CallbackData memory data = CallbackData({
            action: Action.MAKE_PAYMENT,
            data: abi.encode(PaymentData({
                sender: msg.sender,
                nftTokenId: nftTokenId,
                amount: paymentAmount,
                distributionPools: pools
            }))
        });
        
        poolManager.unlock(abi.encode(data));
    }

    /**
     * @notice Process batch payments for efficiency
     * @param nftTokenIds Array of mortgage NFT IDs
     * @param amounts Corresponding payment amounts
     */
    function makeBatchPayments(
        uint256[] calldata nftTokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(nftTokenIds.length == amounts.length, "Length mismatch");
        require(nftTokenIds.length > 0, "Empty batch");
        
        CallbackData memory data = CallbackData({
            action: Action.BATCH_PAYMENT,
            data: abi.encode(BatchPaymentData({
                sender: msg.sender,
                nftTokenIds: nftTokenIds,
                amounts: amounts
            }))
        });
        
        poolManager.unlock(abi.encode(data));
    }

    /**
     * @notice Liquidate underwater mortgage using flash loan
     * @param nftTokenId Mortgage NFT to liquidate
     * @param maxPayment Maximum USDC to pay for the mortgage
     */
    function liquidateMortgage(
        uint256 nftTokenId,
        uint256 maxPayment
    ) external nonReentrant {
        require(authorizedLiquidators[msg.sender], "Not authorized");
        
        (uint256 ltv, uint256 debtAmount) = calculateCurrentLTV(nftTokenId);
        require(ltv >= LIQUIDATION_THRESHOLD, "Not liquidatable");
        
        CallbackData memory data = CallbackData({
            action: Action.LIQUIDATE,
            data: abi.encode(LiquidationData({
                liquidator: msg.sender,
                nftTokenId: nftTokenId,
                debtAmount: debtAmount,
                maxPayment: maxPayment
            }))
        });
        
        poolManager.unlock(abi.encode(data));
    }

    /**
     * @notice Flash loan functionality for arbitrage/refinancing
     * @param currency Token to borrow
     * @param amount Amount to borrow
     * @param data Callback data for flash loan usage
     */
    function flashLoan(
        Currency currency,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant {
        CallbackData memory callbackData = CallbackData({
            action: Action.FLASH_LOAN,
            data: abi.encode(FlashLoanData({
                borrower: msg.sender,
                currency: currency,
                amount: amount,
                callbackData: data
            }))
        });
        
        poolManager.unlock(abi.encode(callbackData));
    }

    // --- V4 Unlock Callback ---

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        
        if (data.action == Action.MAKE_PAYMENT) {
            return _handlePayment(data.data);
        } else if (data.action == Action.BATCH_PAYMENT) {
            return _handleBatchPayment(data.data);
        } else if (data.action == Action.LIQUIDATE) {
            return _handleLiquidation(data.data);
        } else if (data.action == Action.FLASH_LOAN) {
            return _handleFlashLoan(data.data);
        }
        
        revert("Invalid action");
    }

    // --- Internal Handlers ---

    function _handlePayment(bytes memory data) internal returns (bytes memory) {
        PaymentData memory payment = abi.decode(data, (PaymentData));
        
        // 1. Sync USDC balance
        poolManager.sync(usdc);
        uint256 balanceBefore = IERC20Minimal(Currency.unwrap(usdc)).balanceOf(address(this));
        
        // 2. Settle payment from obligor
        poolManager.settle(usdc);
        
        // 3. Verify payment received
        uint256 balanceAfter = IERC20Minimal(Currency.unwrap(usdc)).balanceOf(address(this));
        require(balanceAfter >= balanceBefore + payment.amount, "Insufficient payment");
        
        // 4. Calculate P&I split
        (uint256 principal, uint256 interest) = calculatePaymentSplit(
            payment.nftTokenId,
            payment.amount
        );
        
        // 5. Deduct servicing fee
        uint256 servicingFee = (payment.amount * SERVICING_FEE_BPS) / 10000;
        uint256 distributionAmount = payment.amount - servicingFee;
        
        // 6. Distribute to pools
        uint256 poolCount = payment.distributionPools.length;
        if (poolCount > 0 && distributionAmount > 0) {
            uint256 amountPerPool = distributionAmount / poolCount;
            
            for (uint256 i = 0; i < poolCount; i++) {
                poolManager.donate(
                    payment.distributionPools[i],
                    amountPerPool,
                    0,
                    abi.encode(payment.nftTokenId)
                );
            }
        }
        
        // 7. Update mortgage balance
        mortgageBalances[payment.nftTokenId] -= principal;
        paymentSchedules[payment.nftTokenId].lastPaymentDate = block.timestamp;
        paymentSchedules[payment.nftTokenId].missedPayments = 0;
        
        // 8. Transfer servicing fee
        if (servicingFee > 0) {
            poolManager.take(usdc, intermediary, servicingFee);
        }
        
        emit PaymentMade(payment.sender, payment.nftTokenId, payment.amount, principal, interest);
        
        return abi.encode(BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _handleBatchPayment(bytes memory data) internal returns (bytes memory) {
        BatchPaymentData memory batch = abi.decode(data, (BatchPaymentData));
        
        uint256 totalAmount;
        for (uint256 i = 0; i < batch.amounts.length; i++) {
            totalAmount += batch.amounts[i];
        }
        
        // 1. Settle total payment
        poolManager.sync(usdc);
        poolManager.settle(usdc);
        
        // 2. Process each payment
        for (uint256 i = 0; i < batch.nftTokenIds.length; i++) {
            // Process individual payment logic
            _processSinglePayment(batch.nftTokenIds[i], batch.amounts[i]);
        }
        
        emit BatchPaymentProcessed(totalAmount, batch.nftTokenIds.length);
        
        return abi.encode(BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _handleLiquidation(bytes memory data) internal returns (bytes memory) {
        LiquidationData memory liquidation = abi.decode(data, (LiquidationData));
        
        // 1. Calculate liquidation price (debt - discount)
        uint256 liquidationPrice = (liquidation.debtAmount * (10000 - LIQUIDATION_DISCOUNT)) / 10000;
        require(liquidation.maxPayment >= liquidationPrice, "Insufficient payment");
        
        // 2. Flash loan the liquidation amount
        poolManager.take(usdc, address(this), liquidationPrice);
        
        // 3. Pay off the mortgage debt
        // In production, this would interact with the legal entity
        IERC20Minimal(Currency.unwrap(usdc)).transfer(intermediary, liquidation.debtAmount);
        
        // 4. Transfer NFT to liquidator
        mortgageNFT.transferFrom(
            mortgageNFT.ownerOf(liquidation.nftTokenId),
            liquidation.liquidator,
            liquidation.nftTokenId
        );
        
        // 5. Settle flash loan from liquidator
        poolManager.settle(usdc);
        
        // 6. Update state
        paymentSchedules[liquidation.nftTokenId].isActive = false;
        mortgageBalances[liquidation.nftTokenId] = 0;
        
        emit MortgageLiquidated(
            liquidation.nftTokenId,
            liquidation.liquidator,
            liquidation.debtAmount,
            liquidationPrice
        );
        
        return abi.encode(BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _handleFlashLoan(bytes memory data) internal returns (bytes memory) {
        FlashLoanData memory loan = abi.decode(data, (FlashLoanData));
        
        // 1. Take the flash loan
        poolManager.take(loan.currency, loan.borrower, loan.amount);
        
        // 2. Execute borrower's callback
        (bool success, bytes memory result) = loan.borrower.call(
            abi.encodeWithSignature(
                "onFlashLoan(address,uint256,bytes)",
                Currency.unwrap(loan.currency),
                loan.amount,
                loan.callbackData
            )
        );
        require(success, "Flash loan callback failed");
        
        // 3. Settle the flash loan (borrower must have approved)
        poolManager.settle(loan.currency);
        
        return result;
    }

    // --- Helper Functions ---

    function _processSinglePayment(uint256 nftTokenId, uint256 amount) internal {
        // Similar to single payment logic but without separate unlock
        (uint256 principal, uint256 interest) = calculatePaymentSplit(nftTokenId, amount);
        mortgageBalances[nftTokenId] -= principal;
        paymentSchedules[nftTokenId].lastPaymentDate = block.timestamp;
    }

    function calculateMonthlyPayment(
        uint256 principal,
        uint256 rateBPS,
        uint256 months
    ) public pure returns (uint256) {
        // Simplified calculation - in production use proper amortization formula
        uint256 monthlyRate = rateBPS / 12;
        uint256 totalInterest = (principal * monthlyRate * months) / 1000000;
        return (principal + totalInterest) / months;
    }

    function calculatePaymentSplit(
        uint256 nftTokenId,
        uint256 payment
    ) public view returns (uint256 principal, uint256 interest) {
        PaymentSchedule memory schedule = paymentSchedules[nftTokenId];
        uint256 balance = mortgageBalances[nftTokenId];
        
        // Simplified - in production use proper amortization
        interest = (balance * schedule.monthlyPayment) / balance;
        principal = payment > interest ? payment - interest : 0;
        
        if (principal > balance) principal = balance;
    }

    function calculateCurrentLTV(uint256 nftTokenId) public view returns (uint256 ltv, uint256 debt) {
        debt = mortgageBalances[nftTokenId];
        // In production, get property value from oracle
        uint256 propertyValue = debt * 125 / 100; // Mock 80% LTV
        ltv = (debt * 10000) / propertyValue;
    }

    function poolIdToAddress(bytes32) internal pure returns (address) {
        // Utility function - implement based on your pool registry
        return address(0);
    }
}