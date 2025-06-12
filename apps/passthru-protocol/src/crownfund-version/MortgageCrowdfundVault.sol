// src/MortgageCrowdfund.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";
import {MortgageRouter_Crowdfund} from "./MortgageRouter_Crowdfund.sol";
import {MortgageNFT} from "./MortgageNFT.sol";
import {LST} from "./LST.sol";

contract MortgageCrowdfund {
    enum Status {
        OPEN,
        FUNDED,
        FAILED,
        CANCELED
    }

    IERC20Minimal public immutable usdc;
    LST public immutable lst;
    MortgageRouter_Crowdfund public immutable mortgageRouter;

    uint256 public immutable fundingGoal;
    uint256 public immutable fundingDeadline;
    uint256 public immutable lstId;
    MortgageNFT.MortgageDetails public immutable mortgageDetails;

    uint256 public totalContributed;
    mapping(address => uint256) public contributions;
    Status public currentStatus;

    event Contributed(address indexed contributor, uint256 amount);
    event FundingExecuted(uint256 totalAmount);
    event FundingCanceled();
    event Refunded(address indexed contributor, uint256 amount);

    modifier onlyWhenOpen() {
        require(currentStatus == Status.OPEN, "Crowdfund not open");
        _;
    }

    constructor(
        address _usdc,
        address _lst,
        address _router,
        uint256 _goal,
        uint256 _deadline,
        uint256 _lstId,
        MortgageNFT.MortgageDetails memory _details
    ) {
        usdc = IERC20Minimal(_usdc);
        lst = LST(_lst);
        mortgageRouter = MortgageRouter_Crowdfund(_router);
        fundingGoal = _goal;
        fundingDeadline = _deadline;
        lstId = _lstId;
        mortgageDetails = _details;
        currentStatus = Status.OPEN;
    }

    function contribute(uint256 amount) external onlyWhenOpen {
        require(block.timestamp < fundingDeadline, "Funding deadline passed");
        require(
            totalContributed + amount <= fundingGoal,
            "Contribution exceeds goal"
        );

        totalContributed += amount;
        contributions[msg.sender] += amount;

        usdc.transferFrom(msg.sender, address(this), amount);
        lst.mint(msg.sender, lstId, amount, "");

        emit Contributed(msg.sender, amount);
    }

    function executeFunding() external onlyWhenOpen {
        require(totalContributed == fundingGoal, "Funding goal not yet met");
        currentStatus = Status.FUNDED;

        usdc.approve(address(mortgageRouter), fundingGoal);
        mortgageRouter.executeFundedMortgage(fundingGoal, mortgageDetails);

        emit FundingExecuted(fundingGoal);
    }

    function claimRefund() external {
        require(
            block.timestamp > fundingDeadline && totalContributed < fundingGoal,
            "Not in failed state"
        );
        currentStatus = Status.FAILED;

        uint256 amountToRefund = contributions[msg.sender];
        require(amountToRefund > 0, "No contribution to refund");

        contributions[msg.sender] = 0;
        usdc.transfer(msg.sender, amountToRefund);

        emit Refunded(msg.sender, amountToRefund);
    }

    function adminCancelAndRefund() external {
        // This function should be callable only by the MortgageRouter/platform owner
        require(
            msg.sender == address(mortgageRouter),
            "Only router can cancel"
        );
        require(currentStatus == Status.OPEN, "Not an open campaign");
        currentStatus = Status.CANCELED;

        emit FundingCanceled();
        // Note: This requires a pull pattern. Users must call `claimRefund` themselves.
        // A push pattern would be too gas-intensive and risky.
    }
}
