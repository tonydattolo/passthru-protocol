// src/MBSPrimeJumbo2024.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MortgageNFT} from "./MortgageNFT.sol";

/**
 * @title MBSPrimeJumbo2024
 * @notice The securitization pool. Accepts MortgageNFTs and mints tranched ERC-1155 tokens.
 * It also tracks the health of the collateral pool and allocates losses.
 */
contract MBSPrimeJumbo2024 is ERC1155, Ownable {
    uint256 public constant AAA_TRANCHE_ID = 0;
    uint256 public constant BBB_TRANCHE_ID = 1;
    uint256 public constant NR_TRANCHE_ID = 2; // Not-Rated / Equity

    MortgageNFT public immutable mortgageNFT;

    // Capital structure percentages
    uint256 public constant AAA_PERCENT = 70;
    uint256 public constant BBB_PERCENT = 20;
    uint256 public constant NR_PERCENT = 10;

    // State variables to track the value backing each tranche
    uint256 public totalCollateralValue;
    uint256 public aaaOutstanding;
    uint256 public bbbOutstanding;
    uint256 public nrOutstanding;

    event Securitized(
        address indexed investor,
        uint256 indexed nftTokenId,
        uint256 value
    );
    event LossRegistered(
        uint256 lossAmount,
        uint256 nrLoss,
        uint256 bbbLoss,
        uint256 aaaLoss
    );

    constructor(
        address initialOwner,
        address _mortgageNFTAddress
    )
        ERC1155("https://api.example.com/mbs-p24/{id}.json")
        Ownable(initialOwner)
    {
        mortgageNFT = MortgageNFT(_mortgageNFTAddress);
    }

    function securitize(uint256 nftTokenId) external {
        require(mortgageNFT.ownerOf(nftTokenId) == msg.sender, "Not NFT owner");
        mortgageNFT.transferFrom(msg.sender, address(this), nftTokenId);

        (uint256 originalBalance,,,,,,, ) = mortgageNFT.mortgageDetails(nftTokenId);
        uint256 value = originalBalance;

        uint256 aaaAmount = (value * AAA_PERCENT) / 100;
        uint256 bbbAmount = (value * BBB_PERCENT) / 100;
        uint256 nrAmount = value - aaaAmount - bbbAmount; // Avoid rounding errors

        totalCollateralValue += value;
        aaaOutstanding += aaaAmount;
        bbbOutstanding += bbbAmount;
        nrOutstanding += nrAmount;

        uint256[] memory ids = new uint256[](3);
        ids[0] = AAA_TRANCHE_ID;
        ids[1] = BBB_TRANCHE_ID;
        ids[2] = NR_TRANCHE_ID;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = aaaAmount;
        amounts[1] = bbbAmount;
        amounts[2] = nrAmount;

        _mintBatch(msg.sender, ids, amounts, "");
        emit Securitized(msg.sender, nftTokenId, value);
    }

    function registerLoss(uint256 lossAmount) external onlyOwner {
        // In prod, only from a trusted oracle/admin
        uint256 remainingLoss = lossAmount;
        uint256 nrLoss;
        uint256 bbbLoss;
        uint256 aaaLoss;

        if (remainingLoss > 0 && nrOutstanding > 0) {
            nrLoss = remainingLoss > nrOutstanding
                ? nrOutstanding
                : remainingLoss;
            nrOutstanding -= nrLoss;
            remainingLoss -= nrLoss;
        }
        if (remainingLoss > 0 && bbbOutstanding > 0) {
            bbbLoss = remainingLoss > bbbOutstanding
                ? bbbOutstanding
                : remainingLoss;
            bbbOutstanding -= bbbLoss;
            remainingLoss -= bbbLoss;
        }
        if (remainingLoss > 0 && aaaOutstanding > 0) {
            aaaLoss = remainingLoss > aaaOutstanding
                ? aaaOutstanding
                : remainingLoss;
            aaaOutstanding -= aaaLoss;
        }

        totalCollateralValue -= lossAmount;
        emit LossRegistered(lossAmount, nrLoss, bbbLoss, aaaLoss);
    }
}

