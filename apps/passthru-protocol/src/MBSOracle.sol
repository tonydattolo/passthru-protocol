// src/MBSOracle.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MBSOracle
 * @author Your Name
 * @notice A simplified oracle for providing fair value prices for MBS tranches.
 * In a production environment, this would be replaced by a robust, decentralized
 * oracle network (e.g., Chainlink) that aggregates data on prepayments, defaults,
 * and interest rates.
 */
contract MBSOracle is Ownable {
    // Mapping from MBS token address to its fair value in USDC (with 18 decimals)
    mapping(address => uint256) public fairValues;

    event PriceUpdated(address indexed mbsToken, uint256 newPrice);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Updates the fair value of an MBS tranche.
     * @param mbsToken The address of the MBS ERC1155 contract.
     * @param trancheId The ID of the tranche (e.g., AAA, BBB).
     * @param newPrice The new price in USDC (1e18 scale).
     */
    function updatePrice(
        address mbsToken,
        uint256 trancheId,
        uint256 newPrice
    ) external onlyOwner {
        // A unique key for each tranche of a specific MBS pool
        address trancheKey = address(
            uint160(uint256(keccak256(abi.encodePacked(mbsToken, trancheId))))
        );
        fairValues[trancheKey] = newPrice;
        emit PriceUpdated(trancheKey, newPrice);
    }

    /**
     * @notice Gets the fair value of a specific MBS tranche.
     * @param mbsToken The address of the MBS ERC1155 contract.
     * @param trancheId The ID of the tranche.
     * @return The price in USDC (1e18 scale).
     */
    function getPrice(
        address mbsToken,
        uint256 trancheId
    ) external view returns (uint256) {
        address trancheKey = address(
            uint160(uint256(keccak256(abi.encodePacked(mbsToken, trancheId))))
        );
        uint256 price = fairValues[trancheKey];
        if (price == 0) {
            revert("Price not available for this tranche");
        }
        return price;
    }
}
