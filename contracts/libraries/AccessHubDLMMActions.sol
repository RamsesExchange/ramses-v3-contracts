// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Errors} from "contracts/libraries/Errors.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";
import {IDLMMFeeCollector} from "contracts/DLMM/interfaces/IDLMMFeeCollector.sol";
import {IDLMMFactory} from "contracts/DLMM/interfaces/IDLMMFactory.sol";
import {IDLMMPool} from "contracts/DLMM/interfaces/IDLMMPool.sol";
import {IDLMMRewarderFactory} from "contracts/DLMM/interfaces/IDLMMRewarderFactory.sol";

library AccessHubDLMMActions {
    bytes32 internal constant LB_HOOKS_MANAGER_ROLE = keccak256("LB_HOOKS_MANAGER_ROLE");

    function acceptFactoryOwnership(IVoter voter) external {
        Ownable2Step(_factory(voter)).acceptOwnership();
    }

    function createPool(IVoter voter, address tokenX, address tokenY, uint24 activeId, uint16 binStep)
        external
        returns (address)
    {
        IDLMMFactory dlmmFactory = IDLMMFactory(_factory(voter));
        IERC20 tokenXERC20 = IERC20(tokenX);
        IERC20 tokenYERC20 = IERC20(tokenY);

        if (!dlmmFactory.isQuoteAsset(tokenYERC20)) dlmmFactory.addQuoteAsset(tokenYERC20);

        return address(dlmmFactory.createLBPair(tokenXERC20, tokenYERC20, activeId, binStep));
    }

    function setTreasury(IVoter voter, address newTreasury) external {
        _feeCollector(voter).setTreasury(newTreasury);
    }

    function setTreasuryFees(IVoter voter, uint256 treasuryFees) external {
        _feeCollector(voter).setTreasuryFees(treasuryFees);
    }

    function setVoter(IVoter voter, address newVoter) external {
        _feeCollector(voter).setVoter(newVoter);
    }

    function setFeeSplit(IVoter voter, address[] calldata pools, uint16[] calldata protocolShares) external {
        require(pools.length == protocolShares.length, Errors.LENGTH_MISMATCH());

        IDLMMFactory dlmmFactory = IDLMMFactory(_factory(voter));
        for (uint256 i; i < pools.length; ++i) {
            dlmmFactory.setPoolProtocolShare(pools[i], protocolShares[i]);
        }
    }

    function setSwapBaseFee(IVoter voter, address[] calldata pools, uint16[] calldata baseFactors) external {
        require(pools.length == baseFactors.length, Errors.LENGTH_MISMATCH());

        IDLMMFactory dlmmFactory = IDLMMFactory(_factory(voter));
        for (uint256 i; i < pools.length; ++i) {
            IDLMMPool pool = IDLMMPool(pools[i]);
            IERC20 tokenX = pool.getTokenX();
            IERC20 tokenY = pool.getTokenY();
            uint16 binStep = pool.getBinStep();
            (
                ,
                uint16 filterPeriod,
                uint16 decayPeriod,
                uint16 reductionFactor,
                uint24 variableFeeControl,
                uint16 protocolShare,
                uint24 maxVolatilityAccumulator
            ) = pool.getStaticFeeParameters();

            dlmmFactory.setFeesParametersOnPair(
                tokenX,
                tokenY,
                binStep,
                baseFactors[i],
                filterPeriod,
                decayPeriod,
                reductionFactor,
                variableFeeControl,
                protocolShare,
                maxVolatilityAccumulator
            );
        }
    }

    function setGlobalFeeSplit(IVoter voter, uint16 binStep, uint16 protocolShare) external {
        IDLMMFactory(_factory(voter)).setPresetProtocolShare(binStep, protocolShare);
    }

    function setRewarderFactoryImplementation(IVoter voter, address newImplementation) external {
        IDLMMRewarderFactory(voter.dlmmRewarderFactory()).setImplementation(newImplementation);
    }

    function setHooksManager(IVoter voter, address manager, bool enabled) external {
        if (enabled) {
            IAccessControl(_factory(voter)).grantRole(LB_HOOKS_MANAGER_ROLE, manager);
        } else {
            IAccessControl(_factory(voter)).revokeRole(LB_HOOKS_MANAGER_ROLE, manager);
        }
    }

    function collectFees(IVoter voter, address pool) external {
        address dlmmFactory = voter.dlmmFactory();
        if (dlmmFactory == address(0)) return;

        address dlmmFeeCollector = IDLMMFactory(dlmmFactory).feeCollector();
        if (dlmmFeeCollector != address(0)) IDLMMFeeCollector(dlmmFeeCollector).collectProtocolFees(pool);
    }

    function _factory(IVoter voter) private view returns (address dlmmFactory) {
        dlmmFactory = voter.dlmmFactory();
        require(dlmmFactory != address(0), Errors.NOT_INIT());
    }

    function _feeCollector(IVoter voter) private view returns (IDLMMFeeCollector) {
        address dlmmFeeCollector = IDLMMFactory(_factory(voter)).feeCollector();
        require(dlmmFeeCollector != address(0), Errors.NOT_INIT());

        return IDLMMFeeCollector(dlmmFeeCollector);
    }
}
