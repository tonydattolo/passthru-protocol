// src/MortgageNFT.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MortgageNFT is ERC721, Ownable {
    uint256 private _nextTokenId;

    // Struct to hold all underwriting data for a mortgage
    struct MortgageDetails {
        uint256 originalBalance; // In USDC (1e6)
        uint256 interestRateBPS; // e.g., 550 for 5.50%
        uint32 termInMonths;
        uint8 ltv; // Loan-to-Value, e.g., 80 for 80%
        uint8 dti; // Debt-to-Income, e.g., 36 for 36%
        uint16 fico;
        string loanType; // "Prime", "Alt-A", "Subprime"
        string amortizationScheme; // "FullyAmortizing", "InterestOnly"
    }

    mapping(uint256 => MortgageDetails) public mortgageDetails;

    // Only a trusted router contract can mint new mortgage NFTs
    address public mortgageRouter;

    event MortgageOriginated(
        uint256 indexed tokenId,
        address indexed lender,
        uint256 balance
    );

    modifier onlyRouter() {
        require(
            msg.sender == mortgageRouter,
            "Caller is not the mortgage router"
        );
        _;
    }

    constructor(
        address initialOwner,
        address _router
    ) ERC721("Decentralized Mortgage Note", "dMORT") Ownable(initialOwner) {
        mortgageRouter = _router;
    }

    function setRouter(address _newRouter) external onlyOwner {
        mortgageRouter = _newRouter;
    }

    function mint(
        address lender,
        MortgageDetails calldata details
    ) external onlyRouter returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(lender, tokenId);
        mortgageDetails[tokenId] = details;
        emit MortgageOriginated(tokenId, lender, details.originalBalance);
        return tokenId;
    }
}
