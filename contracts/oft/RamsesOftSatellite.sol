// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RamsesOftSatellite
/// @notice The RAM ERC20 deployed on each satellite chain.
/// @dev Stock LayerZero OFT behavior burns RAM on send and mints RAM on an
///      authenticated receive. There is no externally callable mint function.
contract RamsesOftSatellite is OFT {
    constructor(address lzEndpoint, address delegate) OFT("Ramses", "RAM", lzEndpoint, delegate) Ownable(delegate) {}
}
