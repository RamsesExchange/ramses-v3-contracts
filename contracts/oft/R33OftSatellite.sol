// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title R33OftSatellite
/// @notice The r33 ERC20 deployed on each satellite chain.
/// @dev Stock LayerZero OFT behavior burns r33 on send and mints r33 on an
///      authenticated receive. There is no externally callable mint function.
contract R33OftSatellite is OFT {
    constructor(address lzEndpoint, address delegate)
        OFT("xRAM Liquid Staking Token", "r33", lzEndpoint, delegate)
        Ownable(delegate)
    {}
}
