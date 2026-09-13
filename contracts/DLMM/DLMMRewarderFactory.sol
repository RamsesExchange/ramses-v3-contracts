// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Errors} from "contracts/libraries/Errors.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";
import {IDLMMFactory} from "contracts/DLMM/interfaces/IDLMMFactory.sol";
import {IDLMMPool} from "contracts/DLMM/interfaces/IDLMMPool.sol";
import {IDLMMRewarderFactory} from "contracts/DLMM/interfaces/IDLMMRewarderFactory.sol";
import {DLMMRewarder} from "contracts/DLMM/DLMMRewarder.sol";

contract DLMMRewarderFactory is IDLMMRewarderFactory {
    address public override voter;
    address public override implementation;

    mapping(address pool => address rewarder) public override getRewarder;

    constructor(address _voter, address _implementation) {
        require(_voter != address(0), Errors.ZERO_ADDRESS());
        require(_implementation != address(0), Errors.ZERO_ADDRESS());
        require(_implementation.code.length != 0, Errors.INVALID_CONTRACT());

        voter = _voter;
        implementation = _implementation;

        emit Upgraded(_implementation);
    }

    function createRewarder(address pool) external override returns (address rewarder) {
        address _voter = voter;
        require(msg.sender == _voter, Errors.NOT_AUTHORIZED(msg.sender));
        require(pool != address(0), Errors.ZERO_ADDRESS());
        require(getRewarder[pool] == address(0), Errors.ACTIVE_GAUGE(getRewarder[pool]));

        IDLMMFactory dlmmFactory = IDLMMFactory(IVoter(_voter).dlmmFactory());
        require(address(dlmmFactory) != address(0), Errors.NOT_INIT());
        require(dlmmFactory.isPool(pool), Errors.NOT_POOL(pool));

        IDLMMPool dlmmPool = IDLMMPool(pool);
        rewarder = address(
            new BeaconProxy(
                address(this),
                abi.encodeWithSelector(DLMMRewarder.initialize.selector, dlmmPool, IERC20(IVoter(_voter).ram()), _voter)
            )
        );

        getRewarder[pool] = rewarder;

        dlmmFactory.setLBHooksParametersOnPair(
            dlmmPool.getTokenX(),
            dlmmPool.getTokenY(),
            dlmmPool.getBinStep(),
            DLMMRewarder(rewarder).getHooksParameters(),
            ""
        );

        emit DLMMRewarderCreated(pool, rewarder);
    }

    function setImplementation(address newImplementation) external override {
        require(msg.sender == IVoter(voter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));
        require(newImplementation != address(0), Errors.ZERO_ADDRESS());
        require(newImplementation.code.length != 0, Errors.INVALID_CONTRACT());

        if (newImplementation != implementation) {
            implementation = newImplementation;
            emit Upgraded(newImplementation);
        }
    }

    function setVoter(address newVoter) external override {
        address oldVoter = voter;

        require(msg.sender == IVoter(oldVoter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));
        require(newVoter != address(0), Errors.ZERO_ADDRESS());

        voter = newVoter;
        emit VoterChanged(oldVoter, newVoter);
    }
}
