// src/MortgageRouter_SingleLender.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MortgageNFT} from "./MortgageNFT.sol";
import {MBSPrimeJumbo2024} from "./MBSPrimeJumbo2024.sol";

/**
 * @title MortgageRouter_SingleLender
 * @notice A router for the single-lender model. Handles funding, securitization, and payment distribution.
 */
contract MortgageRouter_SingleLender is IUnlockCallback, Ownable {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    MortgageNFT public immutable mortgageNFT;
    MBSPrimeJumbo2024 public immutable mbsPool;
    Currency public immutable usdc;
    address public immutable intermediary; // Off-chain legal entity's wallet

    event MortgageFunded(
        address indexed lender,
        uint256 indexed nftTokenId,
        uint256 amount
    );
    event PaymentMade(
        address indexed obligor,
        uint256 amount,
        bytes32 indexed poolId,
        uint256 distributedAmount
    );

    enum Action {
        MAKE_PAYMENT
    }
    struct CallbackData {
        Action action;
        address sender;
        uint256 amount;
        PoolKey key;
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

    /// @notice A single lender calls this to fully fund a mortgage opportunity.
    /// @dev This function is triggered via the platform's frontend after a loan is underwritten.
    function fundMortgage(
        MortgageNFT.MortgageDetails calldata details
    ) external {
        IERC20Minimal(Currency.unwrap(usdc)).transferFrom(
            msg.sender,
            intermediary,
            details.originalBalance
        );

        // In production, an oracle would confirm off-chain settlement before minting.
        // For this example, we assume immediate success.
        uint256 tokenId = mortgageNFT.mint(msg.sender, details);

        emit MortgageFunded(msg.sender, tokenId, details.originalBalance);
    }

    /// @notice An investor holding a MortgageNFT calls this to securitize it.
    function securitizeMortgage(uint256 nftTokenId) external {
        // This contract must be approved to spend the NFT on behalf of the user.
        mortgageNFT.approve(address(mbsPool), nftTokenId);
        mbsPool.securitize(nftTokenId);
    }

    /// @notice A homeowner calls this function to make their monthly mortgage payment.
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

    /// @inheritdoc IUnlockCallback
    function unlockCallback(
        bytes calldata rawData
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not PoolManager");
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.action == Action.MAKE_PAYMENT) {
            _handlePayment(data);
        }
        return "";
    }

    function _handlePayment(CallbackData memory data) internal {
        poolManager.settle(usdc, data.sender, data.amount);
        poolManager.take(usdc, address(this), data.amount, false);

        uint256 servicingFee = (data.amount * 25) / 10000; // 0.25%
        uint256 amountToDistribute = data.amount - servicingFee;

        if (servicingFee > 0) {
            usdc.transfer(intermediary, servicingFee);
        }

        if (amountToDistribute > 0) {
            // Donate to LPs of the appropriate V4 pool
            poolManager.donate(data.key, usdc, amountToDistribute);
            emit PaymentMade(
                data.sender,
                data.amount,
                data.key.toId(),
                amountToDistribute
            );
        }
    }
}
