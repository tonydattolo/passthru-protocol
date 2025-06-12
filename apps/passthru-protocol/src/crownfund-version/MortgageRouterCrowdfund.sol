// src/MortgageRouter_Crowdfund.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";
import {MortgageNFT} from "./MortgageNFT.sol";
import {MortgageCrowdfund} from "./MortgageCrowdfund.sol";
import {LST} from "./LST.sol";

// This router would also contain the payment distribution logic as in the single-lender model
contract MortgageRouter_Crowdfund is Ownable {
    MortgageNFT public immutable mortgageNFT;
    LST public immutable lst;
    IERC20Minimal public immutable usdc;
    address public immutable intermediary;

    address[] public activeCrowdfunds;

    constructor(
        address initialOwner,
        address _mortgageNFTAddress,
        address _lstAddress,
        address _usdcAddress,
        address _intermediary
    ) Ownable(initialOwner) {
        mortgageNFT = MortgageNFT(_mortgageNFTAddress);
        lst = LST(_lstAddress);
        usdc = IERC20Minimal(_usdcAddress);
        intermediary = _intermediary;
    }

    function listMortgageForFunding(
        MortgageNFT.MortgageDetails calldata details,
        uint256 fundingDuration
    ) external onlyOwner returns (address crowdfundAddress) {
        uint256 lstId = uint256(
            keccak256(
                abi.encodePacked(details.originalBalance, block.timestamp)
            )
        );
        uint256 deadline = block.timestamp + fundingDuration;

        MortgageCrowdfund newCrowdfund = new MortgageCrowdfund(
            address(usdc),
            address(lst),
            address(this),
            details.originalBalance,
            deadline,
            lstId,
            details
        );

        lst.addMinter(lstId, address(newCrowdfund));
        activeCrowdfunds.push(address(newCrowdfund));
        return address(newCrowdfund);
    }

    function executeFundedMortgage(
        uint256 totalAmount,
        MortgageNFT.MortgageDetails calldata details
    ) external {
        // Verify caller is a legitimate crowdfund contract created by this router
        // A more robust check would involve a registry of deployed crowdfunds.
        bool isValidCaller = false;
        for (uint i = 0; i < activeCrowdfunds.length; i++) {
            if (activeCrowdfunds[i] == msg.sender) {
                isValidCaller = true;
                break;
            }
        }
        require(
            isValidCaller,
            "Caller is not an authorized crowdfund contract"
        );

        usdc.transferFrom(msg.sender, intermediary, totalAmount);

        // ... oracle confirmation ...

        // Mint NFT to be owned by this router/a dedicated vault contract
        mortgageNFT.mint(address(this), details);
    }

    // Add adminCancel function here to trigger refund state in a crowdfund contract
    function adminCancelCampaign(address crowdfundAddress) external onlyOwner {
        MortgageCrowdfund(crowdfundAddress).adminCancelAndRefund();
    }
}
