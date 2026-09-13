// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDLMMRewarder {
    function getRewardToken() external view returns (address);

    function getRemainingRewards() external view returns (uint256);

    function getLastModified(address user, uint256 id) external view returns (uint32);

    function setRewardPerSecond(uint256 maxRewardPerSecond, uint256 expectedDuration)
        external
        returns (uint256 rewardPerSecond);

    function setDeltaBins(int24 deltaBinA, int24 deltaBinB) external;

    function sweep(IERC20 token, address to) external;
}
