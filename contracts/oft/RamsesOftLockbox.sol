// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RamsesOftLockbox
/// @notice LayerZero OFT adapter for the existing canonical RAM token on HyperEVM.
/// @dev RAM is locked here when bridging out and released when bridging back.
///      Deploy exactly one lockbox for the canonical RAM token.
contract RamsesOftLockbox is OFTAdapter {
    constructor(address ramsesToken, address lzEndpoint, address delegate)
        OFTAdapter(ramsesToken, lzEndpoint, delegate)
        Ownable(delegate)
    {}
}
