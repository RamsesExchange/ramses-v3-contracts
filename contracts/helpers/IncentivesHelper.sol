// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGenericIncentives {
    function incentivize(address token, uint256 amount) external;
    function notifyRewardAmount(address token, uint256 amount) external;
    function notifyRewardAmountForPeriod(address token, uint256 amount, uint256 period) external;
}

contract IncentivesHelper is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    constructor(address _owner) Ownable(_owner) {}

    /// @dev submits vote bribes
    function incentivizeVoting(
        IGenericIncentives[] calldata distributors,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(distributors.length == tokens.length && distributors.length == amounts.length, "Invalid input lengths");
        uint256 i;
        for (; i < distributors.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 tokenAmount = amounts[i];
            address distributor = address(distributors[i]);
            token.safeTransferFrom(msg.sender, address(this), tokenAmount);
            token.forceApprove(distributor, tokenAmount);
            distributors[i].incentivize(address(token), tokenAmount);
            /// @dev wipe the approval
            token.forceApprove(distributor, 0);
        }
    }

    /// @dev submits liquidity rewards for legacy
    function notifyLiquidityRewardsLegacy(
        IGenericIncentives[] calldata distributors,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(distributors.length == tokens.length && distributors.length == amounts.length, "Invalid input lengths");
        uint256 i;
        for (; i < distributors.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 tokenAmount = amounts[i];
            address distributor = address(distributors[i]);
            token.safeTransferFrom(msg.sender, address(this), tokenAmount);
            token.forceApprove(distributor, tokenAmount);
            distributors[i].notifyRewardAmount(address(token), tokenAmount);
            /// @dev wipe the approval
            token.forceApprove(distributor, 0);
        }
    }

    /// @dev submits liquidity rewards for CL
    function notifyLiquidityRewardsCL(
        IGenericIncentives[] calldata distributors,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata periods
    ) external nonReentrant {
        require(
            distributors.length == tokens.length && distributors.length == amounts.length
                && distributors.length == periods.length,
            "Invalid input lengths"
        );
        uint256 i;
        uint256 currentPeriod = getPeriod();
        for (; i < distributors.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 tokenAmount = amounts[i];
            uint256 period = periods[i];
            address distributor = address(distributors[i]);
            token.safeTransferFrom(msg.sender, address(this), tokenAmount);
            token.forceApprove(distributor, tokenAmount);
            /// @dev check that the period is valid (cannot LP bribe past epochs through these functions)
            require(period >= currentPeriod, "Invalid period");
            /// @dev check for the current period first
            if (period == currentPeriod) {
                distributors[i].notifyRewardAmount(address(token), tokenAmount);
            }
            /// @dev if the period is for a future one, use the forPeriod variant
            else {
                distributors[i].notifyRewardAmountForPeriod(address(token), tokenAmount, period);
            }
            /// @dev wipe the approval
            token.forceApprove(distributor, 0);
        }
    }

    /// @notice general read function for grabbing the current period (epoch)
    function getPeriod() public view returns (uint256) {
        return (block.timestamp / 1 weeks);
    }

    /// @dev recover stuck tokens that are mistakenly sent here
    function sweep(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
