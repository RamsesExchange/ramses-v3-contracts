// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {VoterStorage} from "contracts/libraries/VoterStorage.sol";
import {Errors} from "contracts/libraries/Errors.sol";

import {IFeeDistributorFactory} from "contracts/interfaces/IFeeDistributorFactory.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";
import {IDLMMFeeCollector} from "contracts/DLMM/interfaces/IDLMMFeeCollector.sol";
import {IDLMMPool} from "contracts/DLMM/interfaces/IDLMMPool.sol";
import {IDLMMHooks} from "contracts/DLMM/interfaces/IDLMMHooks.sol";
import {IDLMMRewarder} from "contracts/DLMM/interfaces/IDLMMRewarder.sol";
import {IDLMMRewarderFactory} from "contracts/DLMM/interfaces/IDLMMRewarderFactory.sol";
import {IDLMMFactory} from "contracts/DLMM/interfaces/IDLMMFactory.sol";
import {Hooks} from "contracts/DLMM/libraries/Hooks.sol";

library VoterDLMMActions {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    uint256 internal constant DURATION = 7 days;

    function setDLMMFactory(address _dlmmFactory) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        emit IVoter.DLMMFactoryChanged($.dlmmFactory, _dlmmFactory);

        $.dlmmFactory = _dlmmFactory;
    }

    function setDLMMRewarderFactory(address _dlmmRewarderFactory) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        emit IVoter.DLMMRewarderFactoryChanged($.dlmmRewarderFactory, _dlmmRewarderFactory);

        $.dlmmRewarderFactory = _dlmmRewarderFactory;
    }

    function addAuthorizedDLMMManager(address manager) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require(manager != address(0), Errors.ZERO_ADDRESS());
        require(!$.isAuthorizedDLMMManager[manager], Errors.ALREADY_ADDED(manager));

        $.isAuthorizedDLMMManager[manager] = true;
        emit IVoter.AuthorizedDLMMManagerAdded(manager);
    }

    function removeAuthorizedDLMMManager(address manager) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require($.isAuthorizedDLMMManager[manager], Errors.NOT_FOUND(manager));

        $.isAuthorizedDLMMManager[manager] = false;
        emit IVoter.AuthorizedDLMMManagerRemoved(manager);
    }

    function createDLMMRewarder(address pool) external returns (address rewarder) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require(pool != address(0), Errors.ZERO_ADDRESS());
        require($.dlmmFactory != address(0), Errors.NOT_INIT());
        require(IDLMMFactory($.dlmmFactory).isPool(pool), Errors.NOT_POOL(pool));
        require($.gaugeForPool[pool] == address(0), Errors.ACTIVE_GAUGE($.gaugeForPool[pool]));

        IDLMMPool dlmmPool = IDLMMPool(pool);
        address tokenX = address(dlmmPool.getTokenX());
        address tokenY = address(dlmmPool.getTokenY());
        require($.isWhitelisted[tokenX] && $.isWhitelisted[tokenY], Errors.BOTH_NOT_WHITELISTED());

        address feeCollector = IDLMMFactory($.dlmmFactory).feeCollector();
        require(feeCollector != address(0), Errors.NOT_INIT());
        require($.dlmmRewarderFactory != address(0), Errors.NOT_INIT());

        IDLMMFeeCollector(feeCollector).collectProtocolFees(pool);

        rewarder = IDLMMRewarderFactory($.dlmmRewarderFactory).createRewarder(pool);

        require(IDLMMRewarder(rewarder).getRewardToken() == $.ram, Errors.INVALID_CONTRACT());
        require(address(IDLMMHooks(rewarder).getLBPair()) == pool, Errors.INVALID_CONTRACT());
        require(IDLMMHooks(rewarder).isLinked(), Errors.INVALID_CONTRACT());
        require(Hooks.getHooks(dlmmPool.getLBHooksParameters()) == rewarder, Errors.INVALID_CONTRACT());
        require(Ownable(rewarder).owner() == address(this), Errors.INVALID_CONTRACT());

        address feeDistributor = IFeeDistributorFactory($.feeDistributorFactory).createFeeDistributor(feeCollector);

        $.feeDistributorForGauge[rewarder] = feeDistributor;
        $.originalFeeDistributorForGauge[rewarder] = feeDistributor;
        $.gaugeForPool[pool] = rewarder;
        $.poolForGauge[rewarder] = pool;
        $.poolForFeeDistributor[feeDistributor] = pool;
        $.lastDistro[rewarder] = getPeriod();
        $.pools.add(pool);
        $.gauges.add(rewarder);
        $.feeDistributors.add(feeDistributor);
        $.isDLMMRewarder[rewarder] = true;
        $.isAlive[rewarder] = true;

        IDLMMFactory($.dlmmFactory).setPoolGaugedProtocolShare(pool);
        IDLMMRewarder(rewarder).setDeltaBins(0, 1);

        emit IVoter.DLMMRewarderSet(rewarder, true);
        emit IVoter.GaugeCreated(rewarder, msg.sender, feeDistributor, pool);
    }

    function setDLMMRewarderDeltaBins(address rewarder, int24 deltaBinA, int24 deltaBinB) external {
        require(VoterStorage.getStorage().isDLMMRewarder[rewarder], Errors.INVALID_CONTRACT());

        IDLMMRewarder(rewarder).setDeltaBins(deltaBinA, deltaBinB);
    }

    function notifyRewarder(address rewarder, address token, uint256 amount) external {
        require(IDLMMRewarder(rewarder).getRewardToken() == token, Errors.INVALID_CONTRACT());

        IERC20(token).safeTransfer(rewarder, amount);

        uint256 remaining = IDLMMRewarder(rewarder).getRemainingRewards();
        if (remaining < DURATION) return;

        IDLMMRewarder(rewarder).setRewardPerSecond((remaining + DURATION - 1) / DURATION, DURATION);
    }

    function collectFees(address rewarder, address pool) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        address dlmmFactoryAddress = $.dlmmFactory;
        if (dlmmFactoryAddress == address(0)) return;

        IDLMMFactory dlmmFactory = IDLMMFactory(dlmmFactoryAddress);
        (,,,,, uint16 currentProtocolShare,) = IDLMMPool(pool).getStaticFeeParameters();
        uint16 defaultProtocolShare = dlmmFactory.defaultProtocolShare();
        uint16 gaugedProtocolShare = dlmmFactory.gaugedProtocolShare();

        if (currentProtocolShare == defaultProtocolShare || currentProtocolShare == gaugedProtocolShare) {
            if ($.isAlive[rewarder]) {
                dlmmFactory.setPoolGaugedProtocolShare(pool);
            } else {
                dlmmFactory.setPoolDefaultProtocolShare(pool);
            }
        }

        address feeCollector = dlmmFactory.feeCollector();
        if (feeCollector != address(0)) IDLMMFeeCollector(feeCollector).collectProtocolFees(pool);
    }

    function setKilledProtocolShare(address rewarder) external {
        _syncProtocolShare(rewarder, false);
    }

    function setRevivedProtocolShare(address rewarder) external {
        _syncProtocolShare(rewarder, true);
    }

    function _syncProtocolShare(address rewarder, bool alive) private {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        if (!$.isDLMMRewarder[rewarder] || $.dlmmFactory == address(0)) return;

        IDLMMFactory dlmmFactory = IDLMMFactory($.dlmmFactory);
        address pool = $.poolForGauge[rewarder];
        (,,,,, uint16 currentProtocolShare,) = IDLMMPool(pool).getStaticFeeParameters();
        uint16 defaultProtocolShare = dlmmFactory.defaultProtocolShare();
        uint16 gaugedProtocolShare = dlmmFactory.gaugedProtocolShare();

        if (currentProtocolShare == defaultProtocolShare || currentProtocolShare == gaugedProtocolShare) {
            if (alive) {
                dlmmFactory.setPoolGaugedProtocolShare(pool);
            } else {
                dlmmFactory.setPoolDefaultProtocolShare(pool);
            }
        }
    }

    function getPeriod() private view returns (uint256 period) {
        period = block.timestamp / 1 weeks;
    }
}
