// src/LST.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LoanShareToken (LST)
 * @notice An ERC1155 token where each tokenId represents a fractional share
 * of a specific, crowdfunded mortgage.
 */
contract LST is ERC1155, Ownable {
    mapping(uint256 => address) public minters;

    constructor(address initialOwner) ERC1155("") Ownable(initialOwner) {}

    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }

    function addMinter(
        uint256 lstId,
        address crowdfundContract
    ) external onlyOwner {
        minters[lstId] = crowdfundContract;
    }

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public {
        require(
            minters[id] == msg.sender,
            "LST: Caller is not the authorized minter for this ID"
        );
        _mint(to, id, amount, data);
    }
}
