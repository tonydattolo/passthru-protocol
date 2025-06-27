// src/MBSStablecoinVault.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title dMBS_USD Stablecoin
 * @notice An ERC20 stablecoin backed by locked ERC-6909 claims on MBS tokens.
 */
contract dMBS_USD is ERC20, Ownable {
    constructor(
        address initialOwner
    ) ERC20("dMBS Backed Dollar", "dMBS-USD") Ownable(initialOwner) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

/**
 * @title MBSStablecoinVault
 * @notice Allows users to lock ERC-6909 claims on MBS tokens to mint dMBS-USD stablecoins.
 */
contract MBSStablecoinVault is Ownable {
    IPoolManager public immutable poolManager;
    dMBS_USD public immutable stablecoin;

    // Mapping: user => claimId => amount locked
    mapping(address => mapping(uint256 => uint256)) public lockedClaims;

    constructor(
        address initialOwner,
        address _poolManager,
        address _stablecoin
    ) Ownable(initialOwner) {
        poolManager = IPoolManager(_poolManager);
        stablecoin = dMBS_USD(_stablecoin);
    }

    /// @notice Lock ERC-6909 claims and mint an equivalent amount of dMBS-USD
    function lockClaimsAndMintStablecoin(
        uint256 claimId,
        uint256 amount
    ) external {
        // 1. Verify user has sufficient ERC-6909 claims in the PoolManager
        uint256 userClaimBalance = poolManager.balanceOf(msg.sender, claimId);
        require(userClaimBalance >= amount, "Insufficient claim balance");

        // 2. "Lock" the claims by transferring them from the user to this vault contract
        // This is a virtual transfer within the PoolManager's ERC-6909 ledger.
        poolManager.transferFrom(msg.sender, address(this), claimId, amount);

        // 3. Record the lock
        lockedClaims[msg.sender][claimId] += amount;

        // 4. Mint the stablecoin to the user
        stablecoin.mint(msg.sender, amount);
    }

    /// @notice Burn dMBS-USD stablecoins to unlock the corresponding ERC-6909 claims
    function burnStablecoinAndUnlockClaims(
        uint256 claimId,
        uint256 amount
    ) external {
        // 1. Verify user has enough locked claims to unlock
        require(
            lockedClaims[msg.sender][claimId] >= amount,
            "Amount exceeds locked claims"
        );

        // 2. Burn the user's stablecoins
        stablecoin.burn(msg.sender, amount);

        // 3. Update the lock record
        lockedClaims[msg.sender][claimId] -= amount;

        // 4. Transfer the ERC-6909 claims from this vault back to the user
        poolManager.transfer(msg.sender, claimId, amount);
    }
}
