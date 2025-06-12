// src/MortgageRouter.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {MortgageNFT} from "./MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MortgageRouter is IUnlockCallback, Ownable {
    using CurrencyLibrary for Currency;

    // --- State Variables ---
    IPoolManager public immutable poolManager;
    MortgageNFT public immutable mortgageNFT;
    MBSPrimeJumbo2024 public immutable mbsPool;
    Currency public immutable usdc;
    address public immutable intermediary; // The off-chain legal entity's wallet

    // --- Events ---
    event MortgageFunded(
        address indexed lender,
        uint256 indexed nftTokenId,
        uint256 amount
    );
    event PaymentMade(
        address indexed obligor,
        uint256 amount,
        address indexed pool,
        uint256 distributedAmount
    );

    // --- Structs for unlockCallback ---
    enum Action {
        MAKE_PAYMENT
    }
    struct CallbackData {
        Action action;
        address sender;
        uint256 amount;
        PoolKey key; // For payment distribution
    }

    constructor(
        address initialOwner,
        address _poolManager,
        address _mortgageNFTAddress,
        address _mbsPoolAddress,
        address _usdcAddress,
        address _intermediary
    ) Ownable(initialOwner) {
        poolManager = IPoolManager(_poolManager);
        mortgageNFT = MortgageNFT(_mortgageNFTAddress);
        mbsPool = MBSPrimeJumbo2024(_mbsPoolAddress);
        usdc = Currency.wrap(_usdcAddress);
        intermediary = _intermediary;
    }

    // --- External User-Facing Functions ---

    function fundMortgage(
        MortgageNFT.MortgageDetails calldata details
    ) external {
        usdc.transfer(intermediary, details.originalBalance);
        uint256 tokenId = mortgageNFT.mint(msg.sender, details);
        emit MortgageFunded(msg.sender, tokenId, details.originalBalance);
    }

    function securitizeMortgage(uint256 nftTokenId) external {
        mortgageNFT.approve(address(mbsPool), nftTokenId);
        mbsPool.securitize(nftTokenId);
    }

    function makeMonthlyPayment(
        PoolKey calldata key,
        uint256 paymentAmount
    ) external {
        CallbackData memory data = CallbackData({
            action: Action.MAKE_PAYMENT,
            sender: msg.sender,
            amount: paymentAmount,
            key: key
        });
        poolManager.unlock(abi.encode(data));
    }

    // --- V4 Unlock Callback Implementation ---

    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not PoolManager");
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.action == Action.MAKE_PAYMENT) {
            _handlePayment(data);
        }
        return "";
    }

    function _handlePayment(CallbackData memory data) internal {
        // 1. Settle the payment from the obligor to the PoolManager.
        // This creates a negative delta for the obligor, which is settled by their USDC transfer.
        poolManager.settle(usdc, data.sender, data.amount, false);

        // 2. Take the funds to this router contract to manage distribution.
        // This creates a positive delta for this contract.
        poolManager.take(usdc, address(this), data.amount, false);

        // 3. Deduct servicing fee for the intermediary.
        uint256 servicingFee = (data.amount * 25) / 10000; // 0.25%
        uint256 amountToDistribute = data.amount - servicingFee;

        if (servicingFee > 0) {
            usdc.transfer(intermediary, servicingFee);
        }

        // 4. Donate the remaining amount to the specified V4 pool.
        // This creates a negative delta for this contract, which is settled by the USDC taken in step 2.
        if (amountToDistribute > 0) {
            // Note: `donate` creates a negative delta, which is resolved by the `take` above.
            poolManager.donate(data.key, usdc, amountToDistribute);
            emit PaymentMade(
                data.sender,
                data.amount,
                poolIdToAddress(data.key.toId()),
                amountToDistribute
            );
        }
    }
}

// // src/MortgageRouter.sol
// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.30;

// import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
// import {MortgageNFT} from "./MortgageNFT.sol";
// import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// contract MortgageRouter is Ownable {
//     MortgageNFT public immutable mortgageNFT;
//     MBSPrimeJumbo2024 public immutable mbsPool;
//     IERC20Minimal public immutable usdc;
//     address public immutable intermediary; // The off-chain legal entity's wallet

//     event MortgageFunded(address indexed lender, uint256 nftTokenId, uint256 amount);
//     event PaymentMade(address indexed obligor, uint256 amount);

//     constructor(
//         address initialOwner,
//         address _mortgageNFTAddress,
//         address _mbsPoolAddress,
//         address _usdcAddress,
//         address _intermediary
//     ) Ownable(initialOwner) {
//         mortgageNFT = MortgageNFT(_mortgageNFTAddress);
//         mbsPool = MBSPrimeJumbo2024(_mbsPoolAddress);
//         usdc = IERC20Minimal(_usdcAddress);
//         intermediary = _intermediary;
//     }

//     function fundMortgage(
//         uint256 originalBalance,
//         uint256 interestRateBPS,
//         uint32 termInMonths,
//         // ... other details
//     ) external {
//         // 1. Take funds from lender
//         usdc.transferFrom(msg.sender, intermediary, originalBalance);

//         // 2. Oracle confirms off-chain purchase (mocked here by assuming success)
//         // ... oracle logic ...

//         // 3. Mint the Mortgage NFT to the lender
//         MortgageNFT.MortgageDetails memory details = MortgageNFT.MortgageDetails({
//             originalBalance: originalBalance,
//             interestRateBPS: interestRateBPS,
//             termInMonths: termInMonths,
//             ltv: 80, dti: 35, fico: 780, // Example data
//             loanType: "Prime",
//             amortizationScheme: "FullyAmortizing"
//         });
//         uint256 tokenId = mortgageNFT.mint(msg.sender, details);

//         emit MortgageFunded(msg.sender, tokenId, originalBalance);
//     }

//     function securitizeMortgage(uint256 nftTokenId) external {
//         // Approve the MBS pool to take the NFT
//         mortgageNFT.approve(address(mbsPool), nftTokenId);
//         // Call the securitization function
//         mbsPool.securitize(nftTokenId);
//     }

//     function makeMonthlyPayment(uint256 paymentAmount) external {
//         // 1. Take payment from obligor
//         usdc.transferFrom(msg.sender, address(this), paymentAmount);

//         // 2. Deduct servicing fee for the intermediary
//         uint256 servicingFee = (paymentAmount * 25) / 10000; // 0.25%
//         uint256 amountToDistribute = paymentAmount - servicingFee;

//         usdc.transfer(intermediary, servicingFee);

//         // 3. Approve and call the distribution function on the MBS Pool
//         usdc.approve(address(mbsPool), amountToDistribute);
//         mbsPool.distributePayments(amountToDistribute);

//         emit PaymentMade(msg.sender, paymentAmount);
//     }
// }
