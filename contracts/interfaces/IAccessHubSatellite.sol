// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAccessHub} from "./IAccessHub.sol";

interface IAccessHubSatellite is IAccessHub {
    /// @notice Legacy creation selectors cannot choose the required initial protocol-fee share.
    error InitialFeeProtocolRequired();

    /// @notice Creates a CL gauge and atomically sets the pool's protocol share of swap fees.
    /// @param _pool An initialized pool belonging to the configured CL factory.
    /// @param _initialFeeProtocol Protocol share in millionths: 200_000 means 20% protocol / 80% LP.
    function createCLGauge(address _pool, uint24 _initialFeeProtocol) external returns (address gauge);
}
