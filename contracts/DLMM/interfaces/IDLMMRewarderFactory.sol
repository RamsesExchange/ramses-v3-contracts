// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IDLMMRewarderFactory {
    event DLMMRewarderCreated(address indexed pool, address indexed rewarder);
    event Upgraded(address indexed implementation);
    event VoterChanged(address indexed oldVoter, address indexed newVoter);

    function voter() external view returns (address);

    function implementation() external view returns (address);

    function getRewarder(address pool) external view returns (address);

    function createRewarder(address pool) external returns (address rewarder);

    function setImplementation(address newImplementation) external;

    function setVoter(address newVoter) external;
}
