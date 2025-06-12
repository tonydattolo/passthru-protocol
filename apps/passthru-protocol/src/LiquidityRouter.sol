// src/LiquidityRouter.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/**
 * @title LiquidityRouter
 * @author Your Name
 * @notice A router for high-frequency traders to deposit underlying tokens into the
 * PoolManager in exchange for gas-efficient ERC-6909 claim tokens, and withdraw them.
 * This follows the official Uniswap V4 `unlockCallback` pattern.
 */
contract LiquidityRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;

    // Enum and struct to pass commands and data through the unlock mechanism
    enum Action {
        DEPOSIT,
        WITHDRAW
    }
    struct CallbackData {
        Action action;
        address user;
        Currency currency;
        uint256 amount;
    }

    /// @param _poolManager The address of the Uniswap V4 PoolManager
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Deposits an underlying token (ERC-20/1155) into the PoolManager and mints ERC-6909 claims to the user.
    /// @dev The user must have approved this router to spend their tokens beforehand.
    /// @param currency The currency object representing the token to deposit.
    /// @param amount The amount of the token to deposit.
    function deposit(Currency currency, uint256 amount) external {
        // We will take the tokens from the `msg.sender`
        if (CurrencyLibrary.isAddressZero(currency)) {
            require(msg.value == amount, "Incorrect ETH sent");
        } else {
            // This is a generic way to handle both ERC20 and ERC1155.
            // A production contract might have separate functions for clarity.
            // For now, we assume approval is handled by the user frontend.
            // Using a simple IERC20Minimal interface for the transferFrom call.
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        CallbackData memory data = CallbackData({
            action: Action.DEPOSIT,
            user: msg.sender,
            currency: currency,
            amount: amount
        });

        // The `unlock` call will trigger the `unlockCallback` function.
        poolManager.unlock(abi.encode(data));
    }

    /// @notice Burns a user's ERC-6909 claims and withdraws the underlying token from the PoolManager.
    /// @param currency The currency object representing the token to withdraw.
    /// @param amount The amount of the token to withdraw.
    function withdraw(Currency currency, uint256 amount) external {
        CallbackData memory data = CallbackData({
            action: Action.WITHDRAW,
            user: msg.sender,
            currency: currency,
            amount: amount
        });
        poolManager.unlock(abi.encode(data));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        require(
            msg.sender == address(poolManager),
            "Caller must be PoolManager"
        );
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.action == Action.DEPOSIT) {
            _handleDeposit(data);
        } else if (data.action == Action.WITHDRAW) {
            _handleWithdraw(data);
        }

        return ""; // Must return bytes
    }

    function _handleDeposit(CallbackData memory data) internal {
        // 1. Send the underlying tokens from this router to the PoolManager.
        // For ERC-20s, we first `sync` the balance this contract holds, then `settle`.
        if (!CurrencyLibrary.isAddressZero(data.currency)) {
            IERC20Minimal(Currency.unwrap(data.currency)).transfer(
                address(poolManager),
                data.amount
            );
            poolManager.sync(data.currency);
        }
        // `settle` will use msg.value for native ETH or the synced balance for ERC20s.
        poolManager.settle{
            value: CurrencyLibrary.isAddressZero(data.currency)
                ? data.amount
                : 0
        }();

        // This operation creates a negative delta for this router contract.
        // We now resolve it by minting claims for the user.

        // 2. Mint ERC-6909 claims to the original user.
        // This creates a positive delta for the user, crediting them with the claims.
        // The `id` for an ERC-6909 claim is the uint256 representation of the currency address.
        poolManager.mint(
            data.user,
            CurrencyLibrary.toId(data.currency),
            data.amount
        );
    }

    function _handleWithdraw(CallbackData memory data) internal {
        // 1. Burn the user's ERC-6909 claims.
        // This is initiated by the user, and the PoolManager enforces that they have sufficient balance.
        // This creates a negative delta for the user.
        poolManager.burn(
            data.user,
            CurrencyLibrary.toId(data.currency),
            data.amount
        );

        // 2. Give the user the underlying token from the PoolManager.
        // This creates a positive delta for the user, which is settled by the `take` call.
        poolManager.take(data.currency, data.user, data.amount);
    }

    // This contract needs to be able to receive ETH if it's wrapping/unwrapping it.
    receive() external payable {}
}
