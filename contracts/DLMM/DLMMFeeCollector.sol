// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IFeeDistributor} from "contracts/interfaces/IFeeDistributor.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {IDLMMPool} from "./interfaces/IDLMMPool.sol";
import {IDLMMFeeCollector} from "./interfaces/IDLMMFeeCollector.sol";

contract DLMMFeeCollector is IDLMMFeeCollector {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS = 1_000_000;
    uint256 public treasuryFees;

    address public override treasury;
    address public voter;
    IAccessHub public accessHub;

    constructor(IAccessHub _accessHub) {
        accessHub = _accessHub;
        treasury = _accessHub.treasury();
        voter = address(_accessHub.voter());
    }

    modifier onlyAccessHub() {
        require(msg.sender == address(accessHub), Errors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    function setTreasury(address _treasury) external override onlyAccessHub {
        emit TreasuryChanged(treasury, _treasury);

        treasury = _treasury;
    }

    function setVoter(address _voter) external override onlyAccessHub {
        voter = _voter;
    }

    function setTreasuryFees(uint256 _treasuryFees) external override onlyAccessHub {
        require(_treasuryFees <= BASIS, Errors.FEE_TOO_LARGE());
        emit TreasuryFeesChanged(treasuryFees, _treasuryFees);

        treasuryFees = _treasuryFees;
    }

    function collectProtocolFees(address pool) external override {
        IDLMMPool dlmmPool = IDLMMPool(pool);
        IERC20 tokenX = dlmmPool.getTokenX();
        IERC20 tokenY = dlmmPool.getTokenY();

        (uint128 pendingX, uint128 pendingY) = dlmmPool.getProtocolFees();
        if (!(pendingX > 1 || pendingY > 1)) return;

        uint256 balanceXBefore = tokenX.balanceOf(address(this));
        uint256 balanceYBefore = tokenY.balanceOf(address(this));

        dlmmPool.collectProtocolFees();

        uint256 amountX = tokenX.balanceOf(address(this)) - balanceXBefore;
        uint256 amountY = tokenY.balanceOf(address(this)) - balanceYBefore;

        if (voter == address(0)) {
            _sendToTreasury(tokenX, tokenY, amountX, amountY);
            emit FeesCollected(pool, 0, 0, amountX, amountY);
            return;
        }

        IVoter _voter = IVoter(voter);
        address rewarder = _voter.gaugeForPool(pool);
        bool isAlive = _voter.isAlive(rewarder);

        if (rewarder == address(0) || !isAlive) {
            _sendToTreasury(tokenX, tokenY, amountX, amountY);
            emit FeesCollected(pool, 0, 0, amountX, amountY);
            return;
        }

        uint256 amountXTreasury;
        uint256 amountYTreasury;

        uint256 _treasuryFees = treasuryFees;
        if (_treasuryFees != 0) {
            amountXTreasury = (amountX * _treasuryFees) / BASIS;
            amountYTreasury = (amountY * _treasuryFees) / BASIS;

            amountX -= amountXTreasury;
            amountY -= amountYTreasury;

            _sendToTreasury(tokenX, tokenY, amountXTreasury, amountYTreasury);
        }

        IFeeDistributor feeDist = IFeeDistributor(_voter.feeDistributorForGauge(rewarder));

        if (amountX > 0) {
            tokenX.forceApprove(address(feeDist), amountX);
            feeDist.notifyRewardAmount(address(tokenX), amountX);
        }
        if (amountY > 0) {
            tokenY.forceApprove(address(feeDist), amountY);
            feeDist.notifyRewardAmount(address(tokenY), amountY);
        }

        emit FeesCollected(pool, amountX, amountY, amountXTreasury, amountYTreasury);
    }

    function _sendToTreasury(IERC20 tokenX, IERC20 tokenY, uint256 amountX, uint256 amountY) internal {
        address _treasury = treasury;

        if (amountX > 0) {
            tokenX.safeTransfer(_treasury, amountX);
        }
        if (amountY > 0) {
            tokenY.safeTransfer(_treasury, amountY);
        }
    }
}
