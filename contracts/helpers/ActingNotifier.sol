// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVoter} from "../interfaces/IVoter.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IMockGauge {
    function notifyRewardAmount(address token, uint256 amount) external;
}

contract ActingNotifier {
    address private operator;

    IVoter private VOTER;

    IERC20 private xRam;

    modifier onlyOperator() {
        require(msg.sender == operator, "!operator");
        _;
    }

    constructor(address _voter, address _xRam) {
        operator = msg.sender;
        VOTER = IVoter(_voter);
        xRam = IERC20(_xRam);
    }

    function notifyEmissions(address[] calldata pools, uint256[] calldata emissions) external onlyOperator {
        for (uint256 i; i < pools.length; ++i) {
            address pool = pools[i];
            address gauge = VOTER.gaugeForPool(pool);
            uint256 amount = emissions[i];
            xRam.approve(gauge, amount);
            IMockGauge(gauge).notifyRewardAmount(address(xRam), amount);
        }
    }

    function rescue(address token) external onlyOperator {
        IERC20(token).transfer(operator, IERC20(token).balanceOf(address(this)));
    }

    function setNewOperator(address _newOperator) external onlyOperator {
        operator = _newOperator;
    }
}
